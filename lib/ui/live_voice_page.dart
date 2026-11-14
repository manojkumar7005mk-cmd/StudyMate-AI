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
  late final AnimationController _breath;
  final List<Map<String, String>> _history = [];
  VoiceUiState _state = VoiceUiState.idle;
  bool _running = false;
  bool _paused = false;
  bool _muted = false;
  String _heard = '';
  String _answer = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _breath = AnimationController(vsync: this, duration: const Duration(seconds: 3))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _running = false;
    widget.voice.stopAll();
    _breath.dispose();
    super.dispose();
  }

  void _set(VoiceUiState s) {
    if (mounted) setState(() => _state = s);
  }

  /// Listen, understand, answer briefly, speak, repeat. Runs until the student stops it.
  Future<void> _start() async {
    if (_running) return;
    if (!widget.llama.running) {
      setState(() => _error = 'Load a model in Models first.');
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

        setState(() {
          _heard = heard;
          _answer = '';
        });
        _set(VoiceUiState.processing);
        _history.add({'role': 'user', 'content': heard});
        if (_history.length > 8) _history.removeRange(0, _history.length - 8);

        final buffer = StringBuffer();
        await for (final piece in widget.llama.askStream(_history, widget.profile, voice: true)) {
          if (!_running || !mounted) break;
          buffer.write(piece);
          setState(() => _answer = LlamaService.clean(buffer.toString()));
        }
        final reply = LlamaService.clean(buffer.toString());
        _history.add({'role': 'assistant', 'content': reply});
        if (!_running || !mounted) break;

        if (!_muted && reply.isNotEmpty) {
          _set(VoiceUiState.speaking);
          await widget.voice.speakAndWait(VoiceService.spokenPart(reply));
        }
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

  Widget _orb(BuildContext context) {
    final active = _state == VoiceUiState.listening || _state == VoiceUiState.speaking;
    final accent = _state == VoiceUiState.speaking ? brandViolet : brandBlue;
    return AnimatedBuilder(
      animation: _breath,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_breath.value);
        final scale = _state == VoiceUiState.listening
            ? 1.0 + 0.06 * t
            : _state == VoiceUiState.speaking
                ? 1.0 + 0.10 * t
                : 1.0 + 0.03 * t;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 190,
            height: 190,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                colors: [Color(0xFFB4C5FF), brandBlue, brandViolet],
                stops: [0.0, 0.6, 1.0],
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: active ? 0.28 : 0.12),
                  blurRadius: 36,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Center(
              child: _state == VoiceUiState.processing
                  ? const SizedBox(
                      width: 64,
                      height: 64,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                    )
                  : Icon(_orbIcon, color: Colors.white, size: 56),
            ),
          ),
        );
      },
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

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    if (reduceMotion && _breath.isAnimating) _breath.stop();
    if (!reduceMotion && !_breath.isAnimating) _breath.repeat(reverse: true);

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
              const Spacer(),
              Semantics(label: 'Voice status: $_statusText', child: _orb(context)),
              const SizedBox(height: 20),
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
