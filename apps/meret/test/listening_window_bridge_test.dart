import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/src/rust/api/core.dart' as rust;
import 'package:meret/src/rust/frb_generated.dart';

void main() {
  test('the real bridge returns the requested listening window and excludes its end', () async {
    final library = Platform.environment['MERET_TEST_DYLIB'] ?? '${Directory.current.path}/../../target/debug/libmeret_ffi.dylib';
    await RustLib.init(externalLibrary: ExternalLibrary.open(library));
    final data = await Directory.systemTemp.createTemp('meret-window-data-');
    final music = await Directory.systemTemp.createTemp('meret-window-music-');
    addTearDown(() async {
      await music.delete(recursive: true);
      await data.delete(recursive: true);
    });
    await File('${Directory.current.path}/test/fixtures/tone-16-44.flac').copy('${music.path}/tone.flac');
    await rust.startCore(dataDir: data.path, nullOutput: true);
    final core = RustCore();
    final scanned = core.status().firstWhere((status) => status.tracks == BigInt.one);
    await core.addRoot(music.path);
    await scanned.timeout(const Duration(seconds: 10));
    const view = ViewDto(sort: SortKeyDto.library_, descending: false, group: false);
    final row = ((await core.rows('', view, 0, 1)).items.single as ItemDto_Track).row;
    final started = core.now().firstWhere((now) => now.trackId == row.trackId && now.anchor != null);
    await core.playResults('', view, 0);
    await started.timeout(const Duration(seconds: 5));
    await core.transport(const TransportDto.stop());
    await core.flushMemory();

    final listen = (await core.history(10)).single;
    final at = listen.startedAtMs.toInt();
    final window = await core.listeningWindow(at, at + 1);
    expect(window.listens, [listen]);
    expect(window.mostPlayed.length, listen.counted ? 1 : 0);
    expect((await core.listeningWindow(at - 1, at)).listens, isEmpty);
    expect((await core.listeningWindow(at + 1, at + 2)).listens, isEmpty);
    await expectLater(core.jumpToQueued(BigInt.from(999999)), throwsA(contains('no longer available')));
  });
}
