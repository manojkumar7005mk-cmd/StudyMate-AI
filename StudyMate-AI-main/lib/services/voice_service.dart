import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Voice input and output, kept on this PC.
/// Linux: arecord (microphone), whisper-cli (speech to text), espeak-ng (voice).
/// Windows: record package (microphone), whisper-cli.exe (speech to text), system voice (flutter_tts).
/// Voice choices the student makes. Saved on this PC.
class VoicePrefs {
  static String language = 'en'; // 'en' or 'ta'
  static String variant = 'female'; // 'female' or 'male'
  static double speed = 1.0; // 0.7 to 1.4

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    language = p.getString('voice_lang') ?? 'en';
    variant = p.getString('voice_variant') ?? 'female';
    speed = p.getDouble('voice_speed') ?? 1.0;
  }

  static Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('voice_lang', language);
    await p.setString('voice_variant', variant);
    await p.setDouble('voice_speed', speed);
  }
}

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

  /// Whisper English model for English, and the multilingual model (which knows Tamil) for Tamil.
  Future<String?> _whisperModel() async {
    final names = VoicePrefs.language == 'ta'
        ? ['ggml-base.bin']
        : ['ggml-base.en.bin', 'ggml-base.bin'];
    final dir = await _modelDir();
    for (final n in names) {
      final f = File('$dir${Platform.pathSeparator}$n');
      if (f.existsSync()) return f.path;
    }
    if (!Platform.isWindows) {
      final home = Platform.environment['HOME'] ?? '';
      for (final n in names) {
        final f = File('$home/models/$n');
        if (f.existsSync()) return f.path;
      }
    }
    return null;
  }

  /// Returns a message explaining what is missing, or null when voice can run.
  Future<String?> setupProblem() async {
    if (Platform.isWindows) return null;
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

    throw Exception('Voice input is not available on Windows in this build yet. Voice input works on Linux.');
  }

  /// Converts a recorded WAV file to text with whisper.cpp.
  Future<String> transcribe(String wavPath) async {
    if (wavPath.isEmpty) return '';
    final tool = await _findTool('whisper-cli');
    final model = await _whisperModel();
    if (tool == null || model == null) {
      throw Exception('Speech-to-text is not set up.');
    }
    final r = await Process.run(tool, ['-m', model, '-f', wavPath, '-nt', '-np', '-l', VoicePrefs.language]);
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
        final espeakVoice = VoicePrefs.language == 'ta'
            ? 'ta'
            : (VoicePrefs.variant == 'male' ? 'en+m3' : 'en+f3');
        final wpm = (175 * VoicePrefs.speed).round().toString();
        _speakProc = await Process.start('espeak-ng', ['-v', espeakVoice, '-s', wpm, text]);
        await _speakProc!.exitCode;
        _speakProc = null;
      } else if (_tts != null) {
        await _tts.setLanguage(VoicePrefs.language == 'ta' ? 'ta-IN' : 'en-US');
        await _tts.setSpeechRate((0.5 * VoicePrefs.speed).clamp(0.2, 1.0).toDouble());
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


  static const whisperModelUrl =
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin';

  /// Downloads the Whisper base English speech model (about 150 MB) into the models folder.
  Future<String> downloadWhisperModel({String lang = 'en'}) async {
    final dir = Directory(await _modelDir());
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final fileName = lang == 'ta' ? 'ggml-base.bin' : 'ggml-base.en.bin';
    final modelUrl = lang == 'ta'
        ? 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin'
        : whisperModelUrl;
    final dest = File('${dir.path}${Platform.pathSeparator}$fileName');
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(modelUrl));
      req.headers.set('User-Agent', 'StudyMate-AI');
      final res = await req.close();
      if (res.statusCode != 200) {
        throw Exception('Voice model download failed (error ${res.statusCode}).');
      }
      final tmp = File('${dest.path}.part');
      await res.pipe(tmp.openWrite());
      if (dest.existsSync()) dest.deleteSync();
      tmp.renameSync(dest.path);
      return 'Voice model saved to ${dest.path}';
    } finally {
      client.close(force: true);
    }
  }

  /// Transcribes an audio file. WAV is used directly; other formats are converted with ffmpeg on Linux.
  Future<String> transcribeAny(String path) async {
    if (path.toLowerCase().endsWith('.wav')) return transcribe(path);
    if (!Platform.isLinux) {
      throw Exception('Convert this audio file to WAV first. Automatic conversion works on Linux.');
    }
    final ffmpeg = await _findTool('ffmpeg');
    if (ffmpeg == null) {
      throw Exception('ffmpeg is missing. Install ffmpeg, or convert the file to WAV.');
    }
    final tmp = await getTemporaryDirectory();
    final out = '${tmp.path}${Platform.pathSeparator}studymate_import.wav';
    final r = await Process.run(ffmpeg, ['-y', '-i', path, '-ar', '16000', '-ac', '1', out]);
    if (r.exitCode != 0) throw Exception('Could not convert this audio file.');
    return transcribe(out);
  }

  Future<bool> speechModelInstalled() async => (await _whisperModel()) != null;

  Future<void> deleteSpeechModel() async {
    final path = await _whisperModel();
    if (path != null) File(path).deleteSync();
  }

  Future<bool> speechToolInstalled() async => (await _findTool('whisper-cli')) != null;

  /// Listens for [seconds] and returns the recognised words.
  /// Windows uses the built-in Windows speech recognizer. Linux records and uses Whisper.
  Future<String> listenOnce(int seconds) async {
    if (Platform.isWindows) return _windowsDictate(seconds);
    final wav = await recordSeconds(seconds);
    return transcribe(wav);
  }

  Future<String> _windowsDictate(int seconds) async {
    final tmp = await getTemporaryDirectory();
    final script = File('${tmp.path}${Platform.pathSeparator}studymate_dictate.ps1');
    script.writeAsStringSync(
      _dictateScript
          .replaceAll('SECONDS', '$seconds')
          .replaceAll('LANG', VoicePrefs.language == 'ta' ? 'ta-IN' : 'en-US'),
    );
    final r = await Process.run(
      'powershell',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script.path],
    );
    if (r.exitCode != 0) {
      throw Exception(
        'Windows speech recognition failed. Turn on speech recognition in Windows Settings, '
        'under Time & language > Speech, and install the English language pack. ${r.stderr}'.trim(),
      );
    }
    return (r.stdout as String).replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static const _dictateScript = r'''
Add-Type -AssemblyName System.Speech
$engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine (New-Object System.Globalization.CultureInfo('LANG'))
$engine.SetInputToDefaultAudioDevice()
$engine.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
$result = $engine.Recognize([TimeSpan]::FromSeconds(SECONDS))
if ($result) { Write-Output $result.Text }
''';

  void dispose() {
    speaking.dispose();
  }
}
