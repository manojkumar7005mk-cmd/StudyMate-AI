import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../services/model_manager.dart';
import '../services/voice_service.dart';

/// Lists every model with download, use, and delete. Low-memory mode is shared by all models.
class ModelsPage extends StatefulWidget {
  const ModelsPage({
    super.key,
    required this.voice,
    required this.loaded,
    required this.status,
    required this.lowMemory,
    required this.onLowMemory,
    required this.onLoad,
    required this.onUnload,
    required this.onMessage,
  });

  final VoiceService voice;
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
  Map<String, bool> _installed = {};
  String? _activeId;
  String? _busyId;
  String _progress = '';
  bool _speechReady = false;
  bool _speechToolReady = false;
  bool _speechBusy = false;
  String _speechProgress = '';
  int _ctx = 2048;
  Map<String, bool> _voiceInstalled = {};
  String _voiceInUse = '';
  bool _engineReady = true;
  String? _voiceBusyId;
  String _voiceProgress = '';

  @override
  void initState() {
    super.initState();
    _refresh();
    _checkSpeech();
    _loadVoices();
    ModelManager.contextSize().then((v) {
      if (mounted) setState(() => _ctx = v);
    });
  }

  Future<void> _loadVoices() async {
    final installed = <String, bool>{};
    for (final v in piperVoices) {
      installed[v.id] = await widget.voice.isVoiceInstalled(v);
    }
    final chosen = await widget.voice.selectedVoiceId();
    var inUse = chosen == 'system' ? 'system' : '';
    if (inUse.isEmpty) {
      for (final v in piperVoices) {
        if (installed[v.id] != true) continue;
        if (v.id == chosen) {
          inUse = v.id;
          break;
        }
        if (inUse.isEmpty) inUse = v.id; // the first downloaded voice is the default
      }
    }
    final engine = await widget.voice.piperEngineInstalled();
    if (!mounted) return;
    setState(() {
      _voiceInstalled = installed;
      _voiceInUse = inUse;
      _engineReady = engine;
    });
  }

