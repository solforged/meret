import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../core/playhead.dart';
import '../now/now_pane.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';

/// Today's first section, because most sessions are press-play. The LCD
/// already shows the dial's worth (title, time, quality), so this keeps to
/// the choices: Resume beside what it resumes, where it stopped, the
/// idiom's rule for where Resume really starts, and the start instead.
/// [points] are the core's resume points, which say when the loaded
/// release stopped.
class ResumeHeader extends StatelessWidget {
  const ResumeHeader({super.key, required this.now, required this.clock, required this.onToggle, required this.points});
  final NowDto now;
  final PlayheadClock clock;
  final VoidCallback onToggle;
  final List<ResumeDto> points;

  /// "Paused yesterday 21:57 at 2:42 of 3:27 · on This Mac"; while
  /// playing, "Playing at 0:14 of 3:27 · on This Mac".
  Widget _where(int? updatedAt) {
    Widget line(String? when) => ListenableBuilder(listenable: clock, builder: (_, _) => Text(
      '${clock.playing ? 'Playing' : when == null ? 'Paused' : 'Paused $when'} at ${positionOf(clock.positionMs.round(), now.lengthMs?.toInt())} · on This Mac',
      key: const ValueKey('resume-where'), style: Tok.monoSmall, maxLines: 1, overflow: TextOverflow.ellipsis,
    ));
    return updatedAt == null ? line(null) : Moment(ms: updatedAt, builder: (_, when) => line(when));
  }

  @override
  Widget build(BuildContext context) {
    final point = points.where((point) => point.releaseId == now.releaseId).firstOrNull;
    final accent = Light.of(context).accent;
    final toggle = ListenableBuilder(listenable: clock, builder: (_, _) => TextButton(
      key: const ValueKey('resume-toggle'),
      style: TextButton.styleFrom(
        foregroundColor: Tok.ink, backgroundColor: Tok.panel2,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(side: BorderSide(color: accent), borderRadius: BorderRadius.circular(3)),
      ),
      onPressed: onToggle,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(clock.playing ? Icons.pause : Icons.play_arrow, size: 17, color: accent),
        const SizedBox(width: 7),
        // Both words hold the button's width, so it never jumps as playback starts.
        Stack(children: [
          for (final word in ['Resume', 'Pause'])
            Opacity(opacity: (word == 'Pause') == clock.playing ? 1 : 0, child: Text(word, style: Tok.body.copyWith(fontSize: 15))),
        ]),
        const SizedBox(width: 16),
        const Text('Space', style: Tok.label),
      ]),
    ));
    final what = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text(now.title, style: Tok.body.copyWith(fontSize: 15, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
      const SizedBox(height: 2),
      Text(now.subtitle, style: Tok.label.copyWith(color: Tok.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
    ]);
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ListenableBuilder(listenable: clock, builder: (_, _) => Text(
          clock.playing ? 'Playing' : 'Pick up where you left off',
          style: Tok.label.copyWith(color: Tok.ink),
        )),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (context, box) => box.maxWidth >= 380
          ? Row(children: [toggle, const SizedBox(width: 16), Expanded(child: what)])
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Align(alignment: Alignment.centerLeft, child: toggle), const SizedBox(height: 10), what,
            ])),
        const SizedBox(height: 10),
        _where(point?.updatedAt.toInt()),
        const SizedBox(height: 4),
        // Narrow, the way to the start drops under the rule.
        Wrap(runSpacing: 4, children: [
          if (point != null) ...[
            Text(resumeRule(point.idiom), key: const ValueKey('resume-rule'), style: Tok.label),
            const Text('  ·  ', style: Tok.label),
          ],
          const Text('or from the start · ⌥Space', style: Tok.label),
        ]),
        if (now.why case final why?) Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(why, key: const ValueKey('now-why'), style: Tok.label.copyWith(color: Tok.gold), maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        if (now.error != null) Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(now.error!, style: Tok.label.copyWith(color: Tok.warn)),
        ),
      ]),
    );
  }
}
