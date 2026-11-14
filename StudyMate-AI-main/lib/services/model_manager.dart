import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One file that belongs to a model: the language model or its vision file.
class ModelFile {
  const ModelFile(this.name, this.url, {this.isVision = false});

  final String name;
  final String url;
  final bool isVision;
}

/// A model the student can download, use, or delete.
class ModelEntry {
  const ModelEntry({
    required this.id,
    required this.title,
    required this.summary,
    required this.sizeText,
    required this.ramText,
    required this.files,
    this.lowRamFriendly = false,
  });

  final String id;
  final String title;
  final String summary;
  final String sizeText;
  final String ramText;
  final List<ModelFile> files;
  final bool lowRamFriendly;
}

/// Models offered in the app. The 2B model is the one for 4 GB RAM laptops.
const modelCatalog = [
  ModelEntry(
    id: 'qwen35-08b',
    title: 'StudyMate V1 Ultra Lite (0.8B)',
    summary: 'Fastest model. Reads images when the vision file is on. Good for short answers and simple questions.',
    sizeText: 'about 0.6 GB + 0.1 GB vision file',
    ramText: 'about 3 GB RAM. Turn on Low-memory mode if the PC is slow.',
    lowRamFriendly: true,
    files: [
      ModelFile(
        'Qwen_Qwen3.5-0.8B-Q4_K_M-vendor-sampling.gguf',
        'https://huggingface.co/NobodyWho/Qwen_Qwen3.5-0.8B-GGUF/resolve/main/Qwen_Qwen3.5-0.8B-Q4_K_M-vendor-sampling.gguf',
      ),
      ModelFile(
        'mmproj-BF16.gguf',
        'https://huggingface.co/NobodyWho/Qwen_Qwen3.5-0.8B-GGUF/resolve/main/mmproj-BF16.gguf',
        isVision: true,
      ),
    ],
  ),
  ModelEntry(
    id: 'qwen35-2b',
    title: 'StudyMate V1 Lite (2B)',
    summary: 'Fast and light. Reads images when the vision file is on. Best for 4 GB RAM laptops.',
    sizeText: 'about 1.2 GB + 0.6 GB vision file',
    ramText: 'about 4 GB RAM. Turn on Low-memory mode.',
    lowRamFriendly: true,
    files: [
      ModelFile(
        'Qwen3.5-2B-Q4_K_M.gguf',
        'https://huggingface.co/Repasar-Labs/qwen3.5-2b-gguf/resolve/main/Qwen3.5-2B-Q4_K_M.gguf',
      ),
      ModelFile(
        'mmproj-F16.gguf',
        'https://huggingface.co/Repasar-Labs/qwen3.5-2b-gguf/resolve/main/mmproj-F16.gguf',
        isVision: true,
      ),
    ],
  ),
  ModelEntry(
    id: 'omni-3b',
    title: 'StudyMate V1 (3B)',
    summary: 'Stronger answers. Reads images when the vision file is on.',
    sizeText: 'about 2 GB + vision file',
    ramText: 'about 6-8 GB RAM',
    files: [
      ModelFile(
        'Qwen2.5-Omni-3B-Q4_K_M.gguf',
        'https://huggingface.co/ggml-org/Qwen2.5-Omni-3B-GGUF/resolve/main/Qwen2.5-Omni-3B-Q4_K_M.gguf',
      ),
      ModelFile(
        'mmproj-Qwen2.5-Omni-3B-Q8_0.gguf',
        'https://huggingface.co/ggml-org/Qwen2.5-Omni-3B-GGUF/resolve/main/mmproj-Qwen2.5-Omni-3B-Q8_0.gguf',
        isVision: true,
      ),
    ],
  ),
];

/// Downloads, selects, and deletes models. Each model has its own folder.
class ModelManager {
  static const _activeKey = 'active_model_id';

  static String get _sep => Platform.pathSeparator;

  static Future<Directory> _root() async {
    final base = Platform.isWindows
        ? (Platform.environment['APPDATA'] ?? (await getApplicationSupportDirectory()).path)
        : (await getApplicationSupportDirectory()).path;
    final dir = Directory('$base${_sep}StudyMate${_sep}models');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Finds a file in the model's folder, or in the older flat models folder.
  static Future<String?> _pathOf(ModelEntry e, ModelFile f) async {
    final root = (await _root()).path;
    final inFolder = File('$root$_sep${e.id}$_sep${f.name}');
    if (inFolder.existsSync()) return inFolder.path;
    final legacy = File('$root$_sep${f.name}');
    if (legacy.existsSync()) return legacy.path;
    return null;
  }

  static Future<bool> isInstalled(ModelEntry e) async {
    for (final f in e.files) {
      if (await _pathOf(e, f) == null) return false;
    }
    return true;
  }

  static Future<void> download(ModelEntry e, void Function(String) onStatus) async {
    final root = (await _root()).path;
    final dir = Directory('$root$_sep${e.id}');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final client = HttpClient();
    try {
      for (final f in e.files) {
        if (await _pathOf(e, f) != null) continue;
        onStatus('Downloading ${f.name}...');
        final req = await client.getUrl(Uri.parse(f.url));
        req.headers.set('User-Agent', 'StudyMate-AI');
        final res = await req.close();
        if (res.statusCode != 200) {
          throw Exception('Download failed for ${f.name} (error ${res.statusCode}). Check the internet connection.');
        }
        final total = res.contentLength;
        var received = 0;
        final part = File('${dir.path}$_sep${f.name}.part');
        final sink = part.openWrite();
        await for (final chunk in res) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onStatus('${f.name}: ${received * 100 ~/ total}%');
        }
        await sink.close();
        part.renameSync('${dir.path}$_sep${f.name}');
      }
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> delete(ModelEntry e) async {
    final root = (await _root()).path;
    final dir = Directory('$root$_sep${e.id}');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    for (final f in e.files) {
      final legacy = File('$root$_sep${f.name}');
      if (legacy.existsSync()) legacy.deleteSync();
    }
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_activeKey) == e.id) await prefs.remove(_activeKey);
  }

  static const _ctxKey = 'context_size';

  /// Context size in tokens: 2048 (short), 4096 (standard), or 8192 (long).
  static Future<int> contextSize() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_ctxKey) ?? 4096;
  }

  static Future<void> setContextSize(int size) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_ctxKey, size);
  }

  static Future<String?> activeId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeKey);
  }

  static Future<void> setActive(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeKey, id);
  }

  /// Paths of the selected model and its vision file, or null if the selected model is not complete.
  static Future<({String model, String? vision})?> activeFiles() async {
    final id = await activeId();
    ModelEntry? entry;
    for (final e in modelCatalog) {
      if (e.id == id) entry = e;
    }
    if (entry == null) return null;
    String? model;
    String? vision;
    for (final f in entry.files) {
      final path = await _pathOf(entry, f);
      if (path == null) return null;
      if (f.isVision) {
        vision = path;
      } else {
        model = path;
      }
    }
    if (model == null) return null;
    return (model: model, vision: vision);
  }
}