  Future<void> _downloadVoice(PiperVoice v) async {
    setState(() {
      _voiceBusyId = v.id;
      _voiceProgress = 'Starting...';
    });
    try {
      await widget.voice.downloadVoice(v, onStatus: (s) {
        if (mounted) setState(() => _voiceProgress = s);
      });
      widget.onMessage('${v.title} downloaded.');
    } catch (e) {
      widget.onMessage(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      await _loadVoices();
      if (mounted) setState(() => _voiceBusyId = null);
    }
  }

  Future<void> _useVoice(PiperVoice v) async {
    await widget.voice.setSelectedVoice(v.id);
    widget.onMessage('${v.title} will be used.');
    await _loadVoices();
  }

  Future<void> _deleteVoice(PiperVoice v) async {
    await widget.voice.deleteVoice(v);
    widget.onMessage('${v.title} deleted.');
    await _loadVoices();
  }

  Future<void> _sampleVoice(PiperVoice v) async {
    setState(() => _voiceBusyId = v.id);
    _voiceProgress = 'Playing a sample...';
    try {
      await widget.voice.sampleVoice(v);
      final err = widget.voice.lastTtsError;
      if (err != null) widget.onMessage(err);
    } finally {
      if (mounted) setState(() => _voiceBusyId = null);
    }
  }

  Widget _voiceCard(PiperVoice v) {
    final installed = _voiceInstalled[v.id] ?? false;
    final inUse = _voiceInUse == v.id;
    final busy = _voiceBusyId == v.id;
    final who = v.gender == VoiceGender.male ? 'Man' : 'Woman';
    return Card(
      child: ListTile(
        leading: Icon(
          installed ? (inUse ? Icons.check_circle : Icons.record_voice_over) : Icons.cloud_download_outlined,
          color: brandBlue,
        ),
        title: Text(v.title),
        subtitle: Text(busy ? _voiceProgress : '$who voice, ${v.sizeText}${inUse ? '. In use' : ''}'),
        trailing: installed
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Play a sample',
                    icon: const Icon(Icons.play_arrow),
                    onPressed: _voiceBusyId != null ? null : () => _sampleVoice(v),
                  ),
                  if (!inUse) TextButton(onPressed: () => _useVoice(v), child: const Text('Use')),
                  IconButton(
                    tooltip: 'Delete voice',
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: _voiceBusyId != null ? null : () => _deleteVoice(v),
                  ),
                ],
              )
            : IconButton(
                tooltip: 'Download voice',
                icon: const Icon(Icons.download),
                onPressed: _voiceBusyId != null ? null : () => _downloadVoice(v),
              ),
      ),
    );
  }

  Future<void> _refresh() async {
    final installed = <String, bool>{};
    for (final e in modelCatalog) {
      installed[e.id] = await ModelManager.isInstalled(e);
    }
    final active = await ModelManager.activeId();
    if (mounted) {
      setState(() {
        _installed = installed;
        _activeId = active;
      });
    }
  }

  Future<void> _checkSpeech() async {
    final model = await widget.voice.speechModelInstalled();
    final tool = await widget.voice.speechToolInstalled();
    if (mounted) {
      setState(() {
        _speechReady = model;
        _speechToolReady = tool;
      });
    }
  }

  Future<void> _downloadSpeech() async {
    setState(() {
      _speechBusy = true;
      _speechProgress = 'Starting...';
    });
    try {
      final msg = await widget.voice.downloadWhisperModel(onStatus: (s) {
        if (mounted) setState(() => _speechProgress = s);
      });
      widget.onMessage(msg);
    } catch (e) {
      widget.onMessage(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      await _checkSpeech();
      if (mounted) {
        setState(() {
          _speechBusy = false;
          _speechProgress = '';
        });
      }
    }
  }

  Future<void> _download(ModelEntry e) async {
    setState(() {
      _busyId = e.id;
      _progress = 'Starting...';
    });
    try {
      await ModelManager.download(e, (s) {
        if (mounted) setState(() => _progress = s);
      });
      await ModelManager.setActive(e.id);
      widget.onMessage('${e.title} downloaded. Press Load model to use it.');
    } catch (err) {
      widget.onMessage(err.toString().replaceFirst('Exception: ', ''));
    } finally {
      await _refresh();
      if (mounted) {
        setState(() {
          _busyId = null;
          _progress = '';
        });
      }
    }
  }

  Future<void> _use(ModelEntry e) async {
    await ModelManager.setActive(e.id);
    widget.onMessage('${e.title} selected. Press Load model to use it.');
    await _refresh();
  }

  Future<void> _delete(ModelEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${e.title}?'),
        content: const Text('The model files are removed from this PC. You can download them again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (_activeId == e.id && widget.loaded) widget.onUnload();
    await ModelManager.delete(e);
    widget.onMessage('${e.title} deleted.');
    await _refresh();
  }

  Widget _modelCard(ModelEntry e) {
    final installed = _installed[e.id] ?? false;
    final active = _activeId == e.id;
    final busy = _busyId == e.id;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(e.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
                if (active)
                  const Chip(label: Text('In use'), visualDensity: VisualDensity.compact),
              ],
            ),
            const SizedBox(height: 4),
            Text(e.summary),
            const SizedBox(height: 6),
            Text('Size: ${e.sizeText}', style: const TextStyle(fontSize: 13)),
            Text('Memory: ${e.ramText}', style: const TextStyle(fontSize: 13)),
            if (e.lowRamFriendly)
              const Text('Recommended for 4 GB RAM', style: TextStyle(fontSize: 13, color: Colors.green)),
            const SizedBox(height: 4),
            Text(
              installed ? 'Installed on this PC' : 'Not downloaded',
              style: TextStyle(color: installed ? Colors.green : Colors.grey),
            ),
            if (busy) ...[
              const SizedBox(height: 8),
              Text(_progress),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!installed)
                  FilledButton.icon(
                    onPressed: _busyId != null ? null : () => _download(e),
                    icon: const Icon(Icons.download),
                    label: const Text('Download'),
                  ),
                if (installed && !active)
                  OutlinedButton.icon(
                    onPressed: _busyId != null ? null : () => _use(e),
                    icon: const Icon(Icons.check),
                    label: const Text('Use this model'),
                  ),
                if (installed)
                  OutlinedButton.icon(
                    onPressed: _busyId != null ? null : () => _delete(e),
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    label: const Text('Delete', style: TextStyle(color: Colors.red)),
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
    final activeEntry = modelCatalog.where((e) => e.id == _activeId).toList();
    final canLoad = activeEntry.isNotEmpty && (_installed[_activeId] ?? false);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Models',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text('Status: ${widget.status}'),
        const SizedBox(height: 12),
        SwitchListTile(
          value: widget.lowMemory,
          onChanged: widget.onLowMemory,
          title: const Text('Low-memory mode'),
          subtitle: const Text(
            'Use this on 4 GB RAM. It uses a smaller context and skips the vision file to save memory.',
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: (widget.loaded || !canLoad) ? null : widget.onLoad,
                icon: const Icon(Icons.play_arrow),
                label: Text(canLoad ? 'Load ${activeEntry.first.title}' : 'Download a model first'),
              ),
            ),
            if (widget.loaded) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: widget.onUnload,
                icon: const Icon(Icons.stop),
                label: const Text('Unload'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        Text('Answer memory (context)', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text('Short is fastest. Long remembers more of a chat and of your textbook passages. Applies after Load.'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final opt in const [(2048, 'Short 2048'), (4096, 'Standard 4096'), (8192, 'Long 8192')])
              ChoiceChip(
                label: Text(opt.$2),
                selected: _ctx == opt.$1,
                onSelected: (_) async {
                  await ModelManager.setContextSize(opt.$1);
                  if (mounted) setState(() => _ctx = opt.$1);
                  widget.onMessage('Context set to ${opt.$1}. Press Load to apply it.');
                },
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text('AI models', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final e in modelCatalog) _modelCard(e),
        const SizedBox(height: 8),
        const Text(
          'Model: Qwen3.5 2B from the Repasar-Labs build (Qwen base model, Apache 2.0 license).',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 16),
        Text('Speech (voice to text)', style: Theme.of(context).textTheme.titleMedium),
        Card(
          child: ListTile(
            leading: Icon(
              _speechReady && _speechToolReady ? Icons.check_circle : Icons.record_voice_over_outlined,
              color: brandBlue,
            ),
            title: const Text('Whisper base (99+ languages)'),
            subtitle: Text(
              !_speechToolReady
                  ? 'Speech engine (whisper-cli) is not installed in this build.'
                  : _speechBusy
                      ? _speechProgress
                      : _speechReady
                          ? 'Installed. Better accuracy for English, Tamil and many more languages.'
                          : 'Not installed (about 540 MB). Needs about 2 GB free RAM while listening. Replaces the old base file.',
            ),
            isThreeLine: true,
            trailing: _speechReady
                ? IconButton(
                    tooltip: 'Delete speech model',
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () async {
                      await widget.voice.deleteSpeechModel();
                      await _checkSpeech();
                    },
                  )
                : IconButton(
                    tooltip: 'Download speech model',
                    icon: const Icon(Icons.download),
                    onPressed: _speechBusy ? null : _downloadSpeech,
                  ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Tutor voice (offline)', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          _engineReady
              ? 'Pick the voices you like and download only those. They run on this PC with no internet. '
                  'Tamil answers use the Windows voice.'
              : 'The voice engine (piper) is not installed in this build, so the Windows voice is used.',
          style: const TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 8),
        for (final v in piperVoices) _voiceCard(v),
      ],
    );
  }
}
