import 'package:flutter/material.dart';

const educationSystems = [
  'CBSE',
  'ICSE',
  'State Board',
  'IB',
  'Cambridge / IGCSE',
  'Other',
];

const classLevels = [
  'Class 1', 'Class 2', 'Class 3', 'Class 4', 'Class 5', 'Class 6',
  'Class 7', 'Class 8', 'Class 9', 'Class 10', 'Class 11', 'Class 12',
  'College / University',
  'Competitive exam prep',
  'Other',
];

const streams = ['Science', 'Commerce', 'Arts / Humanities'];

const subjectChoices = [
  'Mathematics',
  'Physics',
  'Chemistry',
  'Biology',
  'Computer Science',
  'English',
  'Hindi',
  'Second language',
  'Social Science',
  'History',
  'Geography',
  'Economics',
  'Accountancy',
  'Business Studies',
  'JEE Mathematics',
  'JEE Physics',
  'JEE Chemistry',
  'NEET Biology',
  'NEET Chemistry',
  'NEET Physics',
];

bool _isSeniorClass(String? level) => level == 'Class 11' || level == 'Class 12';

bool _needsCourse(String? level) =>
    level == 'College / University' ||
    level == 'Competitive exam prep' ||
    level == 'Other';

String _text(Object? value) => value?.toString() ?? '';

/// Onboarding and profile editor. Returns the saved profile map, or null if cancelled.
class OnboardingDialog extends StatefulWidget {
  const OnboardingDialog({super.key, required this.initial});

  final Map<String, dynamic> initial;

  @override
  State<OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<OnboardingDialog> {
  late final TextEditingController _name;
  late final TextEditingController _board;
  late final TextEditingController _course;
  late final TextEditingController _goal;
  late final TextEditingController _customSubject;
  late final List<String> _subjects;
  String? _system;
  String? _level;
  String? _stream;
  String? _nameError;

  @override
  void initState() {
    super.initState();
    final p = widget.initial;
    final edu = _text(p['education']);
    final savedBoard = _text(p['board']);

    // Older profiles stored the board name directly, so accept that too.
    if (educationSystems.contains(edu)) {
      _system = edu;
    } else if (educationSystems.contains(savedBoard)) {
      _system = savedBoard;
    } else if (savedBoard.isNotEmpty) {
      _system = 'Other';
    }

    final level = _text(p['class']);
    _level = classLevels.contains(level) ? level : null;

    final stream = _text(p['stream']);
    _stream = streams.contains(stream) ? stream : null;

    _name = TextEditingController(text: _text(p['name']));
    _board = TextEditingController(text: _system == 'Other' ? savedBoard : '');
    _course = TextEditingController(text: _text(p['course']));
    _goal = TextEditingController(text: _text(p['goals']));
    _customSubject = TextEditingController();
    _subjects = _text(p['subjects'])
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  @override
  void dispose() {
    _name.dispose();
    _board.dispose();
    _course.dispose();
    _goal.dispose();
    _customSubject.dispose();
    super.dispose();
  }

  void _addCustomSubject() {
    final s = _customSubject.text.trim();
    if (s.isEmpty) return;
    setState(() {
      if (!_subjects.contains(s)) _subjects.add(s);
      _customSubject.clear();
    });
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Please enter your name.');
      return;
    }
    Navigator.pop(context, <String, dynamic>{
      'name': name,
      'education': _system ?? '',
      'board': _system == 'Other' ? _board.text.trim() : (_system ?? ''),
      'class': _level ?? '',
      'stream': _isSeniorClass(_level) ? (_stream ?? '') : '',
      'course': _needsCourse(_level) ? _course.text.trim() : '',
      'subjects': _subjects.join(', '),
      'goals': _goal.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final allSubjects = {...subjectChoices, ..._subjects};

    return AlertDialog(
      title: const Text("Let's personalise your StudyMate"),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Your details stay on this PC. You can edit them later in Settings.'),
              const SizedBox(height: 14),
              TextField(
                controller: _name,
                decoration: InputDecoration(
                  labelText: 'Your name *',
                  errorText: _nameError,
                ),
                onChanged: (_) {
                  if (_nameError != null) setState(() => _nameError = null);
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _system,
                decoration: const InputDecoration(labelText: 'Education system'),
                items: [
                  for (final e in educationSystems)
                    DropdownMenuItem(value: e, child: Text(e)),
                ],
                onChanged: (v) => setState(() => _system = v),
              ),
              if (_system == 'Other') ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _board,
                  decoration: const InputDecoration(
                    labelText: 'Your board or curriculum',
                  ),
                ),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _level,
                decoration: const InputDecoration(labelText: 'Class or level'),
                items: [
                  for (final c in classLevels)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (v) => setState(() {
                  _level = v;
                  if (!_isSeniorClass(v)) _stream = null;
                }),
              ),
              if (_isSeniorClass(_level)) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _stream,
                  decoration: const InputDecoration(labelText: 'Stream'),
                  items: [
                    for (final s in streams)
                      DropdownMenuItem(value: s, child: Text(s)),
                  ],
                  onChanged: (v) => setState(() => _stream = v),
                ),
              ],
              if (_needsCourse(_level)) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _course,
                  decoration: const InputDecoration(
                    labelText: 'Course or exam (optional)',
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text('Subjects', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in allSubjects)
                    FilterChip(
                      label: Text(s),
                      selected: _subjects.contains(s),
                      onSelected: (on) => setState(() {
                        if (on) {
                          if (!_subjects.contains(s)) _subjects.add(s);
                        } else {
                          _subjects.remove(s);
                        }
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _customSubject,
                      decoration: const InputDecoration(
                        labelText: 'Add a subject not listed',
                      ),
                      onSubmitted: (_) => _addCustomSubject(),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Add subject',
                    icon: const Icon(Icons.add),
                    onPressed: _addCustomSubject,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _goal,
                decoration: const InputDecoration(
                  labelText: 'Exam goal, e.g. JEE 2027 (optional)',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Save profile'),
        ),
      ],
    );
  }
}
