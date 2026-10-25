import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../core/playhead.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';
import 'now_pane.dart';

/// What's playing, at the top centre of every desktop width (iTunes' place;
/// navigation.md, "Now"): transport, title, a hairline scrubber, the time
/// and the quality marks. A click on the title opens the Now panel.
class Lcd extends StatelessWidget {
  const Lcd({
    super.key, required this.core, required this.now, required this.clock, required this.onToggle,
    this.onOpen, this.nothingToPlay = false, this.open = false,
  });
  final CoreBridge core;
  final NowDto? now;
  final PlayheadClock clock;
  final VoidCallback onToggle;

  /// Opens or closes the Now panel; [open] says which it is now.
  final VoidCallback? onOpen;
  final bool open;
  final bool nothingToPlay;

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
      child: LayoutBuilder(builder: (context, box) => Row(children: [
        Transport(core: core, now: n, clock: clock, onToggle: onToggle, compact: true, id: 'lcd'),
        const SizedBox(width: 10),
        Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          GestureDetector(
            key: const ValueKey('lcd-title'),
            behavior: HitTestBehavior.opaque,
            onTap: onOpen,
            child: MouseRegion(
              cursor: onOpen == null ? MouseCursor.defer : SystemMouseCursors.click,
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: nowTitle(n, nothingToPlay: nothingToPlay), style: Tok.body.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.2)),
                  if (n?.subtitle.isNotEmpty == true) TextSpan(text: '  ${n!.subtitle}', style: Tok.label.copyWith(height: 1.2)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(height: 2),
          SizedBox(height: 10, child: SeekBar(core: core, now: n, clock: clock, hairline: true, id: 'lcd')),
        ])),
        if (box.maxWidth >= 420) ...[
          const SizedBox(width: 12),
          ListenableBuilder(
            listenable: clock,
            builder: (_, _) => Text(
              n?.anchor == null ? '–:––' : positionOf(clock.positionMs.round(), n?.lengthMs?.toInt()),
              key: const ValueKey('lcd-time'),
              style: Tok.label.copyWith(color: Tok.muted),
            ),
          ),
        ],
        if (dr != null && box.maxWidth >= 500) ...[
          const SizedBox(width: 8),
          Text('DR $dr', style: Tok.label),
        ],
      ])),
    );
  }
}
