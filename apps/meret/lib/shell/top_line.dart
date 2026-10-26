import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'window_chrome.dart';

/// The one line of chrome on desktop (navigation.md, plate 04): back and
/// forward along the trail and the trail chip at the left, activity at the
/// right, and one centre slot shared by whatever you're doing. With
/// something loaded the LCD holds the window's centre and the query waits
/// docked at the right; `/` grows the query over the centre and folds the LCD
/// to a pill beside it. With nothing loaded the query has the centre. The
/// LCD opens the Now panel, so the line has no Now button of its own. It is
/// also the window's title bar: the window buttons sit at its left, and its
/// empty space moves the window.
class TopLine extends StatelessWidget {
  const TopLine({
    super.key, required this.query, required this.queryFocus, required this.lcd, required this.activity,
    this.loaded = false, this.onBack, this.onForward, this.chip,
  });

  final Widget query;

  /// The query's focus: while it has it, the query holds the centre.
  final FocusNode queryFocus;

  /// The open trail's chip, built for the line's room: the star alone, the
  /// current stop, or the whole name with its counts.
  final Widget Function({bool compact, bool star})? chip;
  final Widget lcd;
  final Widget activity;

  /// Something is in the player, so the LCD has the centre.
  final bool loaded;

  /// `[` and `]`; null when there's nowhere to go.
  final VoidCallback? onBack;
  final VoidCallback? onForward;

  static const height = 44.0;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: WindowChrome.instance.fullScreen,
    builder: (context, _, _) => Container(
      height: height,
      decoration: const BoxDecoration(color: Color(0xFF050917), border: Border(bottom: BorderSide(color: Tok.line))),
      // The drag area lies under the controls, so a drag in the field selects text.
      child: Stack(children: [
        const Positioned.fill(child: WindowDragArea(child: SizedBox.expand())),
        LayoutBuilder(builder: (context, box) {
          final inset = 12 + WindowChrome.instance.buttonsInset;
          // A phone swipes along the trail and keeps its player bar, so the
          // query has the line to itself there.
          if (box.maxWidth < 600) {
            return Padding(
              padding: EdgeInsets.only(left: inset, right: 12),
              child: Row(children: [
                if (this.chip case final chip?) ...[
                  Flexible(child: ConstrainedBox(constraints: BoxConstraints(maxWidth: box.maxWidth * 0.4), child: chip(compact: true))),
                  const SizedBox(width: 8),
                ],
                Expanded(child: SizedBox(height: 28, child: query)),
              ]),
            );
          }
          final chip = this.chip;
          final left = Row(mainAxisSize: MainAxisSize.min, children: [
            _Step(key: const ValueKey('top-back'), glyph: '‹', tooltip: 'Back along the trail  [', onTap: onBack),
            _Step(key: const ValueKey('top-forward'), glyph: '›', tooltip: 'Forward  ]', onTap: onForward),
            // T and the Go menu reach the tree when there's no room for the star.
            if (chip != null) ...[
              const SizedBox(width: 8),
              Flexible(child: chip(compact: box.maxWidth < 1000, star: box.maxWidth < 800)),
            ],
          ]);
          return ListenableBuilder(
            listenable: queryFocus,
            builder: (context, _) => TweenAnimationBuilder<double>(
              tween: Tween(end: queryFocus.hasFocus ? 1 : 0),
              duration: kMotion,
              curve: Curves.easeOut,
              builder: (context, t, _) => CustomMultiChildLayout(
                delegate: _CentreSlot(t: t, loaded: loaded, inset: inset),
                children: [
                  LayoutId(id: _Slot.left, child: left),
                  // Too narrow to say anything, the LCD gives its room away.
                  LayoutId(id: _Slot.lcd, child: LayoutBuilder(builder: (_, slot) => slot.maxWidth < _CentreSlot.pill * 0.6 ? const SizedBox.shrink() : lcd)),
                  LayoutId(id: _Slot.query, child: query),
                  LayoutId(id: _Slot.right, child: activity),
                ],
              ),
            ),
          );
        }),
      ]),
    ),
  );
}

enum _Slot { left, lcd, query, right }

/// Places the line's four parts. [t] runs from resting (0) to searching (1),
/// and the LCD and query slide between their two places along it.
class _CentreSlot extends MultiChildLayoutDelegate {
  _CentreSlot({required this.t, required this.loaded, required this.inset});
  final double t;
  final bool loaded;
  final double inset;

  static const _gap = 14.0;
  static const _docked = 200.0;
  static const _wide = 560.0;
  static const _lcdMax = 760.0;

  /// The LCD folded beside a search: the transport and the time.
  static const pill = 210.0;

  /// Narrower than this on the centre, the LCD centres between its
  /// neighbours instead; narrower than [_lcdLeast], it folds away.
  static const _lcdCentred = 360.0;
  static const _lcdLeast = 240.0;

  @override
  void performLayout(Size size) {
    final w = size.width;
    final h = size.height;
    final centre = w / 2;

    // The chip takes up to a fifth of the line; activity keeps its words, up to a quarter.
    final left = layoutChild(_Slot.left, BoxConstraints(maxWidth: (w * 0.22).clamp(120.0, 380.0) + 60, maxHeight: h));
    positionChild(_Slot.left, Offset(inset, (h - left.height) / 2));
    final right = layoutChild(_Slot.right, BoxConstraints(maxWidth: (w * 0.25).clamp(40.0, 380.0), maxHeight: h));
    positionChild(_Slot.right, Offset(w - 12 - right.width, (h - right.height) / 2));

    final from = inset + left.width + _gap;
    final to = w - 12 - right.width - _gap;
    Rect row(double x, double width, double height) => Rect.fromLTWH(x, (h - height) / 2, math.max(0, width), height);

    // The query on the centre as far as its neighbours allow.
    Rect wide(double end) {
      final width = math.max(0.0, math.min(_wide, end - from));
      return row(math.max(from, math.min(centre - width / 2, end - width)), width, 28);
    }

    final docked = (w * 0.18).clamp(120.0, _docked);
    final restQuery = loaded ? row(to - docked, docked, 28) : wide(to);

    // At rest the LCD sits on the window's centre, as wide as the nearer side allows.
    Rect? restLcd;
    if (loaded) {
      final room = to - docked - _gap;
      final half = math.min(centre - from, room - centre);
      if (half * 2 >= _lcdCentred) {
        final width = math.min(_lcdMax, half * 2);
        restLcd = row(centre - width / 2, width, 34);
      } else if (room - from >= _lcdLeast) {
        final width = math.min(_lcdMax, room - from);
        restLcd = row(from + (room - from - width) / 2, width, 34);
      }
    }

    // Searching, the LCD folds to a pill at the right and the query takes the centre.
    final pillLcd = loaded ? row(to - pill, pill, 34) : null;
    final searchQuery = wide(pillLcd == null ? to : pillLcd.left - _gap);

    final lcd = loaded ? Rect.lerp(restLcd ?? row(to, 0, 34), pillLcd, t)! : Rect.zero;
    layoutChild(_Slot.lcd, BoxConstraints.tight(lcd.size));
    positionChild(_Slot.lcd, lcd.topLeft);
    final query = Rect.lerp(restQuery, searchQuery, t)!;
    layoutChild(_Slot.query, BoxConstraints.tight(query.size));
    positionChild(_Slot.query, query.topLeft);
  }

  @override
  bool shouldRelayout(_CentreSlot old) => old.t != t || old.loaded != loaded || old.inset != inset;
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
