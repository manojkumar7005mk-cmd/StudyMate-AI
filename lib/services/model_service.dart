import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Downloads the model files by discovering their names from the Hugging Face API.
class ModelService {
  static const repo = 'ggml-org/Qwen2.5-Omni-3B-GGUF';
  Future<Directory> modelDirectory() async {
    final base = Platform.isWindows ? Platform.environment['APPDATA'] : (await getApplicationSupportDirectory()).path;
    final dir = Directory('${base ?? (await getApplicationSupportDirectory()).path}${Platform.pathSeparator}StudyMate${Platform.pathSeparator}models');
    await dir.create(recursive: true); return dir;
  }
  Future<List<String>> localModels() async {
    final dir = await modelDirectory();
    return dir.list().where((e) => e is File && e.path.toLowerCase().endsWith('.gguf')).map((e) => e.path).toList();
  }
  Future<List<String>> discoverFiles() async {
    final response = await http.get(Uri.parse('https://huggingface.co/api/models/$repo')).timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) throw Exception('Could not check the model list. Check your internet connection.');
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final siblings = (data['siblings'] as List? ?? []).map((e) => (e as Map)['rfilename'].toString()).where((n) => n.endsWith('.gguf')).toList();
    final models = siblings.where((n) => n.toLowerCase().contains('q4_k_m') && !n.toLowerCase().contains('mmproj')).toList();
    final fallbacks = siblings.where((n) => n.toLowerCase().contains('q4_') && !n.toLowerCase().contains('mmproj')).toList()..sort((a,b) => a.length.compareTo(b.length));
    final mm = siblings.where((n) => n.toLowerCase().contains('mmproj')).toList();
    if (models.isEmpty && fallbacks.isEmpty) throw Exception('No compatible Q4 model file was listed by the model repository.');
    final selected = models.isNotEmpty ? models.first : fallbacks.first;
    final mmPick = mm.firstWhere((n) => n.toLowerCase().contains('q8_0'), orElse: () => mm.firstWhere((n) => n.toLowerCase().contains('f16'), orElse: () => mm.isEmpty ? '' : mm.first));
    return [selected, if (mmPick.isNotEmpty) mmPick];
  }
  Future<void> download(String filename, void Function(int received, int total) onProgress) async {
    final dir = await modelDirectory(); final target = File('${dir.path}${Platform.pathSeparator}$filename');
    final part = File('${target.path}.part');
    final existing = await part.exists() ? await part.length() : 0;
    final client = http.Client();
    try {
      final uri = Uri.parse('https://huggingface.co/$repo/resolve/main/${filename.replaceAll(' ', '%20')}');
      final request = http.Request('GET', uri);
      if (existing > 0) request.headers['Range'] = 'bytes=$existing-';
      final response = await client.send(request).timeout(const Duration(minutes: 3));
      if (response.statusCode != 200 && response.statusCode != 206) throw Exception('Download failed (HTTP ${response.statusCode}).');
      final contentLength = int.tryParse(response.headers['content-length'] ?? '') ?? 0;
      final total = response.statusCode == 206 ? existing + contentLength : contentLength;
      final sink = part.openWrite(mode: response.statusCode == 206 ? FileMode.append : FileMode.write);
      var received = existing;
      await for (final chunk in response.stream) { sink.add(chunk); received += chunk.length; onProgress(received, total); }
      await sink.flush(); await sink.close();
      if (total > 0 && await part.length() != total) throw Exception('Downloaded file size did not match the expected size. Retry to resume.');
      if (await target.exists()) await target.delete(); await part.rename(target.path);
    } on FileSystemException { throw Exception('Not enough disk space to save the model. Free some space and retry.'); }
    finally { client.close(); }
  }
}
