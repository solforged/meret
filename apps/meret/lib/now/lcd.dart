import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../core/playhead.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';
import 'now_pane.dart';

/// What's playing, at the top centre of every desktop width (iTunes' place;
/// navigation.md, "Now"): transport, title, a hairline scrubber, the time
/// and the quality marks. Beside a search it folds to a pill: the transport,
/// the time and the scrubber. A click anywhere past the transport opens the
/// Now panel, and the gold border says it's open.
class Lcd extends StatelessWidget {
  const Lcd({
    super.key, required this.core, required this.now, required this.clock, required this.onToggle,
    this.onOpen, this.nothingToPlay = false, this.open = false, this.folded = false,
  });
  final CoreBridge core;
  final NowDto? now;
  final PlayheadClock clock;
  final VoidCallback onToggle;

  /// Opens or closes the Now panel; [open] says which it is now.
  final VoidCallback? onOpen;
  final bool open;
  final bool nothingToPlay;

  /// Beside a search: the pill, whatever the width on the way there.
  final bool folded;

  @override
  Widget build(BuildContext context) {
    final n = now;
    final dr = n?.dr;
    return Container(
      key: const ValueKey('lcd'),
      padding: const EdgeInsets.only(left: 4, right: 12),
      decoration: BoxDecoration(
        color: Color.alphaBlend(Light.of(context).wash, const Color(0xFF040713)),
        border: Border.all(color: open ? Tok.gold3 : Tok.rule),
      ),
      // Narrow, the DR mark goes first, then the time; the title and scrubber stay.
      // Narrower still, the pill keeps the time and scrubber and lets the title go.
      child: LayoutBuilder(builder: (context, box) {
        final pill = folded || box.maxWidth < 240;
        final time = ListenableBuilder(
          listenable: clock,
          builder: (_, _) => Text(
            n?.anchor == null ? '–:––' : positionOf(clock.positionMs.round(), n?.lengthMs?.toInt()),
            key: const ValueKey('lcd-time'),
            maxLines: 1,
            overflow: TextOverflow.clip,
            softWrap: false,
            style: Tok.label.copyWith(color: Tok.muted),
          ),
        );
        final seek = SizedBox(height: 10, child: SeekBar(core: core, now: n, clock: clock, hairline: true, id: 'lcd'));
        return Row(children: [
          Transport(core: core, now: n, clock: clock, onToggle: onToggle, compact: true, id: 'lcd'),
          SizedBox(width: pill ? 6 : 10),
          // The full face and the pill cross-fade as the slot slides, so
          // nothing snaps between layouts halfway.
          Expanded(child: AnimatedSwitcher(duration: kMotion, child: Tooltip(
            key: ValueKey(pill),
            message: onOpen == null ? '' : open ? 'Hide Now  N' : 'Show Now  N',
            child: GestureDetector(
              key: const ValueKey('lcd-title'),
              behavior: HitTestBehavior.opaque,
              onTap: onOpen,
              child: MouseRegion(
                cursor: onOpen == null ? MouseCursor.defer : SystemMouseCursors.click,
                child: pill
                    ? Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        time,
                        const SizedBox(height: 2),
                        seek,
                      ])
                    : Row(children: [
                        Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Text.rich(
                            TextSpan(children: [
                              TextSpan(text: nowTitle(n, nothingToPlay: nothingToPlay), style: Tok.body.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.2)),
                              if (n?.subtitle.isNotEmpty == true) TextSpan(text: '  ${n!.subtitle}', style: Tok.label.copyWith(height: 1.2)),
                            ]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          seek,
                        ])),
                        if (box.maxWidth >= 420) ...[
                          const SizedBox(width: 12),
                          time,
                        ],
                        if (dr != null && box.maxWidth >= 500) ...[
                          const SizedBox(width: 8),
                          Text('DR $dr', style: Tok.label),
                        ],
                      ]),
              ),
            ),
          ))),
        ]);
      }),
    );
  }
}
