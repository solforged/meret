import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';

/// The trail in the top line (plate 02): where it started and where you
/// are, how many stops and forks, and `T` for the whole tree. It replaces
/// the strip; the threads themselves are drawn on the panes.
class TrailChip extends StatelessWidget {
  const TrailChip({super.key, required this.trail, required this.onTree, this.compact = false, this.star = false});
  final TrailDto trail;
  final VoidCallback onTree;

  /// A phone's chip: the star and where you are, nothing more.
  final bool compact;

  /// A narrow line's chip: the star alone, with the rest in its tooltip.
  final bool star;

  @override
  Widget build(BuildContext context) {
    final stops = {for (final stop in trail.stops) stop.index: stop};
    final here = stops[trail.current];
    final root = trail.stops.where((stop) => stop.parent == null).firstOrNull;
    final title = trail.name ?? [
      ?root?.title,
      if (here != null && here.index != root?.index) here.title,
    ].join(' → ');
    final name = trail.kept ? '◆ $title' : title;
    final count = trail.stops.where((stop) => !stop.isPeek).length;
    final forks = trail.stops.where((stop) => stop.isFork).length;
    final meta = [
      '$count ${count == 1 ? 'stop' : 'stops'}',
      if (forks > 0) '$forks ${forks == 1 ? 'fork' : 'forks'}',
      'T',
    ].join(' · ');
    final light = Light.of(context).accent;
    return Tooltip(
      message: '$name\n$meta',
      child: InkWell(
        key: const ValueKey('trail-chip'),
        onTap: onTree,
        canRequestFocus: false,
        child: Container(
          height: 26,
          padding: EdgeInsets.symmetric(horizontal: star ? 9 : 10),
          decoration: BoxDecoration(border: Border.all(color: Tok.rule)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 7, height: 7, decoration: BoxDecoration(
              shape: BoxShape.circle, color: light, boxShadow: [BoxShadow(color: light, blurRadius: 6)],
            )),
            if (!star) ...[
              const SizedBox(width: 8),
              Flexible(child: Text(
                compact ? here?.title ?? name : name,
                key: const ValueKey('trail-chip-name'),
                style: Tok.body.copyWith(fontSize: 12, fontWeight: FontWeight.w500, color: Tok.muted),
                maxLines: 1, overflow: TextOverflow.ellipsis,
              )),
              if (!compact) ...[
                const SizedBox(width: 8),
                Flexible(child: Text(meta, style: Tok.label.copyWith(letterSpacing: 0), maxLines: 1, overflow: TextOverflow.clip, softWrap: false)),
              ],
            ],
          ]),
        ),
      ),
    );
  }
}
