import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
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

  /// Imports a PDF, Word (.docx), PowerPoint (.pptx) or Excel (.xlsx) file, page by page.
  static Future<String> importPdf(String path) async {
    final lower = path.toLowerCase();
    final List<String> pages;
    if (lower.endsWith('.pdf')) {
      pages = await _pdfPages(path);
    } else if (lower.endsWith('.docx')) {
      pages = _docxPages(File(path).readAsBytesSync());
    } else if (lower.endsWith('.pptx')) {
      pages = _pptxPages(File(path).readAsBytesSync());
    } else if (lower.endsWith('.xlsx')) {
      pages = _xlsxPages(File(path).readAsBytesSync());
    } else if (lower.endsWith('.doc') || lower.endsWith('.ppt') || lower.endsWith('.xls')) {
      throw Exception('Old Office files (.doc, .ppt, .xls) are not supported. Save the file as .docx, .pptx or .xlsx, then import it again.');
    } else {
      throw Exception('This file type is not supported. Use PDF, DOCX, PPTX or XLSX.');
    }
    final book = path.split(Platform.pathSeparator).last;
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
      throw Exception('No readable text was found in this file. Scanned pages (photos) cannot be read yet.');
    }
    final kept = (await _load()).where((c) => c['book'] != book).toList();
    await _save([...kept, ...added]);
    return '$book imported: ${added.length} sections from ${pages.length} pages or slides.';
  }

  /// Finds pdftotext: the bundled copy on Windows, or the system copy on Linux.
  static Future<String?> _pdfTool() async {
    if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final f = File('$exeDir${Platform.pathSeparator}bin${Platform.pathSeparator}pdftotext.exe');
      return f.existsSync() ? f.path : null;
    }
    final r = await Process.run('which', ['pdftotext']);
    return r.exitCode == 0 ? (r.stdout as String).trim() : null;
  }

  static Future<List<String>> _pdfPages(String path) async {
    final tool = await _pdfTool();
    if (tool == null) {
      throw Exception(Platform.isWindows
          ? 'The PDF reader is missing from this build. Install the latest StudyMate version.'
          : 'pdftotext is missing. Install "poppler" from your software center, then try again.');
    }
    final r = await Process.run(tool, ['-layout', path, '-']);
    if (r.exitCode != 0) {
      throw Exception('Could not read this PDF. It may be damaged or password protected.');
    }
    return (r.stdout as String).split('\f');
  }

  static String _unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  static String _xmlText(String xml, RegExp tag) =>
      tag.allMatches(xml).map((m) => _unescape(m.group(1) ?? '')).join();

  static String _xmlOf(ArchiveFile f) => utf8.decode(f.content as List<int>);

  static List<String> _docxPages(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final doc = archive.findFile('word/document.xml');
    if (doc == null) throw Exception('This is not a valid Word (.docx) file.');
    final tag = RegExp(r'<w:t[^>]*>([^<]*)</w:t>');
    final paragraphs = _xmlOf(doc)
        .split('</w:p>')
        .map((p) => _xmlText(p, tag))
        .where((p) => p.trim().isNotEmpty)
        .toList();
    // Forty paragraphs make one page, so a citation points to a place in the document.
    final pages = <String>[];
    for (var i = 0; i < paragraphs.length; i += 40) {
      final end = i + 40 > paragraphs.length ? paragraphs.length : i + 40;
      pages.add(paragraphs.sublist(i, end).join('\n'));
    }
    return pages;
  }

  static int _numberIn(String name, RegExp pattern) =>
      int.parse(pattern.firstMatch(name)!.group(1)!);

  static List<String> _pptxPages(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final numbered = RegExp(r'slide(\d+)\.xml');
    final slides = archive.files
        .where((f) => RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(f.name))
        .toList()
      ..sort((a, b) => _numberIn(a.name, numbered).compareTo(_numberIn(b.name, numbered)));
    if (slides.isEmpty) throw Exception('No slides were found in this (.pptx) file.');
    final tag = RegExp(r'<a:t>([^<]*)</a:t>');
    return [
      for (final s in slides)
        _xmlOf(s)
            .split('</a:p>')
            .map((p) => _xmlText(p, tag))
            .where((t) => t.trim().isNotEmpty)
            .join('\n'),
    ];
  }

  static List<String> _xlsxPages(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final shared = <String>[];
    final ss = archive.findFile('xl/sharedStrings.xml');
    if (ss != null) {
      final si = RegExp(r'<si>(.*?)</si>', dotAll: true);
      final t = RegExp(r'<t[^>]*>([^<]*)</t>');
      for (final m in si.allMatches(_xmlOf(ss))) {
        shared.add(_xmlText(m.group(1)!, t));
      }
    }
    final numbered = RegExp(r'sheet(\d+)\.xml');
    final sheets = archive.files
        .where((f) => RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(f.name))
        .toList()
      ..sort((a, b) => _numberIn(a.name, numbered).compareTo(_numberIn(b.name, numbered)));
    if (sheets.isEmpty) throw Exception('No sheets were found in this (.xlsx) file.');

    final cell = RegExp(r'<c ([^>]*?)(?:/>|>(.*?)</c>)', dotAll: true);
    final value = RegExp(r'<v>([^<]*)</v>');
    final inline = RegExp(r'<t[^>]*>([^<]*)</t>');
    final result = <String>[];
    for (final sheet in sheets) {
      final rows = <String>[];
      for (final row in RegExp(r'<row[^>]*>(.*?)</row>', dotAll: true).allMatches(_xmlOf(sheet))) {
        final values = <String>[];
        for (final c in cell.allMatches(row.group(1)!)) {
          final attrs = c.group(1) ?? '';
          final body = c.group(2) ?? '';
          final v = value.firstMatch(body)?.group(1);
          String text;
          if (attrs.contains('t="s"') && v != null) {
            final i = int.tryParse(v);
            text = (i != null && i < shared.length) ? shared[i] : '';
          } else if (attrs.contains('t="inlineStr"')) {
            text = _xmlText(body, inline);
          } else {
            text = _unescape(v ?? '');
          }
          if (text.trim().isNotEmpty) values.add(text.trim());
        }
        if (values.isNotEmpty) rows.add(values.join(' | '));
      }
      result.add(rows.join('\n'));
    }
    return result;
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
