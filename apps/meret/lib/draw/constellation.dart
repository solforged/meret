import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../core/bridge.dart';
import '../core/when.dart';
import '../theme/tokens.dart';

/// The tree's depth-and-lane layout: the current branch on the middle
/// lane, earlier branches above and below it.
class TrailTreeLayout {
  TrailTreeLayout(TrailDto trail) {
    final stops = {for (final stop in trail.stops) stop.index: stop};
    int depth(StopDto stop) => depths.putIfAbsent(stop.index, () {
      final parent = stops[stop.parent];
      return parent == null ? 0 : depth(parent) + 1;
    });
    final ordered = stops.values.toList();
    for (final stop in ordered) {
      depth(stop);
    }
    ordered.sort((a, b) {
      final order = depth(a).compareTo(depth(b));
      return order == 0 ? a.index.compareTo(b.index) : order;
    });
    final continued = <int>{};
    var nextLane = 1;
    int lane() {
      final n = nextLane++;
      return n.isOdd ? (n + 1) ~/ 2 : -n ~/ 2;
    }
    for (final stop in ordered) {
      final parentLane = lanes[stop.parent];
      lanes[stop.index] = stop.onPath ? 0
          : parentLane != null && parentLane != 0 && continued.add(stop.parent!) && !stop.isPeek
              ? parentLane : lane();
    }
  }

  final depths = <int, int>{};
  static const rowSpacing = 88.0;
  static const topInset = 52.0;
  static const bottomInset = 44.0;
  final lanes = <int, int>{};
  int get maxDepth => depths.values.fold(0, math.max);
  int get topLane => lanes.values.fold(0, math.min);
  int get bottomLane => lanes.values.fold(0, math.max);
  double get expandedHeight => topInset + (bottomLane - topLane) * rowSpacing + bottomInset;

  double columnSpacing(double width) => (width / (maxDepth + 1)).clamp(224.0, 280.0);

  /// Labels take the room between neighbouring stars, less a gutter, up to a reading width.
  double labelWidth(double width) => (columnSpacing(width) - 24).clamp(190.0, 240.0);

  Map<int, Offset> positions(TrailDto trail, Size size) {
    final step = columnSpacing(size.width);
    final middle = topInset - topLane * rowSpacing;
    return {
      for (final stop in trail.stops)
        if (depths[stop.index] case final depth?)
          stop.index: Offset(
            step * (depth + 0.5 - (stop.isPeek && !stop.onPath ? 0.45 : 0)),
            middle + lanes[stop.index]! * rowSpacing,
          ),
    };
  }
}

String trailActions(List<String> actions) {
  final counts = <String, int>{};
  for (final action in actions) {
    counts.update(action, (count) => count + 1, ifAbsent: () => 1);
  }
  return counts.entries.map((entry) {
    final label = entry.key == 'wanted' ? '♥ want' : entry.key;
    return entry.value == 1 ? label : '$label ×${entry.value}';
  }).join(' · ');
}

/// The whole tree (T): every branch, peek and meeting, at a reading size.
class TrailTree extends StatefulWidget {
  const TrailTree({super.key, required this.trail, required this.onGo});
  final TrailDto trail;
  final ValueChanged<int> onGo;

  @override
  State<TrailTree> createState() => _TrailTreeState();
}

class _TrailTreeState extends State<TrailTree> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final painter = ConstellationPainter(widget.trail);
    final size = Size(painter.contentWidth(box.maxWidth), painter.contentHeight);
    final positions = painter.layoutPositions(size);
    return DecoratedBox(
      decoration: BoxDecoration(color: Tok.void_, border: Border.all(color: Tok.line)),
      child: Scrollbar(
        controller: _scroll,
        thumbVisibility: size.width > box.maxWidth,
        child: SingleChildScrollView(
          key: const ValueKey('tree-drawing-scroll'),
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: size.width, height: size.height,
            child: Stack(children: [
              Positioned.fill(child: CustomPaint(painter: painter)),
              for (final stop in widget.trail.stops)
                if (positions[stop.index] case final position?)
                  Positioned(
                    left: position.dx - 22, top: position.dy - 22, width: 44, height: 44,
                    child: Semantics(
                      key: ValueKey('tree-stop-${stop.index}'),
                      label: stop.isPeek && !stop.onPath ? 'peeked: ${stop.title}' : stop.title,
                      button: true, selected: stop.index == widget.trail.current,
                      child: Tooltip(
                        message: stop.title,
                        excludeFromSemantics: true,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => widget.onGo(stop.index),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                  ),
            ]),
          ),
        ),
      ),
    );
  });
}

