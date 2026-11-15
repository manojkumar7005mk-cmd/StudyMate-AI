import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Voice the tutor speaks with.
enum VoiceGender { female, male }

/// Language the student speaks and hears.
enum VoiceLanguage { english, tamil }

/// One offline Piper voice the student can download, use, or delete.
class PiperVoice {
  const PiperVoice(this.id, this.title, this.gender, this.sizeText, this.path);

  final String id;
  final String title;
  final VoiceGender gender;
  final String sizeText;

  /// Folder inside the rhasspy/piper-voices repository.
  final String path;

  /// Short name for chips, such as "Ryan" or "Lessac HQ".
  String get shortTitle => title.split(' (').first + (id.endsWith('-high') ? ' HQ' : '');

  String get onnxUrl =>
      'https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/$path/$id.onnx';
  String get jsonUrl => '$onnxUrl.json';
}

/// Voices offered in the app. Quality "high" sounds best; "medium" is smaller and faster.
const piperVoices = [
  PiperVoice('en_US-ryan-high', 'Ryan (US man, best quality)', VoiceGender.male, 'about 115 MB', 'en/en_US/ryan/high'),
  PiperVoice('en_US-ryan-medium', 'Ryan (US man, fast)', VoiceGender.male, 'about 63 MB', 'en/en_US/ryan/medium'),
  PiperVoice('en_US-john-medium', 'John (US man)', VoiceGender.male, 'about 63 MB', 'en/en_US/john/medium'),
  PiperVoice('en_US-bryce-medium', 'Bryce (US man)', VoiceGender.male, 'about 63 MB', 'en/en_US/bryce/medium'),
  PiperVoice('en_GB-alan-medium', 'Alan (British man)', VoiceGender.male, 'about 63 MB', 'en/en_GB/alan/medium'),
  PiperVoice('en_US-lessac-high', 'Lessac (US woman, best quality)', VoiceGender.female, 'about 115 MB', 'en/en_US/lessac/high'),
  PiperVoice('en_US-lessac-medium', 'Lessac (US woman, fast)', VoiceGender.female, 'about 63 MB', 'en/en_US/lessac/medium'),
  PiperVoice('en_US-amy-medium', 'Amy (US woman)', VoiceGender.female, 'about 63 MB', 'en/en_US/amy/medium'),
  PiperVoice('en_US-kristin-medium', 'Kristin (US woman)', VoiceGender.female, 'about 63 MB', 'en/en_US/kristin/medium'),
  PiperVoice('en_GB-jenny_dioco-medium', 'Jenny (British woman)', VoiceGender.female, 'about 63 MB', 'en/en_GB/jenny_dioco/medium'),
];

/// Voice input and output.
/// Speech to text: Whisper medium (99+ languages) through whisper-cli on Windows and Linux.
/// Windows falls back to built-in dictation until the Whisper medium file is downloaded.
/// Voice out: Piper (offline, natural voices the student downloads) with system voices as backup.
/// Everything runs on this PC. Nothing is sent online.
class VoiceService {
  final ValueNotifier<bool> speaking = ValueNotifier<bool>(false);
  final FlutterTts? _tts = Platform.isWindows ? FlutterTts() : null;
  Process? _recordProc;
  Process? _speakProc;
  Process? _synthProc;

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

  // ---------- Whisper medium (speech to text) ----------

  static const whisperBaseName = 'ggml-base.bin';
  static const whisperBaseUrl =
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin';
  static const whisperMediumName = 'ggml-medium-q5_0.bin';

  /// Old speech files that Whisper medium replaces.
  static const _oldWhisperNames = [
    'ggml-small.en.bin',
    'ggml-small.bin',
    'ggml-tiny.en.bin',
    'ggml-tiny.bin',
  ];

  /// Whisper medium is multilingual, so one file covers English, Tamil and the other languages.
  Future<String?> _whisperModel() async {
    final dirs = <String>[await _modelDir()];
    if (!Platform.isWindows) dirs.add('${Platform.environment['HOME'] ?? ''}/models');
    for (final dir in dirs) {
      for (final name in const [whisperBaseName, 'ggml-base.en.bin', whisperMediumName, 'ggml-medium.bin']) {
        final f = File('$dir${Platform.pathSeparator}$name');
        if (await f.exists()) return f.path;
      }
    }
    return null;
  }

