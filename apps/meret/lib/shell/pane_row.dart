import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Where each pane of a row sits: a window of full panes around the focus,
/// spines either side of it, and what's left over (docs/navigation.md,
/// "The pane row").
@immutable
class RowLayout {
  const RowLayout({required this.start, required this.full, required this.pane, required this.x, required this.widths, this.ghost});

  static const empty = RowLayout(start: 0, full: 0, pane: 0, x: [], widths: []);

  /// The first pane of the window, and how many panes it holds.
  final int start;
  final int full;

  /// A full pane's width; it depends on the row's width alone.
  final double pane;

  /// Each pane's left edge, or null for a spine with no room to show.
  final List<double?> x;
  final List<double> widths;

  /// The slot where the next pane will open: left edge and width.
  final (double, double)? ghost;

  bool showing(int i) => x[i] != null;
}

/// The row of panes along a trail: the path and the stops ahead of it.
///
/// Built on `Flow`, so a move changes paint transforms, never layout. One
/// rule: only the thing that changed moves. A pane that enters fades in
/// from the left, panes that leave drop and fade, and panes that stay
/// slide to their new place when the window shifts. The row never moves
/// as a block.
///
/// Panes that left the row ride along in [parked]: laid out at the width
/// they last had, never painted, hit or focused, so a stop that comes back
/// keeps its loaded data and scroll. Give every pane a `GlobalKey`; the
/// same key moves it between [children] and [parked].
class PaneRow extends StatefulWidget {
  const PaneRow({
    super.key, required this.children, this.focus, this.parked = const [], this.ghost, this.swap = 0,
    this.maxVisible = 5, this.minPane = 440, this.maxPane = 560, this.wide = const {}, this.spine = 46, this.ghostMin = 140,
  });

  final List<Widget> children;

  /// The focused pane; the window shifts only to keep it in view. The last
  /// pane when null.
  final int? focus;

  /// Off-row panes kept mounted, oldest first.
  final List<Widget> parked;

  /// Drawn in the leftover room after the last pane, when there's [ghostMin].
  final Widget? ghost;

  /// 1 or -1 when the next change swaps branches: what enters comes up
  /// from below (1) or down from above (-1) instead of from the left.
  final int swap;

  /// The width class's cap on panes shown at full width.
  final int maxVisible;
  final double minPane;
  final double maxPane;

  /// Indices of panes that take the leftover room (search tables).
  final Set<int> wide;
  final double spine;
  final double ghostMin;

  static const move = Duration(milliseconds: 200);
  static const enter = Duration(milliseconds: 160);
  static const drop = Duration(milliseconds: 160);
  static const swapping = Duration(milliseconds: 180);

  /// How many full panes [width] holds: as many [minPane]-wide panes as fit
  /// with one spine's room kept back, at most [maxVisible].
  static int fit({required double width, required int maxVisible, required double minPane, required double spine}) =>
      ((width - spine) / minPane).floor().clamp(1, math.max(1, maxVisible));

  /// A full pane's width. It doesn't change when a neighbour opens; a lone
  /// pane on a one-pane screen takes the whole width.
  static double paneWidth({required int count, required double width, required int maxVisible, required double minPane, required double maxPane, required double spine}) {
    final n = fit(width: width, maxVisible: maxVisible, minPane: minPane, spine: spine);
    if (n == 1) return count > 1 ? math.max(0, width - spine) : width;
    return math.min(maxPane, (width - spine) / n);
  }

