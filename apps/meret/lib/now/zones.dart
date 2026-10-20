import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';
import 'now_pane.dart';

/// Output choices and their sound verdicts, as reported by the core.
class PlayOn extends StatefulWidget {
  const PlayOn({super.key, required this.core, required this.now, this.settingsChanges});
  final CoreBridge core;
  final NowDto? now;
  final Listenable? settingsChanges;

  @override
  State<PlayOn> createState() => _PlayOnState();
}

class _PlayOnState extends State<PlayOn> {
  List<ZoneDto> _zones = const [];
  String? _error;
  bool _switching = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    widget.settingsChanges?.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(PlayOn old) {
    super.didUpdateWidget(old);
    if (old.settingsChanges != widget.settingsChanges) {
      old.settingsChanges?.removeListener(_load);
      widget.settingsChanges?.addListener(_load);
    }
    if (old.core != widget.core || old.settingsChanges != widget.settingsChanges ||
        old.now?.anchor?.item != widget.now?.anchor?.item) {
      _load();
    }
  }

  @override
  void dispose() {
    widget.settingsChanges?.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    try {
      final zones = await widget.core.zones();
      if (!mounted || request != _request) return;
      setState(() { _zones = zones; _error = null; });
    } catch (error) {
      if (mounted && request == _request) setState(() => _error = error.toString());
    }
  }

  Future<void> _select(String id) async {
    ++_request;
    setState(() { _switching = true; _error = null; });
    try {
      await widget.core.playOn(id);
      if (mounted) await _load();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    const NowSection(title: 'Play on'),
    for (final zone in _zones)
      Semantics(selected: zone.current, child: NowDoor(
        key: ValueKey('now-zone-${zone.id}'),
        onTap: zone.current || _switching ? null : () => _select(zone.id),
        child: Row(children: [
          Container(
            key: ValueKey('now-zone-marker-${zone.id}'),
            width: 9, height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: zone.current ? Light.of(context).accent : Colors.transparent,
              border: Border.all(color: zone.current ? Light.of(context).accent : Tok.faint, width: 1.5),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(zone.name, style: Tok.body),
            Text(zone.detail, style: Tok.body.copyWith(fontSize: 12, color: Tok.faint)),
          ])),
          const SizedBox(width: 10),
          Text(zone.verdict, textAlign: TextAlign.right, style: Tok.monoSmall.copyWith(
            fontSize: 11, fontWeight: FontWeight.w500, color: zone.warn ? Tok.warn : Tok.ok,
          )),
        ]),
      )),
    if (_error != null) Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(_error!, style: Tok.label.copyWith(color: Tok.warn)),
    ),
  ]);
}
