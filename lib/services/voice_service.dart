import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';

/// Voice the tutor speaks with.
enum VoiceGender { female, male }

/// Language the student speaks and hears.
enum VoiceLanguage { english, tamil }

/// Voice input and output, kept on this PC.
/// Linux: arecord (microphone), whisper-cli (speech to text), espeak-ng (voice).
/// Windows: built-in speech recognition (System.Speech), system voices (flutter_tts).
class VoiceService {
  final ValueNotifier<bool> speaking = ValueNotifier<bool>(false);
  final FlutterTts? _tts = Platform.isWindows ? FlutterTts() : null;
  Process? _recordProc;
  Process? _speakProc;

  /// Changed from the Live voice screen. Applies from the next answer.
  VoiceGender gender = VoiceGender.female;
  VoiceLanguage language = VoiceLanguage.english;

  bool get isTamil => language == VoiceLanguage.tamil;

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

  /// English uses the small English model when present. Tamil needs a multilingual model,
  /// because the English-only file cannot write Tamil.
  Future<String?> _whisperModel({bool tamil = false}) async {
    final dirs = <String>[await _modelDir()];
    if (!Platform.isWindows) dirs.add('${Platform.environment['HOME'] ?? ''}/models');
    final names = tamil
        ? const ['ggml-small.bin', 'ggml-base.bin']
        : const ['ggml-base.en.bin', 'ggml-small.en.bin', 'ggml-small.bin', 'ggml-base.bin'];
    for (final dir in dirs) {
      for (final name in names) {
        final f = File('$dir${Platform.pathSeparator}$name');
        if (await f.exists()) return f.path;
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
    if (await _whisperModel(tamil: isTamil) == null) {
      return isTamil
          ? 'Tamil needs the multilingual speech model ggml-small.bin. Put it in the StudyMate models folder or in ~/models.'
          : 'Speech model missing. Put ggml-base.en.bin in the StudyMate models folder or in ~/models.';
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

    throw Exception('Recording is not used on Windows. Windows listens with its built-in speech recognizer.');
  }

  /// Converts a recorded WAV file to text with whisper.cpp.
  Future<String> transcribe(String wavPath) async {
    if (wavPath.isEmpty) return '';
    final tool = await _findTool('whisper-cli');
    final model = await _whisperModel(tamil: isTamil);
    if (tool == null || model == null) {
      throw Exception('Speech-to-text is not set up.');
    }
    final lang = isTamil ? 'ta' : 'en';
    final r = await Process.run(
      tool,
      ['-m', model, '-f', wavPath, '-nt', '-np', '-l', lang],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (r.exitCode != 0) {
      throw Exception('Speech recognition failed: ${r.stderr}'.trim());
    }
    final text = (r.stdout as String).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.contains('BLANK_AUDIO') || text.contains('(silence)')) return '';
    return text;
  }

  // ---------- Speaking ----------

  /// Reads text aloud and returns when speech has finished or been stopped.
  Future<void> speakAndWait(String text) async {
    if (text.trim().isEmpty) return;
    speaking.value = true;
    try {
      if (Platform.isLinux) {
        final proc = await Process.start('espeak-ng', [
          '-v', _espeakVoice(),
          '-p', '${_espeakPitch()}',
          '-s', '165', // speed (words per minute)
          '-a', '200', // loudness: 200 is the maximum
          '-b', '1', // input text is UTF-8, so Tamil script works
          '--stdin', // text goes through stdin, so it cannot be read as an option
        ]);
        _speakProc = proc;
        proc.stdin.write(text);
        await proc.stdin.close();
        proc.stdout.drain<void>();
        proc.stderr.drain<void>();
        await proc.exitCode;
        if (identical(_speakProc, proc)) _speakProc = null;
      } else if (_tts != null) {
        await _configureTts();
        await _tts.speak(text);
      }
    } catch (_) {
      // Voice output is optional. The answer is still shown in the chat.
    } finally {
      speaking.value = false;
    }
  }

  String _espeakVoice() {
    if (isTamil) return 'ta';
    return gender == VoiceGender.male ? 'en+m3' : 'en+f3';
  }

  int _espeakPitch() {
    if (isTamil) return gender == VoiceGender.male ? 30 : 60;
    return 50;
  }

  static const _maleHints = ['david', 'mark', 'valluvar', 'ravi', 'male'];
  static const _femaleHints = ['zira', 'hazel', 'pallavi', 'heera', 'female'];

  /// Picks a Windows voice of the right language and gender. Pitch and volume are the fallback.
  Future<void> _configureTts() async {
    final tts = _tts;
    if (tts == null) return;
    final locale = isTamil ? 'ta-IN' : 'en-US';
    await tts.setLanguage(locale);
    await tts.setVolume(1.0);
    await tts.setSpeechRate(0.5);
    await tts.setPitch(gender == VoiceGender.male ? 0.85 : 1.15);
    await tts.awaitSpeakCompletion(true);
    final voices = await tts.getVoices;
    if (voices is List) {
      final wanted = gender == VoiceGender.male ? _maleHints : _femaleHints;
      final prefix = locale.substring(0, 2).toLowerCase();
      for (final v in voices) {
        if (v is! Map) continue;
        final name = (v['name'] ?? '').toString();
        final loc = (v['locale'] ?? '').toString();
        if (!loc.toLowerCase().startsWith(prefix)) continue;
        if (wanted.any((h) => name.toLowerCase().contains(h))) {
          await tts.setVoice({'name': name, 'locale': loc});
          break;
        }
      }
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

  // ---------- Speech model download ----------

  static const whisperEnglishUrl =
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin';
  static const whisperTamilUrl =
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin';
  static const whisperModelUrl = whisperEnglishUrl;

  /// Downloads a Whisper model into the models folder.
  /// English: base English model (about 150 MB). Tamil: multilingual small model (about 470 MB).
  Future<String> downloadWhisperModel({bool tamil = false}) async {
    final name = tamil ? 'ggml-small.bin' : 'ggml-base.en.bin';
    final url = tamil ? whisperTamilUrl : whisperEnglishUrl;
    final dir = Directory(await _modelDir());
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final dest = File('${dir.path}${Platform.pathSeparator}$name');
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
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

  // ---------- Listening ----------

  /// Listens for [seconds] and returns the recognised words.
  /// Windows uses the built-in speech recognizer in the chosen language. Linux records and uses Whisper.
  Future<String> listenOnce(int seconds) async {
    if (Platform.isWindows) return _windowsDictate(seconds);
    final wav = await recordSeconds(seconds);
    return transcribe(wav);
  }

  Future<String> _windowsDictate(int seconds) async {
    final tmp = await getTemporaryDirectory();
    final script = File('${tmp.path}${Platform.pathSeparator}studymate_dictate.ps1');
    final culture = isTamil ? 'ta-IN' : 'en-US';
    script.writeAsStringSync(
      _dictateScript.replaceAll('SECONDS', '$seconds').replaceAll('CULTURE', culture),
    );
    final r = await Process.run(
      'powershell',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script.path],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (r.exitCode != 0) {
      final hint = isTamil
          ? 'Install the Tamil (India) language pack and its speech feature in Windows Settings, under Time & language > Language & region.'
          : 'Turn on speech recognition in Windows Settings, under Time & language > Speech.';
      throw Exception('Windows speech recognition failed. $hint ${r.stderr}'.trim());
    }
    return (r.stdout as String).replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static const _dictateScript = r'''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Speech
$culture = New-Object System.Globalization.CultureInfo('CULTURE')
$engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine -ArgumentList $culture
$engine.SetInputToDefaultAudioDevice()
$engine.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
$result = $engine.Recognize([TimeSpan]::FromSeconds(SECONDS))
if ($result) { Write-Output $result.Text }
''';

  void dispose() {
    speaking.dispose();
  }
}
