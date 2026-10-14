import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../core/playhead.dart';
import '../draw/body_painter.dart';
import '../theme/tokens.dart';

/// Now: the playing body, the signal path and, later, the queue.
/// Pinned at the right on large screens; a bar on phones.
class NowPane extends StatelessWidget {
  const NowPane({super.key, required this.now, required this.clock, required this.onToggle});

  final NowDto? now;
  final PlayheadClock clock;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final n = now;
    final length = n?.lengthMs?.toDouble() ?? 1;
    return Container(
      color: Tok.panel,
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('NOW', style: Tok.label),
        const SizedBox(height: 8),
        Text(n?.title ?? 'Nothing playing', style: Tok.title.copyWith(fontSize: 17)),
        Text(n?.subtitle ?? '', style: Tok.body.copyWith(color: Tok.muted, fontSize: 12)),
        const SizedBox(height: 8),
        // Rebuilt per tick, but only this one Text.
        ListenableBuilder(
          listenable: clock,
          builder: (_, _) => Text('${_fmt(clock.positionMs)} / ${_fmt(length)}', style: Tok.monoSmall),
        ),
        Expanded(
          child: GestureDetector(
            onTap: onToggle,
            child: RepaintBoundary(
              child: CustomPaint(
                size: Size.infinite,
                painter: BodyPainter(clock: clock, lengthMs: length, loudness: _demoBody(0), bands: [_demoBody(1), _demoBody(2), _demoBody(3)]),
              ),
            ),
          ),
        ),
        Text('SIGNAL PATH', style: Tok.label),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final s in n?.path ?? const <StageDto>[]) _Stage(s),
        ]),
        const SizedBox(height: 8),
        if (n?.fidelity case final f?)
          Text(
            switch (f) {
              FidelityDto.bitPerfect => '● Bit-perfect',
              FidelityDto.altered => '◐ Altered',
              FidelityDto.lossy => '○ Lossy source',
            },
            style: Tok.monoSmall.copyWith(color: f == FidelityDto.bitPerfect ? Tok.ok : Tok.warn),
          ),
      ]),
    );
  }

  static String _fmt(double ms) {
    final s = (ms / 1000).floor();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  // TODO(now): replace with the core's body summary for the playing recording.
  static final _bodies = <int, Uint8List>{};
  static Uint8List _demoBody(int seed) => _bodies.putIfAbsent(seed, () {
        final r = math.Random(seed + 7);
        var v = 120.0;
        return Uint8List.fromList(List.generate(180, (i) {
          v = (v + r.nextDouble() * 40 - 20).clamp(30, 250);
          return v.round();
        }));
      });
}

class _Stage extends StatelessWidget {
  const _Stage(this.s);
  final StageDto s;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(border: Border.all(color: s.alters ? Tok.warn : Tok.rule), borderRadius: BorderRadius.circular(3)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.name, style: Tok.label.copyWith(fontSize: 9.5)),
          Text(s.detail, style: Tok.monoSmall.copyWith(color: Tok.ink)),
        ]),
      );
}
