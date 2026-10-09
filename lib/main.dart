import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:intl/intl.dart';

import 'core/constants.dart';
import 'services/llama_service.dart';
import 'services/local_store.dart';
import 'services/model_service.dart';
import 'services/planner_service.dart';
import 'ui/onboarding_dialog.dart';
import 'ui/planner_page.dart';

void main() => runApp(const StudyMateApp());

class StudyMateApp extends StatefulWidget {
  const StudyMateApp({super.key});

  @override
  State<StudyMateApp> createState() => _StudyMateAppState();
}

class _StudyMateAppState extends State<StudyMateApp> {
  ThemeMode _mode = ThemeMode.light;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      themeMode: _mode,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: brandBlue),
        scaffoldBackgroundColor: pageBackground,
        cardTheme: const CardThemeData(
          color: Colors.white,
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: brandBlue, brightness: Brightness.dark),
      ),
      home: MainShell(
        onThemeChanged: (dark) =>
            setState(() => _mode = dark ? ThemeMode.dark : ThemeMode.light),
      ),
    );
  }
}

Widget _field(TextEditingController c, String label) => Padding(
      padding: const EdgeInsets.only(top: 9),
      child: TextField(
        controller: c,
        decoration: InputDecoration(labelText: label),
      ),
    );

class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.onThemeChanged});

  final ValueChanged<bool> onThemeChanged;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  static const _labels = [
    'Home', 'Learn', 'Calendar', 'Planner', 'Notes', 'Progress', 'Models', 'Settings',
  ];
  static const _icons = [
    Icons.home_rounded,
    Icons.auto_awesome,
    Icons.calendar_month,
    Icons.event_note,
    Icons.sticky_note_2_outlined,
    Icons.insights,
    Icons.memory,
    Icons.settings_outlined,
  ];
  static const _modelsIndex = 6;

  int _index = 0;
  bool _loading = true;
  bool _dark = false;
  bool _lowMemory = false;
  Map<String, dynamic> _profile = {};
  List<Map<String, dynamic>> _sessions = [];
  List<Map<String, dynamic>> _notes = [];
  List<String> _completed = [];
  String _modelMessage = 'Model not loaded';

  final _models = ModelService();
  final _llama = LlamaService();
  final _tts = FlutterTts();

  @override
  void initState() {
    super.initState();
    _tts.setLanguage('en-US');
    _load();
  }

  @override
  void dispose() {
    _llama.stop();
    _tts.stop();
    super.dispose();
  }

  Future<void> _load() async {
    _profile = await LocalStore.profile();
    _sessions = await LocalStore.sessions();
    _notes = await LocalStore.notes();
    _completed = await LocalStore.completed();
    if (!mounted) return;
    setState(() => _loading = false);
    if (_profile.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onboard();
      });
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  // ---------- Profile ----------

  Future<void> _onboard() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: _profile.isNotEmpty,
      builder: (_) => OnboardingDialog(initial: _profile),
    );
    if (result == null) return;
    _profile = result;
    await LocalStore.saveProfile(_profile);
    if (mounted) setState(() {});
  }

  // ---------- Sessions ----------

  Future<void> _saveSessions() async {
    await LocalStore.saveSessions(_sessions);
    if (mounted) setState(() {});
  }

  Future<void> _addSession({DateTime? date}) async {
    final title = TextEditingController();
    final subject = TextEditingController();
    final start = TextEditingController(text: '16:00');
    final end = TextEditingController(text: '17:00');
    DateTime chosen = date ?? DateTime.now();
    String? error;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Add study session'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _field(title, 'Topic / activity'),
                  _field(subject, 'Subject'),
                  TextButton.icon(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: ctx,
                        initialDate: chosen,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2100),
                      );
                      if (d != null) setD(() => chosen = d);
                    },
                    icon: const Icon(Icons.calendar_today),
                    label: Text(DateFormat('EEE, d MMM yyyy').format(chosen)),
                  ),
                  _field(start, 'Start (HH:mm)'),
                  _field(end, 'End (HH:mm)'),
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
                if (title.text.trim().isEmpty) {
                  setD(() => error = 'Enter a topic.');
                  return;
                }
                if (!PlannerLogic.validTime(start.text) || !PlannerLogic.validTime(end.text)) {
                  setD(() => error = 'Use 24-hour times like 16:30.');
                  return;
                }
                _sessions.add({
                  'id': DateTime.now().microsecondsSinceEpoch.toString(),
                  'title': title.text.trim(),
                  'subject': subject.text.trim(),
                  'date': PlannerLogic.dateKey(chosen),
                  'start': start.text.trim(),
                  'end': end.text.trim(),
                  'created': DateTime.now().toIso8601String(),
                });
                await _saveSessions();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Add session'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _completeSession(String id) async {
    await LocalStore.markCompleted(id);
    _completed = await LocalStore.completed();
    if (mounted) setState(() {});
  }

  Future<void> _deleteSession(String id) async {
    _sessions.removeWhere((s) => s['id'] == id);
    await _saveSessions();
  }

  // ---------- Notes ----------

  Future<void> _addNote({String? title, String? body}) async {
    final t = TextEditingController(text: title ?? '');
    final b = TextEditingController(text: body ?? '');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New note'),
        content: SizedBox(
          width: 450,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _field(t, 'Title'),
                Padding(
                  padding: const EdgeInsets.only(top: 9),
                  child: TextField(
                    controller: b,
                    minLines: 4,
                    maxLines: 10,
                    decoration: const InputDecoration(labelText: 'Notes'),
                  ),
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
              if (b.text.trim().isEmpty) return;
              _notes.insert(0, {
                'id': DateTime.now().microsecondsSinceEpoch.toString(),
                'title': t.text.trim().isEmpty ? 'Untitled' : t.text.trim(),
                'body': b.text.trim(),
                'created': DateTime.now().toIso8601String(),
              });
              await LocalStore.saveNotes(_notes);
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) setState(() {});
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveAnswer(String text) => _addNote(title: 'AI answer', body: text);

  Future<void> _deleteNote(String id) async {
    _notes.removeWhere((n) => n['id'] == id);
    await LocalStore.saveNotes(_notes);
    if (mounted) setState(() {});
  }

  // ---------- Model and voice ----------

  Future<void> _loadModel() async {
    setState(() => _modelMessage = 'Starting local AI...');
    try {
      await _llama.start(lowMemory: _lowMemory);
      if (mounted) setState(() => _modelMessage = '$assistantDisplayName • Ready');
    } catch (e) {
      if (mounted) setState(() => _modelMessage = 'Model not loaded');
      _message(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _unloadModel() async {
    await _llama.stop();
    if (mounted) setState(() => _modelMessage = 'Model not loaded');
  }

  Future<void> _speak(String text) async {
    await _tts.stop();
    await _tts.speak(text);
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: appName,
      applicationVersion: '1.2.0',
      children: const [
        Text('Designed and developed by Manoj Kumar, a student.'),
        Text('Flutter • Dart • llama.cpp • local model inference.'),
        Text('All student data stays on this PC.'),
      ],
    );
  }

  // ---------- Layout ----------

  Widget _header() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [brandBlue, brandViolet]),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Image.asset('assets/branding/studymate_logo_192.png', height: 40, width: 40),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'StudyMate AI',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                ),
                Text(
                  'Your personal learning companion',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .16),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _modelMessage,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final wide = MediaQuery.sizeOf(context).width > 760;

    final pages = <Widget>[
      HomePage(
        profile: _profile,
        sessions: _sessions,
        completed: _completed,
        onNavigate: (i) => setState(() => _index = i),
        onAdd: _addSession,
      ),
      TutorPage(
        profile: _profile,
        llama: _llama,
        onModel: () => setState(() => _index = _modelsIndex),
        onSaveNote: _saveAnswer,
        onSpeak: _speak,
      ),
      CalendarPage(
        sessions: _sessions,
        completed: _completed,
        onAdd: _addSession,
        onComplete: _completeSession,
        onDelete: _deleteSession,
      ),
      PlannerPage(
        sessions: _sessions,
        completed: _completed,
        onSessionsChanged: (list) async {
          _sessions = list;
          await _saveSessions();
        },
      ),
      NotesPage(
        notes: _notes,
        onAdd: () => _addNote(),
        onDelete: _deleteNote,
      ),
      ProgressPage(sessions: _sessions, completed: _completed, notes: _notes),
      ModelsPage(
        service: _models,
        loaded: _llama.running,
        status: _modelMessage,
        lowMemory: _lowMemory,
        onLowMemory: (v) => setState(() => _lowMemory = v),
        onLoad: _loadModel,
        onUnload: _unloadModel,
        onMessage: _message,
      ),
      SettingsPage(
        profile: _profile,
        dark: _dark,
        onProfile: _onboard,
        onTheme: (v) {
          setState(() => _dark = v);
          widget.onThemeChanged(v);
        },
        onAbout: _showAbout,
      ),
    ];

    final content = Column(
      children: [
        _header(),
        Expanded(child: IndexedStack(index: _index, children: pages)),
      ],
    );

    return Scaffold(
      body: SafeArea(
        child: wide
            ? Row(
                children: [
                  NavigationRail(
                    selectedIndex: _index,
                    labelType: NavigationRailLabelType.all,
                    onDestinationSelected: (v) => setState(() => _index = v),
                    destinations: List.generate(
                      _labels.length,
                      (i) => NavigationRailDestination(
                        icon: Icon(_icons[i]),
                        label: Text(_labels[i]),
                      ),
                    ),
                  ),
                  Expanded(child: content),
                ],
              )
            : content,
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (v) => setState(() => _index = v),
              destinations: List.generate(
                _labels.length,
                (i) => NavigationDestination(icon: Icon(_icons[i]), label: _labels[i]),
              ),
            ),
    );
  }
}

