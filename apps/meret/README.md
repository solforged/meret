# Meret app

The Flutter UI over the Rust core. Architecture, rules and how to work on it are in [`docs/architecture.md`](../../docs/architecture.md).

- `lib/core/bridge.dart` is the only way the UI talks to the core. `RustCore` is the real one; `FakeCore` serves the plates' Tuesday evening for tests and design work.
- `lib/src/rust/` is generated. Change `crates/meret-ffi/src/api/`, then run `flutter_rust_bridge_codegen generate` here.
- `hook/build.dart` builds `crates/meret-ffi` with Flutter native assets (`flutter_rust_bridge_hooks`), using the pinned toolchain in `rust-toolchain.toml`. Plugins come through Swift Package Manager. Neither cargokit nor CocoaPods is used.
