import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/src/rust/api/core.dart' as rust;
import 'package:meret/src/rust/frb_generated.dart';

void main() {
  test('fake listening memory uses the plate times, counts and existing row identities', () async {
    final core = FakeCore();
    final history = await core.history(20);
    expect(history.map((row) => row.title), ['Small Two of Pieces', 'Creid, track 3', 'Stars of Tears', 'Corridors of Time']);
    expect(history.map((row) {
      final at = DateTime.fromMillisecondsSinceEpoch(row.startedAtMs.toInt());
      return (at.hour, at.minute);
    }), [(23, 10), (22, 58), (22, 41), (21, 31)]);
    for (final listen in history) {
      final release = await core.release(listen.releaseId!);
      expect(release.rows.any((row) => row.trackId == listen.trackId), isTrue);
    }
    final most = await core.mostPlayed(7, 20);
    expect(most.map((row) => row.plays), [BigInt.from(14), BigInt.from(11), BigInt.from(6)]);
    expect(most.first.trackId, history.first.trackId);
    final dormant = await core.dormant(20);
    expect(dormant.map((row) => row.title), ['Sunday at the Village Vanguard', 'Outer Wilds', 'Gould Goldberg 1955']);
    final now = DateTime.now().millisecondsSinceEpoch;
    expect(dormant.map((row) => ((now - row.lastPlayedMs.toInt()) / 86400000).round()), [730, 548, 1095]);
    expect(await core.history(0), isEmpty);
    expect(await core.mostPlayed(0, 20), isEmpty);
    expect(await core.mostPlayed(7, 1), hasLength(1));
    expect(await core.dormant(1), hasLength(1));
    final empty = FakeCore.empty();
    expect(await empty.history(20), isEmpty);
    expect(await empty.mostPlayed(7, 20), isEmpty);
    expect(await empty.dormant(20), isEmpty);
  });

  test('real playback persists a counted listen and a one-second skip across the bridge', () async {
    final lib = Platform.environment['MERET_FFI_DYLIB'] ?? '${Directory.current.path}/../../target/debug/libmeret_ffi.dylib';
    await RustLib.init(externalLibrary: ExternalLibrary.open(lib));
    final data = await Directory.systemTemp.createTemp('meret-listens-bridge');
    final music = await Directory.systemTemp.createTemp('meret-listens-music');
    addTearDown(() async {
      await data.delete(recursive: true);
      await music.delete(recursive: true);
    });
    await File('${Directory.current.path}/test/fixtures/tone-16-44.flac').copy('${music.path}/tone.flac');
    await rust.startCore(dataDir: data.path, nullOutput: true);
    final core = RustCore();
    final scanned = core.status().firstWhere((state) => state.tracks == BigInt.one);
    await core.addRoot(music.path);
    await scanned.timeout(const Duration(seconds: 10));
    const view = ViewDto(sort: SortKeyDto.library_, descending: false, group: false);
    final rows = await core.rows('', view, 0, 1);
    final row = (rows.items.single as ItemDto_Track).row;
    final finished = core.now().firstWhere((now) => now.trackId == row.trackId && now.anchor?.rate == 0 && now.path.isNotEmpty);
    await core.playResults('', view, 0);
    await finished.timeout(const Duration(seconds: 12));
    var history = await core.history(10);
    expect(history, hasLength(1));
    expect(history.single.counted, isTrue);
    expect(history.single.trackId, row.trackId);
    expect((await core.mostPlayed(7, 10)).single.plays, BigInt.one);
    expect((await core.rows('plays:1', view, 0, 10)).tracks, BigInt.one);
    expect(await core.dormant(10), isEmpty);
    final started = core.now().firstWhere((now) => now.trackId == row.trackId && now.anchor?.rate == 1);
    await core.playResults('', view, 0);
    await started.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(seconds: 1));
    final stopped = core.now().firstWhere((now) => now.anchor?.rate == 0);
    await core.transport(const TransportDto.next());
    await stopped.timeout(const Duration(seconds: 5));
    history = await core.history(10);
    expect(history, hasLength(2));
    expect(history.first.counted, isFalse);
    expect(history.first.playedMs.toInt(), inInclusiveRange(900, 1500));
    expect((await core.mostPlayed(7, 10)).single.plays, BigInt.one);
  });
}