// ---------- Home ----------

class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.profile,
    required this.sessions,
    required this.completed,
    required this.onNavigate,
    required this.onAdd,
  });

  final Map<String, dynamic> profile;
  final List<Map<String, dynamic>> sessions;
  final List<String> completed;
  final ValueChanged<int> onNavigate;
  final Future<void> Function({DateTime? date}) onAdd;

  @override
  Widget build(BuildContext context) {
    final today = PlannerLogic.dateKey(DateTime.now());
    final todays = sessions.where((s) => s['date'] == today).toList()
      ..sort((a, b) => a['start'].toString().compareTo(b['start'].toString()));
    final name = profile['name']?.toString() ?? 'Student';

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Hi $name',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(DateFormat('EEEE, d MMMM yyyy').format(DateTime.now())),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _quick('Ask StudyMate', Icons.auto_awesome, 1),
            _quick('Calendar', Icons.calendar_month, 2),
            _quick('Planner', Icons.event_note, 3),
            _quick('My notes', Icons.sticky_note_2_outlined, 4),
            _quick('Progress', Icons.insights, 5),
          ],
        ),
        const SizedBox(height: 20),
        Text("Today's sessions", style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (todays.isEmpty)
          const Text('Nothing planned today. Add a session in Calendar or the Planner.')
        else
          ...todays.map(
            (s) => Card(
              child: ListTile(
                leading: Icon(
                  completed.contains(s['id'].toString())
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: brandBlue,
                ),
                title: Text(s['title'].toString()),
                subtitle: Text('${s['start']}–${s['end']}  ${s['subject'] ?? ''}'),
              ),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () => onAdd(),
          icon: const Icon(Icons.add),
          label: const Text('Add session today'),
        ),
      ],
    );
  }

  Widget _quick(String label, IconData icon, int index) {
    return OutlinedButton.icon(
      onPressed: () => onNavigate(index),
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

// ---------- Calendar ----------

class CalendarPage extends StatefulWidget {
  const CalendarPage({
    super.key,
    required this.sessions,
    required this.completed,
    required this.onAdd,
    required this.onComplete,
    required this.onDelete,
  });

  final List<Map<String, dynamic>> sessions;
  final List<String> completed;
  final Future<void> Function({DateTime? date}) onAdd;
  final ValueChanged<String> onComplete;
  final ValueChanged<String> onDelete;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  DateTime _selected = DateTime.now();

  Future<void> _pick() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _selected,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _selected = d);
  }

  @override
  Widget build(BuildContext context) {
    final key = PlannerLogic.dateKey(_selected);
    final items = widget.sessions.where((s) => s['date'] == key).toList()
      ..sort((a, b) => a['start'].toString().compareTo(b['start'].toString()));

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(() => _selected = DateTime(
                      _selected.year, _selected.month, _selected.day - 1)),
              ),
              Expanded(
                child: TextButton(
                  onPressed: _pick,
                  child: Text(
                    DateFormat('EEEE, d MMM yyyy').format(_selected),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(() => _selected = DateTime(
                      _selected.year, _selected.month, _selected.day + 1)),
              ),
            ],
          ),
          FilledButton.icon(
            onPressed: () => widget.onAdd(date: _selected),
            icon: const Icon(Icons.add),
            label: const Text('Add session'),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: items.isEmpty
                ? const Center(child: Text('No sessions on this day.'))
                : ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final s = items[i];
                      final id = s['id'].toString();
                      final done = widget.completed.contains(id);
                      return Card(
                        child: ListTile(
                          leading: IconButton(
                            tooltip: 'Mark completed',
                            icon: Icon(
                              done ? Icons.check_circle : Icons.radio_button_unchecked,
                              color: brandBlue,
                            ),
                            onPressed: () => widget.onComplete(id),
                          ),
                          title: Text(s['title'].toString()),
                          subtitle: Text('${s['start']}–${s['end']}  ${s['subject'] ?? ''}'),
                          trailing: IconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => widget.onDelete(id),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------- Notes ----------

class NotesPage extends StatefulWidget {
  const NotesPage({
    super.key,
    required this.notes,
    required this.onAdd,
    required this.onDelete,
  });

  final List<Map<String, dynamic>> notes;
  final VoidCallback onAdd;
  final ValueChanged<String> onDelete;

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final list = widget.notes
        .where((n) => '${n['title']} ${n['body']}'.toLowerCase().contains(q))
        .toList();

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Notes',
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              FilledButton.icon(
                onPressed: widget.onAdd,
                icon: const Icon(Icons.add),
                label: const Text('New note'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search your notes',
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: list.isEmpty
                ? const Center(child: Text('No notes yet. Create one or save an AI answer.'))
                : ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final n = list[i];
                      return Card(
                        child: ListTile(
                          leading: const Icon(Icons.sticky_note_2_outlined, color: brandBlue),
                          title: Text(
                            n['title'].toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            n['body'].toString(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => showDialog<void>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text(n['title'].toString()),
                              content: SingleChildScrollView(
                                child: SelectableText(n['body'].toString()),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text('Close'),
                                ),
                              ],
                            ),
                          ),
                          trailing: IconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => widget.onDelete(n['id'].toString()),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------- Progress ----------

class ProgressPage extends StatelessWidget {
  const ProgressPage({
    super.key,
    required this.sessions,
    required this.completed,
    required this.notes,
  });

  final List<Map<String, dynamic>> sessions;
  final List<String> completed;
  final List<Map<String, dynamic>> notes;

  @override
  Widget build(BuildContext context) {
    final total = sessions.length;
    final done = sessions.where((s) => completed.contains(s['id'].toString())).length;
    final ratio = total == 0 ? 0.0 : done / total;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Progress',
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _stat('Sessions planned', '$total'),
            _stat('Completed', '$done'),
            _stat('Notes saved', '${notes.length}'),
          ],
        ),
        const SizedBox(height: 20),
        const Text('Completion'),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: ratio, minHeight: 10),
        const SizedBox(height: 6),
        Text('${(ratio * 100).round()}% of planned sessions done'),
      ],
    );
  }

  Widget _stat(String label, String value) {
    return Card(
      child: Container(
        width: 170,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: brandBlue),
            ),
            Text(label),
          ],
        ),
      ),
    );
  }
}

