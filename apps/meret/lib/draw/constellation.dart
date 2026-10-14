import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../core/bridge.dart';
import '../theme/tokens.dart';

class NoTrailStrip extends StatelessWidget {
  const NoTrailStrip({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: Row(children: [
      Container(width: 9, height: 9, decoration: const BoxDecoration(shape: BoxShape.circle, color: Tok.gold)),
      const SizedBox(width: 8),
      Text('Front', style: Tok.body.copyWith(color: Tok.gold)),
      const SizedBox(width: 20),
      const Expanded(child: Text('no trail yet · open anything to start one', style: Tok.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
    ]),
  );
}
class TrailStrip extends StatelessWidget {
  const TrailStrip({super.key, required this.trail, required this.onGo});
  final TrailDto trail;
  final ValueChanged<int> onGo;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final painter = ConstellationPainter(trail);
    final positions = painter.layoutPositions(box.biggest);
    return Stack(children: [
      Positioned.fill(child: CustomPaint(painter: painter)),
      for (final stop in trail.stops)
        if (positions[stop.index] case final position?)
          Positioned(
            left: position.dx - 12,
            top: position.dy - 12,
            width: 24,
            height: 24,
            child: Semantics(
              key: ValueKey('trail-stop-${stop.index}'),
              button: true,
              selected: stop.index == trail.current,
              label: stop.title,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onGo(stop.index),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
    ]);
  });
}


/// The trail strip: a star per stop, a line per thread. The current branch
/// runs along the main line in gold; other branches sit above and below in
/// grey; forks are ringed; peeks are left out (plates 01, 06).
class ConstellationPainter extends CustomPainter {
  ConstellationPainter(this.trail);

  final TrailDto trail;
  final _labels = <String, TextPainter>{};

  TextPainter _text(String s, TextStyle style) => _labels.putIfAbsent(
        '$s/${style.color}',
        () => TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr)..layout(),
      );
  Map<int, Offset> layoutPositions(Size size) {
    final stops = {for (final stop in trail.stops.where((s) => !s.isPeek || s.onPath)) stop.index: stop};
    final depths = <int, int>{};
    int depth(StopDto stop) => depths.putIfAbsent(stop.index, () {
      final parent = stops[stop.parent];
      return parent == null ? 0 : depth(parent) + 1;
    });
    var maxDepth = 0;
    for (final stop in stops.values) {
      final d = depth(stop);
      if (d > maxDepth) maxDepth = d;
    }
    final step = size.width / (maxDepth + 1.5);
    final middle = size.height * 0.55;
    final positions = <int, Offset>{};
    // The first branch goes below: titles on the main line sit above it.
    var flip = 1.0;
    for (final stop in stops.values.toList()..sort((a, b) => depth(a).compareTo(depth(b)))) {
      final parent = positions[stop.parent];
      final y = stop.onPath ? middle : parent != null && !stops[stop.parent]!.onPath
          ? parent.dy : middle + flip * size.height * 0.28;
      positions[stop.index] = Offset(step * (depth(stop) + 0.5), y);
      if (!stop.onPath && (parent == null || stops[stop.parent]!.onPath)) flip = -flip;
    }
    return positions;
  }


  @override
  void paint(Canvas canvas, Size size) {
    final stops = trail.stops.where((s) => !s.isPeek || s.onPath).toList();
    final pos = layoutPositions(size);

    final gold = Paint()
      ..color = Tok.gold
      ..strokeWidth = 1.2;
    final grey = Paint()
      ..color = Tok.dim
      ..strokeWidth = 1;
    for (final s in stops) {
      final p = pos[s.index], q = pos[s.parent];
      if (p == null || q == null) continue;
      canvas.drawLine(q, p, s.onPath ? gold : grey);
      // Only the main line names its threads; a grey branch's label would sit on the gold one's.
      if (s.via != null && s.onPath) {
        final t = _text(s.via!, Tok.label.copyWith(fontSize: 9.5, fontStyle: FontStyle.italic));
        t.paint(canvas, Offset((p.dx + q.dx) / 2 - t.width / 2, (p.dy + q.dy) / 2 + 8));
      }
    }
    for (final s in stops) {
      final p = pos[s.index];
      if (p == null) continue;
      final current = s.index == trail.current;
      canvas.drawCircle(p, current ? 4.5 : 3, Paint()..color = s.onPath ? Tok.gold : Tok.faint);
      if (s.isFork) {
        canvas.drawCircle(p, 7, Paint()
          ..color = Tok.gold2
          ..style = PaintingStyle.stroke);
      }
      if (s.onPath) {
        final t = _text(s.title, Tok.body.copyWith(fontSize: 11.5, color: current ? Tok.ink : Tok.muted));
        t.paint(canvas, p + Offset(-t.width / 2, -22));
      } else {
        final t = _text(s.title, Tok.label.copyWith(fontSize: 9));
        t.paint(canvas, p + Offset(8, -t.height / 2));
      }
    }
  }


  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    final positions = layoutPositions(size);
    return [for (final stop in trail.stops)
      if (positions[stop.index] case final position?)
        CustomPainterSemantics(
          rect: Rect.fromCenter(center: position, width: 24, height: 24),
          properties: SemanticsProperties(label: stop.title, textDirection: TextDirection.ltr),
        ),
    ];
  };

  @override
  bool shouldRebuildSemantics(ConstellationPainter oldDelegate) => oldDelegate.trail != trail;

  @override
  bool shouldRepaint(ConstellationPainter old) => old.trail != trail;
}
