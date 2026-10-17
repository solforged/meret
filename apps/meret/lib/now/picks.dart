import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../theme/tokens.dart';
import 'now_pane.dart';

/// The core's ranked picks, with its reason and playback plan left intact.
class PlaySomething extends StatefulWidget {
  const PlaySomething({super.key, required this.core, required this.now, this.expanded = false});
  final CoreBridge core;
  final NowDto? now;
  final bool expanded;

  @override
  State<PlaySomething> createState() => _PlaySomethingState();
}

class _PlaySomethingState extends State<PlaySomething> {
  List<PickDto>? _picks;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PlaySomething old) {
    super.didUpdateWidget(old);
    if (old.core != widget.core || old.now?.anchor?.item != widget.now?.anchor?.item) _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final picks = await widget.core.picks(3);
      if (!mounted || generation != _generation) return;
      setState(() {
        _picks = picks;
        _error = null;
      });
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error.toString());
    }
  }

  Future<void> _play(PickDto pick) async {
    try {
      await widget.core.playPick(pick.releaseId);
      if (mounted) await _load();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Widget _cell(PickDto pick, {required bool first}) => NowDoor(
    key: ValueKey('now-pick-${pick.releaseId}'),
    onTap: () => _play(pick),
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
          Expanded(child: Text(pick.label.toUpperCase(), style: Tok.label.copyWith(color: first ? Tok.gold : Tok.faint))),
          if (first) ...[
            const SizedBox(width: 8),
            const Text('Play ⇧Space', style: Tok.label),
          ],
        ]),
        const SizedBox(height: 4),
        Text(pick.title, style: Tok.body.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(pick.reason, style: Tok.body.copyWith(color: Tok.muted, fontSize: 12.5)),
        Text(pick.plan, style: Tok.body.copyWith(color: Tok.muted, fontSize: 12.5)),
        const SizedBox(height: 10),
        Text(pick.meta, style: Tok.label.copyWith(letterSpacing: 0)),
      ]),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    NowSection(title: 'Or play something', meta: widget.expanded ? '⇧Space plays the first · always says why' : null),
    if (_error != null) Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(_error!, style: Tok.label.copyWith(color: Tok.warn)),
    ),
    if (_picks == null && _error == null)
      const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('Finding something to play…', style: Tok.label)),
    if (_picks?.isEmpty == true)
      const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('Nothing to play yet · add a folder', style: Tok.label)),
    for (final pick in _picks ?? const <PickDto>[]) _cell(pick, first: identical(pick, _picks!.first)),
  ]);
}
