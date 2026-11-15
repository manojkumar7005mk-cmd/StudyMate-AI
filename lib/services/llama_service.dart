import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import '../core/identity.dart';
import 'model_manager.dart';

/// Runs the local model through llama-server. Nothing leaves this PC.
class LlamaService {
  Process? _process;
  int? _port;
  String? _executable;
  bool _vision = false;
  final List<String> _log = [];
  int _contextSize = 6144;
  /// 'length' means the last reply was cut off by the token limit.
  String? lastFinishReason;
  int _historyBudget = 6000;
  final http.Client _client = http.Client();
  bool _stopping = false;
  int? _exitCode;

  /// Set when the engine exits on its own (crash or out of memory). Shown on the Live voice screen.
  String? lastCrash;

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
    if (running) return;
    _stopping = false;
    lastCrash = null;
    _exitCode = null;
    _historyBudget = lowMemory ? 2000 : 3000;
    final savedCtx = await ModelManager.contextSize();
    _contextSize = lowMemory && savedCtx > 4096 ? 4096 : savedCtx;
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
    final active = await ModelManager.activeFiles();
    if (active == null) {
      throw Exception('Choose a model in Models, download it, then press Load model.');
    }
    final model = File(active.model);
    final mmproj = active.vision == null ? null : File(active.vision!);

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
    // Zip and tar downloads can lose the execute bit, and Linux needs the bin folder
    // on the library path so llama-server finds the libraries shipped beside it.
    final binDir = File(exe).parent.path;
    Map<String, String>? env;
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', exe]);
      env = {'LD_LIBRARY_PATH': '$binDir:${Platform.environment['LD_LIBRARY_PATH'] ?? ''}'};
    }
    final proc = await Process.start(
      exe,
      args,
      runInShell: false,
      workingDirectory: binDir,
      environment: env,
      includeParentEnvironment: true,
    );
    _process = proc;
    _log.clear();
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_addLog);
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(_addLog);
    _port = port;
    _vision = useVision;
    _executable = exe;
    proc.exitCode.then((code) {
      if (!identical(_process, proc)) return; // we stopped it on purpose
      _exitCode = code;
      _process = null;
      _port = null;
      _vision = false;
      if (!_stopping) {
        lastCrash = 'The AI engine stopped (exit code $code). ${_exitHint(code)} ${_logTail()}';
      }
    });

    final until = DateTime.now().add(const Duration(minutes: 2));
    while (DateTime.now().isBefore(until)) {
      if (_process == null) {
        throw Exception(_startError('The AI engine stopped while starting.'));
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
    throw Exception(_startError('The AI engine took too long to start.'));
  }

  void _addLog(String line) {
    if (line.trim().isEmpty) return;
    _log.add(line.trim());
    if (_log.length > 40) _log.removeAt(0);
  }

  String _logTail() {
    final tail = _log.length > 12 ? _log.sublist(_log.length - 12) : List<String>.from(_log);
    if (tail.isEmpty) return 'No output was received from the engine.';
    var text = tail.join(' | ');
    if (text.length > 700) text = text.substring(text.length - 700);
    return 'Engine said: $text';
  }

  /// Adds the engine's last messages to a startup error, so the real cause is visible.
  String _startError(String head) {
    final code = _exitCode;
    final codeText = code == null ? '' : ' (exit code $code) ${_exitHint(code)}';
    return '$head$codeText ${_logTail()}';
  }

  /// Turns a Windows/Linux exit code into a plain explanation.
  static String _exitHint(int code) {
    switch (code) {
      case -1073741795: // 0xC000001D
      case -4: // SIGILL
      case 132:
        return 'This CPU cannot run this engine build (illegal instruction). Use the engine built without AVX-512.';
      case -1073741819: // 0xC0000005
      case -11: // SIGSEGV
      case 139:
        return 'The engine crashed while reading the model. The model file may be damaged, or memory ran out.';
      case -1073741515: // 0xC0000135
      case -1073741701: // 0xC000007B
        return 'A required DLL is missing next to llama-server.exe.';
      case -1073740791: // 0xC0000409
        return 'The engine aborted (often a model/engine version mismatch or low memory).';
      default:
        return '';
    }
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

  static const _referenceInstruction =
      ' Answer using the REFERENCE EXCERPTS from the student\'s textbooks. Use only facts found in those excerpts, cite each fact as [book, page], and if the excerpts do not contain the answer, say clearly that the book does not cover it. Do not guess.';

  static const _voiceInstruction =
      ' Voice mode: answer in at most two short, plain sentences with no lists or formatting, because the answer will be read aloud.';

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
    final wanted = (thinker ? 500 : 300) + n * (thinker ? 220 : 140) + words ~/ 2;
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
    bool tamil = false,
    String? references,
    bool deepThink = false,
  }) async* {
    if (!running) throw Exception(lastCrash ?? 'Load your model from the Models screen first.');
    if (imageDataUri != null && !_vision) {
      throw Exception('Image analysis is off. Turn off Low-memory mode in Models and load the model again.');
    }

    lastFinishReason = null;
    if (voice) {
      yield* _voiceStream(history, tamil: tamil);
      return;
    }
    final studentContext =
        'Student name: ${profile['name'] ?? 'Student'}, class: ${profile['class'] ?? 'not specified'}, '
        'education system: ${profile['education'] ?? 'not specified'}, '
        'board: ${profile['board'] ?? 'not specified'}, subjects: ${profile['subjects'] ?? 'not specified'}, '
        'exam goal: ${profile['goals'] ?? 'not specified'}.';

    final recent = _recentHistory(history);
    final lastUser = recent.isEmpty ? '' : (recent.last['content'] ?? '');
    final qCount = questionCount(lastUser);
    final promptChars = recent.fold<int>(0, (n, m) => n + (m['content'] ?? '').length) + (references?.length ?? 0);
    final maxTokens = replyBudget(
      question: lastUser,
      promptChars: promptChars,
      thinker: thinker,
      contextSize: _contextSize,
    );
    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': '$studyMateSystemPrompt $studentContext'
            '${thinker ? _thinkerInstruction : ''}${voice ? _voiceInstruction : (qCount > 1 ? _multiQuestionInstruction : '')}'
            '${references == null ? '' : '$_referenceInstruction\n\nREFERENCE EXCERPTS:\n$references'}',
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
        'chat_template_kwargs': {'enable_thinking': deepThink},
        'max_tokens': voice && maxTokens > 90 ? 90 : maxTokens,
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

  static const _voiceSystemEnglish =
      'You are StudyMate, a friendly tutor talking with a student out loud. '
      'Reply in one or two short, plain, simple sentences. Never use lists, markdown or symbols. Be quick.';

  static const _voiceSystemTamil =
      'You are StudyMate, a friendly tutor talking with a student out loud. '
      'Reply only in Tamil script, in one or two short, simple sentences. Never use lists, markdown or symbols. Be quick.';

  static String _tail(String text, int n) => text.length > n ? text.substring(text.length - n) : text;

  /// Short, fast spoken replies: a tiny system prompt, the last few turns only,
  /// no textbook excerpts, no profile block and no thinking step.
  Stream<String> _voiceStream(List<Map<String, String>> history, {required bool tamil}) async* {
    final turns = history.length > 4 ? history.sublist(history.length - 4) : history;
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': tamil ? _voiceSystemTamil : _voiceSystemEnglish},
      for (final m in turns) {'role': m['role'] ?? 'user', 'content': _tail(m['content'] ?? '', 240)},
    ];
    final request = http.Request('POST', Uri.parse('http://127.0.0.1:$_port/v1/chat/completions'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'messages': messages,
        'stream': true,
        'temperature': 0.6,
        'top_p': 0.9,
        'max_tokens': tamil ? 60 : 50,
        'chat_template_kwargs': {'enable_thinking': false},
        'cache_prompt': true,
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
      final delta = (choices.first as Map)['delta'] as Map?;
      final piece = delta?['content']?.toString() ?? '';
      if (piece.isNotEmpty) yield piece;
    }
  }

  Future<void> stop() async {
    _stopping = true;
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
