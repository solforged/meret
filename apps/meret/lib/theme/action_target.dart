import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

/// Keyboard and accessibility behavior for a custom button's existing layout.
/// The foreground ring stays visible over opaque children without moving them,
/// and only the target that holds the focus draws it, never the one around it.
class ActionTarget extends StatefulWidget {
  const ActionTarget({
    super.key,
    required this.child,
    this.onTap,
    this.onSpace,
    this.semanticLabel,
    this.selected,
    this.excludeChildSemantics = false,
    this.focusNode,
    this.focusColor = Tok.gold,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// What Space does here when it isn't [onTap]: the LCD's face opens Now on
  /// Enter, but Space is play or pause wherever focus is.
  final VoidCallback? onSpace;
  final String? semanticLabel;
  final bool? selected;
  final bool excludeChildSemantics;
  final FocusNode? focusNode;
  final Color focusColor;

  @override
  State<ActionTarget> createState() => _ActionTargetState();
}

class _SpaceIntent extends Intent {
  const _SpaceIntent();
}

class _ActionTargetState extends State<ActionTarget> {
  FocusNode? _own;
  bool _showFocus = false;
  bool _holdsFocus = false;

  FocusNode get _node => widget.focusNode ?? (_own ??= FocusNode(debugLabel: widget.semanticLabel));

  @override
  void initState() {
    super.initState();
    _node.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(ActionTarget old) {
    super.didUpdateWidget(old);
    if (old.focusNode == widget.focusNode) return;
    (old.focusNode ?? _own)?.removeListener(_focusChanged);
    _node.addListener(_focusChanged);
    _holdsFocus = _node.hasPrimaryFocus;
  }

  @override
  void dispose() {
    _node.removeListener(_focusChanged);
    _own?.dispose();
    super.dispose();
  }

  /// A target that wraps another (the LCD's face around its slider) hears of
  /// every focus change inside it; the ring belongs to the one that is focused.
  void _focusChanged() {
    final holds = _node.hasPrimaryFocus;
    if (mounted && holds != _holdsFocus) setState(() => _holdsFocus = holds);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final onSpace = widget.onSpace;
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      selected: widget.selected,
      label: widget.semanticLabel,
      onTap: widget.onTap,
      child: FocusableActionDetector(
        enabled: enabled,
        focusNode: _node,
        mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onShowFocusHighlight: (show) => setState(() => _showFocus = show),
        shortcuts: {
          const SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false): const ActivateIntent(),
          const SingleActivator(LogicalKeyboardKey.numpadEnter, includeRepeats: false): const ActivateIntent(),
          const SingleActivator(LogicalKeyboardKey.space, includeRepeats: false):
              onSpace == null ? const ActivateIntent() : const _SpaceIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            widget.onTap?.call();
            return null;
          }),
          if (onSpace != null) _SpaceIntent: CallbackAction<_SpaceIntent>(onInvoke: (_) {
            onSpace();
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
              border: Border.all(color: _showFocus && _holdsFocus && enabled ? widget.focusColor : Colors.transparent, width: 2),
              borderRadius: BorderRadius.circular(3),
            ),
            child: ExcludeSemantics(excluding: widget.excludeChildSemantics, child: widget.child),
          ),
        ),
      ),
    );
  }
}
