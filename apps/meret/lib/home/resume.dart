import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../core/playhead.dart';
import '../now/now_pane.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';

/// Today's first section, because most sessions are press-play: the dial,
/// the facts, where it stopped, Resume, and the idiom's rule for where
/// Resume really starts. [points] are the core's resume points, which
/// say when the loaded release stopped.
class ResumeHeader extends StatelessWidget {
  const ResumeHeader({super.key, required this.core, required this.now, required this.clock, required this.onToggle, required this.points});
  final CoreBridge core;
  final NowDto now;
  final PlayheadClock clock;
  final VoidCallback onToggle;
  final List<ResumeDto> points;

  /// "Paused yesterday 21:57 at 2:42 of 3:27 · on This Mac"; while
  /// playing, "Playing at 0:14 of 3:27 · on This Mac".
  Widget _where(int? updatedAt) {
    Widget line(String? when) => ListenableBuilder(listenable: clock, builder: (_, _) => Text(
      '${clock.playing ? 'Playing' : when == null ? 'Paused' : 'Paused $when'} at ${positionOf(clock.positionMs.round(), now.lengthMs?.toInt())} · on This Mac',
      key: const ValueKey('resume-where'), style: Tok.monoSmall,
    ));
    return updatedAt == null ? line(null) : Moment(ms: updatedAt, builder: (_, when) => line(when));
  }

  @override
  Widget build(BuildContext context) {
    final point = points.where((point) => point.releaseId == now.releaseId).firstOrNull;
    return Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: LayoutBuilder(builder: (context, box) {
        final dialSize = box.maxWidth < 520 ? 144.0 : 176.0;
        final dial = SizedBox(width: dialSize, height: dialSize, child: NowDial(now: now, clock: clock, onToggle: onToggle));
        final details = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ListenableBuilder(listenable: clock, builder: (_, _) => Text(
            clock.playing ? 'Playing' : 'Pick up where you left off',
            style: Tok.label.copyWith(color: Tok.ink),
          )),
          const SizedBox(height: 8),
          Text(now.title, style: Tok.title),
          const SizedBox(height: 4),
          Text(now.subtitle, style: Tok.body.copyWith(color: Tok.muted)),
          NowFacts(now: now),
          if (now.why case final why?) Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(why, key: const ValueKey('now-why'), style: Tok.label.copyWith(color: Tok.gold), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(height: 12),
          _where(point?.updatedAt.toInt()),
          const SizedBox(height: 16),
          ListenableBuilder(listenable: clock, builder: (_, _) => Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('resume-toggle'),
              style: TextButton.styleFrom(
                foregroundColor: Tok.ink, backgroundColor: Tok.panel2,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                shape: RoundedRectangleBorder(side: BorderSide(color: Light.of(context).accent), borderRadius: BorderRadius.circular(3)),
              ),
              onPressed: onToggle,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(clock.playing ? Icons.pause : Icons.play_arrow, size: 19, color: Light.of(context).accent),
                const SizedBox(width: 8),
                Text(clock.playing ? 'Pause' : 'Resume', style: Tok.body.copyWith(fontSize: 17)),
                const SizedBox(width: 24),
                const Text('Space', style: Tok.label),
              ]),
            ),
          )),
          if (point != null) ...[
            const SizedBox(height: 10),
            Text(resumeRule(point.idiom), key: const ValueKey('resume-rule'), style: Tok.label),
          ],
          const SizedBox(height: 10),
          const Text('or from the start · ⌥Space', style: Tok.label),
          if (now.fidelity != null) ...[
            const SizedBox(height: 12),
            NowFidelity(now: now, exclusive: core.settings().exclusive),
          ],
          if (now.error != null) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(now.error!, style: Tok.label.copyWith(color: Tok.warn)),
          ),
        ]);
        return box.maxWidth >= 440
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [dial, const SizedBox(width: 24), Expanded(child: details)])
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Align(alignment: Alignment.centerLeft, child: dial),
              const SizedBox(height: 14), details,
            ]);
      }),
    );
  }
}
