import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../theme/tokens.dart';

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

  @override
  void paint(Canvas canvas, Size size) {
    final stops = trail.stops.where((s) => !s.isPeek).toList();
    final path = stops.where((s) => s.onPath).toList();
    if (path.isEmpty) return;

    final step = size.width / (path.length + 0.5);
    final mid = size.height * 0.55;
    final pos = <int, Offset>{};
    for (var i = 0; i < path.length; i++) {
      pos[path[i].index] = Offset(step * (i + 0.5), mid);
    }
    // Off-branch stops hang above or below their parent, alternating.
    var flip = -1.0;
    for (final s in stops.where((s) => !s.onPath)) {
      final parent = pos[s.parent];
      if (parent == null) continue;
      pos[s.index] = parent + Offset(step * 0.6, flip * size.height * 0.32);
      flip = -flip;
    }

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
      if (s.onPath && s.via != null) {
        final t = _text(s.via!, Tok.label.copyWith(fontSize: 9.5, fontStyle: FontStyle.italic));
        t.paint(canvas, Offset((p.dx + q.dx) / 2 - t.width / 2, mid + 8));
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
        final name = s.entity.split(':').last;
        final t = _text(name, Tok.body.copyWith(fontSize: 11.5, color: current ? Tok.ink : Tok.muted));
        t.paint(canvas, p + Offset(-t.width / 2, -22));
      }
    }
  }

  @override
  bool shouldRepaint(ConstellationPainter old) => old.trail != trail;
}
