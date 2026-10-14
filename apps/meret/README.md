# Meret app

The Flutter UI over the Rust core. Architecture, rules and how to work on it are in [`docs/architecture.md`](../../docs/architecture.md).

- `lib/core/bridge.dart` is the only way the UI talks to the core. `RustCore` is the real one: the table pages rows from the core's library and plays them through the queue. `FakeCore` serves the plates' Tuesday evening plus a 48,210-row fake library, for tests and design work (`--dart-define=MERET_FAKE=true`).
- `lib/src/rust/` is generated. Change `crates/meret-ffi/src/api/`, then run `flutter_rust_bridge_codegen generate` here.
- `hook/build.dart` builds `crates/meret-ffi` with Flutter native assets (`flutter_rust_bridge_hooks`), using the pinned toolchain in `rust-toolchain.toml`. Plugins come through Swift Package Manager. Neither cargokit nor CocoaPods is used.
- The macOS app isn't sandboxed, so it reads music folders anywhere. The window has no native title bar: the query line stands in for it, and `meret/window` (`MainFlutterWindow.swift`, `lib/shell/window_chrome.dart`) moves and zooms the window and reports full screen.
- `test/bridge_test.dart` runs against `target/debug/libmeret_ffi.dylib`; run `cargo build -p meret-ffi` from the repo root first.
