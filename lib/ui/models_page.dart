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

  @override
  void initState() {
    super.initState();
    _refresh();
    _checkSpeech();
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
    setState(() => _speechBusy = true);
    try {
      final msg = await widget.voice.downloadWhisperModel();
      widget.onMessage(msg);
    } catch (e) {
      widget.onMessage(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      await _checkSpeech();
      if (mounted) setState(() => _speechBusy = false);
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
            title: const Text('Whisper base (English)'),
            subtitle: Text(
              !_speechToolReady
                  ? 'Speech engine (whisper-cli) is not installed in this build.'
                  : _speechReady
                      ? 'Installed'
                      : 'Not installed (about 150 MB)',
            ),
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
      ],
    );
  }
}
