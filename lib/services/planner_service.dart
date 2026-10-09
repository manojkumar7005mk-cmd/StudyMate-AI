import 'dart:convert';

import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Storage for the weekly timetable and test dates.
/// Study sessions stay in the existing sessions store so Calendar and Progress see them.
class PlannerStore {
  static const _timetableKey = 'timetable_v1';
  static const _testsKey = 'tests_v1';

  static Future<List<Map<String, dynamic>>> _readList(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _writeList(
      String key, List<Map<String, dynamic>> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(items));
  }

  static Future<List<Map<String, dynamic>>> timetable() =>
      _readList(_timetableKey);

  static Future<void> saveTimetable(List<Map<String, dynamic>> items) =>
      _writeList(_timetableKey, items);

  static Future<List<Map<String, dynamic>>> tests() => _readList(_testsKey);

  static Future<void> saveTests(List<Map<String, dynamic>> items) =>
      _writeList(_testsKey, items);
}

/// Pure planning logic. No widgets and no storage, so it can be unit tested.
class PlannerLogic {
  static const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static final _timePattern = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
  static final _dateFormat = DateFormat('yyyy-MM-dd');

  /// DateTime.weekday: 1 = Monday ... 7 = Sunday.
  static String weekdayName(int weekday) => _dayNames[weekday - 1];

  static String dateKey(DateTime d) => _dateFormat.format(d);

  static DateTime? parseDate(String key) {
    try {
      return _dateFormat.parseStrict(key);
    } catch (_) {
      return null;
    }
  }

  static bool validTime(String value) => _timePattern.hasMatch(value.trim());

  static int minutes(String hhmm) {
    final parts = hhmm.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }

  /// Uses the DateTime(y, m, d + n) constructor so DST changes never shift the day.
  static DateTime _day(int year, int month, int day) =>
      DateTime(year, month, day);

  static DateTime? testWhen(Map<String, dynamic> test) {
    final day = parseDate(test['date'].toString());
    final time = test['time'].toString();
    if (day == null || !validTime(time)) return null;
    final m = minutes(time);
    return DateTime(day.year, day.month, day.day, m ~/ 60, m % 60);
  }

  static String countdown(DateTime when, DateTime now) {
    final diff = DateTime.utc(when.year, when.month, when.day)
        .difference(DateTime.utc(now.year, now.month, now.day))
        .inDays;
    if (diff < 0) return 'Passed';
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    return 'In $diff days';
  }

  /// One session per timetable class for each of the next [days] days.
  static List<Map<String, dynamic>> sessionsFromTimetable(
    List<Map<String, dynamic>> timetable,
    DateTime from, {
    int days = 7,
  }) {
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < days; i++) {
      final day = _day(from.year, from.month, from.day + i);
      final date = dateKey(day);
      for (final entry in timetable) {
        if ((entry['day'] as num).toInt() != day.weekday) continue;
        out.add({
          'id': 'tt-${entry['id']}-$date',
          'title': entry['subject'].toString(),
          'subject': entry['subject'].toString(),
          'date': date,
          'start': entry['start'].toString(),
          'end': entry['end'].toString(),
          'created': DateTime.now().toIso8601String(),
          'source': 'timetable',
        });
      }
    }
    return out;
  }

  /// Revision sessions on the [daysBefore] days leading up to a test.
  /// Days already in the past are skipped.
  static List<Map<String, dynamic>> revisionPlan(
    Map<String, dynamic> test,
    DateTime now, {
    int daysBefore = 3,
    String start = '16:00',
    String end = '17:00',
  }) {
    final when = testWhen(test);
    if (when == null) return [];
    final today = _day(now.year, now.month, now.day);
    final out = <Map<String, dynamic>>[];
    for (var i = daysBefore; i >= 1; i--) {
      final day = _day(when.year, when.month, when.day - i);
      if (day.isBefore(today)) continue;
      final date = dateKey(day);
      out.add({
        'id': 'test-${test['id']}-$date',
        'title': 'Revise ${test['subject']}',
        'subject': test['subject'].toString(),
        'date': date,
        'start': start,
        'end': end,
        'created': now.toIso8601String(),
        'source': 'plan',
      });
    }
    return out;
  }

  /// Adds incoming sessions whose ids are not already present.
  static List<Map<String, dynamic>> merge(
    List<Map<String, dynamic>> existing,
    List<Map<String, dynamic>> incoming,
  ) {
    final ids = existing.map((s) => s['id'].toString()).toSet();
    final result = [...existing];
    for (final s in incoming) {
      if (ids.add(s['id'].toString())) result.add(s);
    }
    return result;
  }

  /// Items due in the next 8 days (tests) or today/tomorrow (sessions),
  /// sorted by time. Completed sessions are left out.
  static List<Map<String, dynamic>> reminders({
    required List<Map<String, dynamic>> tests,
    required List<Map<String, dynamic>> sessions,
    required List<String> completed,
    required DateTime now,
  }) {
    final today = _day(now.year, now.month, now.day);
    final horizon = _day(now.year, now.month, now.day + 8);
    final tomorrow = _day(now.year, now.month, now.day + 1);
    final items = <Map<String, dynamic>>[];

    for (final t in tests) {
      final when = testWhen(t);
      if (when == null || when.isBefore(now) || when.isAfter(horizon)) continue;
      items.add({
        'when': when,
        'kind': 'test',
        'label': '${t['subject']} test',
        'detail': (t['topics'] ?? '').toString(),
      });
    }

    for (final s in sessions) {
      if (completed.contains(s['id'].toString())) continue;
      final day = parseDate(s['date'].toString());
      final start = s['start'].toString();
      if (day == null || !validTime(start)) continue;
      if (day.isBefore(today) || day.isAfter(tomorrow)) continue;
      final m = minutes(start);
      items.add({
        'when': DateTime(day.year, day.month, day.day, m ~/ 60, m % 60),
        'kind': 'session',
        'label': s['title'].toString(),
        'detail': '$start–${s['end']}',
      });
    }

    items.sort((a, b) => (a['when'] as DateTime).compareTo(b['when'] as DateTime));
    return items;
  }
}
