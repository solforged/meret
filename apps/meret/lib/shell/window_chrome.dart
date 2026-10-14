import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The macOS window has no native title bar (`MainFlutterWindow.swift`);
/// the query line stands in for it. This moves and zooms the window and
/// knows when full screen hides the window buttons.
class WindowChrome {
  WindowChrome._() {
    if (!Platform.isMacOS) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'fullScreen') fullScreen.value = call.arguments as bool;
    });
    _channel.invokeMethod<bool>('fullScreen').then((v) => fullScreen.value = v ?? false, onError: (_) {});
  }

  static final instance = WindowChrome._();
  static const _channel = MethodChannel('meret/window');

  final fullScreen = ValueNotifier(false);

  /// Room to leave at the left of the bar for the window buttons.
  double get buttonsInset => Platform.isMacOS && !fullScreen.value ? 76 : 0;

  void _call(String method) {
    if (Platform.isMacOS) _channel.invokeMethod<void>(method).catchError((_) {});
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
