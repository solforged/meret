import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'core/bridge.dart';
import 'shell/surface.dart';
import 'src/rust/api/core.dart' as rust;
import 'src/rust/frb_generated.dart';
import 'theme/tokens.dart';

/// `flutter run --dart-define=MERET_FAKE=true` runs on mock data, without Rust.
const _fake = bool.fromEnvironment('MERET_FAKE');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  CoreBridge core = FakeCore();
  if (!_fake) {
    await RustLib.init();
    final dir = await getApplicationSupportDirectory();
    // CoreAudio on macOS; elsewhere the null output until AAudio, WASAPI
    // and PipeWire land (docs/architecture.md).
    await rust.startCore(dataDir: dir.path, nullOutput: !Platform.isMacOS);
    core = RustCore();
  }
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
