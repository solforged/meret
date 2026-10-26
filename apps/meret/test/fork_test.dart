import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64, PlatformInt64Util;
import 'package:meret/core/bridge.dart';
import 'package:meret/main.dart';
import 'package:meret/panes/pane.dart';
import 'package:meret/panes/person_pane.dart';
import 'package:meret/panes/release_pane.dart';
import 'package:meret/panes/search_pane.dart';
import 'package:meret/shell/pane_row.dart';
import 'package:meret/shell/trail_chip.dart';
import 'package:meret/shell/window_chrome.dart';
import 'package:meret/theme/tokens.dart';

void main() {
  testWidgets('fork rows open their leaves and mark the current branch', (tester) async {
    final core = await _forkSurface(tester);
    final oldBranch = find.byKey(const ValueKey('fork-0-2'));
    final current = find.byKey(const ValueKey('fork-0-3'));
    expect(find.descendant(of: oldBranch, matching: find.text('Low tide')), findsOneWidget);
    expect(tester.widget<Text>(find.descendant(of: current, matching: find.text('Cinder orchard'))).style!.color, Tok.gold);
    final root = find.descendant(of: find.byType(PaneRow), matching: find.byType(Pane)).first;
    expect(find.descendant(of: root, matching: find.text('⑂ 2')), findsOneWidget, reason: 'two branches leave the root');
    await tester.tap(oldBranch);
    await tester.pumpAndSettle();
    expect(core.visited, [2]);
    expect((await core.trail())!.current, 2);
    expect(_titles(tester), ['Nera Vale', 'Glass harbour', 'Low tide']);
  });

  testWidgets('search-root forks show branch rows and mark followed person and release hits', (tester) async {
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = _SearchForkCore();
    await core.startTrail(const TargetDto.search(query: 'tide'));
    await core.follow(0, TargetDto.release(id: PlatformInt64Util.from(1)), ThreadKind.appearsOn, 'local_tags');
    await core.follow(1, TargetDto.work(id: PlatformInt64Util.from(1)), ThreadKind.recordingOf, 'local_tags');
    await core.follow(0, TargetDto.person(id: PlatformInt64Util.from(1)), ThreadKind.by, 'local_tags');
    await core.follow(0, TargetDto.release(id: PlatformInt64Util.from(2)), ThreadKind.appearsOn, 'local_tags');
    await tester.pumpWidget(MeretApp(core: core));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await tester.pumpAndSettle();
    core.visited.clear();

    final search = find.byType(SearchPane);
    final oldBranch = find.descendant(of: search, matching: find.byKey(const ValueKey('fork-0-2')));
    expect(find.descendant(of: oldBranch, matching: find.text('Low tide')), findsOneWidget);
    expect(find.descendant(of: search, matching: find.byKey(const ValueKey('fork-0-3'))), findsOneWidget);
    final current = find.descendant(of: search, matching: find.byKey(const ValueKey('fork-0-4')));
    expect(tester.widget<Text>(find.descendant(of: current, matching: find.text('Cinder orchard'))).style!.color, Tok.gold);
    final personHit = find.byKey(const ValueKey('search-hit-person-1'));
    final releaseHit = find.byKey(const ValueKey('search-hit-release-1'));
    expect(find.descendant(of: personHit, matching: find.text('⑂ → Nera Vale')), findsOneWidget);
    expect(find.descendant(of: releaseHit, matching: find.text('⑂ → Low tide')), findsOneWidget);
    expect(find.descendant(
      of: find.byKey(const ValueKey('search-hit-release-2')), matching: find.byType(Text),
    ).evaluate().map((element) => (element.widget as Text).data), ['Cinder orchard']);

    await tester.ensureVisible(oldBranch);
    await tester.tap(oldBranch);
    await tester.pumpAndSettle();
    expect(core.visited, [2]);
    expect((await core.trail())!.current, 2);
    expect(_titles(tester), ['tide', 'Glass harbour', 'Low tide']);

    await tester.ensureVisible(personHit);
    await tester.tap(personHit);
    await tester.pumpAndSettle();
    expect((await core.trail())!.current, 3);
    expect((await core.trail())!.stops, hasLength(5));
    expect(find.descendant(of: personHit, matching: find.text('⑂ → Nera Vale')), findsNothing);
  });

  testWidgets('an off-path thread names its newest leaf and still revisits its child', (tester) async {
    final core = await _forkSurface(tester);
    final person = find.byType(PersonPane);
    final thread = find.descendant(of: person, matching: find.byWidgetPredicate(
      (widget) => widget is ThreadLine && widget.thread.to == TargetDto.release(id: PlatformInt64Util.from(1)),
    ));
    final mark = find.descendant(of: thread, matching: find.text('⑂ → Low tide'));
    expect(mark, findsOneWidget);
    await tester.tap(mark);
    await tester.pumpAndSettle();
    expect((await core.trail())!.current, 1);
    expect((await core.trail())!.stops, hasLength(4));
    expect(find.descendant(of: thread, matching: find.text('⑂ → Low tide')), findsNothing);
  });

  testWidgets('option brackets switch siblings to the last stop and ignore text editing', (tester) async {
    final core = await _forkSurface(tester);
    await _key(tester, LogicalKeyboardKey.bracketRight, modifier: LogicalKeyboardKey.altLeft);
    expect(core.siblings, [1]);
    expect((await core.trail())!.current, 2);
    await _key(tester, LogicalKeyboardKey.bracketLeft, modifier: LogicalKeyboardKey.altLeft);
    expect(core.siblings, [1, -1]);
    expect((await core.trail())!.current, 3);
    await tester.tap(find.byType(TextField));
    await _key(tester, LogicalKeyboardKey.bracketRight, modifier: LogicalKeyboardKey.altLeft);
    await _key(tester, LogicalKeyboardKey.backspace, modifier: LogicalKeyboardKey.metaLeft);
    expect(core.siblings, [1, -1]);
    expect(core.pruned, isEmpty);
    expect((await core.trail())!.current, 3);
  });

  testWidgets('a fork prune removes that branch and refreshes the chip and pane', (tester) async {
    final core = await _forkSurface(tester);
    await tester.tap(find.byKey(const ValueKey('prune-0-2')));
    await tester.pumpAndSettle();
    expect(core.pruned, [2]);
    expect((await core.trail())!.stops.map((stop) => stop.index), [0, 3]);
    expect(find.byKey(const ValueKey('fork-0-2')), findsNothing);
    expect(tester.widget<TrailChip>(find.byType(TrailChip)).trail.stops, hasLength(2));
    expect(find.byKey(const ValueKey('pane-forks')), findsNothing, reason: 'no branch leaves the root now');
  });

  testWidgets('command backspace prunes the newest eligible branch', (tester) async {
    final core = await _forkSurface(tester);
    await _key(tester, LogicalKeyboardKey.backspace, modifier: LogicalKeyboardKey.metaLeft);
    expect(core.pruned, [2]);
    expect((await core.trail())!.current, 3);
  });

  testWidgets('menu playback selects branch or tree without moving and shows core failures', (tester) async {
    final core = await _forkSurface(tester);
    WindowChrome.instance.onMenu!('playBranch');
    await tester.pump();
    await tester.pump();
    expect(core.playedTrails, [false]);
    expect((await core.trail())!.current, 3);
    WindowChrome.instance.onMenu!('playTree');
    await tester.pump();
    await tester.pump();
    expect(core.playedTrails, [false, true]);
    expect((await core.trail())!.current, 3);
    expect(find.byKey(const ValueKey('prune-0-2')), findsNothing);
    core.playError = 'nothing on this trail has tracks to play';
    WindowChrome.instance.onMenu!('playBranch');
    await tester.pump();
    final error = find.text(core.playError!);
    expect(error, findsOneWidget);
    expect(tester.widget<Text>(error).style!.color, Tok.warn);
  });

  test('fake refuses current and played branches and preserves stable indices after pruning', () async {
    final core = await _forkCore();
    await expectLater(core.pruneBranch(3), throwsA(isA<String>()));
    await core.pruneBranch(2);
    final next = await core.follow(0, TargetDto.release(id: PlatformInt64Util.from(1)), ThreadKind.appearsOn, 'local_tags');
    expect(next.current, 4);
    await core.playRelease(id: PlatformInt64Util.from(1), index: 0, fromStop: 4);
    await core.trailGo(3);
    await expectLater(core.pruneBranch(4), throwsA(isA<String>()));
    expect((await core.trail())!.branches.last.actions, ['played']);
  });
}