  /// The row's geometry for [count] panes with [focus] in view, keeping the
  /// window at [start] unless the focus has left it.
  static RowLayout layout({
    required int count, required int focus, required int start, required double width, required int maxVisible,
    required double minPane, required double maxPane, required Set<int> wide, required double spine, required double ghostMin,
  }) {
    if (count == 0) return RowLayout.empty;
    final pane = paneWidth(count: count, width: width, maxVisible: maxVisible, minPane: minPane, maxPane: maxPane, spine: spine);
    final n = math.min(count, fit(width: width, maxVisible: maxVisible, minPane: minPane, spine: spine));
    final at = focus.clamp(0, count - 1);
    var s = start.clamp(0, count - n);
    if (at < s) s = at;
    if (at >= s + n) s = at - n + 1;

    // Spines nearest the window show first; the far ones wait for room.
    final slots = math.max(0, ((width - n * pane) / spine + 1e-6).floor());
    final leftNeed = s;
    final rightNeed = count - s - n;
    final left = math.max(0, math.min(leftNeed, slots - (rightNeed > 0 && slots >= 2 ? 1 : 0)));
    final right = math.min(rightNeed, slots - left);

    final widths = [for (var i = 0; i < count; i++) i >= s && i < s + n ? pane : spine];
    var leftover = math.max(0.0, width - n * pane - (left + right) * spine);
    final wideIn = [for (var i = s; i < s + n; i++) if (wide.contains(i)) i];
    if (wideIn.isNotEmpty && leftover > 0) {
      for (final i in wideIn) {
        widths[i] += leftover / wideIn.length;
      }
      leftover = 0;
    }

    final x = List<double?>.filled(count, null);
    var at0 = 0.0;
    for (var i = s - left; i < s + n + right; i++) {
      x[i] = at0;
      at0 += widths[i];
    }
    final ghost = rightNeed == 0 && leftover >= ghostMin ? (at0, leftover) : null;
    return RowLayout(start: s, full: n, pane: pane, x: x, widths: widths, ghost: ghost);
  }

  @override
  State<PaneRow> createState() => _PaneRowState();
}

/// One pane's paint over the clock: from where it was to where it goes.
class _Motion {
  const _Motion({
    required this.fromX, required this.toX, this.fromY = 0, this.toY = 0, this.fromOpacity = 1, this.toOpacity = 1,
    this.delay = 0, required this.length, this.curve = Curves.easeOutCubic,
  });

  final double fromX, toX, fromY, toY, fromOpacity, toOpacity;

  /// Milliseconds into the clock.
  final double delay, length;
  final Curve curve;

  double get end => delay + length;

  ({double x, double y, double opacity}) at(double ms) {
    final t = curve.transform(((ms - delay) / length).clamp(0.0, 1.0));
    double lerp(double a, double b) => a + (b - a) * t;
    return (x: lerp(fromX, toX), y: lerp(fromY, toY), opacity: lerp(fromOpacity, toOpacity));
  }
}

class _PaneRowState extends State<PaneRow> with SingleTickerProviderStateMixin {
  late final _clock = AnimationController(vsync: this)..addStatusListener(_settled);
  var _start = 0;
  double? _width;
  var _length = 1.0;

  /// Where each showing pane settles, by key, as of the last build.
  var _placed = <Key, (double, double)>{};

  /// Panes moving on the clock, by key; leaving ones are parked panes still fading.
  var _motions = <Key, _Motion>{};
  var _leaving = <Key, double>{};

  /// The last full width each keyed pane had; parked panes keep it.
  final _lastWidths = <Key, double>{};

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  void _settled(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    final relayout = _leaving.isNotEmpty;
    _motions = {};
    _leaving = {};
    if (relayout) setState(() {});
  }

  ({double x, double y, double opacity}) _painted(Key key) {
    final motion = _motions[key];
    if (motion != null && _clock.isAnimating) return motion.at(_clock.value * _length);
    final place = _placed[key]!;
    return (x: place.$1, y: 0, opacity: 1);
  }

