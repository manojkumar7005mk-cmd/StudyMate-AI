import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Voice the tutor speaks with.
enum VoiceGender { female, male }

/// Language the student speaks and hears.
enum VoiceLanguage { english, tamil }

/// Voice input and output.
/// Speech to text: Whisper medium (99+ languages) through whisper-cli on Windows and Linux.
/// Windows falls back to built-in dictation until the Whisper medium file is downloaded.
/// Voice out: ElevenLabs (Adam by default) when an API key is saved, else system voices.
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

  // ---------- Whisper medium (speech to text) ----------

  static const whisperMediumName = 'ggml-medium-q5_0.bin';
  static const whisperMediumUrl =
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin';

  /// Old speech files that Whisper medium replaces.
  static const _oldWhisperNames = [
    'ggml-base.en.bin',
    'ggml-base.bin',
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
      for (final name in const [whisperMediumName, 'ggml-medium.bin']) {
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
    final lang = isTamil ? 'ta' : 'en';
    final threads = (Platform.numberOfProcessors ~/ 2).clamp(2, 8);
    final wav = await _toWhisperWav(wavPath);
    final r = await Process.run(
      tool,
      ['-m', model, '-f', wav, '-nt', '-np', '-l', lang, '-t', '$threads', '-bs', '1'],
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
    return text;
  }

  // ---------- Speaking ----------

  /// Reads text aloud and returns when speech has finished or been stopped.
  /// Uses ElevenLabs when a key is saved, and falls back to the system voice if it fails.
  Future<void> speakAndWait(String text) async {
    if (text.trim().isEmpty) return;
    speaking.value = true;
    final token = ++_speakToken;
    try {
      if (await _speakEleven(text, token)) return;
      if (token != _speakToken) return; // stopped while the voice was being made
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
    _speakToken++;
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

  // ---------- ElevenLabs natural voice ----------

  static const elevenAdamVoiceId = 'pNInz6obpgDQGcFmaJgB';
  static const elevenRachelVoiceId = '21m00Tcm4TlvDq8ikWAM';
  static const _kElevenKey = 'elevenlabs_api_key';
  static const _kElevenMale = 'elevenlabs_voice_male';
  static const _kElevenFemale = 'elevenlabs_voice_female';

  int _speakToken = 0;

  /// The last ElevenLabs problem (bad key, no credits, offline), or null. Shown in Models.
  String? lastTtsError;

  Future<String> elevenKey() async =>
      (await SharedPreferences.getInstance()).getString(_kElevenKey) ?? '';

  /// The voice ID saved by the student, or the default (Adam for male, Rachel for female).
  Future<String> elevenVoiceId(VoiceGender g, {bool savedOnly = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = (prefs.getString(g == VoiceGender.male ? _kElevenMale : _kElevenFemale) ?? '').trim();
    if (saved.isNotEmpty || savedOnly) return saved;
    return g == VoiceGender.male ? elevenAdamVoiceId : elevenRachelVoiceId;
  }

  /// Saves the ElevenLabs key and voice IDs. An empty key turns the natural voice off.
  Future<void> saveElevenSettings({
    required String key,
    String maleVoice = '',
    String femaleVoice = '',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kElevenKey, key.trim());
    await prefs.setString(_kElevenMale, maleVoice.trim());
    await prefs.setString(_kElevenFemale, femaleVoice.trim());
  }

  String _elevenProblem(int status, String body) {
    var detail = '';
    try {
      final j = jsonDecode(body);
      final d = j is Map ? j['detail'] : null;
      if (d is Map) detail = (d['message'] ?? d['status'] ?? '').toString();
      if (d is String) detail = d;
    } catch (_) {}
    final String reason;
    if (status == 401) {
      reason = 'ElevenLabs did not accept the API key.';
    } else if (status == 402 || status == 429) {
      reason = 'ElevenLabs credits or the request limit ran out.';
    } else if (status == 404) {
      reason = 'That voice ID was not found in your ElevenLabs account.';
    } else {
      reason = 'ElevenLabs error $status.';
    }
    return detail.isEmpty ? reason : '$reason $detail';
  }

  /// Speaks with ElevenLabs. Returns false when it is off or failed, so the system voice takes over.
  Future<bool> _speakEleven(String text, int token) async {
    final key = (await elevenKey()).trim();
    if (key.isEmpty) return false;
    try {
      final voiceId = await elevenVoiceId(gender);
      final res = await http
          .post(
            Uri.parse('https://api.elevenlabs.io/v1/text-to-speech/$voiceId?output_format=pcm_24000'),
            headers: {'xi-api-key': key, 'Content-Type': 'application/json'},
            body: jsonEncode({
              'text': text,
              'model_id': isTamil ? 'eleven_multilingual_v2' : 'eleven_flash_v2_5',
              'voice_settings': {
                'stability': 0.5,
                'similarity_boost': 0.75,
                'use_speaker_boost': true,
              },
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        lastTtsError = _elevenProblem(res.statusCode, utf8.decode(res.bodyBytes, allowMalformed: true));
        return false;
      }
      lastTtsError = null;
      if (token != _speakToken) return true; // stopped while the voice was being made
      final tmp = await getTemporaryDirectory();
      final file = File('${tmp.path}${Platform.pathSeparator}studymate_speech.wav');
      await file.writeAsBytes(_wavFromPcm(res.bodyBytes, 24000));
      await _playWav(file.path);
      return true;
    } catch (e) {
      lastTtsError = 'Natural voice could not play: $e';
      return false;
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
    final dest = File('${dir.path}${Platform.pathSeparator}$whisperMediumName');
    if (dest.existsSync()) {
      await removeOldSpeechModels();
      return 'Whisper medium is already installed.';
    }
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(whisperMediumUrl));
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

  /// Listens for [seconds] and returns the recognised words.
  /// With Whisper medium installed, Windows and Linux record and use Whisper.
  /// Windows falls back to its built-in recognizer until the Whisper file is downloaded.
  Future<String> listenOnce(int seconds) async {
    if (Platform.isWindows) {
      final haveWhisper = await _findTool('whisper-cli') != null && await _whisperModel() != null;
      if (!haveWhisper) return _windowsDictate(seconds);
    }
    final wav = await recordSeconds(seconds);
    return transcribe(wav);
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