// ---------- Tutor ----------

class TutorPage extends StatefulWidget {
  const TutorPage({
    super.key,
    required this.profile,
    required this.llama,
    required this.onModel,
    required this.onSaveNote,
    required this.onSpeak,
  });

  final Map<String, dynamic> profile;
  final LlamaService llama;
  final VoidCallback onModel;
  final Future<void> Function(String text) onSaveNote;
  final Future<void> Function(String text) onSpeak;

  @override
  State<TutorPage> createState() => _TutorPageState();
}

class _TutorPageState extends State<TutorPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<Map<String, String>> _history = [];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send([String? prompt]) async {
    final text = (prompt ?? _input.text).trim();
    if (text.isEmpty || _busy) return;
    setState(() {
      _history.add({'role': 'user', 'content': text});
      _busy = true;
      _error = null;
    });
    _input.clear();
    try {
      final answer = await widget.llama.ask(_history, widget.profile);
      if (mounted) setState(() => _history.add({'role': 'assistant', 'content': answer}));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  Future<void> _attach() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'md'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    final text = await File(path).readAsString();
    _input.text = 'Please explain these study notes:\n$text';
  }

  Widget _bubble(BuildContext context, int i) {
    final m = _history[i];
    final user = m['role'] == 'user';
    final content = m['content'] ?? '';
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 700),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: user ? brandBlue : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(
              content,
              style: TextStyle(color: user ? Colors.white : scheme.onSurface, height: 1.4),
            ),
            if (!user)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton.icon(
                    onPressed: () => widget.onSaveNote(content),
                    icon: const Icon(Icons.bookmark_add_outlined, size: 16),
                    label: const Text('Save to notes'),
                  ),
                  TextButton.icon(
                    onPressed: () => widget.onSpeak(content),
                    icon: const Icon(Icons.volume_up_outlined, size: 16),
                    label: const Text('Listen'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'AI tutor',
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              OutlinedButton.icon(
                onPressed: widget.onModel,
                icon: const Icon(Icons.memory),
                label: const Text('Models'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (!widget.llama.running)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: Colors.orange),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('Load a local model in Models to start chatting.'),
                  ),
                  TextButton(onPressed: widget.onModel, child: const Text('Set up')),
                ],
              ),
            ),
          Expanded(
            child: _history.isEmpty
                ? const Center(child: Text('What would you like to learn today?'))
                : ListView.builder(
                    controller: _scroll,
                    itemCount: _history.length,
                    itemBuilder: (context, i) => _bubble(context, i),
                  ),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('StudyMate AI is thinking...'),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in ['Explain simply', 'Give an example', 'Quiz me', 'Solve step by step'])
                ActionChip(
                  label: Text(p),
                  onPressed: _busy ? null : () => _send(p),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: 'Ask a doubt or paste an equation...',
                    prefixIcon: const Icon(Icons.chat_bubble_outline),
                    suffixIcon: IconButton(
                      tooltip: 'Attach a text file',
                      onPressed: _attach,
                      icon: const Icon(Icons.attach_file),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _busy ? null : () => _send(),
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------- Models ----------

class ModelsPage extends StatefulWidget {
  const ModelsPage({
    super.key,
    required this.service,
    required this.loaded,
    required this.status,
    required this.lowMemory,
    required this.onLowMemory,
    required this.onLoad,
    required this.onUnload,
    required this.onMessage,
  });

  final ModelService service;
  final bool loaded;
  final String status;
  final bool lowMemory;
  final ValueChanged<bool> onLowMemory;
  final VoidCallback onLoad;
  final VoidCallback onUnload;
  final ValueChanged<String> onMessage;

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  List<String> _available = [];
  List<String> _local = [];
  bool _checking = false;
  bool _downloading = false;
  double _progress = 0;
  String _downloadName = '';

  @override
  void initState() {
    super.initState();
    _refreshLocal();
  }

  Future<void> _refreshLocal() async {
    final files = await widget.service.localModels();
    if (mounted) setState(() => _local = files);
  }

  Future<void> _discover() async {
    setState(() => _checking = true);
    try {
      final files = await widget.service.discoverFiles();
      if (mounted) setState(() => _available = files);
    } catch (e) {
      widget.onMessage(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _download(String file) async {
    setState(() {
      _downloading = true;
      _progress = 0;
      _downloadName = file;
    });
    try {
      await widget.service.download(file, (received, total) {
        if (mounted && total > 0) setState(() => _progress = received / total);
      });
      widget.onMessage('Downloaded $file');
      await _refreshLocal();
    } catch (e) {
      widget.onMessage(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Models',
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text('Status: ${widget.status}'),
        const SizedBox(height: 12),
        SwitchListTile(
          value: widget.lowMemory,
          onChanged: widget.onLowMemory,
          title: const Text('Low-memory mode'),
          subtitle: const Text('Use a smaller context and skip the image projector.'),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _checking ? null : _discover,
              icon: const Icon(Icons.cloud_download_outlined),
              label: Text(_checking ? 'Checking...' : 'Find model files'),
            ),
            FilledButton.icon(
              onPressed: widget.loaded || _local.isEmpty ? null : widget.onLoad,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Load model'),
            ),
            if (widget.loaded)
              OutlinedButton.icon(
                onPressed: widget.onUnload,
                icon: const Icon(Icons.stop),
                label: const Text('Unload'),
              ),
          ],
        ),
        if (_downloading) ...[
          const SizedBox(height: 12),
          Text('Downloading $_downloadName'),
          LinearProgressIndicator(value: _progress > 0 ? _progress : null),
        ],
        const SizedBox(height: 16),
        Text('Available online', style: Theme.of(context).textTheme.titleMedium),
        if (_available.isEmpty)
          const Text('Press "Find model files" to list downloads.')
        else
          for (final f in _available)
            Card(
              child: ListTile(
                title: Text('$assistantDisplayName model file'),
                trailing: IconButton(
                  tooltip: 'Download',
                  icon: const Icon(Icons.download),
                  onPressed: _downloading ? null : () => _download(f),
                ),
              ),
            ),
        const SizedBox(height: 16),
        Text('On this PC', style: Theme.of(context).textTheme.titleMedium),
        if (_local.isEmpty)
          const Text('No model downloaded yet.')
        else
          for (final f in _local)
            Card(
              child: ListTile(
                leading: const Icon(Icons.memory, color: brandBlue),
                title: Text('$assistantDisplayName (installed)'),
              ),
            ),
      ],
    );
  }
}

// ---------- Settings ----------

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.profile,
    required this.dark,
    required this.onProfile,
    required this.onTheme,
    required this.onAbout,
  });

  final Map<String, dynamic> profile;
  final bool dark;
  final VoidCallback onProfile;
  final ValueChanged<bool> onTheme;
  final VoidCallback onAbout;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Settings',
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(profile['name']?.toString() ?? 'Student'),
            subtitle: const Text('Edit your profile'),
            onTap: onProfile,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: SwitchListTile(
            value: dark,
            onChanged: onTheme,
            title: const Text('Dark theme'),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About StudyMate AI'),
            onTap: onAbout,
          ),
        ),
        const SizedBox(height: 8),
        const Card(
          child: ListTile(
            leading: Icon(Icons.privacy_tip_outlined),
            title: Text('Privacy'),
            subtitle: Text(
              'Profile, sessions, notes and chats stay on this PC. The app downloads model files only when you ask it to.',
            ),
          ),
        ),
      ],
    );
  }
}
