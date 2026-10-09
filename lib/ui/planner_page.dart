import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/constants.dart';
import '../services/planner_service.dart';

class PlannerPage extends StatefulWidget {
  const PlannerPage({
    super.key,
    required this.sessions,
    required this.completed,
    required this.onSessionsChanged,
  });

  final List<Map<String, dynamic>> sessions;
  final List<String> completed;
  final Future<void> Function(List<Map<String, dynamic>> sessions)
      onSessionsChanged;

  @override
  State<PlannerPage> createState() => _PlannerPageState();
}

class _PlannerPageState extends State<PlannerPage> {
  List<Map<String, dynamic>> _timetable = [];
  List<Map<String, dynamic>> _tests = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final timetable = await PlannerStore.timetable();
    final tests = await PlannerStore.tests();
    if (!mounted) return;
    setState(() {
      _timetable = timetable;
      _tests = tests;
    });
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  // ---------- Timetable ----------

  List<Map<String, dynamic>> _sortedTimetable() {
    final list = [..._timetable];
    list.sort((a, b) {
      final day = (a['day'] as num).compareTo(b['day'] as num);
      if (day != 0) return day;
      return PlannerLogic.minutes(a['start'].toString())
          .compareTo(PlannerLogic.minutes(b['start'].toString()));
    });
    return list;
  }