  /// Deletes the old Whisper base/small/tiny files from the StudyMate models folder.
  Future<void> removeOldSpeechModels() async {
    final dir = await _modelDir();
    for (final name in _oldWhisperNames) {
      final f = File('$dir${Platform.pathSeparator}$name');
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// Returns a message explaining what is missing, or null when voice can run.
  /// Windows always can run: it uses built-in dictation until Whisper medium is installed.
  Future<String?> setupProblem() async {
    if (Platform.isWindows) return null;
    if (await _findTool('whisper-cli') == null) {
      return 'Speech-to-text is not installed. Install whisper.cpp (whisper-cli) first.';
    }
    if (await _whisperModel() == null) {
      return 'Speech model missing. Open Models and download Whisper medium (about 540 MB).';
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
    if (Platform.isWindows) return _windowsRecord(seconds);

    throw Exception('Recording is supported on Windows and Linux.');
  }

  /// Converts a recorded WAV file to text with whisper.cpp (Whisper medium).
  Future<String> transcribe(String wavPath) async {
    if (wavPath.isEmpty) return '';
    final tool = await _findTool('whisper-cli');
    final model = await _whisperModel();
    if (tool == null || model == null) {
      throw Exception('Whisper medium is not installed. Open Models and download it.');
    }
    final threads = (Platform.numberOfProcessors ~/ 2).clamp(2, 8);
    final wav = await _toWhisperWav(wavPath);
    // Whisper normally works on 30 seconds of audio. For a short clip, a smaller window is
    // much faster. Language is detected by Whisper, so English and Tamil both just work.
    final seconds = (await File(wav).length() - 44) / 32000;
    final args = ['-m', model, '-f', wav, '-nt', '-np', '-l', 'auto', '-t', '$threads', '-bs', '1'];
    if (seconds > 0 && seconds < 25) {
      args.addAll(['-ac', '${math.min(1500, (seconds * 50).ceil() + 150)}']);
    }
    final r = await Process.run(
      tool,
      args,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
      workingDirectory: File(tool).parent.path,
    );
    if (r.exitCode != 0) {
      throw Exception('Speech recognition failed (exit code ${r.exitCode}). ${r.stderr}'.trim());
    }
    final text = (r.stdout as String).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.contains('BLANK_AUDIO') || text.contains('(silence)')) return '';
    // Whisper writes sounds like [MUSIC] or (noise) when nobody is speaking.
    if (RegExp(r'^[\[(].*[\])]$').hasMatch(text)) return '';
    final plain = text.toLowerCase().replaceAll(RegExp(r'[^a-z ]'), '').trim();
    if (plain == 'you' || plain == 'thanks for watching') return ''; // Whisper's silence guesses
    return text;
  }

  // ---------- Speaking ----------

  /// Reads text aloud and returns when speech has finished or been stopped.
  Future<void> speakAndWait(String text) => speakStream(Stream.value(text));

  void Function()? _signalSpeak;
  bool _piperChmodDone = false;

  /// Speaks sentences as they arrive. The next sentence is made while the current one plays,
  /// so the first words start quickly and there are no long gaps. Uses the chosen offline
  /// Piper voice, and the system voice when none is downloaded (or for Tamil).
  Future<void> speakStream(Stream<String> sentences, {PiperVoice? force}) async {
    speaking.value = true;
    final token = ++_speakToken;
    PiperVoice? voice;
    String? exe;
    try {
      if (force != null || !isTamil) voice = force ?? await _voiceToUse();
      if (voice != null) {
        exe = await _piperExe();
        if (exe == null) {
          lastTtsError = 'The voice engine (piper) is not installed in this build.';
          voice = null;
        }
      }
    } catch (_) {
      voice = null;
    }
    final v = voice;
    final e = exe;

    final items = <_Utterance>[];
    var done = false;
    Completer<void>? wake;
    var chain = Future<void>.value();
    var n = 0;
    void signal() {
      final w = wake;
      wake = null;
      if (w != null && !w.isCompleted) w.complete();
    }

    _signalSpeak = signal;

    final producer = () async {
      try {
        await for (final raw in sentences) {
          if (token != _speakToken) break;
          final t = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
          if (t.isEmpty) continue;
          Future<String?>? wav;
          if (v != null && e != null) {
            final id = n++;
            final Future<String?> turn =
                chain.then<String?>((_) => token != _speakToken ? null : _synthPiper(e, v, t, token, id));
            wav = turn;
            chain = turn.then((_) {});
          }
          items.add(_Utterance(t, wav));
          signal();
        }
      } catch (_) {
        // The answer is still shown in the chat if voice fails.
      } finally {
        done = true;
        signal();
      }
    }();
    unawaited(producer);

    var i = 0;
    try {
      while (token == _speakToken) {
        if (i >= items.length) {
          if (done) break;
          wake = Completer<void>();
          await wake!.future;
          continue;
        }
        final u = items[i++];
        final path = u.wav == null ? null : await u.wav;
        if (token != _speakToken) break;
        if (path != null) {
          await _playWav(path);
          try {
            File(path).deleteSync();
          } catch (_) {}
        } else {
          await _speakSystem(u.text);
        }
      }
    } catch (_) {
      // Voice output is optional.
    } finally {
      if (token == _speakToken) speaking.value = false;
    }
  }

  /// Windows voice (or espeak on Linux). Used when no Piper voice is ready.
  Future<void> _speakSystem(String text) async {
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
      // Voice output is optional.
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
    _speakToken++;
    _speakProc?.kill();
    _speakProc = null;
    _synthProc?.kill();
    _synthProc = null;
    _signalSpeak?.call();
    await _tts?.stop();
    speaking.value = false;
  }

  Future<void> stopAll() async {
    _recAborted = true;
    final rd = _recDone;
    if (rd != null && !rd.isCompleted) rd.complete();
    _recordProc?.kill();
    _recordProc = null;
    await stopSpeak();
  }

  /// Removes formatting marks so text reads naturally aloud.
  static String speechClean(String text) =>
      text.replaceAll(RegExp(r'[*#`_>]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Tamil letters mean the student is speaking Tamil. Anything else is treated as English.
  static VoiceLanguage detectLanguage(String text) =>
      RegExp(r'[\u0B80-\u0BFF]').hasMatch(text) ? VoiceLanguage.tamil : VoiceLanguage.english;

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

  // ---------- Piper offline voices ----------

  static const _kPiperVoice = 'piper_voice';

  int _speakToken = 0;

  /// The last voice problem, or null. Shown in Models.
  String? lastTtsError;

  Future<String> _voicesDir() async {
    final dir = Directory('${await _modelDir()}${Platform.pathSeparator}voices');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  Future<String> _voiceFile(PiperVoice v) async =>
      '${await _voicesDir()}${Platform.pathSeparator}${v.id}.onnx';

  /// piper.exe sits in bin/piper beside the app, with its espeak data and DLLs.
  Future<String?> _piperExe() async {
    final sep = Platform.pathSeparator;
    final name = Platform.isWindows ? 'piper.exe' : 'piper';
    final local = File(
      '${File(Platform.resolvedExecutable).parent.path}${sep}bin${sep}piper$sep$name',
    );
    if (await local.exists()) return local.path;
    return _findTool('piper');
  }

  Future<bool> piperEngineInstalled() async => (await _piperExe()) != null;

  Future<bool> isVoiceInstalled(PiperVoice v) async {
    final onnx = File(await _voiceFile(v));
    return await onnx.exists() && await File('${onnx.path}.json').exists();
  }

  /// Downloads one voice: its model file and its settings file.
  Future<void> downloadVoice(PiperVoice v, {void Function(String)? onStatus}) async {
    final dest = await _voiceFile(v);
    await _downloadFile(v.jsonUrl, '$dest.json', 'settings', null, minBytes: 100);
    await _downloadFile(v.onnxUrl, dest, v.title, onStatus, minBytes: 5 * 1024 * 1024);
    if ((await selectedVoiceId()).isEmpty) await setSelectedVoice(v.id);
  }

  Future<void> deleteVoice(PiperVoice v) async {
    final dest = await _voiceFile(v);
    for (final path in [dest, '$dest.json']) {
      final f = File(path);
      if (await f.exists()) await f.delete();
    }
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_kPiperVoice) == v.id) await prefs.remove(_kPiperVoice);
  }

  /// The voice character the student chose: a voice id, 'system' for the Windows voice,
  /// or '' to use the first downloaded voice.
  Future<String> selectedVoiceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kPiperVoice) ?? '';
  }

  Future<void> setSelectedVoice(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPiperVoice, id);
  }

