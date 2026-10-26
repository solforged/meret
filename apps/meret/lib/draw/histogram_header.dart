import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// A numeric column header drawn as a histogram of its values (plate 04).
/// Dragging across it brushes a range; the caller turns that into a query
/// clause such as `last:30d` and asks the core for new counts.
class HistogramHeader extends StatefulWidget {
  const HistogramHeader({super.key, required this.label, required this.bins, this.range, this.onBrush, this.height = 44});

  final String label;

  /// The span the bins cover, drawn at the right of the label: `1950–2026`.
  final String? range;
  final Uint32List bins;
  final ValueChanged<(double, double)?>? onBrush;
  final double height;

  @override
  State<HistogramHeader> createState() => _HistogramHeaderState();
}

class _HistogramHeaderState extends State<HistogramHeader> {
  // The brush lives in a notifier so dragging repaints without rebuilding.
  final _brush = ValueNotifier<(double, double)?>(null);
  double? _start;

  @override
  void dispose() {
    _brush.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      double frac(Offset p) => (p.dx / box.maxWidth).clamp(0.0, 1.0);
      return GestureDetector(
        onHorizontalDragStart: (d) => _start = frac(d.localPosition),
        onHorizontalDragUpdate: (d) {
          final a = _start!, b = frac(d.localPosition);
          _brush.value = a < b ? (a, b) : (b, a);
        },
        onHorizontalDragEnd: (_) => widget.onBrush?.call(_brush.value),
        onDoubleTap: () {
          _brush.value = null;
          widget.onBrush?.call(null);
        },
        child: SizedBox(
          height: widget.height,
          child: CustomPaint(
            painter: _HistogramPainter(widget.bins, _brush),
            child: Align(
              alignment: Alignment.topLeft,
              child: Row(children: [
                Flexible(child: Text(widget.label.toUpperCase(), style: Tok.label, maxLines: 1, overflow: TextOverflow.clip)),
                const Spacer(),
                // A narrow header keeps its label and drops the span.
                if (widget.range case final range? when box.maxWidth >= 140) Text(range, style: Tok.label.copyWith(color: Tok.faint)),
              ]),
            ),
          ),
        ),
      );
    });
  }
}

class _HistogramPainter extends CustomPainter {
  _HistogramPainter(this.bins, this.brush) : super(repaint: brush);

  final Uint32List bins;
  final ValueNotifier<(double, double)?> brush;

  @override
  void paint(Canvas canvas, Size size) {
    if (bins.isEmpty) return;
    final max = bins.reduce((a, b) => a > b ? a : b).toDouble();
    final w = size.width / bins.length;
    final top = 14.0;
    final h = size.height - top;
    final sel = brush.value;
    final on = Paint()..color = Tok.gold2;
    final off = Paint()..color = Tok.dim;
    for (var i = 0; i < bins.length; i++) {
      final x = i * w;
      final mid = (x + w / 2) / size.width;
      final inBrush = sel == null || (mid >= sel.$1 && mid <= sel.$2);
      final bh = max == 0 ? 0.0 : h * bins[i] / max;
      canvas.drawRect(Rect.fromLTWH(x + 0.5, size.height - bh, w - 1, bh), inBrush ? on : off);
    }
    if (sel != null) {
      canvas.drawRect(
        Rect.fromLTRB(sel.$1 * size.width, top, sel.$2 * size.width, size.height),
        Paint()..color = Tok.gold.withValues(alpha: 0.08),
      );
    }
  }

  @override
  bool shouldRepaint(_HistogramPainter old) => old.bins != bins;
}
