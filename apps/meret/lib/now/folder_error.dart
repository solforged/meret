import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../panes/add_folder.dart';
import '../settings/settings_window.dart';
import '../theme/tokens.dart';

/// An error that Settings ▸ Folders can answer, as the core worded it (it
/// names the file) with the one action that goes there. Shown wherever a
/// play, a pick up or a queue jump fails, and scrolled into view when it
/// appears so a pane's fold never hides it.
class FolderError extends StatefulWidget {
  const FolderError({super.key, required this.message, required this.actionKey, this.padding = const EdgeInsets.symmetric(vertical: 8)});
  final String message;

  /// Each site keeps its own: `now-check-folders`, `up-next-check-folders`.
  final Key actionKey;
  final EdgeInsets padding;

  @override
  State<FolderError> createState() => _FolderErrorState();
}

class _FolderErrorState extends State<FolderError> {
  @override
  void initState() {
    super.initState();
    _reveal();
  }

  @override
  void didUpdateWidget(FolderError old) {
    super.didUpdateWidget(old);
    if (old.message != widget.message) _reveal();
  }

  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) Scrollable.ensureVisible(context, duration: Duration.zero);
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: widget.padding,
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SelectableText(widget.message, style: Tok.label.copyWith(color: Tok.warn)),
      TextButton(
        key: widget.actionKey,
        onPressed: () => showSettings(context, section: SettingsSection.folders),
        child: const Text('Check music folders'),
      ),
    ]),
  );
}

/// Why Play something has nothing to play, in the core's words, with the
/// action that answers it: a folder to add, or the folders to check.
/// [label] and [actions] leave out what the place already says or offers.
class NothingToPlayNote extends StatefulWidget {
  const NothingToPlayNote({
    super.key, required this.reason, required this.core, this.label = true, this.actions = true,
    this.padding = const EdgeInsets.symmetric(vertical: 10),
  });
  final NothingToPlayDto reason;
  final CoreBridge core;
  final bool label;
  final bool actions;
  final EdgeInsets padding;

  @override
  State<NothingToPlayNote> createState() => _NothingToPlayNoteState();
}

class _NothingToPlayNoteState extends State<NothingToPlayNote> {
  String? _error;

  Future<void> _add() async {
    try {
      await addMusicFolder(widget.core, isMounted: () => mounted);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: widget.padding,
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (widget.label) Text(widget.reason.label, style: Tok.label),
      if (_error != null) Text(_error!, style: Tok.label.copyWith(color: Tok.warn)),
      switch (widget.reason.kind) {
        NothingToPlayKind.noMusic when widget.actions => TextButton(
          key: const ValueKey('nothing-add-folder'),
          onPressed: _add,
          child: const Text('Add a folder'),
        ),
        NothingToPlayKind.foldersOffline when widget.actions => TextButton(
          key: const ValueKey('nothing-check-folders'),
          onPressed: () => showSettings(context, section: SettingsSection.folders),
          child: const Text('Check music folders'),
        ),
        _ => const SizedBox.shrink(),
      },
    ]),
  );
}