  /// The voice to speak with: the chosen one if it is downloaded, else the first downloaded
  /// voice. Null means use the system voice (none downloaded, or the student picked it).
  Future<PiperVoice?> _voiceToUse() async {
    final chosen = await selectedVoiceId();
    if (chosen == 'system') return null;
    PiperVoice? first;
    for (final v in piperVoices) {
      if (!await isVoiceInstalled(v)) continue;
      if (v.id == chosen) return v;
      first ??= v;
    }
    return first;
  }

  /// Speaks a short sample with one voice, for the Play button in Models.
  Future<void> sampleVoice(PiperVoice v) async {
    lastTtsError = null;
    await speakStream(
      Stream.value('Hello, I am your StudyMate tutor. Let us learn something new today.'),
      force: v,
    );
  }

  /// Makes one sentence of speech with Piper (offline) and returns the WAV path, or null on failure.
  Future<String?> _synthPiper(String exe, PiperVoice voice, String text, int token, int id) async {
    try {
      final env = <String, String>{};
      if (!Platform.isWindows) {
        if (!_piperChmodDone) {
          await Process.run('chmod', ['+x', exe]);
          _piperChmodDone = true;
        }
        env['LD_LIBRARY_PATH'] = '${File(exe).parent.path}:${Platform.environment['LD_LIBRARY_PATH'] ?? ''}';
      }
      final tmp = await getTemporaryDirectory();
      final wav = '${tmp.path}${Platform.pathSeparator}studymate_say_${token}_$id.wav';
      final proc = await Process.start(
        exe,
        ['--model', await _voiceFile(voice), '--output_file', wav, '--sentence_silence', '0.15'],
        workingDirectory: File(exe).parent.path,
        environment: env,
      );
      _synthProc = proc;
      final err = StringBuffer();
      proc.stdout.drain<void>();
      proc.stderr.transform(utf8.decoder).listen(err.write);
      proc.stdin.write(text);
      await proc.stdin.close();
      final code = await proc.exitCode;
      if (identical(_synthProc, proc)) _synthProc = null;
      if (token != _speakToken) return null; // stopped on purpose
      if (code != 0 || !File(wav).existsSync()) {
        lastTtsError = 'The voice engine stopped (exit code $code). ${err.toString().trim()}';
        return null;
      }
      return wav;
    } catch (e) {
      lastTtsError = 'The voice could not be made: $e';
      return null;
    }
  }

