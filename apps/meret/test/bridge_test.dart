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
late Directory _fixtureDir;
Future<void>? _scan;

Future<void> _scanFixture(CoreBridge core) => _scan ??= () async {
  final scanned = core.status().firstWhere((status) => status.tracks >= BigInt.one);
  expect(await core.addRoot(_fixtureDir.path), greaterThan(0));
  await scanned.timeout(const Duration(seconds: 10));
}();

void main() {
  setUpAll(() async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(_lib));
    final dir = await Directory.systemTemp.createTemp('meret-bridge-test');
    await rust.startCore(dataDir: dir.path, nullOutput: true);
    addTearDown(() => dir.delete(recursive: true));
    _fixtureDir = await Directory.systemTemp.createTemp('meret-library-test');
    await File('${Directory.current.path}/test/fixtures/tone-16-44.flac').copy('${_fixtureDir.path}/tone.flac');
    addTearDown(() => _fixtureDir.delete(recursive: true));
  });

  test('the query line parses through Rust', () {
    final core = RustCore();
    final q = core.parse('sung:"Joanne Hogg" not:owned year:1990s');
    expect(q.kind, QueryKind.search);
    expect(q.canonical, 'sung:"Joanne Hogg" not:owned year:1990s');
    expect(core.parse('colour:red').kind, QueryKind.invalid);
  });

  test('a command runs from its canonical form, and unbuilt ones say so', () async {
    final core = RustCore();
    final queue = core.parse('queue  year:2010');
    expect(queue.kind, QueryKind.command);
    expect(queue.canonical, 'queue year:2010');
    await expectLater(core.runCommand(queue.canonical), throwsA(contains("queue isn't built yet")));
    await core.runCommand(core.parse('play release:nothing-here').canonical);
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

  test('the Front reports the scanned fixture, its idiom door and folder', () async {
    final core = RustCore();
    await _scanFixture(core);
    final front = await core.front();
    expect(front.tracks, BigInt.one);
    expect(front.idioms.any((idiom) => idiom.query != null && idiom.tracks == BigInt.one), isTrue);
    expect(front.roots, hasLength(1));
    expect(front.roots.single.path, await _fixtureDir.resolveSymbolicLinks());
    expect(front.roots.single.online, isTrue);
  });

  test('a scanned folder supplies table rows and plays its results', () async {
    final core = RustCore();
    try {
      await _scanFixture(core);

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
    }
  });
}
