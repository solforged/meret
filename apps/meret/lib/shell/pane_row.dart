import 'package:flutter/widgets.dart';

/// The row of panes along a trail. Older panes fold to spines.
///
/// Built on `Flow`: sliding along the trail changes only paint transforms,
/// never layout, so it runs at display rate however heavy the panes are.
/// Layout happens once, when the number of panes or the width changes.
class PaneRow extends StatelessWidget {
  const PaneRow({super.key, required this.children, required this.visible, required this.slide, this.spine = 30});

  final List<Widget> children;

  /// How many panes show at full width; the rest are spines.
  final int visible;

  /// 0 when settled; animates from 1 to 0 as a new pane arrives.
  final Animation<double> slide;
  final double spine;

  @override
  Widget build(BuildContext context) {
    return Flow(
      delegate: _PaneFlow(count: children.length, visible: visible, slide: slide, spine: spine),
      children: [for (final c in children) RepaintBoundary(child: c)],
    );
  }
}

class _PaneFlow extends FlowDelegate {
  _PaneFlow({required this.count, required this.visible, required this.slide, required this.spine})
      : super(repaint: slide);

  final int count;
  final int visible;
  final Animation<double> slide;
  final double spine;

  int get _spines => (count - visible).clamp(0, count);

  double _paneWidth(Size size) => (size.width - _spines * spine) / visible.clamp(1, count == 0 ? 1 : count);

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) {
    final size = constraints.biggest;
    final w = i < _spines ? spine : _paneWidth(size);
    return BoxConstraints.tightFor(width: w, height: size.height);
  }

  @override
  void paintChildren(FlowPaintingContext context) {
    final w = _paneWidth(context.size);
    final shift = slide.value * w;
    var x = 0.0;
    for (var i = 0; i < context.childCount; i++) {
      final childW = i < _spines ? spine : w;
      // Spines stay put; full panes slide in from the right.
      final dx = i < _spines ? x : x + shift;
      context.paintChild(i, transform: Matrix4.translationValues(dx, 0, 0));
      x += childW;
    }
  }

  @override
  bool shouldRelayout(_PaneFlow old) => old.count != count || old.visible != visible || old.spine != spine;

  @override
  bool shouldRepaint(_PaneFlow old) => old.slide != slide || shouldRelayout(old);
}