  /// Starts the motions from what's painted now to [layout]'s places.
  void _plan(RowLayout layout, List<Key?> keys, Set<Key?> parked) {
    final next = <Key, (double, double)>{
      for (var i = 0; i < keys.length; i++)
        if (keys[i] case final key? when layout.showing(i)) key: (layout.x[i]!, layout.widths[i]),
    };
    if (mapEquals(next, _placed)) {
      _placed = next;
      return;
    }
    final swap = widget.swap.sign.toDouble();
    final motions = <Key, _Motion>{};
    final leaving = <Key, double>{};
    var shifted = false;
    for (final MapEntry(:key, value: (x, _)) in next.entries) {
      if (!_placed.containsKey(key)) continue;
      final now = _painted(key);
      if ((now.x - x).abs() > 0.5) shifted = true;
      motions[key] = _Motion(
        fromX: now.x, toX: x, fromY: now.y, fromOpacity: now.opacity,
        length: (swap == 0 ? PaneRow.move : PaneRow.swapping).inMilliseconds.toDouble(),
      );
    }
    for (final MapEntry(:key, value: (_, width)) in _placed.entries) {
      if (next.containsKey(key) || !parked.contains(key)) continue;
      final now = _painted(key);
      leaving[key] = width;
      motions[key] = _Motion(
        fromX: now.x, toX: now.x, fromY: now.y, toY: swap == 0 ? 16 : -swap * 24, fromOpacity: now.opacity, toOpacity: 0,
        length: (swap == 0 ? PaneRow.drop : PaneRow.swapping).inMilliseconds.toDouble(), curve: Curves.easeIn,
      );
    }
    // A pane still fading from an earlier change finishes from where it is.
    final elapsed = _clock.value * _length;
    for (final MapEntry(:key, value: width) in _leaving.entries) {
      final old = _motions[key];
      if (old == null || next.containsKey(key) || !parked.contains(key) || leaving.containsKey(key)) continue;
      final now = _painted(key);
      if (now.opacity <= 0) continue;
      leaving[key] = width;
      motions[key] = _Motion(
        fromX: now.x, toX: now.x, fromY: now.y, toY: old.toY, fromOpacity: now.opacity, toOpacity: 0,
        length: math.max(1, old.end - elapsed), curve: Curves.linear,
      );
    }
    // Follow past the window: the shift first, then the new pane enters.
    final delay = swap != 0 ? 0.0 : shifted ? PaneRow.move.inMilliseconds.toDouble() : leaving.isNotEmpty ? 120.0 : 0.0;
    for (final MapEntry(:key, value: (x, _)) in next.entries) {
      if (_placed.containsKey(key)) continue;
      // One that comes back mid-fade returns from where it is painted.
      if (_leaving.containsKey(key) && _motions.containsKey(key) && _clock.isAnimating) {
        final now = _painted(key);
        motions[key] = _Motion(
          fromX: now.x, toX: x, fromY: now.y, fromOpacity: now.opacity,
          length: (swap == 0 ? PaneRow.move : PaneRow.swapping).inMilliseconds.toDouble(),
        );
        continue;
      }
      motions[key] = _Motion(
        fromX: swap == 0 ? x - 12 : x, toX: x, fromY: swap * 24, fromOpacity: 0, delay: delay,
        length: (swap == 0 ? PaneRow.enter : PaneRow.swapping).inMilliseconds.toDouble(), curve: Curves.easeOut,
      );
    }
    _placed = next;
    _motions = motions;
    _leaving = leaving;
    _length = motions.values.fold(1.0, (end, motion) => math.max(end, motion.end));
    _clock.duration = Duration(milliseconds: _length.ceil());
    _clock.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final PaneRow(:children, :parked) = widget;
    final width = box.maxWidth;
    // A resize fits the window afresh, keeping as much of the path before
    // the focus in view as it can.
    if (_width != width) _start = 0;
    final layout = PaneRow.layout(
      count: children.length, focus: widget.focus ?? children.length - 1, start: _start, width: width,
      maxVisible: widget.maxVisible, minPane: widget.minPane, maxPane: widget.maxPane, wide: widget.wide,
      spine: widget.spine, ghostMin: widget.ghostMin,
    );
    _start = layout.start;
    final keys = [for (final c in children) c.key];
    final parkedKeys = {for (final c in parked) c.key};
    if (_width != width) {
      // A resize settles at once; only navigation moves panes.
      _clock.stop();
      _motions = {};
      _leaving = {};
      _placed = {
        for (var i = 0; i < keys.length; i++)
          if (keys[i] case final key? when layout.showing(i)) key: (layout.x[i]!, layout.widths[i]),
      };
      _width = width;
    } else {
      _plan(layout, keys, parkedKeys);
    }
    _leaving.removeWhere((key, _) => !parkedKeys.contains(key));

    for (var i = 0; i < children.length; i++) {
      if (keys[i] case final key? when layout.widths[i] > widget.spine) _lastWidths[key] = layout.widths[i];
    }
    final all = {...keys, ...parkedKeys};
    _lastWidths.removeWhere((key, _) => !all.contains(key));

    final widths = <double>[
      ...layout.widths,
      for (final c in parked) _leaving[c.key] ?? _lastWidths[c.key] ?? layout.pane,
    ];
    final paints = <int>[
      for (var i = 0; i < parked.length; i++) if (_leaving.containsKey(parked[i].key)) children.length + i,
      for (var i = 0; i < children.length; i++) if (layout.showing(i)) i,
    ];
    final ghost = layout.ghost;
    final showGhost = ghost != null && widget.ghost != null;
    if (showGhost) widths.add(ghost.$2);
    return Flow(
      delegate: _PaneFlow(
        clock: _clock, length: _length, widths: widths, paints: paints, keys: [...keys, for (final c in parked) c.key],
        motions: _motions, placed: _placed, ghost: showGhost ? (widths.length - 1, ghost.$1) : null,
      ),
      children: [
        for (var i = 0; i < children.length; i++) _slot(children[i], onRow: true, painted: layout.showing(i)),
        for (final c in parked) _slot(c, onRow: false, painted: _leaving.containsKey(c.key)),
        if (showGhost) widget.ghost!,
      ],
    );
  });

  /// Every pane sits in the same wrapper, so moving between the row and the
  /// parked set keeps its State.
  Widget _slot(Widget child, {required bool onRow, required bool painted}) => IgnorePointer(
    ignoring: !onRow,
    child: Visibility(visible: painted, maintainState: true, child: RepaintBoundary(child: child)),
  );
}

