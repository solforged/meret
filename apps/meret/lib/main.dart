import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'core/bridge.dart';
import 'shell/surface.dart';
import 'src/rust/api/core.dart' as rust;
import 'src/rust/frb_generated.dart';
import 'theme/tokens.dart';

/// `flutter run --dart-define=MERET_FAKE=true` runs on mock data, without Rust.
/// `MERET_DATA=/tmp/copy Contents/MacOS/meret` opens a copy of the library
/// instead of the real one, for smoke runs beside the app you use.
const _fake = bool.fromEnvironment('MERET_FAKE');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  CoreBridge core = FakeCore();
  if (!_fake) {
    await RustLib.init();
    final override = Platform.environment['MERET_DATA'];
    final dir = override == null || override.isEmpty ? await getApplicationSupportDirectory() : Directory(override);
    // CoreAudio on macOS; elsewhere the null output until AAudio, WASAPI
    // and PipeWire land (docs/architecture.md).
    await rust.startCore(dataDir: dir.path, nullOutput: !Platform.isMacOS);
    core = RustCore();
  }
  // ⌘Q, the Dock's Quit and logging out ask first; write where playback got
  // to and the open listen before the process ends.
  AppLifecycleListener(onExitRequested: () async {
    await core.flushMemory().timeout(const Duration(seconds: 1), onTimeout: () {}).catchError((Object _) {});
    return AppExitResponse.exit;
  });
  runApp(MeretApp(core: core));
}

class MeretApp extends StatelessWidget {
  const MeretApp({super.key, required this.core});
  final CoreBridge core;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Meret',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Tok.void_,
        fontFamily: Tok.sans,
        colorScheme: const ColorScheme.dark(primary: Tok.gold, surface: Tok.panel),
      ),
      home: Scaffold(body: Surface(core: core)),
    );
  }
}