List<String> _titles(WidgetTester tester) => tester.widget<PaneRow>(find.byType(PaneRow)).children
    .cast<Pane>().map((pane) => pane.title).toList();

Future<_ForkCore> _forkCore() async {
  final core = _ForkCore();
  await core.startTrail(TargetDto.person(id: PlatformInt64Util.from(1)));
  await core.follow(0, TargetDto.release(id: PlatformInt64Util.from(1)), ThreadKind.appearsOn, 'local_tags');
  await core.follow(1, TargetDto.work(id: PlatformInt64Util.from(1)), ThreadKind.recordingOf, 'local_tags');
  await core.follow(0, TargetDto.release(id: PlatformInt64Util.from(2)), ThreadKind.appearsOn, 'local_tags');
  return core;
}

Future<_ForkCore> _forkSurface(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1800, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final core = await _forkCore();
  await tester.pumpWidget(MeretApp(core: core));
  await tester.pumpAndSettle();
  await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
  await tester.pumpAndSettle();
  core.visited.clear();
  return core;
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key, {required LogicalKeyboardKey modifier}) async {
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(modifier);
  await tester.pumpAndSettle();
}

class _ForkCore extends FakeCore {
  final visited = <int>[];
  final siblings = <int>[];
  final pruned = <int>[];
  final playedTrails = <bool>[];
  String? playError;

