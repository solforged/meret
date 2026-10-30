import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// A numeric column header drawn as a histogram of its values (plate 04).
/// Dragging across it brushes a range; the caller turns that into a query
/// clause such as `last:30d` and asks the core for new counts.
class HistogramHeader extends StatefulWidget {
  const HistogramHeader({super.key, required this.label, required this.bins, this.range, this.selection, this.onBrush, this.onSetRange, this.height = 48});

  final String label;

  /// The span the bins cover, or the range applied to it, drawn at the
  /// right of the label: `1950–2026`, `11–13`. It opens the same dialog as
  /// the label.
  final String? range;
  final Uint32List bins;
  final (double, double)? selection;
  final ValueChanged<(double, double)?>? onBrush;
  final VoidCallback? onSetRange;
  final double height;

  @override
  State<HistogramHeader> createState() => _HistogramHeaderState();
}

class _HistogramHeaderState extends State<HistogramHeader> {
  // The brush lives in a notifier so dragging repaints without rebuilding.
  late final _brush = ValueNotifier<(double, double)?>(widget.selection);
  double? _start;

  @override
  void didUpdateWidget(HistogramHeader old) {
    super.didUpdateWidget(old);
    if (_start == null) _brush.value = widget.selection;
  }

  @override
  void dispose() {
    _brush.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      double frac(Offset p) => (p.dx / box.maxWidth).clamp(0.0, 1.0);
      final title = widget.label.toUpperCase();
      final range = widget.range;
      // A narrow header keeps both words, the span under the label.
      final stacked = range != null && _width(title) + _width(range) + 12 > box.maxWidth;
      final onSet = widget.onSetRange;
      // "Set DR filter", "Set year filter": acronyms keep their case.
      final tooltip = 'Set ${widget.label == widget.label.toUpperCase() ? widget.label : widget.label.toLowerCase()} filter';
      Widget word(String text, TextStyle style, {bool tip = false}) {
        if (onSet == null) return Text(text, style: style, maxLines: 1, overflow: TextOverflow.clip);
        final button = TextButton(
          onPressed: onSet,
          style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap, alignment: Alignment.centerLeft),
          child: Text(text, style: style, maxLines: 1, overflow: TextOverflow.clip),
        );
        return tip ? Tooltip(message: tooltip, child: button) : button;
      }
      final rangeStyle = Tok.label.copyWith(color: Tok.faint);
      return SizedBox(height: widget.height, child: Stack(children: [
        Positioned.fill(child: GestureDetector(
        onHorizontalDragStart: (d) {
          _start = frac(d.localPosition);
          _brush.value = (_start!, _start!);
        },
        onHorizontalDragUpdate: (d) {
          final a = _start!, b = frac(d.localPosition);
          _brush.value = a < b ? (a, b) : (b, a);
        },
        onHorizontalDragEnd: (_) {
          _start = null;
          widget.onBrush?.call(_brush.value);
        },
        onHorizontalDragCancel: () {
          _start = null;
          _brush.value = widget.selection;
        },
        onDoubleTap: () {
          _brush.value = null;
          widget.onBrush?.call(null);
        },
        child: CustomPaint(painter: _HistogramPainter(widget.bins, _brush, top: stacked ? 28 : 14)),
        )),
        Align(
          alignment: Alignment.topLeft,
          child: stacked
              ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  word(title, Tok.label, tip: true),
                  word(range, rangeStyle),
                ])
              : Row(children: [
                  Expanded(child: Align(alignment: Alignment.centerLeft, child: word(title, Tok.label, tip: true))),
                  if (range != null) word(range, rangeStyle),
                ]),
        ),
      ]));
    });
  }

  static double _width(String text) =>
      (TextPainter(text: TextSpan(text: text, style: Tok.label), textDirection: TextDirection.ltr, maxLines: 1)..layout()).width;
}

class _HistogramPainter extends CustomPainter {
  _HistogramPainter(this.bins, this.brush, {required this.top}) : super(repaint: brush);

  final Uint32List bins;
  final ValueNotifier<(double, double)?> brush;
  final double top;

  @override
  void paint(Canvas canvas, Size size) {
    if (bins.isEmpty) return;
    final max = bins.reduce((a, b) => a > b ? a : b).toDouble();
    final w = size.width / bins.length;
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
  bool shouldRepaint(_HistogramPainter old) => old.bins != bins || old.top != top;
}