/// Current stops run along the gold line; earlier branches get their own lanes.
class ConstellationPainter extends CustomPainter {
  ConstellationPainter(this.trail);

  final TrailDto trail;
  late final _layout = TrailTreeLayout(trail);
  final _labels = <(String, TextStyle, double), TextPainter>{};

  TextPainter _text(String s, TextStyle style, {required double width}) => _labels.putIfAbsent(
    (s, style, width),
    () => TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr, maxLines: 1, ellipsis: '…')
      ..layout(maxWidth: width),
  );

  double labelWidth(Size size) => _layout.labelWidth(size.width);
  double get contentHeight => _layout.expandedHeight;

  double contentWidth(double viewportWidth) => math.max(viewportWidth, (_layout.maxDepth + 1) * 224.0);

  Map<int, Offset> layoutPositions(Size size) => _layout.positions(trail, size);

  @override
  void paint(Canvas canvas, Size size) {
    final stops = trail.stops;
    final pos = layoutPositions(size);
    final width = labelWidth(size);
    final gold = Paint()..color = Tok.gold..strokeWidth = 1.5;
    final grey = Paint()..color = Tok.dim..strokeWidth = 1;
    for (final s in stops) {
      final p = pos[s.index], q = pos[s.parent];
      if (p == null || q == null) continue;
      final peek = s.isPeek && !s.onPath;
      if (peek) {
        _dots(canvas, q, p, Tok.dim);
      } else {
        canvas.drawLine(q, p, s.onPath ? gold : grey);
      }
      if (s.via != null && !peek) {
        final t = _text(s.via!, Tok.label.copyWith(fontSize: 10.5, fontStyle: FontStyle.italic, color: Tok.gold2), width: width);
        t.paint(canvas, Offset((p.dx + q.dx) / 2 - t.width / 2, (p.dy + q.dy) / 2 - t.height - 8));
      }
    }
    for (final (a, b) in trail.meetings) {
      final from = pos[a], to = pos[b];
      if (from != null && to != null) _dots(canvas, from, to, Tok.gold2);
    }
    for (final s in stops) {
      final p = pos[s.index];
      if (p == null) continue;
      final current = s.index == trail.current;
      final peek = s.isPeek && !s.onPath;
      if (peek) {
        canvas.drawLine(p + const Offset(-4, 4), p + const Offset(4, -4), grey..strokeWidth = 2);
      } else {
        if (current) canvas.drawCircle(p, 12, Paint()..color = Tok.gold3);
        canvas.drawCircle(p, current ? 4.5 : 3, Paint()..color = s.onPath ? Tok.gold : Tok.faint);
        if (s.isFork) {
          canvas.drawCircle(p, 9, Paint()..color = Tok.gold2..style = PaintingStyle.stroke);
        }
      }
      final title = _text(peek ? 'peeked: ${s.title}' : s.title, Tok.body.copyWith(
        fontSize: peek ? 11 : 13, color: current ? Tok.ink : s.onPath ? Tok.muted : Tok.faint,
      ), width: width);
      title.paint(canvas, p + Offset(-title.width / 2, -title.height - 28));
      final note = _text([
        clockTime(s.openedMs.toInt()),
        if (s.actions.isNotEmpty) trailActions(s.actions),
        if (current) 'now',
      ].join(' · '), Tok.label.copyWith(fontSize: 10, letterSpacing: 0), width: width);
      note.paint(canvas, p + Offset(-note.width / 2, 15));
    }
  }

  void _dots(Canvas canvas, Offset from, Offset to, Color color) {
    final delta = to - from;
    final distance = delta.distance;
    final paint = Paint()..color = color;
    for (var d = 9.0; d < distance - 8; d += 6) {
      canvas.drawCircle(from + delta * (d / distance), 1, paint);
    }
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    final positions = layoutPositions(size);
    return [for (final stop in trail.stops)
      if (positions[stop.index] case final position?)
        CustomPainterSemantics(
          rect: Rect.fromCenter(center: position, width: 44, height: 44),
          properties: SemanticsProperties(label: stop.title, textDirection: TextDirection.ltr),
        ),
    ];
  };

  @override
  bool shouldRebuildSemantics(ConstellationPainter oldDelegate) => oldDelegate.trail != trail;

  @override
  bool shouldRepaint(ConstellationPainter old) => old.trail != trail;
}
