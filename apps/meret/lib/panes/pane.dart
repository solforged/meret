import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;

import '../core/when.dart';
import '../theme/tokens.dart';

/// "212 plays · last Tuesday", "1 play · today", "no plays yet".
String playsFact(BigInt plays, PlatformInt64? lastPlayedMs) {
  if (plays == BigInt.zero) return 'no plays yet';
  final count = '${plays.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},')} ${plays == BigInt.one ? 'play' : 'plays'}';
  return lastPlayedMs == null ? count : '$count · last ${dayWord(lastPlayedMs.toInt())}';
}

/// Plate 01's actions row: one gold primary, then the actions that aren't
/// built yet, greyed, each saying so on hover. Want and Crate arrive with
/// their stores.
class PaneActions extends StatelessWidget {
  const PaneActions({super.key, required this.primary, required this.onPrimary, this.primaryKey});
  final String primary;
  final VoidCallback? onPrimary;
  final Key? primaryKey;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 8, children: [
    _ActionButton(key: primaryKey, label: primary, hint: 'Space', primary: true, onTap: onPrimary),
    const _ActionButton(label: 'Want', hint: 'W', comingLater: 'Wants arrive with the lead store'),
    const _ActionButton(label: 'Crate', hint: 'C', comingLater: 'Crates arrive with their store'),
  ]);
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({super.key, required this.label, required this.hint, this.primary = false, this.onTap, this.comingLater});
  final String label;
  final String hint;
  final bool primary;
  final VoidCallback? onTap;

  /// Why it's greyed: shown on hover, so the row reads as plate 01 draws it.
  final String? comingLater;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final button = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: primary && enabled ? Tok.gold : Colors.transparent,
            border: Border.all(color: primary && enabled ? Tok.gold : Tok.rule),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: Tok.body.copyWith(
              fontSize: 12.5,
              fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
              color: primary && enabled ? Tok.sky : enabled ? Tok.ink : Tok.faint,
            )),
            const SizedBox(width: 6),
            Text(hint, style: Tok.label.copyWith(color: primary && enabled ? Tok.sky.withValues(alpha: 0.6) : Tok.faint, letterSpacing: 0)),
          ]),
        ),
      ),
    );
    return comingLater == null ? button : Tooltip(message: '$comingLater · coming later', child: button);
  }
}

/// What every pane shows at the top: the thread that brought you, the kind
/// of thing, its name. Folds to a vertical spine when narrow.
class Pane extends StatefulWidget {
  const Pane({
    super.key, required this.kind, required this.title, this.via, this.source, this.body,
    this.showTitle = true, this.compact = false, this.onSpineTap,
  });

  /// "PERSON · COMPOSER", "SCORE · 1998", "GROUP · NOT OWNED".
  final String kind;
  final String title;

  /// The thread followed into this pane: "composed by".
  final String? via;

  /// Who said so: "MusicBrainz · VGMdb".
  final String? source;
  final Widget? body;
  final bool showTitle;

  /// One header line, `kind · title`, for a search whose table needs the room.
  final bool compact;

  /// A folded pane, clicked: bring its stop back into view.
  final VoidCallback? onSpineTap;

  @override
  State<Pane> createState() => _PaneState();
}

class _PaneState extends State<Pane> {
  final _focus = FocusNode();
  FocusNode? _foldedFocus;
  bool _folded = false;
  double _fullWidth = 440;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final folded = box.maxWidth < 60;
      if (folded != _folded) {
        if (folded) {
          _foldedFocus = _focus.hasFocus ? FocusManager.instance.primaryFocus : null;
        } else {
          final focus = _foldedFocus;
          _foldedFocus = null;
          if (focus != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && !_folded && focus.context != null) focus.requestFocus();
            });
          }
        }
        _folded = folded;
      }
      if (!folded) _fullWidth = box.maxWidth;
      final Pane(:kind, :title, :via, :source, :body, :compact, :showTitle, :onSpineTap) = widget;
      return Stack(fit: StackFit.expand, children: [
        Visibility(
          visible: !folded, maintainState: true,
          // Keep a hidden body at its last full width, not the spine's 46 px.
          child: OverflowBox(
            alignment: Alignment.topLeft, minWidth: _fullWidth, maxWidth: _fullWidth,
            child: Focus(
              focusNode: _focus, canRequestFocus: false, descendantsAreFocusable: !folded,
              child: Container(
                decoration: const BoxDecoration(color: Tok.sky, border: Border(right: BorderSide(color: Tok.line))),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (via != null)
                    Row(children: [
                      Text(via, style: Tok.label.copyWith(color: Tok.gold, fontStyle: FontStyle.italic, letterSpacing: 0)),
                      const SizedBox(width: 12),
                      if (source != null)
                        Expanded(
                          child: Text(source, style: Tok.label, textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                    ]),
                  SizedBox(height: compact ? 6 : 10),
                  if (compact)
                    Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                      Text(kind, style: Tok.label),
                      const SizedBox(width: 10),
                      Expanded(child: Text(title, style: Tok.body.copyWith(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ])
                  else ...[
                    Text(kind, style: Tok.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    if (showTitle) Text(title, style: Tok.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                  SizedBox(height: compact ? 8 : 12),
                  Expanded(child: body ?? const SizedBox()),
                ]),
              ),
            ),
          ),
        ),
        if (folded) PaneSpine(title: title, meta: via ?? kind, onTap: onSpineTap),
      ]);
    });
  }
}

/// A folded pane (plate 01): the stop's name written upwards, its thread
/// or kind beneath, in a 46 px column. Clicking it returns to that stop.
class PaneSpine extends StatelessWidget {
  const PaneSpine({super.key, required this.title, this.meta, this.onTap});
  final String title;
  final String? meta;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    label: title,
    child: MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          decoration: const BoxDecoration(color: Tok.void_, border: Border(right: BorderSide(color: Tok.line))),
          alignment: Alignment.topCenter,
          padding: const EdgeInsets.only(top: 14),
          child: RotatedBox(
            quarterTurns: 3,
            child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Flexible(child: Text(title, style: Tok.body.copyWith(fontSize: 12.5, fontWeight: FontWeight.w500, color: Tok.muted), maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (meta case final meta?) ...[
                const SizedBox(width: 8),
                Text(meta, style: Tok.body.copyWith(fontSize: 12.5, color: Tok.dim), maxLines: 1),
              ],
            ]),
          ),
        ),
      ),
    ),
  );
}
