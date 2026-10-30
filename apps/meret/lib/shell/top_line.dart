import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/action_target.dart';
import '../theme/tokens.dart';
import 'window_chrome.dart';

/// The one line of chrome on desktop (navigation.md, plate 04): back and
/// forward along the trail and the trail chip at the left, activity at the
/// right, and one centre slot shared by whatever you're doing. With
/// something loaded the LCD holds the window's centre and the query waits
/// docked at the right; `/` grows the query leftward from there and folds the
/// LCD to a pill at its left, so nothing slides under a pointer that clicked
/// the field. With nothing loaded and Now closed the query has
/// the centre. The
/// LCD opens the Now panel, so the line has no Now button of its own. It is
/// also the window's title bar: the window buttons sit at its left, and its
/// empty space moves the window. Tab runs left, LCD, query, activity whatever
/// the query is doing, so Shift+Tab is its exact reverse.
class TopLine extends StatelessWidget {
  const TopLine({
    super.key, required this.query, required this.queryFocus, required this.lcd, required this.activity,
    this.showLcd = false, this.onBack, this.onForward, this.chip,
  });

  final Widget query;

  /// The query's focus: while it has it, the query holds the centre.
  final FocusNode queryFocus;

  /// The open trail's chip, built for the line's room: the star alone, the
  /// current stop, or the whole name with its counts.
  final Widget Function({bool compact, bool star})? chip;

  /// The LCD, folded to its pill while the query has the centre.
  final Widget Function({bool folded}) lcd;

  /// Activity, quiet down to its dot while the query has the centre.
  final Widget Function({bool quiet}) activity;

  /// Something is in the player, or Now is open, so the LCD has the centre.
  final bool showLcd;

  /// `[` and `]`; null when there's nowhere to go.
  final VoidCallback? onBack;
  final VoidCallback? onForward;

  static const height = 52.0;

  @override
  Widget build(BuildContext context) => FocusTraversalGroup(
    // Explicit orders: the slots' positions move with the query's focus, so a
    // geometric order would differ between one Tab and the next.
    policy: OrderedTraversalPolicy(),
    child: ValueListenableBuilder(
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
                Expanded(child: SizedBox(height: _CentreSlot._queryHeight, child: query)),
                const SizedBox(width: 14),
                ConstrainedBox(constraints: BoxConstraints(maxWidth: box.maxWidth * 0.25), child: activity()),
              ]),
            );
          }
          final chip = this.chip;
          final star = box.maxWidth < 800;
          final left = Row(mainAxisSize: MainAxisSize.min, children: [
            _Step(key: const ValueKey('top-back'), glyph: '‹', tooltip: 'Back along the trail  [', onTap: onBack),
            _Step(key: const ValueKey('top-forward'), glyph: '›', tooltip: 'Forward  ]', onTap: onForward),
            // T and the Go menu reach the tree when there's no room for the star.
            if (chip != null) ...[
              const SizedBox(width: 8),
              Flexible(child: chip(compact: box.maxWidth < 1000, star: star)),
            ],
          ]);
          return ListenableBuilder(
            listenable: queryFocus,
            builder: (context, _) {
              final searching = queryFocus.hasFocus;
              // Built once per change of state, not per frame of the slide.
              final lcd = this.lcd(folded: searching);
              // Narrow, the dot alone leaves the LCD its room; the words wait in its tooltip.
              final activity = this.activity(quiet: searching || box.maxWidth < 720);
              return TweenAnimationBuilder<double>(
                tween: Tween(end: searching ? 1 : 0),
                duration: kMotion,
                curve: Curves.easeOut,
                builder: (context, t, _) => CustomMultiChildLayout(
                  // The chip's words change with every stop and fork, so the LCD
                  // plans around the room it may take; only a star is a fixed size.
                  delegate: _CentreSlot(t: t, showLcd: showLcd, inset: inset, holdChip: chip != null && !star),
                  children: [
                    LayoutId(id: _Slot.left, child: FocusTraversalOrder(order: const NumericFocusOrder(0), child: left)),
                    // Too narrow to say anything, the LCD gives its room away.
                    LayoutId(id: _Slot.lcd, child: FocusTraversalOrder(
                      order: const NumericFocusOrder(1),
                      child: LayoutBuilder(builder: (_, slot) => slot.maxWidth < _CentreSlot.pill ? const SizedBox.shrink() : lcd),
                    )),
                    LayoutId(id: _Slot.query, child: FocusTraversalOrder(order: const NumericFocusOrder(2), child: query)),
                    LayoutId(id: _Slot.right, child: FocusTraversalOrder(order: const NumericFocusOrder(3), child: activity)),
                  ],
                ),
              );
            },
          );
        }),
      ]),
    ),
    ),
  );
}

enum _Slot { left, lcd, query, right }

