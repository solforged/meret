import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'window_chrome.dart';

/// The one line of chrome on desktop (navigation.md, plate 04): back and
/// forward along the trail, the query, the LCD at the centre, then
/// activity and the Now toggle. It is also the window's title bar: the
/// window buttons sit at its left, and its empty space moves the window.
class TopLine extends StatelessWidget {
  const TopLine({
    super.key, required this.query, required this.lcd, required this.activity,
    this.onBack, this.onForward, this.onNow, this.nowOpen = false,
  });

  final Widget query;
  final Widget lcd;
  final Widget activity;

  /// `[` and `]`; null when there's nowhere to go.
  final VoidCallback? onBack;
  final VoidCallback? onForward;

  /// `N`; null hides the toggle.
  final VoidCallback? onNow;
  final bool nowOpen;

  static const height = 44.0;
  static const _query = 300.0;
  static const _lcd = 560.0;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: WindowChrome.instance.fullScreen,
    builder: (context, _, _) => Container(
      height: height,
      decoration: const BoxDecoration(color: Color(0xFF050917), border: Border(bottom: BorderSide(color: Tok.line))),
      // The drag area lies under the controls, so a drag in the field selects text.
      child: Stack(children: [
        const Positioned.fill(child: WindowDragArea(child: SizedBox.expand())),
        // A phone swipes along the trail and keeps its player bar, so the
        // query has the line to itself there.
        LayoutBuilder(builder: (context, box) => Padding(
          padding: EdgeInsets.only(left: 12 + WindowChrome.instance.buttonsInset, right: 12),
          child: Row(children: [
            if (box.maxWidth < 600)
              Expanded(child: SizedBox(height: 28, child: query))
            else ...[
              _Step(key: const ValueKey('top-back'), glyph: '‹', tooltip: 'Back along the trail  [', onTap: onBack),
              _Step(key: const ValueKey('top-forward'), glyph: '›', tooltip: 'Forward  ]', onTap: onForward),
              const SizedBox(width: 12),
              // The query keeps its share; the LCD gives way first.
              SizedBox(width: (box.maxWidth * 0.3).clamp(140.0, _query), height: 28, child: query),
              const SizedBox(width: 14),
              // The LCD centres in the room between the query and the right.
              Expanded(child: LayoutBuilder(builder: (context, box) => box.maxWidth < 240
                ? const SizedBox.shrink()
                : Center(child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: _lcd),
                    child: SizedBox(height: 34, child: lcd),
                  )))),
            ],
            const SizedBox(width: 14),
            // Activity keeps its words, up to a quarter of the line; the LCD gives way first.
            ConstrainedBox(constraints: BoxConstraints(maxWidth: (box.maxWidth * 0.25).clamp(40.0, 380.0)), child: activity),
            if (onNow != null) ...[
              const SizedBox(width: 10),
              _NowToggle(open: nowOpen, onTap: onNow!, hint: box.maxWidth >= 800),
            ],
          ]),
        )),
      ]),
    ),
  );
}

class _Step extends StatelessWidget {
  const _Step({super.key, required this.glyph, required this.tooltip, this.onTap});
  final String glyph;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      canRequestFocus: false,
      child: SizedBox(width: 26, height: 26, child: Center(child: Text(
        glyph,
        style: Tok.body.copyWith(fontSize: 18, height: 1, color: onTap == null ? Tok.dim : Tok.muted),
      ))),
    ),
  );
}

class _NowToggle extends StatelessWidget {
  const _NowToggle({required this.open, required this.onTap, this.hint = true});
  final bool open;
  final VoidCallback onTap;

  /// The `N` beside the word; a narrow line leaves it to the tooltip.
  final bool hint;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: open ? 'Hide Now  N' : 'Show Now  N',
    child: InkWell(
      key: const ValueKey('top-now'),
      onTap: onTap,
      canRequestFocus: false,
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: open ? Tok.panel2 : null,
          border: Border.all(color: open ? Tok.gold3 : Tok.rule),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('Now', style: Tok.body.copyWith(fontSize: 12, fontWeight: FontWeight.w500, color: open ? Tok.ink : Tok.muted)),
          if (hint) ...[
            const SizedBox(width: 6),
            const Text('N', style: Tok.label),
          ],
        ]),
      ),
    ),
  );
}
