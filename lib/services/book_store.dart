import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';

/// Stores textbook text as small sections with book name and page number.
/// Questions are answered only from sections that match (retrieval), which reduces made-up answers.
class BookStore {
  static const _stopWords = {
    'the', 'and', 'for', 'what', 'which', 'with', 'from', 'that', 'this', 'are', 'was',
    'how', 'who', 'why', 'when', 'where', 'explain', 'define', 'give', 'tell', 'about',
    'please', 'question', 'does', 'did', 'can', 'you', 'its', 'their', 'there',
  };

  static Future<File> _indexFile() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}books');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}index.json');
  }

  static Future<List<Map<String, dynamic>>> _load() async {
    final f = await _indexFile();
    if (!f.existsSync()) return [];
    try {
      final list = jsonDecode(await f.readAsString()) as List;
      return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<Map<String, dynamic>> chunks) async {
    final f = await _indexFile();
    await f.writeAsString(jsonEncode(chunks));
  }

  static Future<bool> hasBooks() async => (await _load()).isNotEmpty;

  static Future<List<String>> bookNames() async {
    final names = (await _load()).map((c) => c['book'].toString()).toSet().toList();
    names.sort();
    return names;
  }

  static Future<void> remove(String book) async {
    final chunks = await _load();
    chunks.removeWhere((c) => c['book'] == book);
    await _save(chunks);
  }

  /// Reads a PDF with pdftotext (poppler) and stores it page by page.
  static Future<String> importPdf(String pdfPath) async {
    if (!Platform.isLinux) {
      throw Exception('PDF import works on Linux right now. Install poppler and use the Arch build.');
    }
    final tool = await Process.run('which', ['pdftotext']);
    if (tool.exitCode != 0) {
      throw Exception('pdftotext is missing. Install "poppler" from your software center, then try again.');
    }
    final r = await Process.run('pdftotext', ['-layout', pdfPath, '-']);
    if (r.exitCode != 0) {
      throw Exception('Could not read this PDF. It may be damaged or password protected.');
    }
    final pages = (r.stdout as String).split('\f');
    final book = pdfPath.split(Platform.pathSeparator).last;
    final added = <Map<String, dynamic>>[];
    for (var i = 0; i < pages.length; i++) {
      final text = pages[i]
          .replaceAll(RegExp(r'[ \t]+'), ' ')
          .replaceAll(RegExp(r'\n\s*\n+'), '\n')
          .trim();
      if (text.length < 20) continue;
      for (final piece in _split(text)) {
        added.add({'book': book, 'page': i + 1, 'text': piece});
      }
    }
    if (added.isEmpty) {
      throw Exception('No readable text found. Scanned PDFs (photos of pages) are not supported yet.');
    }
    final kept = (await _load()).where((c) => c['book'] != book).toList();
    await _save([...kept, ...added]);
    return '$book imported: ${added.length} sections from ${pages.length} pages.';
  }

  static List<String> _split(String text) {
    const size = 1000;
    const overlap = 150;
    if (text.length <= size) return [text];
    final out = <String>[];
    var start = 0;
    while (start < text.length) {
      final end = start + size < text.length ? start + size : text.length;
      out.add(text.substring(start, end));
      if (end == text.length) break;
      start = end - overlap;
    }
    return out;
  }

  static List<String> _terms(String question) => question
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.length > 2 && !_stopWords.contains(w))
      .toSet()
      .toList();

  static int _count(String text, String term) {
    var count = 0;
    var i = 0;
    while (true) {
      i = text.indexOf(term, i);
      if (i == -1) break;
      count++;
      i += term.length;
    }
    return count;
  }

  /// Returns the best matching sections for a question, highest score first.
  static Future<List<Map<String, dynamic>>> search(String question, {int limit = 4}) async {
    final chunks = await _load();
    final terms = _terms(question);
    if (terms.isEmpty || chunks.isEmpty) return [];

    final lowered = chunks.map((c) => c['text'].toString().toLowerCase()).toList();
    final n = chunks.length;
    final docFreq = <String, int>{};
    for (final t in terms) {
      docFreq[t] = lowered.where((s) => s.contains(t)).length;
    }

    final scored = <MapEntry<int, double>>[];
    for (var i = 0; i < n; i++) {
      var score = 0.0;
      for (final t in terms) {
        final tf = _count(lowered[i], t);
        if (tf == 0) continue;
        final idf = math.log((n + 1) / ((docFreq[t] ?? 0) + 1)) + 1;
        score += tf * idf;
      }
      if (score > 0) scored.add(MapEntry(i, score));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in scored.take(limit)) chunks[e.key]];
  }

  static String referenceText(List<Map<String, dynamic>> hits) =>
      hits.map((h) => '[${h['book']}, page ${h['page']}]\n${h['text']}').join('\n\n');
}
