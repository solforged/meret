# Meret app

The Flutter UI over the Rust core. Architecture, rules and how to work on it are in [`docs/architecture.md`](../../docs/architecture.md).

`mise run install` builds the release app, quits any running Meret, replaces `/Applications/Meret.app` and opens it. It uses your library in `~/Library/Application Support/io.sowilo.meret`, the same as a debug build.

- `lib/core/bridge.dart` is the only way the UI talks to the core. `RustCore` is the real one: the table pages the core's grouped or flat views, sorts by column, browses Idiom → People → Releases facets, and plays track ordinals from that same view. `FakeCore` serves the plates' Tuesday evening plus a 48,210-track fake library, for tests and design work (`--dart-define=MERET_FAKE=true`).
- Settings live in `library.db` through the core's single writer. The bridge exposes light level, output devices and exclusive mode, the output device's own volume (`volume`, `setVolume`), budgeted folder suggestions, and root removal without deleting files or stored history. Output changes apply at once when idle, on resume when paused, and otherwise from the next track opened. Suggestions never count inside macOS-protected folders before access, and omit the boot volume and mounts hidden from Finder.
- `lib/theme/light.dart` carries the playing release's core-supplied colours and track identity through `LightScope`. The surface, body and playing rows use that light, or brass when it is absent; navigation and status colours stay fixed. Release and Now covers use the core's 256 px files with bounded image decoding.
- `lib/src/rust/` is generated. Change `crates/meret-ffi/src/api/`, then run `flutter_rust_bridge_codegen generate` here.
- `hook/build.dart` builds `crates/meret-ffi` with Flutter native assets (`flutter_rust_bridge_hooks`), using the pinned toolchain in `rust-toolchain.toml`. Plugins come through Swift Package Manager. Neither cargokit nor CocoaPods is used.
- The macOS app isn't sandboxed, so it reads music folders anywhere. The window has no native title bar: the query line stands in for it, and `meret/window` (`MainFlutterWindow.swift`, `lib/shell/window_chrome.dart`) moves and zooms the window and reports full screen.
- `test/bridge_test.dart` runs against `target/debug/libmeret_ffi.dylib`; run `cargo build -p meret-ffi` from the repo root first.
