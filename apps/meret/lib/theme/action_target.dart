import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

/// Keyboard and accessibility behavior for a custom button's existing layout.
/// The foreground ring stays visible over opaque children without moving them.
class ActionTarget extends StatefulWidget {
  const ActionTarget({
    super.key,
    required this.child,
    this.onTap,
    this.semanticLabel,
    this.selected,
    this.excludeChildSemantics = false,
    this.focusNode,
    this.focusColor = Tok.gold,
  });

  final Widget child;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final bool? selected;
  final bool excludeChildSemantics;
  final FocusNode? focusNode;
  final Color focusColor;

  @override
  State<ActionTarget> createState() => _ActionTargetState();
}

class _ActionTargetState extends State<ActionTarget> {
  bool _showFocus = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      selected: widget.selected,
      label: widget.semanticLabel,
      onTap: widget.onTap,
      child: FocusableActionDetector(
        enabled: enabled,
        focusNode: widget.focusNode,
        mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onShowFocusHighlight: (show) => setState(() => _showFocus = show),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.numpadEnter, includeRepeats: false): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space, includeRepeats: false): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            widget.onTap?.call();
            return null;
          }),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: widget.onTap,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: Border.all(color: _showFocus && enabled ? widget.focusColor : Colors.transparent, width: 2),
              borderRadius: BorderRadius.circular(3),
            ),
            child: ExcludeSemantics(excluding: widget.excludeChildSemantics, child: widget.child),
          ),
        ),
      ),
    );
  }
}
