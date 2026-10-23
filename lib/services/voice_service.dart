import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Voice input and output, kept on this PC.
/// Linux: arecord (microphone), whisper-cli (speech to text), espeak-ng (voice).
/// Windows: record package (microphone), whisper-cli.exe (speech to text), system voice (flutter_tts).
class VoiceService {
  final ValueNotifier<bool> speaking = ValueNotifier<bool>(false);
  final FlutterTts? _tts = Platform.isWindows ? FlutterTts() : null;
  Process? _recordProc;
  Process? _speakProc;

  Future<String> _modelDir() async {
    final base = Platform.isWindows
        ? Platform.environment['APPDATA']
        : (await getApplicationSupportDirectory()).path;
    final root = base ?? (await getApplicationSupportDirectory()).path;
    return '$root${Platform.pathSeparator}StudyMate${Platform.pathSeparator}models';
  }

  /// Looks in the app's bin folder first, then on the system PATH (Linux).
  Future<String?> _findTool(String name) async {
    final exeName = Platform.isWindows ? '$name.exe' : name;
    final local = File(
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}bin${Platform.pathSeparator}$exeName',
    );
    if (await local.exists()) return local.path;
    if (Platform.isWindows) return null;
    final r = await Process.run('which', [name]);
    if (r.exitCode == 0) {
      final found = (r.stdout as String).trim();
      if (found.isNotEmpty) return found;
    }
    return null;
  }

  Future<String?> _whisperModel() async {
    final dir = await _modelDir();
    final inModels = File('$dir${Platform.pathSeparator}ggml-base.en.bin');
    if (await inModels.exists()) return inModels.path;
    if (!Platform.isWindows) {
      final home = Platform.environment['HOME'] ?? '';
      final inHome = File('$home/models/ggml-base.en.bin');
      if (await inHome.exists()) return inHome.path;
    }
    return null;
  }

  /// Returns a message explaining what is missing, or null when voice can run.
  Future<String?> setupProblem() async {
    if (await _findTool('whisper-cli') == null) {
      return 'Speech-to-text is not installed. Install whisper.cpp (whisper-cli) first.';
    }
    if (await _whisperModel() == null) {
      return 'Speech model missing. Put ggml-base.en.bin in the StudyMate models folder or in ~/models.';
    }
    if (Platform.isLinux && await _findTool('arecord') == null) {
      return 'Microphone recorder missing. Install alsa-utils (arecord).';
    }
    return null;
  }

  /// Records [seconds] of speech and returns the WAV file path, or '' if stopped early.
  Future<String> recordSeconds(int seconds) async {
    final tmp = await getTemporaryDirectory();
    final path = '${tmp.path}${Platform.pathSeparator}studymate_voice.wav';

    if (Platform.isLinux) {
      final arecord = await _findTool('arecord') ?? 'arecord';
      _recordProc = await Process.start(arecord, [
        '-q', '-d', '$seconds', '-f', 'S16_LE', '-r', '16000', '-c', '1', path,
      ]);
      final code = await _recordProc!.exitCode;
      _recordProc = null;
      return code == 0 ? path : '';
    }

    final rec = AudioRecorder();
    try {
      if (!await rec.hasPermission()) {
        throw Exception('Microphone permission is off. Allow microphone access in Windows Settings.');
      }
      await rec.start(
        RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1),
        path: path,
      );
      await Future<void>.delayed(Duration(seconds: seconds));
      final out = await rec.stop();
      return out ?? '';
    } finally {
      await rec.dispose();
    }
  }

  /// Converts a recorded WAV file to text with whisper.cpp.
  Future<String> transcribe(String wavPath) async {
    if (wavPath.isEmpty) return '';
    final tool = await _findTool('whisper-cli');
    final model = await _whisperModel();
    if (tool == null || model == null) {
      throw Exception('Speech-to-text is not set up.');
    }
    final r = await Process.run(tool, ['-m', model, '-f', wavPath, '-nt', '-np', '-l', 'en']);
    if (r.exitCode != 0) {
      throw Exception('Speech recognition failed: ${r.stderr}'.trim());
    }
    final text = (r.stdout as String).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.contains('BLANK_AUDIO') || text.contains('(silence)')) return '';
    return text;
  }

  /// Reads text aloud and returns when speech has finished or been stopped.
  Future<void> speakAndWait(String text) async {
    if (text.trim().isEmpty) return;
    speaking.value = true;
    try {
      if (Platform.isLinux) {
        _speakProc = await Process.start('espeak-ng', [text]);
        await _speakProc!.exitCode;
        _speakProc = null;
      } else if (_tts != null) {
        await _tts.setLanguage('en-US');
        await _tts.awaitSpeakCompletion(true);
        await _tts.speak(text);
      }
    } catch (_) {
      // Voice output is optional. The answer is still shown in the chat.
    } finally {
      speaking.value = false;
    }
  }

  Future<void> stopSpeak() async {
    _speakProc?.kill();
    _speakProc = null;
    await _tts?.stop();
    speaking.value = false;
  }

  Future<void> stopAll() async {
    _recordProc?.kill();
    _recordProc = null;
    await stopSpeak();
  }

  /// Shortens an answer for speech: removes formatting and keeps the first few sentences.
  static String spokenPart(String text) {
    var t = text.replaceAll(RegExp(r'[*#`_>]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length > 500) {
      t = t.substring(0, 500);
      final end = t.lastIndexOf('.');
      if (end > 100) t = t.substring(0, end + 1);
    }
    return t;
  }

  void dispose() {
    speaking.dispose();
  }
}
