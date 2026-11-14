import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Small local JSON store. Student data remains on this computer.
class LocalStore {
  static const _profileKey = 'student_profile_v1';
  static const _sessionsKey = 'study_sessions_v1';
  static const _notesKey = 'study_notes_v1';
  static const _completedKey = 'completed_sessions_v1';

  static Future<Map<String, dynamic>> profile() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_profileKey);
    if (raw == null) return {};
    try { return Map<String, dynamic>.from(jsonDecode(raw) as Map); } catch (_) { return {}; }
  }
  static Future<void> saveProfile(Map<String, dynamic> value) async {
    final p = await SharedPreferences.getInstance(); await p.setString(_profileKey, jsonEncode(value));
  }
  static Future<List<Map<String, dynamic>>> _readList(String key) async {
    final p = await SharedPreferences.getInstance(); final raw = p.getString(key);
    if (raw == null) return [];
    try { return (jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList(); } catch (_) { return []; }
  }
  static Future<List<Map<String, dynamic>>> sessions() => _readList(_sessionsKey);
  static Future<void> saveSessions(List<Map<String, dynamic>> values) async {
    final p = await SharedPreferences.getInstance(); await p.setString(_sessionsKey, jsonEncode(values));
  }
  static Future<List<Map<String, dynamic>>> notes() => _readList(_notesKey);
  static Future<void> saveNotes(List<Map<String, dynamic>> values) async {
    final p = await SharedPreferences.getInstance(); await p.setString(_notesKey, jsonEncode(values));
  }
  static Future<List<String>> completed() async {
    final p = await SharedPreferences.getInstance(); return p.getStringList(_completedKey) ?? [];
  }
  static Future<void> markCompleted(String id) async {
    final p = await SharedPreferences.getInstance(); final items = p.getStringList(_completedKey) ?? [];
    if (!items.contains(id)) items.add(id); await p.setStringList(_completedKey, items);
  }
}
