import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';

/// Starts llama-server only when the student chooses to load a downloaded model.
class LlamaService {
  Process? _process;
  int? _port;
  String? _executable;
  // Rough character budget for chat history, so the prompt fits the context window.
  int _historyBudget = 6000;

  bool get running => _process != null && _port != null;
  String? get executablePath => _executable;

  Future<String> _modelDir() async {
    final base = Platform.isWindows
        ? Platform.environment['APPDATA']
        : (await getApplicationSupportDirectory()).path;
    final root = base ?? (await getApplicationSupportDirectory()).path;
    return '$root${Platform.pathSeparator}StudyMate${Platform.pathSeparator}models';
  }

  Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  Future<void> start({required bool lowMemory}) async {
    if (!Platform.isWindows) {
      throw Exception('The packaged local AI server is currently configured for Windows.');
    }
    _historyBudget = lowMemory ? 3500 : 6000;
    final exe = '${File(Platform.resolvedExecutable).parent.path}'
        '${Platform.pathSeparator}bin${Platform.pathSeparator}llama-server.exe';
    if (!await File(exe).exists()) {
      throw Exception(
          "llama-server.exe is missing. Place llama-server.exe and its DLL files in the app's bin folder.");
    }
    final dir = Directory(await _modelDir());
    final files = await dir
        .list()
        .where((e) => e is File && e.path.toLowerCase().endsWith('.gguf'))
        .cast<File>()
        .toList();
    final models = files.where((f) => !f.path.toLowerCase().contains('mmproj')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final projectors = files.where((f) => f.path.toLowerCase().contains('mmproj')).toList();
    if (models.isEmpty) throw Exception('Download a model first from the Models screen.');
    final model = models.first;
    final mmproj = projectors.isEmpty ? null : projectors.first;

    final port = await _freePort();
    final cores = Platform.numberOfProcessors.clamp(1, 8);
    final args = [
      '-m', model.path,
      if (!lowMemory && mmproj != null) ...['--mmproj', mmproj.path],
      '--jinja',
      '-c', lowMemory ? '2048' : '4096',
      '-t', '$cores',
      '--port', '$port',
      '--host', '127.0.0.1',
      '--no-webui',
    ];
    _process = await Process.start(exe, args, runInShell: false);
    _port = port;
    _executable = exe;
    _process!.exitCode.then((_) {
      _process = null;
      _port = null;
    });

    final until = DateTime.now().add(const Duration(minutes: 2));
    while (DateTime.now().isBefore(until)) {
      if (_process == null) {
        throw Exception('The local AI server stopped while starting. Check Windows antivirus and available RAM.');
      }
      try {
        final r = await http
            .get(Uri.parse('http://127.0.0.1:$port/health'))
            .timeout(const Duration(seconds: 2));
        if (r.statusCode == 200) return;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    await stop();
    throw Exception('The local AI server took too long to start. Try Low-memory mode or close some apps.');
  }

  /// Keeps the newest messages that fit the budget. Older turns are dropped
  /// so long chats do not overflow the model's context window.
  List<Map<String, String>> _recentHistory(List<Map<String, String>> history) {
    var total = 0;
    final kept = <Map<String, String>>[];
    for (final m in history.reversed) {
      var content = m['content'] ?? '';
      if (content.length > _historyBudget) {
        content = content.substring(content.length - _historyBudget);
      }
      total += content.length;
      if (total > _historyBudget && kept.isNotEmpty) break;
      kept.insert(0, {'role': m['role'] ?? 'user', 'content': content});
    }
    return kept;
  }

  Future<String> ask(List<Map<String, String>> history, Map<String, dynamic> profile) async {
    if (!running) throw Exception('Load your model from the Models screen first.');
    final studentContext =
        'Student name: ${profile['name'] ?? 'Student'}, class: ${profile['class'] ?? 'not specified'}, '
        'board: ${profile['board'] ?? 'not specified'}, subjects: ${profile['subjects'] ?? 'not specified'}.';
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': '$tutorSystemPrompt $studentContext'},
      ..._recentHistory(history),
    ];
    final response = await http
        .post(
          Uri.parse('http://127.0.0.1:$_port/v1/chat/completions'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'messages': messages,
            'stream': false,
            'temperature': 0.7,
            'top_p': 0.8,
            'top_k': 20,
            'repeat_penalty': 1.1,
            'max_tokens': 512,
          }),
        )
        .timeout(const Duration(minutes: 3));
    if (response.statusCode != 200) {
      throw Exception('StudyMate AI could not answer (${response.statusCode}). Try again.');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final raw = data['choices']?[0]?['message']?['content']?.toString() ??
        'I could not form an answer. Please try again.';
    return raw.replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '').trim();
  }

  Future<void> stop() async {
    final p = _process;
    _process = null;
    _port = null;
    if (p != null) {
      p.kill(ProcessSignal.sigterm);
      try {
        await p.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        p.kill();
      }
    }
  }

  @visibleForTesting
  Future<void> dispose() => stop();
}