  Future<void> _playWav(String path) async {
    final Process proc;
    if (Platform.isWindows) {
      final tmp = await getTemporaryDirectory();
      final script = File('${tmp.path}${Platform.pathSeparator}studymate_play.ps1');
      final safe = path.replaceAll("'", "''");
      script.writeAsStringSync("(New-Object System.Media.SoundPlayer '$safe').PlaySync()");
      proc = await Process.start(
        'powershell',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script.path],
      );
    } else {
      proc = await Process.start('aplay', ['-q', path]);
    }
    _speakProc = proc;
    proc.stdout.drain<void>();
    proc.stderr.drain<void>();
    await proc.exitCode;
    if (identical(_speakProc, proc)) _speakProc = null;
  }

  /// Downloads one file with progress. Writes to a .part file first, so a cut download never
  /// leaves a broken model behind.
  Future<void> _downloadFile(
    String url,
    String destPath,
    String label,
    void Function(String)? onStatus, {
    required int minBytes,
  }) async {
    final dest = File(destPath);
    if (dest.existsSync()) return;
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'StudyMate-AI');
      final res = await req.close();
      if (res.statusCode != 200) {
        throw Exception('Download failed for $label (error ${res.statusCode}). Check the internet connection.');
      }
      final total = res.contentLength;
      var got = 0;
      var lastPct = -1;
      final tmp = File('$destPath.part');
      final sink = tmp.openWrite();
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) {
            final pct = got * 100 ~/ total;
            if (pct != lastPct) {
              lastPct = pct;
              onStatus?.call('Downloading $label: $pct%');
            }
          }
        }
      } finally {
        await sink.close();
      }
      if ((total > 0 && got != total) || got < minBytes) {
        if (tmp.existsSync()) tmp.deleteSync();
        throw Exception('The download of $label was cut off. Check the internet connection and try again.');
      }
      tmp.renameSync(destPath);
    } finally {
      client.close(force: true);
    }
  }

  // ---------- WAV helpers ----------

  /// Builds a 16-bit mono WAV file around raw PCM bytes.
  static Uint8List _wavFromPcm(Uint8List pcm, int rate) {
    final h = ByteData(44);
    void tag(int o, String t) {
      for (var i = 0; i < 4; i++) {
        h.setUint8(o + i, t.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    h.setUint32(4, 36 + pcm.length, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little);
    h.setUint16(22, 1, Endian.little);
    h.setUint32(24, rate, Endian.little);
    h.setUint32(28, rate * 2, Endian.little);
    h.setUint16(32, 2, Endian.little);
    h.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    h.setUint32(40, pcm.length, Endian.little);
    final out = Uint8List(44 + pcm.length);
    out.setRange(0, 44, h.buffer.asUint8List());
    out.setRange(44, out.length, pcm);
    return out;
  }

  /// whisper-cli needs 16 kHz, 16-bit, mono. If the recorder gave something else,
  /// this converts it, so any microphone works.
  Future<String> _toWhisperWav(String path) async {
    final bytes = await File(path).readAsBytes();
    if (bytes.length < 44 || String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF') return path;
    final bd = ByteData.sublistView(bytes);
    var pos = 12;
    var channels = 0, rate = 0, bits = 0, fmtTag = 0, dataStart = -1, dataLen = 0;
    while (pos + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(pos, pos + 4));
      final size = bd.getUint32(pos + 4, Endian.little);
      final body = pos + 8;
      if (id == 'fmt ' && body + 16 <= bytes.length) {
        fmtTag = bd.getUint16(body, Endian.little);
        channels = bd.getUint16(body + 2, Endian.little);
        rate = bd.getUint32(body + 4, Endian.little);
        bits = bd.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        dataStart = body;
        dataLen = size > bytes.length - body ? bytes.length - body : size;
        break;
      }
      pos = body + size + (size & 1);
    }
    if (dataStart < 0 || bits != 16 || channels < 1 || rate < 8000) return path;
    if (fmtTag != 1 && fmtTag != 0xFFFE) return path;
    if (rate == 16000 && channels == 1) return path;
    final frames = dataLen ~/ (2 * channels);
    if (frames < 1) return path;
    final mono = Int16List(frames);
    for (var i = 0; i < frames; i++) {
      var sum = 0;
      for (var c = 0; c < channels; c++) {
        sum += bd.getInt16(dataStart + (i * channels + c) * 2, Endian.little);
      }
      mono[i] = sum ~/ channels;
    }
    final outLen = frames * 16000 ~/ rate;
    final out = Int16List(outLen);
    for (var i = 0; i < outLen; i++) {
      final src = i * rate / 16000;
      final i0 = src.floor();
      final i1 = i0 + 1 < frames ? i0 + 1 : i0;
      final f = src - i0;
      out[i] = (mono[i0] * (1 - f) + mono[i1] * f).round();
    }
    final outPath = '$path.16k.wav';
    await File(outPath).writeAsBytes(_wavFromPcm(out.buffer.asUint8List(), 16000));
    return outPath;
  }

  // ---------- Speech model download ----------

  /// Downloads Whisper medium (quantized, about 540 MB, 99+ languages), then removes the
  /// old base/small files. [tamil] is kept only so older callers still compile.
  Future<String> downloadWhisperModel({bool tamil = false, void Function(String)? onStatus}) async {
    final dir = Directory(await _modelDir());
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final dest = File('${dir.path}${Platform.pathSeparator}$whisperBaseName');
    if (dest.existsSync()) {
      await removeOldSpeechModels();
      return 'Whisper base is already installed.';
    }
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(whisperBaseUrl));
      req.headers.set('User-Agent', 'StudyMate-AI');
      final res = await req.close();
      if (res.statusCode != 200) {
        throw Exception('Voice model download failed (error ${res.statusCode}). Check the internet connection.');
      }
      final total = res.contentLength;
      var got = 0;
      var lastPct = -1;
      final tmp = File('${dest.path}.part');
      final sink = tmp.openWrite();
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) {
            final pct = got * 100 ~/ total;
            if (pct != lastPct) {
              lastPct = pct;
              onStatus?.call('Downloading Whisper medium: $pct%');
            }
          }
        }
      } finally {
        await sink.close();
      }
      if ((total > 0 && got != total) || got < 100 * 1024 * 1024) {
        if (tmp.existsSync()) tmp.deleteSync();
        throw Exception('The download was cut off. Check the internet connection and try again.');
      }
      tmp.renameSync(dest.path);
      await removeOldSpeechModels();
      return 'Whisper medium installed. The old speech files were removed.';
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

  Future<bool> speechModelInstalled() async {
    final found = await _whisperModel() != null;
    if (found) await removeOldSpeechModels();
    return found;
  }

  Future<void> deleteSpeechModel() async {
    final path = await _whisperModel();
    if (path != null) File(path).deleteSync();
  }

  Future<bool> speechToolInstalled() async => (await _findTool('whisper-cli')) != null;

  // ---------- Listening ----------

  /// Listens and returns the recognised words. Recording stops by itself shortly after the
  /// student stops talking. If nobody starts talking within [seconds], it returns ''.
  /// Windows falls back to its built-in recognizer until the Whisper file is downloaded.
  Future<String> listenOnce(int seconds) async {
    if (Platform.isWindows) {
      final haveWhisper = await _findTool('whisper-cli') != null && await _whisperModel() != null;
      if (!haveWhisper) return _windowsDictate(seconds);
    }
    String wav;
    try {
      wav = await _recordSmart(waitSeconds: seconds);
    } catch (e) {
      if (e.toString().contains('permission')) rethrow;
      wav = await recordSeconds(seconds); // older fixed-length recording as a backup
    }
    return transcribe(wav);
  }

  Completer<void>? _recDone;
  bool _recAborted = false;

  static double _rms(Uint8List chunk) {
    final n = chunk.length ~/ 2;
    if (n == 0) return 0;
    final bd = ByteData.sublistView(chunk);
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final s = bd.getInt16(i * 2, Endian.little);
      sum += s * s;
    }
    return math.sqrt(sum / n);
  }

  /// Records from the microphone until the student has spoken and then paused.
  /// Returns a 16 kHz mono WAV path, or '' when nothing was said or it was stopped.
  Future<String> _recordSmart({required int waitSeconds, int maxSpeechSeconds = 15}) async {
    final rec = AudioRecorder();
    StreamSubscription<Uint8List>? sub;
    try {
      if (!await rec.hasPermission()) {
        throw Exception(
          'Microphone permission is off. Allow microphone access for StudyMate in your system settings.',
        );
      }
      _recAborted = false;
      final done = Completer<void>();
      _recDone = done;
      void finish() {
        if (!done.isCompleted) done.complete();
      }

      final pcm = BytesBuilder(copy: false);
      final clock = Stopwatch()..start();
      var floor = -1.0;
      var speechStartMs = -1;
      var speechStartByte = 0;
      var lastLoudMs = 0;
      var lastLoudByte = 0;

      final stream = await rec.startStream(
        const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1),
      );
      sub = stream.listen(
        (chunk) {
          pcm.add(chunk);
          final ms = clock.elapsedMilliseconds;
          final level = _rms(chunk);
          // The first half second sets the room-noise level. Speech must be clearly louder.
          if (ms < 500) floor = floor < 0 ? level : math.min(floor, level);
          final threshold = math.max(300.0, (floor < 0 ? 0.0 : floor) * 2.5);
          // Keep learning the room's quiet level while nobody is speaking.
          if (speechStartMs < 0 && level <= threshold) {
            floor = floor < 0 ? level : floor * 0.95 + level * 0.05;
          }
          if (level > threshold) {
            if (speechStartMs < 0) {
              speechStartMs = ms;
              speechStartByte = pcm.length - chunk.length;
            }
            lastLoudMs = ms;
            lastLoudByte = pcm.length;
          }
          if (speechStartMs < 0) {
            if (ms > waitSeconds * 1000) finish();
          } else if (ms - lastLoudMs > 450 || ms - speechStartMs > maxSpeechSeconds * 1000) {
            finish();
          }
        },
        onError: (Object err) {
          if (!done.isCompleted) done.completeError(err);
        },
        onDone: finish,
      );
      await done.future;
      if (_recAborted || speechStartMs < 0) return '';

      final all = pcm.takeBytes();
      var start = speechStartByte - 9600; // keep 0.3 s before the first word
      if (start < 0) start = 0;
      var end = lastLoudByte + 8000; // and 0.25 s after the last one
      if (end > all.length) end = all.length;
      start -= start % 2;
      end -= end % 2;
      if (end - start < 6400) return ''; // under 0.2 seconds: just a click or a cough
      final tmp = await getTemporaryDirectory();
      final path = '${tmp.path}${Platform.pathSeparator}studymate_voice.wav';
      await File(path).writeAsBytes(_wavFromPcm(Uint8List.sublistView(all, start, end), 16000));
      return path;
    } finally {
      await sub?.cancel();
      try {
        await rec.stop();
      } catch (_) {}
      try {
        await rec.dispose();
      } catch (_) {}
      _recDone = null;
    }
  }

  /// Records the microphone on Windows as a WAV file for Whisper.
  Future<String> _windowsRecord(int seconds) async {
    final tmp = await getTemporaryDirectory();
    final wav = '${tmp.path}${Platform.pathSeparator}studymate_voice.wav';
    final script = File('${tmp.path}${Platform.pathSeparator}studymate_record.ps1');
    final old = File(wav);
    if (old.existsSync()) old.deleteSync();
    script.writeAsStringSync(
      _recordScript.replaceAll('SECONDS', '$seconds').replaceAll('WAVPATH', wav.replaceAll("'", "''")),
    );
    final proc = await Process.start(
      'powershell',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script.path],
    );
    _recordProc = proc;
    final err = StringBuffer();
    proc.stdout.drain<void>();
    proc.stderr.transform(utf8.decoder).listen(err.write);
    final code = await proc.exitCode;
    final stoppedOnPurpose = !identical(_recordProc, proc);
    if (identical(_recordProc, proc)) _recordProc = null;
    if (stoppedOnPurpose) return '';
    if (code != 0 || !File(wav).existsSync()) {
      throw Exception(
        'Microphone recording failed. In Windows Settings > Privacy & security > Microphone, '
        'allow desktop apps to use the microphone. ${err.toString().trim()}',
      );
    }
    return wav;
  }

  static const _recordScript = r'''
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class StudyMci {
  [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
  public static extern int mciSendString(string command, StringBuilder ret, int retLen, IntPtr hwnd);
}
"@
function Mci([string]$c, [bool]$must = $true) {
  $r = [StudyMci]::mciSendString($c, $null, 0, [IntPtr]::Zero)
  if ($r -ne 0 -and $must) { throw "Microphone error $r ($c)" }
}
Mci 'close studyrec' $false
Mci 'open new type waveaudio alias studyrec'
Mci 'set studyrec time format ms' $false
Mci 'set studyrec bitspersample 16' $false
Mci 'set studyrec channels 1' $false
Mci 'set studyrec samplespersec 16000' $false
Mci 'set studyrec alignment 2' $false
Mci 'set studyrec bytespersec 32000' $false
Mci 'record studyrec'
Start-Sleep -Seconds SECONDS
Mci 'stop studyrec'
Mci 'save studyrec "WAVPATH"'
Mci 'close studyrec'
''';

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

/// One piece of speech: its text, and the Piper audio being made for it (if any).
class _Utterance {
  _Utterance(this.text, this.wav);

  final String text;
  final Future<String?>? wav;
}
