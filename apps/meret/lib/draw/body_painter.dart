import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../core/playhead.dart';
import '../theme/tokens.dart';

/// The radial Body drawing: time runs clockwise, loudness is the outer edge,
/// bands are rings. Drawn from the core's body summary.
///
/// The static drawing is recorded once into a `Picture` per size and summary;
/// each frame replays it and draws only the hand and the played arc. That's
/// what keeps it cheap at 120 Hz.
class BodyPainter extends CustomPainter {
  BodyPainter({required this.clock, required this.lengthMs, required this.loudness, required this.bands, required this.light})
      : super(repaint: clock);

  final PlayheadClock clock;
  final double lengthMs;
  final Uint8List loudness;
  final List<Uint8List> bands;
  final Color light;

  static final _cache = <Object, ui.Picture>{};

  @override
  void paint(Canvas canvas, Size size) {
    final key = Object.hash(size, lengthMs, loudness.length, bands.length, loudness.isEmpty ? 0 : loudness[0]);
    final picture = _cache[key] ??= _record(size);
    canvas.drawPicture(picture);

    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 24;
    final t = (clock.positionMs / lengthMs).clamp(0.0, 1.0);
    final a = -math.pi / 2 + t * 2 * math.pi;

    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r + 6),
      -math.pi / 2,
      t * 2 * math.pi,
      false,
      Paint()
        ..color = light
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawLine(
      c + Offset(math.cos(a), math.sin(a)) * (r * 0.28),
      c + Offset(math.cos(a), math.sin(a)) * (r + 14),
      Paint()
        ..color = Tok.gold
        ..strokeWidth = 1.2,
    );
  }

  ui.Picture _record(Size size) {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 24;

    final guide = Paint()
      ..color = Tok.line
      ..style = PaintingStyle.stroke;
    for (var k = 1; k <= 4; k++) {
      canvas.drawCircle(c, r * (0.3 + 0.175 * k), guide);
    }

    // Minute ticks.
    final tick = Paint()..color = Tok.gold3;
    final minutes = (lengthMs / 60000).floor();
    for (var m = 0; m <= minutes; m++) {
      final a = -math.pi / 2 + (m * 60000 / lengthMs) * 2 * math.pi;
      final d = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + d * (r + 2), c + d * (r + 10), tick);
    }

    // Bands as rings of radial strokes, loudness as the outer edge.
    final rings = [...bands, loudness];
    for (var ring = 0; ring < rings.length; ring++) {
      final data = rings[ring];
      if (data.isEmpty) continue;
      final inner = r * (0.3 + 0.175 * ring);
      final depth = r * 0.15;
      final p = Paint()
        ..color = (ring == rings.length - 1 ? Tok.gold2 : Tok.muted.withValues(alpha: 0.35))
        ..strokeWidth = math.max(1.0, 2 * math.pi * inner / data.length * 0.6);
      for (var i = 0; i < data.length; i++) {
        final a = -math.pi / 2 + i / data.length * 2 * math.pi;
        final d = Offset(math.cos(a), math.sin(a));
        canvas.drawLine(c + d * inner, c + d * (inner + depth * data[i] / 255), p);
      }
    }
    return rec.endRecording();
  }

  @override
  bool shouldRepaint(BodyPainter old) =>
      old.lengthMs != lengthMs || old.loudness != loudness || old.light != light;
}