  @override
  Stream<NowDto> now() => Stream.value(const NowDto(title: '', subtitle: '', path: []));

  @override
  Future<PersonDto> person(PlatformInt64 id) async => PersonDto(
    id: id, name: 'Nera Vale', tracks: 2, plays: BigInt.zero,
    releases: [
      for (final (index, title) in [(1, 'Glass harbour'), (2, 'Cinder orchard')])
        ThreadDto(kind: ThreadKind.appearsOn, label: 'appears on', source: 'tags', provider: 'local_tags',
          to: TargetDto.release(id: PlatformInt64Util.from(index)), title: title, detail: ''),
    ],
    appearsOn: [], roles: [], works: [], games: [], groups: [], workedWith: [],
  );

  @override
  Future<ReleaseDto> release(PlatformInt64 id) async {
    final source = await super.release(id);
    return ReleaseDto(
      id: id, title: id.toInt() == 1 ? 'Glass harbour' : 'Cinder orchard',
      artistLinks: [], tracks: source.rows.length, discs: 1, lengthMs: source.lengthMs,
      formats: [], rows: source.rows, rowWorks: [for (final _ in source.rows) null],
      credits: [], games: [], plays: BigInt.zero,
    );
  }

  @override
  Future<WorkDto> work(PlatformInt64 id) async {
    final source = await super.work(id);
    return WorkDto(id: id, title: 'Low tide', composerLinks: [], parts: [],
      rows: source.rows, others: [], lengthMs: source.lengthMs, plays: BigInt.zero);
  }

  @override
  Future<TrailDto> trailGo(int stop) {
    visited.add(stop);
    return super.trailGo(stop);
  }

  @override
  Future<TrailDto?> trailSibling(int step) {
    siblings.add(step);
    return super.trailSibling(step);
  }

  @override
  Future<TrailDto> pruneBranch(int leaf) {
    pruned.add(leaf);
    return super.pruneBranch(leaf);
  }

  @override
  Future<int> playTrail(bool whole) async {
    playedTrails.add(whole);
    if (playError != null) throw playError!;
    return super.playTrail(whole);
  }
}

class _SearchForkCore extends _ForkCore {
  @override
  Future<SearchDto> search(String input) async => SearchDto(
    query: input, tracks: BigInt.zero,
    people: [HitDto(kind: HitKind.person, id: PlatformInt64Util.from(1),
      title: 'Nera Vale', detail: '', query: input)],
    peopleTotal: BigInt.one,
    releases: [
      for (final (id, title) in [(1, 'Glass harbour'), (2, 'Cinder orchard')])
        HitDto(kind: HitKind.release, id: PlatformInt64Util.from(id),
          title: title, detail: '', query: input),
    ],
    releasesTotal: BigInt.two, trackHits: [], trackHitsTotal: BigInt.zero,
  );
}
