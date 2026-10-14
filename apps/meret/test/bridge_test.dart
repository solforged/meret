// Exercises the real Rust core through flutter_rust_bridge, on the host,
// without building the app. Needs the debug dylib:
//
//   cargo build -p meret-ffi   (from the repo root)
//
import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/src/rust/api/core.dart' as rust;
import 'package:meret/src/rust/frb_generated.dart';

final _lib = '${Directory.current.path}/../../target/debug/libmeret_ffi.dylib';

void main() {
  setUpAll(() async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(_lib));
    final dir = await Directory.systemTemp.createTemp('meret-bridge-test');
    await rust.startCore(dataDir: dir.path, nullOutput: true);
    addTearDown(() => dir.delete(recursive: true));
  });

  test('the query line parses through Rust', () {
    final core = RustCore();
    final q = core.parse('sung:"Joanne Hogg" not:owned year:1990s');
    expect(q.kind, QueryKind.search);
    expect(q.canonical, 'sung:"Joanne Hogg" not:owned year:1990s');
    expect(core.parse('colour:red').kind, QueryKind.invalid);
  });

  test('the status line streams the registry', () async {
    final s = await RustCore().status().first;
    expect(s.sources.map((x) => x.name), containsAll(['This Mac', 'MusicBrainz']));
  });

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
  });

  test('a scanned folder supplies table rows and plays its results', () async {
    final core = RustCore();
    final dir = await Directory.systemTemp.createTemp('meret-library-test');
    try {
      await File('${Directory.current.path}/test/fixtures/tone-16-44.flac').copy('${dir.path}/tone.flac');
      final scanned = core.status().firstWhere((status) => status.tracks >= BigInt.one);
      expect(await core.addRoot(dir.path), greaterThan(0));
      await scanned.timeout(const Duration(seconds: 10));

      final page = await core.rows('', 0, 50);
      expect(page.total, greaterThanOrEqualTo(BigInt.one));
      expect(page.rows, hasLength(1));
      final row = page.rows.single;
      expect(row.title, isNotEmpty);
      expect(row.format, 'FLAC 16/44.1');

      final started = core.now().firstWhere((now) => now.title == row.title && now.path.isNotEmpty);
      await core.playResults('', 0);
      final now = await started.timeout(const Duration(seconds: 5));
      expect(now.title, row.title);
      expect(now.path.map((stage) => stage.detail), contains('FLAC 16/44.1'));
    } finally {
      await core.transport(const TransportDto.stop());
      await dir.delete(recursive: true);
    }
  });
}
