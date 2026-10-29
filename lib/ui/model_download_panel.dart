import 'package:flutter/material.dart';
import '../services/model_manager.dart';

/// One card per model: chat, vision and speech. Each has its own progress bar and error.
class ModelDownloadPanel extends StatefulWidget {
  const ModelDownloadPanel({super.key, required this.manager, this.onChanged});
  final ModelManager manager;
  final VoidCallback? onChanged;

  @override
  State<ModelDownloadPanel> createState() => _ModelDownloadPanelState();
}

class _ModelDownloadPanelState extends State<ModelDownloadPanel> {
  List<ModelItem>? _items;
  String? _error;
  final Map<String, bool> _ready = {};
  final Map<String, double> _progress = {};
  final Map<String, String> _errors = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _items = null;
    });
    try {
      final items = await widget.manager.catalog();
      for (final i in items) {
        _ready[i.fileName] = await widget.manager.isReady(i);
      }
      if (!mounted) return;
      setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _download(ModelItem item) async {
    setState(() {
      _errors.remove(item.fileName);
      _progress[item.fileName] = 0;
    });
    try {
      await for (final p in widget.manager.download(item)) {
        if (!mounted) return;
        setState(() => _progress[item.fileName] = p.fraction);
      }
      _ready[item.fileName] = true;
      widget.onChanged?.call();
    } catch (e) {
      _errors[item.fileName] = e.toString();
    } finally {
      if (mounted) setState(() => _progress.remove(item.fileName));
    }
  }

  Future<void> _delete(ModelItem item) async {
    await widget.manager.delete(item);
    if (!mounted) return;
    setState(() => _ready[item.fileName] = false);
    widget.onChanged?.call();
  }

  IconData _icon(ModelRole r) => switch (r) {
        ModelRole.chat => Icons.chat_bubble_outline,
        ModelRole.vision => Icons.image_outlined,
        ModelRole.speech => Icons.mic_none,
      };

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Try again')),
          ]),
        ),
      );
    }
    if (_items == null) return const Center(child: CircularProgressIndicator());

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [for (final item in _items!) _card(item)],
    );
  }

  Widget _card(ModelItem item) {
    final ready = _ready[item.fileName] ?? false;
    final progress = _progress[item.fileName];
    final error = _errors[item.fileName];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(_icon(item.role)),
              const SizedBox(width: 12),
              Expanded(child: Text(item.title, style: Theme.of(context).textTheme.titleMedium)),
              if (ready) const Chip(label: Text('Installed')),
            ]),
            const SizedBox(height: 6),
            Text(item.note),
            if (progress != null) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: progress == 0 ? null : progress),
              const SizedBox(height: 4),
              Text('${(progress * 100).round()}%'),
            ],
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: ready
                  ? OutlinedButton(onPressed: () => _delete(item), child: const Text('Delete'))
                  : FilledButton(
                      onPressed: progress != null ? null : () => _download(item),
                      child: Text(error == null ? 'Download' : 'Retry'),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
