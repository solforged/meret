import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;

import '../core/bridge.dart';
import '../core/playhead.dart';
import '../core/when.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';
import 'now_pane.dart';
import 'zones.dart';
import 'picks.dart';

/// The opening view resumes music without starting or changing a trail.
class NowStage extends StatelessWidget {
  const NowStage({
    super.key, required this.core, required this.now, required this.clock,
    required this.onToggle, required this.onRelease, required this.onLeave,
    this.settingsChanges,
  });
  final CoreBridge core;
  final NowDto now;
  final PlayheadClock clock;
  final VoidCallback onToggle;
  final Future<void> Function(PlatformInt64) onRelease;
  final VoidCallback onLeave;
  final Listenable? settingsChanges;

  Widget _resume(List<ResumeDto> points) {
    final updatedAt = points.where((point) => point.releaseId == now.releaseId).firstOrNull?.updatedAt;
    return Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: LayoutBuilder(builder: (context, box) {
        final dialSize = box.maxWidth < 580 ? 144.0 : 176.0;
        final dial = SizedBox(width: dialSize, height: dialSize, child: NowDial(now: now, clock: clock, onToggle: onToggle));
        final details = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(now.title, style: Tok.title),
          const SizedBox(height: 4),
          Text(now.subtitle, style: Tok.body.copyWith(color: Tok.muted)),
          NowFacts(now: now),
          if (now.why case final why?) Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(why, key: const ValueKey('now-why'), style: Tok.label.copyWith(color: Tok.gold), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(height: 12),
          ListenableBuilder(listenable: clock, builder: (_, _) => Text(
            '${clock.playing ? 'Playing ' : updatedAt == null ? '' : 'Paused ${dayAndTime(updatedAt.toInt())} '}at ${clockLength(clock.positionMs.round())}${now.lengthMs == null ? '' : ' of ${clockLength(now.lengthMs!.toInt())}'} · on This Mac',
            style: Tok.monoSmall,
          )),
          const SizedBox(height: 16),
          ListenableBuilder(listenable: clock, builder: (_, _) => Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('now-stage-resume'),
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
          const SizedBox(height: 10),
          const Text('or from the start · ⌥Space', style: Tok.label),
          if (now.fidelity != null) ...[
            const SizedBox(height: 12),
            NowFidelity(now: now),
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

  Widget _queue() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    PlaySomething(core: core, now: now),
    const SizedBox(height: 22),
    PlayOn(core: core, now: now, settingsChanges: settingsChanges),
    const SizedBox(height: 22),
    UpNext(core: core, now: now),
  ]);

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Color.alphaBlend(Light.of(context).wash, Tok.panel),
    child: LayoutBuilder(builder: (context, box) {
      final twoColumns = box.maxWidth >= 900;
      return ListView(
        key: const ValueKey('now-stage-scroll'),
        padding: EdgeInsets.fromLTRB(box.maxWidth < 500 ? 18 : 28, 20, box.maxWidth < 500 ? 18 : 28, 28),
        children: [
          Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 16, runSpacing: 6, children: [
            ListenableBuilder(listenable: clock, builder: (_, _) => Text('Now · ${clock.playing ? 'playing' : 'paused'}', style: Tok.label.copyWith(color: Tok.ink))),
            TextButton(onPressed: onLeave, child: const Text('Front ⌘1', style: Tok.label)),
          ]),
          const SizedBox(height: 20),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: NowMemory(
              core: core, now: now, resumeLimit: 6, historyLimit: 4,
              onRelease: onRelease, header: _resume, expanded: true,
            )),
            if (twoColumns) ...[
              const SizedBox(width: 36),
              Expanded(child: _queue()),
            ],
          ]),
          if (!twoColumns) ...[const SizedBox(height: 26), _queue()],
        ],
      );
    }),
  );
}
