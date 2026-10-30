import 'dart:async';

import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../theme/tokens.dart';

/// The Missing files door: the tracks whose files have gone, which file and
/// folder, and the two ways out: Rescan, or Settings ▸ Folders.
Future<void> showMissingFiles(BuildContext context, CoreBridge core, {required VoidCallback onCheckFolders}) => showDialog<void>(
  context: context,
  barrierColor: Colors.black54,
  builder: (_) => _MissingSheet(core: core, onCheckFolders: onCheckFolders),
);

class _MissingSheet extends StatefulWidget {
  const _MissingSheet({required this.core, required this.onCheckFolders});
  final CoreBridge core;
  final VoidCallback onCheckFolders;

  @override
  State<_MissingSheet> createState() => _MissingSheetState();
}

class _MissingSheetState extends State<_MissingSheet> {
  List<MissingFileDto>? _files;
  String? _error;
  BigInt? _version;
  StreamSubscription<StatusDto>? _statusSub;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _statusSub = widget.core.status().listen((status) {
      final changed = _version != null && _version != status.libraryVersion;
      _version = status.libraryVersion;
      if (changed) _load();
    });
    _load();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final files = await widget.core.missingFiles();
      if (mounted && generation == _generation) setState(() { _files = files; _error = null; });
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error.toString());
    }
  }

  Future<void> _rescan() async {
    try {
      await widget.core.rescan();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  void _checkFolders() {
    Navigator.of(context).pop();
    widget.onCheckFolders();
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    return Dialog(
      key: const ValueKey('missing-sheet'),
      backgroundColor: Tok.panel,
      insetPadding: const EdgeInsets.all(20),
      shape: const RoundedRectangleBorder(side: BorderSide(color: Tok.rule)),
      child: SizedBox(width: 640, height: 480, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 12, 12, 8), child: Row(children: [
          Expanded(child: Text(files == null ? 'Missing files' : 'Missing files · ${files.length}', style: Tok.heading)),
          TextButton(key: const ValueKey('missing-rescan'), onPressed: _rescan, child: const Text('Rescan')),
          TextButton(key: const ValueKey('missing-check-folders'), onPressed: _checkFolders, child: const Text('Check music folders')),
          IconButton(tooltip: 'Close', onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close, size: 18, color: Tok.muted)),
        ])),
        const Divider(height: 1, color: Tok.rule),
        Expanded(child: files == null
          ? Padding(padding: const EdgeInsets.all(20), child: Text(_error ?? 'Reading the library…', style: Tok.label.copyWith(color: _error == null ? null : Tok.warn)))
          : files.isEmpty
            ? const Padding(padding: EdgeInsets.all(20), child: Text('No missing files', style: Tok.label))
            : ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                itemCount: files.length,
                itemBuilder: (context, index) {
                  final file = files[index];
                  return Container(
                    key: ValueKey('missing-file-${file.trackId}'),
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.line))),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(file.file, style: Tok.body.copyWith(color: Tok.warn)),
                      Text(file.folder, style: Tok.data, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text([file.title, if (file.artist != null) file.artist!, file.album].join(' · '), style: Tok.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ]),
                  );
                },
              )),
      ])),
    );
  }
}
