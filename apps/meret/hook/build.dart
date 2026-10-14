// Builds crates/meret-ffi with cargo through Dart's native-assets build hooks
// and bundles the library into the app. Replaces cargokit, so no CocoaPods.
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    await const FlutterRustBridgeNativeAssetsBuilder(cratePath: '../../crates/meret-ffi')
        .run(input: input, output: output);
  });
}
