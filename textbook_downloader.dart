import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'book_store.dart';

/// One official Class 10 book, as listed on https://www.tntextbooks.in/p/10th-books.html
class Textbook {
  const Textbook(this.subject, this.medium, this.driveId);

  final String subject;
  final String medium;
  final String driveId;
}

/// Picks the books for a student's profile and downloads them into the book library.
class TextbookDownloader {
  /// Links are the Google Drive file IDs from the English-medium 10th table on the page.
  /// If a link stops working, the page has changed and this list needs updating.
  static const catalog = [
    Textbook('Mathematics', 'English medium', '13XJXdPhuGqU3BG3BPrsmzZwUUFOuH6Of'),
    Textbook('Science', 'English medium', '1n9pMjxmIWqE5llQpHDdh-vFu8Gemsw1k'),
    Textbook('Social Science', 'English medium', '1neVsjraP49u5rtfQBAzMcojHTtoMhqtb'),
    Textbook('English', 'English medium', '1IM8pIb30Td-Od7Xb5kV-kPLns9_TxvQ3'),
    Textbook('Tamil', 'English medium', '126HDzwgKz1gNaSXWJSow2upisHXVe57-'),
  ];

  static const _aliases = {
    'Mathematics': ['math'],
    'Science': ['science', 'physics', 'chemistry', 'biology'],
    'Social Science': ['social', 'history', 'geography', 'economics'],
    'English': ['english'],
    'Tamil': ['tamil'],
  };

  /// Books this profile needs. Only Class 10 has a catalog for now.
  static List<Textbook> wantedFor(Map<String, dynamic> profile) {
    if (profile['class']?.toString() != 'Class 10') return [];
    final subjects = (profile['subjects'] ?? '').toString().toLowerCase();
    return [
      for (final b in catalog)
        if ((_aliases[b.subject] ?? [b.subject.toLowerCase()]).any(subjects.contains)) b,
    ];
  }

  static Future<Directory> _pdfDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}books${Platform.pathSeparator}pdf');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Downloads each book, checks it is a PDF, and imports it on Linux.
  static Future<String> downloadAll(List<Textbook> books, void Function(String) onStatus) async {
    final dir = await _pdfDir();
    final done = <String>[];
    final failed = <String>[];
    for (final b in books) {
      final name = '${b.subject}-${b.medium}'.replaceAll(' ', '_') + '.pdf';
      final dest = File('${dir.path}${Platform.pathSeparator}$name');
      try {
        onStatus('Downloading ${b.subject}...');
        await _downloadDrive(b.driveId, dest);
        if (Platform.isLinux) {
          onStatus('Reading ${b.subject}...');
          await BookStore.importPdf(dest.path);
          done.add(b.subject);
        } else {
          failed.add('${b.subject} (saved, but reading needs the Arch build)');
        }
      } catch (e) {
        failed.add('${b.subject}: ${e.toString().replaceFirst('Exception: ', '')}');
      }
    }
    final parts = <String>[];
    if (done.isNotEmpty) parts.add('Added to your library: ${done.join(', ')}.');
    if (failed.isNotEmpty) parts.add('Not added: ${failed.join('; ')}.');
    return parts.isEmpty ? 'Nothing to download.' : parts.join(' ');
  }

  static Future<void> _downloadDrive(String fileId, File dest) async {
    final client = HttpClient();
    try {
      var uri = Uri.parse('https://drive.google.com/uc?export=download&id=$fileId');
      for (var step = 0; step < 4; step++) {
        final req = await client.getUrl(uri);
        req.headers.set('User-Agent', 'StudyMate-AI');
        final res = await req.close();
        final type = res.headers.contentType?.mimeType ?? '';
        if (res.statusCode == 200 && (type == 'application/pdf' || type == 'application/octet-stream')) {
          await res.pipe(dest.openWrite());
          await _checkPdf(dest);
          return;
        }
        // Large files show a confirmation page first. Its form carries a token that lets the download continue.
        final body = await res.transform(utf8.decoder).join();
        final confirm = RegExp(r'confirm=([0-9A-Za-z_\-]+)').firstMatch(body)?.group(1);
        final uuid = RegExp(r'name="uuid" value="([^"]+)"').firstMatch(body)?.group(1);
        if (confirm == null && uuid == null) break;
        uri = Uri.parse(
          'https://drive.usercontent.google.com/download?id=$fileId&export=download'
          '&confirm=${confirm ?? 't'}${uuid == null ? '' : '&uuid=$uuid'}',
        );
      }
      throw Exception('Google Drive did not return this PDF. The link may be old or the download limit was reached. Try again later.');
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _checkPdf(File f) async {
    final head = await f.openRead(0, 4).fold<List<int>>([], (a, b) => [...a, ...b]);
    if (String.fromCharCodes(head) != '%PDF') {
      if (f.existsSync()) f.deleteSync();
      throw Exception('The downloaded file is not a PDF.');
    }
  }
}
