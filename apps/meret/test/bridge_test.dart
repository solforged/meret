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
const _libraryView = ViewDto(sort: SortKeyDto.library_, descending: false, group: false);

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

  test('null output reports unsupported device volume and rejects sample gain', () async {
    final core = RustCore();
    final volume = await core.volume();
    expect(volume.settable, isFalse);
    expect(volume.scalar, isNull);
    expect(volume.reason, isNotEmpty);
    await expectLater(core.setVolume(0.5), throwsA(isA<String>()));
    await expectLater(core.setVolume(double.nan), throwsA(isA<String>()));
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

  test('a scanned folder supplies grouped rows and plays from its view ordinal', () async {
    final core = RustCore();
    try {
      await _scanFixture(core);

      const view = ViewDto(sort: SortKeyDto.title, descending: true, group: true);
      final page = await core.rows('', view, 0, 50);
      expect(page.total, BigInt.two);
      expect(page.tracks, BigInt.one);
      expect(page.releases, BigInt.one);
      expect(page.items, hasLength(2));
      final group = (page.items.first as ItemDto_Group).field0;
      final track = page.items.last as ItemDto_Track;
      final row = track.row;
      expect(group.releaseId, row.releaseId);
      expect(group.title, row.album);
      expect(group.tracks, 1);
      expect(group.lengthMs, row.lengthMs);
      expect(group.format, 'Lossless, up to 16/48');
      expect(track.ordinal, 0);
      expect(row.title, isNotEmpty);
      expect(row.format, 'FLAC 16/44.1');

      final started = core.now().firstWhere((now) => now.title == row.title && now.path.isNotEmpty);
      await core.playResults('', view, track.ordinal);
      final now = await started.timeout(const Duration(seconds: 5));
      expect(now.title, row.title);
      expect(now.path.map((stage) => stage.detail), contains('FLAC 16/44.1'));
    } finally {
      await core.transport(const TransportDto.stop());
    }
  });

  test('facets count the fixture and supply selected-release queries', () async {
    final core = RustCore();
    await _scanFixture(core);
    final row = ((await core.rows('', _libraryView, 0, 1)).items.single as ItemDto_Track).row;
    final album = row.album.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    final facets = await core.facets('release:"$album"');
    expect(facets.idioms.tracks, 1);
    expect(facets.idioms.entries.single.tracks, 1);
    expect(facets.people.tracks, 1);
    expect(facets.people.entries, isNotEmpty);
    expect(facets.releases.tracks, 1);
    expect(facets.releases.allQuery, '');
    final release = facets.releases.entries.single;
    expect(release.id, row.releaseId);
    expect(release.name, row.album);
    expect(release.selected, isTrue);
    expect(release.query, '');
    final idiom = facets.idioms.entries.single;
    final selected = await core.facets(idiom.query);
    expect(selected.idioms.entries.single.selected, isTrue);
    expect(selected.people.allQuery, idiom.query);
    expect((await core.rows(idiom.query, _libraryView, 0, 10)).tracks, BigInt.one);
  });

  test('search groups the fixture and starts a trail rooted at its canonical query', () async {
    final core = RustCore();
    await _scanFixture(core);
    final row = ((await core.rows('', _libraryView, 0, 1)).items.single as ItemDto_Track).row;
    final hits = await core.search(row.title);
    expect(hits.query, isNotEmpty);
    expect(hits.tracks, BigInt.one);
    expect(hits.trackHitsTotal, BigInt.one);
    expect(hits.trackHits, hasLength(1));
    expect(hits.trackHits.single.kind, HitKind.track);
    expect(hits.trackHits.single.title, row.title);
    expect(hits.trackHits.single.id, row.trackId);
    expect(hits.trackHits.single.index, BigInt.zero);
    expect(hits.people.every((hit) => hit.kind == HitKind.person), isTrue);
    expect(hits.releases.every((hit) => hit.kind == HitKind.release), isTrue);

    final album = row.album.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    final releases = await core.search('release:"$album"');
    expect(releases.releasesTotal, BigInt.one);
    expect(releases.releases.single.kind, HitKind.release);
    expect(releases.releases.single.title, row.album);

    final trail = await core.startTrail(TargetDto.search(query: hits.query));
    expect(trail.stops, hasLength(1));
    expect(trail.stops.single.target, TargetDto.search(query: hits.query));
    expect(trail.current, trail.stops.single.index);
    expect((await core.trail())!.stops.single.target, trail.stops.single.target);
    await expectLater(core.search('queue ${hits.query}'), throwsA(isA<String>()));
  });

  test('release and person panes follow the fixture credits and navigate their trail', () async {
    final core = RustCore();
    await _scanFixture(core);
    final row = ((await core.rows('', _libraryView, 0, 1)).items.single as ItemDto_Track).row;
    final previous = await core.startTrail(TargetDto.search(query: row.title));
    final root = await core.startTrail(const TargetDto.search(query: ''));
    final releaseTrail = await core.follow(root.current, TargetDto.release(id: row.releaseId), ThreadKind.appearsOn);
    final releaseStop = releaseTrail.current;
    expect(releaseTrail.stops.last.title, row.album);
    expect(releaseTrail.stops.last.via, 'on');
    expect(releaseTrail.stops.last.viaSource, 'tags');
    final release = await core.release(row.releaseId);
    expect(release.id, row.releaseId);
    expect(release.title, row.album);
    expect(release.tracks, 1);
    expect(release.rows.single.trackId, row.trackId);
    expect(release.formats, ['FLAC 16/44.1']);
    expect(release.lengthMs, row.lengthMs);
    final credit = release.credits.first;
    expect(credit.source, 'tags');
    final personId = (credit.to as TargetDto_Person).id;
    final person = await core.person(personId);
    expect(person.id, row.artistId);
    expect(person.name, row.artist);
    expect(person.tracks, 1);
    expect([...person.releases, ...person.appearsOn].single.to, TargetDto.release(id: row.releaseId));
    final personTrail = await core.follow(releaseStop, credit.to, credit.kind);
    final personStop = personTrail.current;
    expect(personTrail.stops.last.title, person.name);
    expect(personTrail.stops.where((stop) => stop.onPath), hasLength(3));

    final back = (await core.trailBack())!;
    expect(back.current, releaseStop);
    expect(back.stops.where((stop) => stop.onPath), hasLength(2));
    expect(await core.trailForward(), isNull, reason: 'the briefly opened person is folded away');
    expect((await core.trailGo(root.current)).stops.where((stop) => stop.onPath), hasLength(1));
    final previousTrail = (await core.trailBack())!;
    expect(previousTrail.rootQuery, previous.rootQuery);
    expect(previousTrail.current, previous.current);
    expect((await core.trailForward())!.current, root.current);
    expect((await core.trailForward())!.current, releaseStop);
    final reopened = await core.follow(releaseStop, credit.to, credit.kind);
    expect(reopened.current, personStop);
    expect(reopened.stops, hasLength(3));
    final loop = await core.follow(personStop, TargetDto.release(id: row.releaseId), ThreadKind.appearsOn);
    expect(loop.current, releaseStop);
    expect(loop.stops, hasLength(3));
    await core.follow(releaseStop, credit.to, credit.kind);

    try {
      final started = core.now().firstWhere((now) => now.title == row.title && now.path.isNotEmpty);
      await core.playRelease(id: release.id, index: 0, fromStop: releaseStop);
      final now = await started.timeout(const Duration(seconds: 5));
      expect(now.title, row.title);
      expect(now.path.map((stage) => stage.detail), contains('FLAC 16/44.1'));
      expect((await core.trail())!.current, personStop);
    } finally {
      await core.transport(const TransportDto.stop());
    }
  });
}
