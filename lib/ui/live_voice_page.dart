import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../services/llama_service.dart';
import '../services/voice_service.dart';

/// The states the Live Voice screen can show. Each one comes from the real voice loop.
enum VoiceUiState { idle, listening, processing, speaking, paused, error }

/// Live Voice: a turn-by-turn spoken conversation with the local tutor.
class LiveVoicePage extends StatefulWidget {
  const LiveVoicePage({
    super.key,
    required this.llama,
    required this.voice,
    required this.profile,
  });

  final LlamaService llama;
  final VoiceService voice;
  final Map<String, dynamic> profile;

  @override
  State<LiveVoicePage> createState() => _LiveVoicePageState();
}

class _LiveVoicePageState extends State<LiveVoicePage> with SingleTickerProviderStateMixin {
  /// One loop drives the glow, the ripples and the rotating ring.
  late final AnimationController _anim;
  final List<Map<String, String>> _history = [];
  VoiceUiState _state = VoiceUiState.idle;
  bool _running = false;
  bool _paused = false;
  bool _muted = false;
  String _heard = '';
  String _answer = '';
  String? _error;
  List<PiperVoice> _voices = [];
  String _voiceId = '';

  @override
  void initState() {
    super.initState();
    _loadVoices();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))
      ..repeat();
  }

  @override
  void dispose() {
    _running = false;
    widget.voice.stopAll();
    _anim.dispose();
    super.dispose();
  }

  void _set(VoiceUiState s) {
    if (mounted) setState(() => _state = s);
  }

  /// Listen, understand, answer briefly, speak, repeat. Runs until the student stops it.
  Future<void> _start() async {
    if (_running) return;
    if (!widget.llama.running) {
      setState(() => _error = widget.llama.lastCrash ?? 'Load a model in Models first.');
      _set(VoiceUiState.error);
      return;
    }
    final problem = await widget.voice.setupProblem();
    if (problem != null) {
      setState(() => _error = problem);
      _set(VoiceUiState.error);
      return;
    }
    setState(() {
      _running = true;
      _paused = false;
      _error = null;
    });

    while (_running && mounted) {
      if (_paused) {
        _set(VoiceUiState.paused);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        continue;
      }
      try {
        _set(VoiceUiState.listening);
        final heard = await widget.voice.listenOnce(6);
        if (!_running || !mounted || _paused) continue;
        if (heard.trim().isEmpty) continue;

        widget.voice.language = VoiceService.detectLanguage(heard);
        setState(() {
          _heard = heard;
          _answer = '';
        });
        _set(VoiceUiState.processing);
        _history.add({'role': 'user', 'content': heard});
        if (_history.length > 8) _history.removeRange(0, _history.length - 8);

        // Speech starts as soon as the first sentence is ready, while the rest is still written.
        final buffer = StringBuffer();
        StreamController<String>? sentences;
        Future<void>? speakDone;
        var sent = 0; // characters of the reply already handed to the voice
        if (!_muted) {
          sentences = StreamController<String>();
          speakDone = widget.voice.speakStream(sentences.stream);
        }
        try {
          await for (final piece in widget.llama.askStream(
            _history,
            widget.profile,
            voice: true,
            tamil: widget.voice.isTamil,
          )) {
            if (!_running || !mounted) break;
            buffer.write(piece);
            final cleaned = LlamaService.clean(buffer.toString());
            setState(() => _answer = cleaned);
            if (sentences != null) {
              final cut = _speakableEnd(cleaned, sent);
              if (cut > sent) {
                final chunk = cleaned.substring(sent, cut);
                sent = cut;
                if (_state != VoiceUiState.speaking) _set(VoiceUiState.speaking);
                sentences.add(VoiceService.speechClean(chunk));
              }
            }
          }
          final reply = LlamaService.clean(buffer.toString());
          if (sentences != null && _running && mounted && reply.length > sent) {
            if (_state != VoiceUiState.speaking) _set(VoiceUiState.speaking);
            sentences.add(VoiceService.speechClean(reply.substring(sent)));
          }
          _history.add({'role': 'assistant', 'content': reply});
        } finally {
          await sentences?.close();
        }
        if (speakDone != null) await speakDone; // wait until the voice has finished
      } catch (e) {
        _running = false;
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
        _set(VoiceUiState.error);
      }
    }
    if (mounted && _state != VoiceUiState.error) _set(VoiceUiState.idle);
  }

  Future<void> _stop() async {
    _running = false;
    await widget.voice.stopAll();
    _set(VoiceUiState.idle);
  }

  Future<void> _togglePause() async {
    if (!_running) return;
    setState(() => _paused = !_paused);
    if (_paused) await widget.voice.stopAll();
  }

  Future<void> _endSession() async {
    await _stop();
    if (mounted) {
      setState(() {
        _heard = '';
        _answer = '';
        _history.clear();
      });
    }
  }

  String get _statusText {
    switch (_state) {
      case VoiceUiState.idle:
        return 'Tap the microphone to start';
      case VoiceUiState.listening:
        return 'Listening...';
      case VoiceUiState.processing:
        return 'Thinking...';
      case VoiceUiState.speaking:
        return 'Speaking...';
      case VoiceUiState.paused:
        return 'Paused';
      case VoiceUiState.error:
        return 'Something needs attention';
    }
  }

  IconData get _orbIcon {
    switch (_state) {
      case VoiceUiState.listening:
        return Icons.graphic_eq;
      case VoiceUiState.speaking:
        return Icons.volume_up;
      case VoiceUiState.paused:
        return Icons.pause;
      case VoiceUiState.error:
        return Icons.error_outline;
      case VoiceUiState.processing:
      case VoiceUiState.idle:
        return Icons.mic_none;
    }
  }

  Widget _orb() {
    return Semantics(
      label: 'Voice status: $_statusText',
      child: SizedBox(
        width: 280,
        height: 280,
        child: AnimatedBuilder(
          animation: _anim,
          builder: (context, _) => Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: const Size(280, 280),
                painter: _OrbPainter(t: _anim.value, state: _state),
              ),
              if (_state == VoiceUiState.processing)
                const SizedBox(
                  width: 56,
                  height: 56,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                )
              else
                Icon(_orbIcon, color: Colors.white, size: 52),
            ],
          ),
        ),
      ),
    );
  }

  Widget _circleButton({required IconData icon, required String tooltip, required VoidCallback? onTap}) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 52,
            height: 52,
            child: Icon(icon, color: onTap == null ? Colors.grey : brandBlue),
          ),
        ),
      ),
    );
  }

  /// Where the next piece of speech can start: after a finished sentence, or after a comma
  /// when the sentence is long, so the first words are not delayed.
  static int _speakableEnd(String text, int from) {
    var cut = from;
    for (final m in RegExp(r'[.!?\u0964]["\u201D)\]]*\s').allMatches(text, from)) {
      cut = m.end;
    }
    if (cut == from && text.length - from > 90) {
      for (final m in RegExp(r'[,;:]\s').allMatches(text, from + 40)) {
        cut = m.end;
      }
    }
    return cut;
  }

  Future<void> _loadVoices() async {
    final list = <PiperVoice>[];
    for (final v in piperVoices) {
      if (await widget.voice.isVoiceInstalled(v)) list.add(v);
    }
    final id = await widget.voice.selectedVoiceId();
    if (!mounted) return;
    setState(() {
      _voices = list;
      _voiceId = id;
    });
  }

  Future<void> _chooseVoice(String id) async {
    await widget.voice.setSelectedVoice(id);
    if (mounted) setState(() => _voiceId = id);
  }

  /// The voice character picker: every downloaded voice, plus the built-in Windows voice.
  Widget _voiceChoices() {
    if (_voices.isEmpty) {
      return Text(
        'Using the built-in voice. For a natural voice, download one in Models, under Tutor voice.',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    var active = _voiceId == 'system' ? 'system' : '';
    if (active.isEmpty) {
      active = _voices.any((v) => v.id == _voiceId) ? _voiceId : _voices.first.id;
    }
    return Column(
      children: [
        Text('Voice character', style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            for (final v in _voices)
              Tooltip(
                message: v.title,
                child: ChoiceChip(
                  avatar: Icon(v.gender == VoiceGender.male ? Icons.man : Icons.woman, size: 18),
                  label: Text(v.shortTitle),
                  selected: active == v.id,
                  onSelected: (_) => _chooseVoice(v.id),
                ),
              ),
            Tooltip(
              message: 'The built-in Windows voice',
              child: ChoiceChip(
                avatar: const Icon(Icons.computer, size: 18),
                label: const Text('Windows voice'),
                selected: active == 'system',
                onSelected: (_) => _chooseVoice('system'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    if (reduceMotion && _anim.isAnimating) _anim.stop();
    if (!reduceMotion && !_anim.isAnimating) _anim.repeat();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live voice'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Chip(
              avatar: Icon(
                widget.llama.running ? Icons.check_circle : Icons.power_settings_new,
                size: 16,
                color: widget.llama.running ? Colors.green : Colors.grey,
              ),
              label: Text(widget.llama.running ? 'Model ready' : 'Model not loaded'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              _voiceChoices(),
              const Spacer(),
              _orb(),
              const SizedBox(height: 12),
              Text(_statusText, style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_heard.isNotEmpty) ...[
                        Text('You said', style: Theme.of(context).textTheme.labelMedium),
                        Text(_heard),
                        const SizedBox(height: 10),
                      ],
                      if (_answer.isNotEmpty) ...[
                        Text('StudyMate AI', style: Theme.of(context).textTheme.labelMedium),
                        Text(_answer),
                      ],
                      if (_error != null) ...[
                        Text(_error!, style: const TextStyle(color: Colors.red)),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _start,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Try again'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _circleButton(
                    icon: _paused ? Icons.play_arrow : Icons.pause,
                    tooltip: _paused ? 'Resume' : 'Pause',
                    onTap: _running ? _togglePause : null,
                  ),
                  Semantics(
                    button: true,
                    label: _running ? 'Stop listening' : 'Start listening',
                    child: FloatingActionButton.large(
                      onPressed: _running ? _stop : _start,
                      backgroundColor: brandBlue,
                      child: Icon(_running ? Icons.stop : Icons.mic, color: Colors.white, size: 34),
                    ),
                  ),
                  _circleButton(
                    icon: _muted ? Icons.volume_off : Icons.volume_up,
                    tooltip: _muted ? 'Unmute voice' : 'Mute voice',
                    onTap: () => setState(() => _muted = !_muted),
                  ),
                  _circleButton(
                    icon: Icons.close,
                    tooltip: 'End session',
                    onTap: _endSession,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Paints the glowing orb: a breathing halo, ripples while listening or speaking,
/// a rotating coloured ring and a bright core. All of it is driven by one loop [t] (0 to 1).
class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.t, required this.state});

  final double t;
  final VoiceUiState state;

  static const _cyan = Color(0xFF22D3EE);
  static const _pink = Color(0xFFEC4899);
  static const _amber = Color(0xFFF59E0B);
  static const _red = Color(0xFFEF4444);
  static const _slate = Color(0xFF94A3B8);

  List<Color> get _palette {
    switch (state) {
      case VoiceUiState.listening:
        return const [_cyan, brandBlue, brandViolet];
      case VoiceUiState.speaking:
        return const [_pink, brandViolet, brandBlue];
      case VoiceUiState.processing:
        return const [brandBlue, Color(0xFF6366F1), _cyan];
      case VoiceUiState.error:
        return const [_amber, _red, _amber];
      case VoiceUiState.paused:
        return const [_slate, brandBlue, _slate];
      case VoiceUiState.idle:
        return const [brandBlue, brandViolet, Color(0xFF38BDF8)];
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide * 0.2;
    final palette = _palette;
    final active = state == VoiceUiState.listening || state == VoiceUiState.speaking;
    // Smooth 0 to 1 to 0 wave, so the glow breathes without a jump.
    final pulse = 0.5 - 0.5 * math.cos(t * 2 * math.pi);

    // 1. Soft outer glow.
    final glowR = r * (active ? 2.3 + 0.25 * pulse : 1.9 + 0.08 * pulse);
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [
          palette[0].withValues(alpha: active ? 0.55 : 0.28),
          palette[1].withValues(alpha: 0.12),
          palette[1].withValues(alpha: 0),
        ],
        stops: const [0.25, 0.6, 1],
      ).createShader(Rect.fromCircle(center: c, radius: glowR));
    canvas.drawCircle(c, glowR, glow);

    // 2. Ripples that travel out while the tutor listens or speaks.
    if (active) {
      for (var i = 0; i < 3; i++) {
        final p = (t + i / 3) % 1.0;
        final ring = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2 * (1 - p) + 0.6
          ..color = palette[0].withValues(alpha: (1 - p) * 0.7);
        canvas.drawCircle(c, r * (1.0 + 0.9 * p), ring);
      }
    }

    // 3. Rotating coloured ring around the core.
    final ringR = r * (active ? 1.12 + 0.03 * pulse : 1.06);
    final sweep = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..shader = SweepGradient(
        colors: [palette[0], palette[1], palette[2], palette[0]],
        transform: GradientRotation(t * 2 * math.pi),
      ).createShader(Rect.fromCircle(center: c, radius: ringR));
    canvas.drawCircle(c, ringR, sweep);

    // 4. Bright core.
    final coreR = r * (active ? 1.0 + 0.07 * pulse : 1.0 + 0.02 * pulse);
    final core = Paint()
      ..shader = RadialGradient(
        colors: [Colors.white.withValues(alpha: 0.95), palette[0], palette[1]],
        stops: const [0, 0.55, 1],
      ).createShader(Rect.fromCircle(center: c, radius: coreR));
    canvas.drawCircle(c, coreR, core);
  }

  @override
  bool shouldRepaint(covariant _OrbPainter old) => old.t != t || old.state != state;
}
