import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// The row of panes along a trail. Older panes fold to spines.
///
/// Built on `Flow`: sliding along the trail changes only paint transforms,
/// never layout, so it runs at display rate however heavy the panes are.
/// Layout happens once, when the number of panes or the width changes.
///
/// Plate 01's geometry: as many panes as fit at [minPane] wide, at most
/// [maxVisible]; the rest fold to [spine]-wide spines on the left. Panes
/// share the width equally, except that panes listed in [wide] (a table)
/// take whatever the others don't need once they reach [maxPane].
///
/// Panes that left the path ride along in [parked]: laid out at the width
/// they last had on the path, never painted, hit or focused, so a stop that
/// comes back keeps its loaded data and scroll. Give every pane a
/// `GlobalKey`; the same key moves it between [children] and [parked].
class PaneRow extends StatefulWidget {
  const PaneRow({
    super.key, required this.children, required this.slide, this.parked = const [],
    this.maxVisible = 5, this.minPane = 440, this.maxPane = 560, this.wide = const {}, this.spine = 46,
  });

  final List<Widget> children;

  /// Off-path panes kept mounted, oldest first.
  final List<Widget> parked;

  /// 0 when settled; eases from 1 for forward or -1 for reverse navigation.
  final Animation<double> slide;

  /// The width class's cap on panes shown at full width.
  final int maxVisible;
  final double minPane;
  final double maxPane;

  /// Indices of panes that absorb spare width (search tables).
  final Set<int> wide;
  final double spine;

  /// How many of [count] panes show at full width in [width].
  static int fit({required int count, required double width, required int maxVisible, required double minPane, required double spine}) {
    if (count == 0) return 0;
    var n = math.min(maxVisible, count);
    while (n > 1 && n * minPane + (count - n) * spine > width) {
      n--;
    }
    return n;
  }

  /// Each pane's width: spines first, then the visible panes.
  static List<double> widths({
    required int count, required double width, required int maxVisible,
    required double minPane, required double maxPane, required Set<int> wide, required double spine,
  }) {
    final visible = fit(count: count, width: width, maxVisible: maxVisible, minPane: minPane, spine: spine);
    final spines = count - visible;
    final room = width - spines * spine;
    final out = List<double>.filled(count, spine);
    if (visible == 0) return out;
    final equal = room / visible;
    final wideIndices = [for (var i = spines; i < count; i++) if (wide.contains(i)) i];
    if (wideIndices.isEmpty || wideIndices.length == visible || equal <= maxPane) {
      for (var i = spines; i < count; i++) {
        out[i] = equal;
      }
      return out;
    }
    // The others take their plate width; the tables split what's left.
    final narrow = visible - wideIndices.length;
    final each = math.min(maxPane, equal);
    final rest = (room - narrow * each) / wideIndices.length;
    for (var i = spines; i < count; i++) {
      out[i] = wide.contains(i) ? rest : each;
    }
    return out;
  }

  @override
  State<PaneRow> createState() => _PaneRowState();
}

class _PaneRowState extends State<PaneRow> {
  /// The last full width each keyed pane had on the path; parked panes keep it.
  final _lastWidths = <Key, double>{};

  @override
  Widget build(BuildContext context) {
    final PaneRow(:children, :parked) = widget;
    final keys = [for (final c in children) c.key, for (final c in parked) c.key];
    _lastWidths.removeWhere((key, _) => !keys.contains(key));
    return Flow(
      delegate: _PaneFlow(
        count: children.length, keys: keys,
        lastWidths: _lastWidths, slide: widget.slide, maxVisible: widget.maxVisible,
        minPane: widget.minPane, maxPane: widget.maxPane, wide: widget.wide, spine: widget.spine,
      ),
      children: [
        for (final c in children) RepaintBoundary(child: c),
        for (final c in parked) Visibility(visible: false, maintainState: true, child: c),
      ],
    );
  }
}

class _PaneFlow extends FlowDelegate {
  _PaneFlow({
    required this.count, required this.keys, required this.lastWidths, required this.slide, required this.maxVisible,
    required this.minPane, required this.maxPane, required this.wide, required this.spine,
  }) : super(repaint: slide);

  /// On-path panes; children past [count] are parked.
  final int count;
  final List<Key?> keys;
  final Map<Key, double> lastWidths;
  final Animation<double> slide;
  final int maxVisible;
  final double minPane;
  final double maxPane;
  final Set<int> wide;
  final double spine;

  List<double> _widths(Size size) => PaneRow.widths(
    count: count, width: size.width, maxVisible: maxVisible,
    minPane: minPane, maxPane: maxPane, wide: wide, spine: spine,
  );

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) {
    final size = constraints.biggest;
    final widths = _widths(size);
    final key = keys[i];
    final double width;
    if (i < count) {
      width = widths[i];
      if (key != null && width > spine) lastWidths[key] = width;
    } else {
      width = (key == null ? null : lastWidths[key]) ?? (widths.isEmpty ? minPane : widths.last);
    }
    return BoxConstraints.tightFor(width: width, height: size.height);
  }

  @override
  void paintChildren(FlowPaintingContext context) {
    final widths = _widths(context.size);
    final spines = count - PaneRow.fit(count: count, width: context.size.width, maxVisible: maxVisible, minPane: minPane, spine: spine);
    final shift = slide.value * (widths.isEmpty ? 0 : widths.last);
    var x = 0.0;
    // Parked panes (past count) are laid out but never painted, so they take no hits.
    for (var i = 0; i < count; i++) {
      // Spines stay put; full panes slide from the direction of navigation.
      final dx = i < spines ? x : x + shift;
      context.paintChild(i, transform: Matrix4.translationValues(dx, 0, 0));
      x += widths[i];
    }
  }

  @override
  bool shouldRelayout(_PaneFlow old) =>
      old.count != count || !listEquals(old.keys, keys) || old.maxVisible != maxVisible || old.minPane != minPane ||
      old.maxPane != maxPane || old.spine != spine || !_sameWide(old.wide);

  bool _sameWide(Set<int> other) => other.length == wide.length && other.containsAll(wide);

  @override
  bool shouldRepaint(_PaneFlow old) => old.slide != slide || shouldRelayout(old);
}
