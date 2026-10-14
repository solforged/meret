// Exercises the real Rust core through flutter_rust_bridge, on the host,
// without building the app. Needs the debug dylib:
//
//   cargo build -p meret-ffi   (from the repo root)
//
// Skipped when the library isn't there.

import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/src/rust/api/core.dart' as rust;
import 'package:meret/src/rust/frb_generated.dart';

final _lib = '${Directory.current.path}/../../target/debug/libmeret_ffi.dylib';

void main() {
  final skip = File(_lib).existsSync() ? null : 'build the dylib first: cargo build -p meret-ffi';

  setUpAll(() async {
    if (skip != null) return;
    await RustLib.init(externalLibrary: ExternalLibrary.open(_lib));
    final dir = await Directory.systemTemp.createTemp('meret-bridge-test');
    await rust.startCore(dataDir: dir.path, nullOutput: true);
  });

  test('the query line parses through Rust', () {
    final core = RustCore();
    final q = core.parse('sung:"Joanne Hogg" not:owned year:1990s');
    expect(q.kind, QueryKind.search);
    expect(q.canonical, 'sung:"Joanne Hogg" not:owned year:1990s');
    expect(core.parse('colour:red').kind, QueryKind.invalid);
  }, skip: skip);

  test('the status line streams the registry', () async {
    final s = await RustCore().status().first;
    expect(s.sources.map((x) => x.name), containsAll(['This Mac', 'MusicBrainz']));
  }, skip: skip);

  test('playing a FLAC streams Now with a bit-perfect path and a moving anchor', () async {
    final core = RustCore();
    final fixture = '${Directory.current.path}/test/fixtures/tone-16-44.flac';
    final started = Completer<NowDto>();
    final sub = core.now().listen((n) {
      if (n.path.isNotEmpty && n.anchor != null && !started.isCompleted) started.complete(n);
    });
    await core.transport(TransportDto.playFile(path: fixture));
    final now = await started.future.timeout(const Duration(seconds: 5));
    await sub.cancel();

    expect(now.title, 'tone-16-44');
    expect(now.path.map((s) => s.detail), contains('FLAC 16/44.1'));
    expect(now.fidelity, FidelityDto.bitPerfect);
    expect(now.anchor!.rate, 1.0);
    await core.transport(const TransportDto.stop());
  }, skip: skip);
}