  Future<void> _addClass() async {
    final subject = TextEditingController();
    final start = TextEditingController(text: '09:00');
    final end = TextEditingController(text: '10:00');
    int day = DateTime.now().weekday;
    String? error;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Add class to timetable'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  value: day,
                  decoration: const InputDecoration(labelText: 'Day'),
                  items: List.generate(
                    7,
                    (i) => DropdownMenuItem(
                      value: i + 1,
                      child: Text(PlannerLogic.weekdayName(i + 1)),
                    ),
                  ),
                  onChanged: (v) => setD(() => day = v ?? day),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: subject,
                  decoration: const InputDecoration(labelText: 'Subject'),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: start,
                        decoration:
                            const InputDecoration(labelText: 'Start (HH:mm)'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: end,
                        decoration:
                            const InputDecoration(labelText: 'End (HH:mm)'),
                      ),
                    ),
                  ],
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(error!, style: const TextStyle(color: Colors.red)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final s = start.text.trim();
                final e = end.text.trim();
                if (subject.text.trim().isEmpty) {
                  setD(() => error = 'Enter a subject.');
                  return;
                }
                if (!PlannerLogic.validTime(s) || !PlannerLogic.validTime(e)) {
                  setD(() => error = 'Use 24-hour times like 09:30.');
                  return;
                }
                if (PlannerLogic.minutes(e) <= PlannerLogic.minutes(s)) {
                  setD(() => error = 'End time must be after start time.');
                  return;
                }
                setState(() => _timetable.add({
                      'id': DateTime.now().microsecondsSinceEpoch.toString(),
                      'day': day,
                      'subject': subject.text.trim(),
                      'start': s,
                      'end': e,
                    }));
                await PlannerStore.saveTimetable(_timetable);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteClass(String id) async {
    setState(() => _timetable.removeWhere((e) => e['id'] == id));
    await PlannerStore.saveTimetable(_timetable);
  }

  Future<void> _addWeekToCalendar() async {
    if (_timetable.isEmpty) {
      _toast('Add classes to your timetable first.');
      return;
    }
    final incoming =
        PlannerLogic.sessionsFromTimetable(_timetable, DateTime.now());
    final merged = PlannerLogic.merge(widget.sessions, incoming);
    final added = merged.length - widget.sessions.length;
    await widget.onSessionsChanged(merged);
    _toast('Added $added class session(s) for the next 7 days.');
  }

  Widget _timetableTab() {
    final sorted = _sortedTimetable();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _addClass,
              icon: const Icon(Icons.add),
              label: const Text('Add class'),
            ),
            OutlinedButton.icon(
              onPressed: _addWeekToCalendar,
              icon: const Icon(Icons.event_available),
              label: const Text('Add next 7 days to calendar'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: sorted.isEmpty
              ? const Center(child: Text('No classes yet. Add your weekly timetable.'))
              : ListView.separated(
                  itemCount: sorted.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final e = sorted[i];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.schedule, color: brandBlue),
                        title: Text(e['subject'].toString()),
                        subtitle: Text(
                          '${PlannerLogic.weekdayName((e['day'] as num).toInt())} • ${e['start']}–${e['end']}',
                        ),
                        trailing: IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _deleteClass(e['id'].toString()),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ---------- Tests ----------

  List<Map<String, dynamic>> _sortedTests() {
    final list = [..._tests];
    list.sort((a, b) {
      final wa = PlannerLogic.testWhen(a);
      final wb = PlannerLogic.testWhen(b);
      if (wa == null || wb == null) {
        return (wa == null ? 1 : 0) - (wb == null ? 1 : 0);
      }
      return wa.compareTo(wb);
    });
    return list;
  }

  Future<void> _addTest() async {
    final subject = TextEditingController();
    final time = TextEditingController(text: '10:00');
    final topics = TextEditingController();
    DateTime chosen = DateTime.now().add(const Duration(days: 7));
    String? error;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Add test'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: subject,
                    decoration: const InputDecoration(labelText: 'Subject'),
                  ),
                  const SizedBox(height: 10),
                  TextButton.icon(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: ctx,
                        initialDate: chosen,
                        firstDate: DateTime.now(),
                        lastDate: DateTime(2100),
                      );
                      if (d != null) setD(() => chosen = d);
                    },
                    icon: const Icon(Icons.calendar_today),
                    label: Text(DateFormat('EEE, d MMM yyyy').format(chosen)),
                  ),
                  TextField(
                    controller: time,
                    decoration: const InputDecoration(labelText: 'Time (HH:mm)'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: topics,
                    minLines: 2,
                    maxLines: 4,
                    decoration:
                        const InputDecoration(labelText: 'Topics (optional)'),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(error!, style: const TextStyle(color: Colors.red)),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                if (subject.text.trim().isEmpty) {
                  setD(() => error = 'Enter a subject.');
                  return;
                }
                if (!PlannerLogic.validTime(time.text)) {
                  setD(() => error = 'Use 24-hour time like 10:00.');
                  return;
                }
                setState(() => _tests.add({
                      'id': DateTime.now().microsecondsSinceEpoch.toString(),
                      'subject': subject.text.trim(),
                      'date': PlannerLogic.dateKey(chosen),
                      'time': time.text.trim(),
                      'topics': topics.text.trim(),
                    }));
                await PlannerStore.saveTests(_tests);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Save test'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteTest(String id) async {
    setState(() => _tests.removeWhere((t) => t['id'] == id));
    await PlannerStore.saveTests(_tests);
  }

  Future<void> _buildPlan(Map<String, dynamic> test) async {
    final plan = PlannerLogic.revisionPlan(test, DateTime.now());
    if (plan.isEmpty) {
      _toast('No revision days left before this test.');
      return;
    }
    final merged = PlannerLogic.merge(widget.sessions, plan);
    final added = merged.length - widget.sessions.length;
    await widget.onSessionsChanged(merged);
    _toast('Added $added revision session(s) to your calendar.');
  }

  Widget _testsTab() {
    final sorted = _sortedTests();
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FilledButton.icon(
          onPressed: _addTest,
          icon: const Icon(Icons.add),
          label: const Text('Add test'),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: sorted.isEmpty
              ? const Center(child: Text('No tests yet. Add an exam date to get reminders.'))
              : ListView.separated(
                  itemCount: sorted.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final t = sorted[i];
                    final when = PlannerLogic.testWhen(t);
                    final subtitle = when == null
                        ? 'Date or time not set'
                        : '${DateFormat('EEE d MMM, HH:mm').format(when)} • ${PlannerLogic.countdown(when, now)}';
                    final topics = (t['topics'] ?? '').toString();
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.flag_outlined, color: Colors.red),
                        title: Text('${t['subject']}'),
                        subtitle: Text(topics.isEmpty ? subtitle : '$subtitle\n$topics'),
                        isThreeLine: topics.isNotEmpty,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Add revision sessions before this test',
                              icon: const Icon(Icons.auto_fix_high),
                              onPressed: () => _buildPlan(t),
                            ),
                            IconButton(
                              tooltip: 'Delete test',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _deleteTest(t['id'].toString()),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ---------- Reminders ----------

  Widget _remindersTab() {
    final now = DateTime.now();
    final items = PlannerLogic.reminders(
      tests: _tests,
      sessions: widget.sessions,
      completed: widget.completed,
      now: now,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Reminders appear here while StudyMate is open. Tests show 8 days ahead; sessions show today and tomorrow.',
        ),
        const SizedBox(height: 12),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('Nothing due soon. Add a test or a session.'))
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final r = items[i];
                    final when = r['when'] as DateTime;
                    final isTest = r['kind'] == 'test';
                    final detail = r['detail'].toString();
                    return Card(
                      child: ListTile(
                        leading: Icon(
                          isTest ? Icons.flag_outlined : Icons.alarm,
                          color: isTest ? Colors.red : brandBlue,
                        ),
                        title: Text(r['label'].toString()),
                        subtitle: Text(
                          '${DateFormat('EEE d MMM, HH:mm').format(when)} • ${PlannerLogic.countdown(when, now)}'
                          '${detail.isEmpty ? '' : '\n$detail'}',
                        ),
                        isThreeLine: detail.isNotEmpty,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Planner',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text('Weekly timetable, test dates and reminders. Everything stays on this PC.'),
            const SizedBox(height: 12),
            const TabBar(
              tabs: [
                Tab(text: 'Timetable'),
                Tab(text: 'Tests'),
                Tab(text: 'Reminders'),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TabBarView(
                children: [_timetableTab(), _testsTab(), _remindersTab()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
