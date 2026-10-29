import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Each download has a role, so the app never mixes the chat model with the vision projector.
enum ModelRole { chat, vision, speech }

class ModelItem {
  const ModelItem({
    required this.role,
    required this.title,
    required this.note,
    required this.fileName,
    required this.url,
  });
  final ModelRole role;
  final String title;
  final String note;
  final String fileName;
  final String url;
}

class ModelDownloadProgress {
  const ModelDownloadProgress(this.received, this.total);
  final int received;
  final int total;
  double get fraction => total <= 0 ? 0 : (received / total).clamp(0.0, 1.0).toDouble();
}

class ModelManager {
  static const chatRepo = 'ggml-org/Qwen2.5-Omni-3B-GGUF';
  static const speechFile = 'ggml-base.en.bin';
  static const speechUrl =
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin';
  static const _minBytes = 1024 * 1024;

  Future<Directory> modelDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/models');
    await dir.create(recursive: true);
    return dir;
  }

  /// Lists the chat model, the optional vision projector and the speech model.
  Future<List<ModelItem>> catalog() async {
    final response = await http
        .get(Uri.parse('https://huggingface.co/api/models/$chatRepo'))
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      throw Exception('Could not reach the model list. Check your internet connection.');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final names = (data['siblings'] as List? ?? [])
        .map((e) => (e as Map)['rfilename'].toString())
        .where((n) => n.toLowerCase().endsWith('.gguf'))
        .toList();

    final chat = names
        .where((n) => n.toLowerCase().contains('q4_k_m') && !n.toLowerCase().contains('mmproj'))
        .toList();
    final vision = names.where((n) => n.toLowerCase().contains('mmproj')).toList();
    if (chat.isEmpty) throw Exception('No Q4_K_M chat model was found in the repository.');

    String? visionPick;
    for (final key in ['q8_0', 'f16']) {
      visionPick ??= _firstWhere(vision, key);
    }
    visionPick ??= vision.isEmpty ? null : vision.first;

    final chatFile = chat.first;
    return [
      ModelItem(
        role: ModelRole.chat,
        title: 'StudyMate chat model',
        note: 'Main brain for answers. Needed for Learn.',
        fileName: chatFile,
        url: _url(chatRepo, chatFile),
      ),
      if (visionPick != null)
        ModelItem(
          role: ModelRole.vision,
          title: 'Image reader (vision add-on)',
          note: 'Lets the tutor read photos of questions. Optional.',
          fileName: visionPick,
          url: _url(chatRepo, visionPick),
        ),
      const ModelItem(
        role: ModelRole.speech,
        title: 'Voice input (Whisper)',
        note: 'Turns your speech into text. Optional.',
        fileName: speechFile,
        url: speechUrl,
      ),
    ];
  }

  static String _url(String repo, String file) =>
      'https://huggingface.co/$repo/resolve/main/${file.replaceAll(' ', '%20')}';

  static String? _firstWhere(List<String> items, String key) {
    for (final n in items) {
      if (n.toLowerCase().contains(key)) return n;
    }
    return null;
  }

  Future<bool> isReady(ModelItem item) async {
    final f = File('${(await modelDir()).path}/${item.fileName}');
    return await f.exists() && await f.length() >= _minBytes;
  }

  Future<void> delete(ModelItem item) async {
    final f = File('${(await modelDir()).path}/${item.fileName}');
    if (await f.exists()) await f.delete();
  }

  /// Downloads with resume support. Emits progress until the file is complete.
  Stream<ModelDownloadProgress> download(ModelItem item) async* {
    final dir = await modelDir();
    final target = File('${dir.path}/${item.fileName}');
    final part = File('${target.path}.part');
    final existing = await part.exists() ? await part.length() : 0;
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(item.url));
      if (existing > 0) request.headers['Range'] = 'bytes=$existing-';
      final response = await client.send(request).timeout(const Duration(minutes: 3));
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw Exception('Download failed (HTTP ${response.statusCode}).');
      }
      final resumed = response.statusCode == 206;
      final length = int.tryParse(response.headers['content-length'] ?? '') ?? 0;
      final total = resumed ? existing + length : length;
      final sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
      var received = resumed ? existing : 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          yield ModelDownloadProgress(received, total);
        }
      } finally {
        await sink.close();
      }
      if (total > 0 && await part.length() != total) {
        throw Exception('File size did not match. Press download again to resume.');
      }
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
    } on FileSystemException {
      throw Exception('Not enough storage space. Free some space and try again.');
    } finally {
      client.close();
    }
  }
}
