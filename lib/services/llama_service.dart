import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';

/// Runs the local model through llama-server. Nothing leaves this PC.
class LlamaService {
  Process? _process;
  int? _port;
  String? _executable;
  bool _vision = false;
  int _contextSize = 6144;
  /// 'length' means the last reply was cut off by the token limit.
  String? lastFinishReason;
  int _historyBudget = 6000;
  final http.Client _client = http.Client();

  bool get running => _process != null && _port != null;

  /// True only when the vision file loaded, so images can be analysed.
  bool get visionReady => running && _vision;

  String? get executablePath => _executable;

  /// Removes any reasoning block the model may emit before its answer.
  static String clean(String text) =>
      text.replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '').trim();

  Future<String> _modelDir() async {
    final base = Platform.isWindows
        ? Platform.environment['APPDATA']
        : (await getApplicationSupportDirectory()).path;
    final root = base ?? (await getApplicationSupportDirectory()).path;
    return '$root${Platform.pathSeparator}StudyMate${Platform.pathSeparator}models';
  }

  static int _modelRank(String path) {
    final p = path.toLowerCase();
    if (p.contains('q4_k_m')) return 0;
    if (p.contains('q4_')) return 1;
    return 2;
  }

  Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  Future<void> start({required bool lowMemory}) async {
    if (!Platform.isWindows && !Platform.isLinux) {
      throw Exception('The local AI server is supported on Windows and Linux.');
    }
    _historyBudget = lowMemory ? 2000 : 3000;
    _contextSize = lowMemory ? 4096 : 6144;
    final binName = Platform.isWindows ? 'llama-server.exe' : 'llama-server';
    var exe = '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}bin${Platform.pathSeparator}$binName';
    if (!await File(exe).exists() && !Platform.isWindows) {
      final which = await Process.run('which', ['llama-server']);
      if (which.exitCode == 0) exe = (which.stdout as String).trim();
    }
    if (!await File(exe).exists()) {
      throw Exception(
          'llama-server is missing. Put $binName in the app bin folder, or install llama.cpp so it is on the PATH.');
    }
    final dir = Directory(await _modelDir());
    if (!await dir.exists()) {
      throw Exception('Download a model first from the Models screen.');
    }
    final files = await dir
        .list()
        .where((e) => e is File && e.path.toLowerCase().endsWith('.gguf'))
        .cast<File>()
        .toList();
    final models = files.where((f) => !f.path.toLowerCase().contains('mmproj')).toList()
      ..sort((a, b) => _modelRank(a.path).compareTo(_modelRank(b.path)));
    final projectors = files.where((f) => f.path.toLowerCase().contains('mmproj')).toList()
      ..sort((a, b) => (a.path.toLowerCase().contains('q8_0') ? 0 : 1)
          .compareTo(b.path.toLowerCase().contains('q8_0') ? 0 : 1));
    if (models.isEmpty) throw Exception('Download a model first from the Models screen.');
    final model = models.first;
    final mmproj = projectors.isEmpty ? null : projectors.first;

    final port = await _freePort();
    final cores = (Platform.numberOfProcessors ~/ 2).clamp(2, 8);
    final useVision = !lowMemory && mmproj != null;
    final args = [
      '-m', model.path,
      if (useVision) ...['--mmproj', mmproj.path],
      '--jinja',
      '-c', '$_contextSize',
      '-t', '$cores',
      '-np', '1',
      '--port', '$port',
      '--host', '127.0.0.1',
      '--no-webui',
    ];
    _process = await Process.start(exe, args, runInShell: false);
    _port = port;
    _vision = useVision;
    _executable = exe;
    _process!.exitCode.then((_) {
      _process = null;
      _port = null;
      _vision = false;
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

  /// Keeps the newest messages that fit the budget so long chats do not overflow the context.
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

  static const _voiceInstruction =
      ' Voice mode: answer in at most three short, plain sentences with no lists or formatting, because the answer will be read aloud.';

  static const _multiQuestionInstruction =
      ' The student has several questions. Answer every numbered question in order, completely, and do not stop early.';

  /// Counts questions: numbered or lettered items, or question marks, whichever is higher.
  static int questionCount(String text) {
    final numbered = RegExp(r'^\s*(\d{1,3}|[a-zA-Z])[\.\)]\s', multiLine: true)
        .allMatches(text)
        .length;
    final marks = '?'.allMatches(text).length;
    final n = numbered > marks ? numbered : marks;
    return n < 1 ? 1 : n;
  }

  /// Chooses the reply length from the question, so long question papers are not cut short.
  static int replyBudget({
    required String question,
    required int promptChars,
    required bool thinker,
    required int contextSize,
  }) {
    final n = questionCount(question);
    final words = question.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    final wanted = (thinker ? 500 : 300) + n * (thinker ? 220 : 140) + words ~/ 6;
    final room = contextSize - promptChars ~/ 3 - 128;
    var result = wanted < room ? wanted : room;
    if (result < 256) result = 256;
    if (result > 3500) result = 3500;
    return result;
  }

  static const _thinkerInstruction =
      ' Thinker mode is on: first reason step by step in a short section headed "Reasoning", '
      'then give the final result under the heading "Answer:".';

  /// Streams the answer token by token. [imageDataUri] is attached to the latest user message.
  Stream<String> askStream(
    List<Map<String, String>> history,
    Map<String, dynamic> profile, {
    String? imageDataUri,
    bool thinker = false,
    bool voice = false,
  }) async* {
    if (!running) throw Exception('Load your model from the Models screen first.');
    if (imageDataUri != null && !_vision) {
      throw Exception('Image analysis is off. Turn off Low-memory mode in Models and load the model again.');
    }

    lastFinishReason = null;
    final studentContext =
        'Student name: ${profile['name'] ?? 'Student'}, class: ${profile['class'] ?? 'not specified'}, '
        'education system: ${profile['education'] ?? 'not specified'}, '
        'board: ${profile['board'] ?? 'not specified'}, subjects: ${profile['subjects'] ?? 'not specified'}, '
        'exam goal: ${profile['goals'] ?? 'not specified'}.';

    final recent = _recentHistory(history);
    final lastUser = recent.isEmpty ? '' : (recent.last['content'] ?? '');
    final qCount = questionCount(lastUser);
    final promptChars = recent.fold<int>(0, (n, m) => n + (m['content'] ?? '').length);
    final maxTokens = replyBudget(
      question: lastUser,
      promptChars: promptChars,
      thinker: thinker,
      contextSize: _contextSize,
    );
    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': '$tutorSystemPrompt $studentContext'
            '${thinker ? _thinkerInstruction : ''}${voice ? _voiceInstruction : (qCount > 1 ? _multiQuestionInstruction : '')}',
      },
    ];
    for (var i = 0; i < recent.length; i++) {
      final m = recent[i];
      final isLatest = i == recent.length - 1;
      if (isLatest && imageDataUri != null && m['role'] == 'user') {
        messages.add({
          'role': 'user',
          'content': [
            {'type': 'image_url', 'image_url': {'url': imageDataUri}},
            {'type': 'text', 'text': m['content'] ?? ''},
          ],
        });
      } else {
        messages.add({'role': m['role'] ?? 'user', 'content': m['content'] ?? ''});
      }
    }

    final request = http.Request('POST', Uri.parse('http://127.0.0.1:$_port/v1/chat/completions'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'messages': messages,
        'stream': true,
        'temperature': 0.7,
        'top_p': 0.8,
        'top_k': 20,
        'repeat_penalty': 1.1,
        'max_tokens': voice && maxTokens > 160 ? 160 : maxTokens,
      });

    final response = await _client.send(request).timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw Exception('StudyMate V1 could not answer (error ${response.statusCode}). Try again.');
    }

    final lines = response.stream.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      if (payload == '[DONE]') break;
      final json = jsonDecode(payload) as Map<String, dynamic>;
      final choices = json['choices'] as List?;
      if (choices == null || choices.isEmpty) continue;
      final reason = (choices.first as Map)['finish_reason'];
      if (reason != null) lastFinishReason = reason.toString();
      final delta = (choices.first as Map)['delta'] as Map?;
      final piece = delta?['content']?.toString() ?? '';
      if (piece.isNotEmpty) yield piece;
    }
  }

  Future<void> stop() async {
    final p = _process;
    _process = null;
    _port = null;
    _vision = false;
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
  Future<void> dispose() async {
    await stop();
    _client.close();
  }
}