class _PaneFlow extends FlowDelegate {
  _PaneFlow({
    required this.clock, required this.length, required this.widths, required this.paints, required this.keys,
    required this.motions, required this.placed, required this.ghost,
  }) : super(repaint: clock);

  final Animation<double> clock;
  final double length;

  /// Every child's width: row panes, parked panes, then the ghost.
  final List<double> widths;

  /// Children to paint, bottom first; the rest are laid out but never painted, so they take no hits.
  final List<int> paints;
  final List<Key?> keys;
  final Map<Key, _Motion> motions;
  final Map<Key, (double, double)> placed;
  final (int, double)? ghost;

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      BoxConstraints.tightFor(width: widths[i], height: constraints.biggest.height);

  @override
  void paintChildren(FlowPaintingContext context) {
    final ms = clock.value * length;
    final moving = clock.isAnimating;
    if (ghost case (final i, final x)) context.paintChild(i, transform: Matrix4.translationValues(x, 0, 0));
    for (final i in paints) {
      final key = keys[i];
      final motion = moving ? motions[key] : null;
      if (motion == null) {
        final place = placed[key];
        if (place == null) continue;
        context.paintChild(i, transform: Matrix4.translationValues(place.$1, 0, 0));
        continue;
      }
      final at = motion.at(ms);
      if (at.opacity <= 0) continue;
      context.paintChild(i, transform: Matrix4.translationValues(at.x, at.y, 0), opacity: at.opacity);
    }
  }

  @override
  bool shouldRelayout(_PaneFlow old) => !listEquals(old.widths, widths);

  @override
  bool shouldRepaint(_PaneFlow old) => true;
}
