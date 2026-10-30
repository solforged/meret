import 'dart:io';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The macOS window has no native title bar (`MainFlutterWindow.swift`);
/// the top line stands in for it. This moves and zooms the window, knows
/// when full screen hides the window buttons, and hands on the Go and
/// Controls menus' items.
class WindowChrome {
  WindowChrome._() {
    if (!Platform.isMacOS) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'fullScreen') fullScreen.value = call.arguments as bool;
      if (call.method == 'showSettings') onSettings?.call();
      if (call.method == 'closeSettings') onCloseSettings?.call();
      if (call.method == 'menu') onMenu?.call(call.arguments as String);
      if (call.method == 'edit') edit(call.arguments as String);
    });
    FocusManager.instance.addListener(_textFocusChanged);
    // A failed call (no native side) still has to leave a bool for `then`.
    _channel.invokeMethod<bool>('fullScreen').catchError((_) => false).then((v) => fullScreen.value = v ?? false);
  }

  static final instance = WindowChrome._();
  static const _channel = MethodChannel('meret/window');

  void _textFocusChanged() {
    final context = FocusManager.instance.primaryFocus?.context;
    final editing = context != null && Actions.maybeFind<SelectAllTextIntent>(context) != null;
    _channel.invokeMethod<void>('textInputFocused', editing).catchError((_) {});
  }

  /// Dispatches a native Edit menu selector through the focused text model.
  void edit(String command) {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return;
    final Intent? intent = switch (command) {
      'selectAll:' => const SelectAllTextIntent(SelectionChangedCause.keyboard),
      'copy:' => CopySelectionTextIntent.copy,
      'cut:' => const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
      'paste:' || 'pasteAsPlainText:' => const PasteTextIntent(SelectionChangedCause.keyboard),
      'undo:' => const UndoTextIntent(SelectionChangedCause.keyboard),
      'redo:' => const RedoTextIntent(SelectionChangedCause.keyboard),
      'delete:' => const DeleteCharacterIntent(forward: true),
      _ => null,
    };
    if (intent != null) Actions.maybeInvoke(context, intent);
  }

  final fullScreen = ValueNotifier(false);
  VoidCallback? onSettings;
  VoidCallback? onCloseSettings;

  /// A menu item's id: `back`, `toggle`, `keep`… (`MainFlutterWindow.menus`).
  void Function(String id)? onMenu;

  Map<String, bool> _menuAvailability = const {};
  Map<String, bool>? _published;
  bool _modal = false;
  Set<String> _sheetKeeps = const {};

  /// What the native menus may do now: the surface's availability, but while
  /// a dialog is open only the items the sheet keeps (the history sheet keeps
  /// Play or Pause, the keys sheet keeps Keys); the rest wait for it to close.
  Map<String, bool> get menuState => {
    for (final MapEntry(:key, :value) in _menuAvailability.entries) key: value && (!_modal || _sheetKeeps.contains(key)),
  };

  void setMenuAvailability(Map<String, bool> availability) {
    _menuAvailability = Map.of(availability);
    _publish();
  }

  void _publish() {
    final state = menuState;
    if (mapEquals(_published, state)) return;
    _published = state;
    if (Platform.isMacOS) {
      _channel.invokeMethod<void>('menuAvailability', state).catchError((_) {});
    }
  }

  void setSettingsVisible(bool visible) {
    if (Platform.isMacOS) _channel.invokeMethod<void>('settingsVisible', visible).catchError((_) {});
  }

  void setModalVisible(bool visible) {
    _modal = visible;
    _publish();
  }

  /// The menu items the open sheet keeps on; empty when it closes.
  set sheetKeeps(Set<String> keeps) {
    _sheetKeeps = keeps;
    _publish();
  }

  /// Room to leave at the left of the bar for the window buttons.
  double get buttonsInset => Platform.isMacOS && !fullScreen.value ? 76 : 0;

  void _call(String method) {
    if (Platform.isMacOS) _channel.invokeMethod<void>(method).catchError((_) {});
  }
}

/// Keep native navigation from changing the page behind a Flutter dialog.
class NativeModalObserver extends NavigatorObserver {
  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    WindowChrome.instance.setModalVisible(topRoute is PopupRoute);
  }
}

/// Drags the window, and zooms it on a double-click, like a title bar.
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => WindowChrome.instance._call('drag'),
        onDoubleTap: () => WindowChrome.instance._call('zoom'),
        child: child,
      );
}
