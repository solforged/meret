import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../core/when.dart';
import '../theme/action_target.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';

/// The trail in the top line (plate 02): where it started and where you
/// are, how many stops, and `T` for the whole tree. It replaces the strip;
/// the threads themselves are drawn on the panes.
///
/// The stop you're at is the useful end, so when the line is short the
/// start gives way and the current stop's name stays. [cue] flashes the
/// border: `[` at the first stop has nowhere to go, and says so without words.
class TrailChip extends StatefulWidget {
  const TrailChip({super.key, required this.trail, required this.onTree, this.compact = false, this.star = false, this.cue});
  final TrailDto trail;
  final VoidCallback onTree;

  /// A phone's chip: the star and where you are, nothing more.
  final bool compact;

  /// A narrow line's chip: the star alone, with the rest in its tooltip.
  final bool star;

  /// Changes each time the chip should flash.
  final Listenable? cue;

  @override
  State<TrailChip> createState() => _TrailChipState();
}

class _TrailChipState extends State<TrailChip> with SingleTickerProviderStateMixin {
  static const flash = Duration(milliseconds: 420);
  late final _flash = AnimationController(vsync: this, duration: flash);

  @override
  void initState() {
    super.initState();
    widget.cue?.addListener(_cued);
  }

  @override
  void didUpdateWidget(TrailChip old) {
    super.didUpdateWidget(old);
    if (old.cue != widget.cue) {
      old.cue?.removeListener(_cued);
      widget.cue?.addListener(_cued);
    }
  }

  @override
  void dispose() {
    widget.cue?.removeListener(_cued);
    _flash.dispose();
    super.dispose();
  }

  void _cued() => _flash.forward(from: 0);

  /// 0 → 1 quickly, then back to 0.
  double get _strength {
    final t = _flash.value;
    return t < 0.25 ? t / 0.25 : 1 - (t - 0.25) / 0.75;
  }

  static final _style = Tok.body.copyWith(fontSize: 12, fontWeight: FontWeight.w500, color: Tok.muted);

  /// "start → current" when it fits [width]; otherwise the start gives way,
  /// as far as "start… → current", then to the current stop alone. The stop
  /// you're at is the useful end.
  static String _fit(BuildContext context, String lead, String current, double width, {required bool kept}) {
    final scaler = MediaQuery.textScalerOf(context);
    final painter = TextPainter(textDirection: TextDirection.ltr, textScaler: scaler, maxLines: 1);
    bool fits(String text) {
      painter.text = TextSpan(text: text, style: _style);
      painter.layout();
      return painter.width <= width;
    }
    String start(int runes) => String.fromCharCodes(lead.runes.take(runes));
    String chosen() {
      if (fits('$lead → $current')) return '$lead → $current';
      var low = 0, high = lead.runes.length;
      while (low < high) {
        final middle = (low + high + 1) ~/ 2;
        if (fits('${start(middle)}… → $current')) {
          low = middle;
        } else {
          high = middle - 1;
        }
      }
      // Less than a few letters of the start says nothing.
      return low >= 4 ? '${start(low)}… → $current' : kept ? '◆ $current' : current;
    }
    final text = chosen();
    painter.dispose();
    return text;
  }

  @override
  Widget build(BuildContext context) {
    final TrailChip(:trail, :compact, :star) = widget;
    final stops = {for (final stop in trail.stops) stop.index: stop};
    final here = stops[trail.current];
    final root = trail.stops.where((stop) => stop.parent == null).firstOrNull;
    final lead = '${trail.kept ? '◆ ' : ''}${trail.name ?? root?.title ?? ''}';
    final current = here != null && here.index != root?.index ? here.title : null;
    final name = current == null ? lead : '$lead → $current';
    final count = trail.stops.where((stop) => !stop.isPeek).length;
    final meta = '$count ${count == 1 ? 'stop' : 'stops'} · T';
    final tip = '$name\n$meta · last visited ${dayAndTime(trail.whenMs.toInt())}';
    final light = Light.of(context).accent;
    return Tooltip(
      message: tip,
      excludeFromSemantics: true,
      child: ActionTarget(
        key: const ValueKey('trail-chip'),
        onTap: widget.onTree,
        semanticLabel: 'Show trail tree: $name. $meta',
        excludeChildSemantics: true,
        child: AnimatedBuilder(
          animation: _flash,
          builder: (context, child) => Container(
            height: 26,
            padding: EdgeInsets.symmetric(horizontal: star ? 9 : 10),
            decoration: BoxDecoration(border: Border.all(color: Color.lerp(Tok.rule, Tok.gold, _strength)!)),
            child: child,
          ),
          // Squeezed by the LCD, the stop count gives way first: it's in the tooltip.
          child: LayoutBuilder(builder: (context, box) {
            final metaStyle = Tok.label;
            final painter = TextPainter(text: TextSpan(text: meta, style: metaStyle), textDirection: TextDirection.ltr,
              textScaler: MediaQuery.textScalerOf(context), maxLines: 1)..layout();
            final showMeta = !compact && box.maxWidth - 7 - 8 - 8 - painter.width >= 48;
            painter.dispose();
            return Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 7, height: 7, decoration: BoxDecoration(
                shape: BoxShape.circle, color: light, boxShadow: [BoxShadow(color: light, blurRadius: 6)],
              )),
              if (!star) ...[
                const SizedBox(width: 8),
                Flexible(child: LayoutBuilder(builder: (context, box) => Text(
                  compact ? here?.title ?? name : current == null ? name : _fit(context, lead, current, box.maxWidth, kept: trail.kept),
                  key: const ValueKey('trail-chip-name'),
                  style: _style,
                  maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false,
                ))),
                if (showMeta) ...[
                  const SizedBox(width: 8),
                  Text(meta, style: metaStyle, maxLines: 1, softWrap: false),
                ],
              ],
            ]);
          }),
        ),
      ),
    );
  }
}