/// Places the line's four parts. [t] runs from resting (0) to searching (1),
/// and the LCD and query slide between their two places along it. The
/// query keeps its right edge for good, so a pointer that clicked the docked
/// field is still over the field when it has grown; the LCD goes left.
class _CentreSlot extends MultiChildLayoutDelegate {
  _CentreSlot({required this.t, required this.showLcd, required this.inset, required this.holdChip});
  final double t;
  final bool showLcd;
  final double inset;

  /// The left slot holds a chip whose text changes: plan around the whole
  /// room it may take, not the width it has now.
  final bool holdChip;

  static const _gap = 14.0;
  static const _lcdHeight = 46.0;
  static const _queryHeight = 30.0;
  static const _docked = 200.0;
  static const _wide = 560.0;
  static const _lcdMax = 760.0;

  /// Least a held chip keeps: the steps and the star.
  static const _leftLeast = 104.0;

  /// The LCD folded beside a search: the transport and the time. It is also the
  /// least the LCD shows at rest, so even at 600 pt it stays within reach.
  static const pill = 210.0;

  /// Narrower than this on the centre, the LCD centres between its
  /// neighbours instead; narrower than [pill], it folds away.
  static const _lcdCentred = 360.0;

  @override
  void performLayout(Size size) {
    final w = size.width;
    final h = size.height;
    final centre = w / 2;

    // The chip takes up to a fifth of the line; activity keeps its words, up to a quarter.
    final right = layoutChild(_Slot.right, BoxConstraints(maxWidth: (w * 0.25).clamp(40.0, 380.0), maxHeight: h));
    positionChild(_Slot.right, Offset(w - 12 - right.width, (h - right.height) / 2));
    final to = w - 12 - right.width - _gap;
    final docked = (w * 0.18).clamp(120.0, _docked);

    // A held chip has one width however its words run, but never more than
    // leaves the LCD its pill: the chip's name gives way, the LCD does not.
    var leftMax = (w * 0.22).clamp(120.0, 380.0) + 60;
    if (holdChip && showLcd) leftMax = math.min(leftMax, math.max(_leftLeast, to - docked - _gap - pill - _gap - inset));
    final left = layoutChild(_Slot.left, BoxConstraints(maxWidth: leftMax, maxHeight: h));
    positionChild(_Slot.left, Offset(inset, (h - left.height) / 2));

    final from = inset + (holdChip ? leftMax : left.width) + _gap;
    Rect row(double x, double width, double height) => Rect.fromLTWH(x, (h - height) / 2, math.max(0, width), height);

    // The query on the centre as far as its neighbours allow.
    Rect wide(double end) {
      final width = math.max(0.0, math.min(_wide, end - from));
      return row(math.max(from, math.min(centre - width / 2, end - width)), width, _queryHeight);
    }

    final restQuery = showLcd ? row(to - docked, docked, _queryHeight) : wide(to);

    // At rest the LCD sits on the window's centre, as wide as the nearer side allows.
    Rect? restLcd;
    if (showLcd) {
      final room = to - docked - _gap;
      final half = math.min(centre - from, room - centre);
      if (half * 2 >= _lcdCentred) {
        final width = math.min(_lcdMax, half * 2);
        restLcd = row(centre - width / 2, width, _lcdHeight);
      } else if (room - from >= pill) {
        final width = math.min(_lcdMax, room - from);
        restLcd = row(from + (room - from - width) / 2, width, _lcdHeight);
      }
    }

    // Searching, the query grows leftward from its docked right edge and the
    // LCD folds to a pill at its left. With no LCD the query has the centre either way.
    final searchWidth = math.min(_wide, math.max(docked, to - from - pill - _gap));
    final searchQuery = showLcd ? row(to - searchWidth, searchWidth, _queryHeight) : restQuery;
    final pillLcd = showLcd ? row(searchQuery.left - _gap - pill, pill, _lcdHeight) : null;

    final lcd = showLcd ? Rect.lerp(restLcd ?? row(pillLcd!.left, 0, _lcdHeight), pillLcd, t)! : Rect.zero;
    layoutChild(_Slot.lcd, BoxConstraints.tight(lcd.size));
    positionChild(_Slot.lcd, lcd.topLeft);
    final query = Rect.lerp(restQuery, searchQuery, t)!;
    layoutChild(_Slot.query, BoxConstraints.tight(query.size));
    positionChild(_Slot.query, query.topLeft);
  }

  @override
  bool shouldRelayout(_CentreSlot old) => old.t != t || old.showLcd != showLcd || old.inset != inset || old.holdChip != holdChip;
}

class _Step extends StatelessWidget {
  const _Step({super.key, required this.glyph, required this.tooltip, this.onTap});
  final String glyph;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    excludeFromSemantics: true,
    child: ActionTarget(
      onTap: onTap,
      semanticLabel: tooltip,
      excludeChildSemantics: true,
      child: SizedBox(width: 26, height: 26, child: Center(child: Text(
        glyph,
        style: Tok.body.copyWith(fontSize: 18, height: 1, color: onTap == null ? Tok.dim : Tok.muted),
      ))),
    ),
  );
}
