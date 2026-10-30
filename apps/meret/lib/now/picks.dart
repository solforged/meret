import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;

import '../core/bridge.dart';
import '../theme/tokens.dart';
import 'folder_error.dart';
import 'now_pane.dart';

/// The core's ranked picks, with its reason and playback plan left intact.
/// With none, it says why in the core's words; [actions] adds the one that answers it.
class PlaySomething extends StatefulWidget {
  const PlaySomething({super.key, required this.core, required this.now, this.onRelease, this.actions = true});
  final CoreBridge core;
  final NowDto? now;
  final Future<void> Function(PlatformInt64)? onRelease;
  final bool actions;

  @override
  State<PlaySomething> createState() => _PlaySomethingState();
}

class _PlaySomethingState extends State<PlaySomething> {
  List<PickDto>? _picks;
  NothingToPlayDto? _nothing;
  String? _error;

  /// A pick that would not play: it names the file, and Settings ▸ Folders is the answer.
  String? _playError;
  int _generation = 0;
  StreamSubscription<StatusDto>? _statusSub;
  BigInt? _libraryVersion;
  PlatformInt64? _playing;

  @override
  void initState() {
    super.initState();
    _watchLibrary();
    _load();
  }

  @override
  void didUpdateWidget(PlaySomething old) {
    super.didUpdateWidget(old);
    if (old.core != widget.core) {
      _statusSub?.cancel();
      _libraryVersion = null;
      _watchLibrary();
    }
    if (old.core != widget.core || old.now?.anchor?.item != widget.now?.anchor?.item) _load();
  }

  void _watchLibrary() {
    _statusSub = widget.core.status().listen((status) {
      final changed = _libraryVersion != null && _libraryVersion != status.libraryVersion;
      _libraryVersion = status.libraryVersion;
      if (changed) _load();
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final picks = await widget.core.picks(3);
      final nothing = picks.isEmpty ? await widget.core.nothingToPlay() : null;
      if (!mounted || generation != _generation) return;
      setState(() {
        _picks = picks;
        _nothing = nothing;
        _error = null;
      });
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error.toString());
    }
  }

  Future<void> _play(PickDto pick) async {
    if (_playing != null) return;
    setState(() {
      _playing = pick.releaseId;
      _playError = null;
    });
    try {
      await widget.core.playPick(pick.releaseId);
      if (mounted) await _load();
    } catch (error) {
      if (mounted) setState(() => _playError = error.toString());
    } finally {
      if (mounted) setState(() => _playing = null);
    }
  }

  Future<void> _open(PickDto pick) async {
    try {
      await widget.onRelease?.call(pick.releaseId);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Widget _cell(PickDto pick, {required bool first}) => NowDoor(
    key: ValueKey('now-pick-${pick.releaseId}'),
    onTap: widget.onRelease == null ? null : () => _open(pick),
    semanticLabel: 'Open release: ${pick.title}',
    child: Container(
      key: ValueKey('now-pick-cell-${pick.releaseId}'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: Tok.panel2,
        border: Border(
          top: BorderSide(color: first ? Tok.gold : Tok.line, width: first ? 2 : 1),
          right: const BorderSide(color: Tok.line),
          bottom: const BorderSide(color: Tok.line),
          left: const BorderSide(color: Tok.line),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(pick.label.toUpperCase(), style: Tok.caps.copyWith(color: first ? Tok.gold : Tok.faint))),
        ]),
        const SizedBox(height: 4),
        Text(pick.title, style: Tok.body.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(pick.reason, style: Tok.body.copyWith(color: Tok.muted, fontSize: 12.5)),
        Text(pick.plan, style: Tok.body.copyWith(color: Tok.muted, fontSize: 12.5)),
        const SizedBox(height: 10),
        Text(pick.meta, style: Tok.label),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          if (widget.onRelease != null) TextButton(
            key: ValueKey('now-pick-open-${pick.releaseId}'),
            onPressed: () => _open(pick),
            child: const Text('Open release'),
          ),
          TextButton.icon(
            key: ValueKey('now-pick-play-${pick.releaseId}'),
            onPressed: _playing == null ? () => _play(pick) : null,
            icon: const Icon(Icons.play_arrow, size: 16),
            label: Text(_playing == pick.releaseId ? 'Starting…' : first ? 'Play ⇧Space' : 'Play'),
          ),
        ]),
      ]),
    ),
  );

  @override
  Widget build(BuildContext context) {
    // Nothing until the picks are in: a loading line would flash on Today's first frames.
    if (_picks == null && _error == null && _playError == null) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const NowSection(title: 'Or play something'),
      if (_error != null) Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(_error!, style: Tok.label.copyWith(color: Tok.warn)),
      ),
      if (_playError != null)
        FolderError(message: _playError!, actionKey: const ValueKey('now-pick-check-folders')),
      if (_picks?.isEmpty == true)
        _nothing == null
          ? const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('Nothing to play yet', style: Tok.label))
          : NothingToPlayNote(reason: _nothing!, core: widget.core, actions: widget.actions),
      for (final pick in _picks ?? const <PickDto>[]) _cell(pick, first: identical(pick, _picks!.first)),
    ]);
  }
}
