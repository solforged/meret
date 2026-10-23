import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/draw/constellation.dart';
import 'package:meret/main.dart';
import 'package:meret/panes/pane.dart';
import 'package:meret/shell/pane_row.dart';
import 'package:meret/theme/tokens.dart';

void main() {
  testWidgets('meetings paint dots between visible stars but not folded peeks', (tester) async {
    final trail = TrailDto(rootQuery: '', current: 2, kept: false, branches: const [], stops: [
      _stop(0, null, true),
      _stop(1, 0, true),
      _stop(2, 1, true),
      _stop(3, 0, false),
      _stop(4, 0, false, peek: true),
    ], meetings: const [(2, 3), (2, 4)]);
    final painter = ConstellationPainter(trail);
    await tester.pumpWidget(MaterialApp(home: SizedBox(
      width: 800, height: 64,
      child: CustomPaint(key: const ValueKey('constellation'), painter: painter),
    )));
    final paint = tester.renderObject<RenderCustomPaint>(find.byKey(const ValueKey('constellation')));
    expect(paint, paints..circle(radius: 1, color: Tok.gold2));
    final positions = painter.layoutPositions(const Size(800, 64));
    expect(positions.keys, containsAll([2, 3]));
    expect(positions, isNot(contains(4)));
    final noMeeting = ConstellationPainter(TrailDto(rootQuery: '', current: 2, kept: false, branches: const [], stops: trail.stops, meetings: const [(2, 4)]));
    await tester.pumpWidget(MaterialApp(home: CustomPaint(
      key: const ValueKey('constellation'), painter: noMeeting,
    )));
    expect(tester.renderObject<RenderCustomPaint>(find.byKey(const ValueKey('constellation'))),
      isNot(paints..circle(radius: 1, color: Tok.gold2)));
  });

  testWidgets('long strips scroll to current without squeezing tap targets', (tester) async {
    var trail = _longTrail(25, 24);
    await tester.pumpWidget(_strip(trail));
    await tester.pumpAndSettle();
    final scroll = tester.widget<SingleChildScrollView>(find.byKey(const ValueKey('trail-scroll'))).controller!;
    expect(scroll.offset, greaterThan(0));
    final viewport = tester.getRect(find.byKey(const ValueKey('trail-scroll')));
    expect(viewport.contains(tester.getCenter(find.byKey(const ValueKey('trail-stop-24')))), isTrue);
    expect(find.byKey(const ValueKey('trail-more-left')), findsOneWidget);
    expect(find.byKey(const ValueKey('trail-more-right')), findsNothing);
    expect(tester.getSize(find.byKey(const ValueKey('trail-stop-24'))), const Size(44, 44));
    final painter = ConstellationPainter(trail);
    final positions = painter.layoutPositions(Size(painter.contentWidth(360), 64)).values.toList();
    for (var i = 1; i < positions.length; i++) {
      expect(positions[i].dx - positions[i - 1].dx, greaterThanOrEqualTo(44));
    }
    trail = _longTrail(25, 0);
    await tester.pumpWidget(_strip(trail));
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);
    expect(viewport.contains(tester.getCenter(find.byKey(const ValueKey('trail-stop-0')))), isTrue);
    expect(find.byKey(const ValueKey('trail-more-left')), findsNothing);
    expect(find.byKey(const ValueKey('trail-more-right')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('trail-more-right')));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
  });

  testWidgets('bracket at a new search root restores the previous trail and strip', (tester) async {
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = FakeCore();
    final first = await core.startTrail(const TargetDto.search(query: 'Iona'));
    final hit = (await core.search('Iona')).people.first;
    final previous = await core.follow(first.current, TargetDto.person(id: hit.id), ThreadKind.matched, 'library');
    await core.startTrail(const TargetDto.search(query: 'year:1998'));
    await tester.pumpWidget(MeretApp(core: core));
    await tester.pump();
    await _restoreTrail(tester);
    expect(_titles(tester), ['year:1998']);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_titles(tester), ['Iona', hit.title]);
    final strip = tester.widget<TrailStrip>(find.byType(TrailStrip));
    expect(strip.trail.rootQuery, previous.rootQuery);
    expect(strip.trail.current, previous.current);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_titles(tester), ['year:1998']);
    expect(tester.widget<TrailStrip>(find.byType(TrailStrip)).trail.current, 0);
  });

  testWidgets('command S names and keeps the open trail, then marks its root', (tester) async {
    _desktop(tester);
    final core = _KeepingCore();
    final root = await core.startTrail(const TargetDto.search(query: 'year:1998'));
    final hit = (await core.search('Iona')).people.first;
    await core.follow(root.current, TargetDto.person(id: hit.id), ThreadKind.matched, 'library');
    await tester.pumpWidget(MeretApp(core: core));
    await tester.pumpAndSettle();
    await _restoreTrail(tester);

    await _command(tester, LogicalKeyboardKey.keyS);
    expect(find.byKey(const ValueKey('keep-trail-dialog')), findsOneWidget);
    final field = find.byKey(const ValueKey('trail-name'));
    expect(tester.widget<TextField>(field).controller!.text, 'year:1998 → ${hit.title}');
    await tester.enterText(field, 'Music for the evening');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(core.names, ['Music for the evening']);
    expect(find.byKey(const ValueKey('keep-trail-dialog')), findsNothing);
    expect(find.text('◆ Music for the evening'), findsOneWidget);
    final strip = tester.widget<TrailStrip>(find.byType(TrailStrip));
    expect(strip.trail.kept, isTrue);
    expect(strip.trail.stops, hasLength(2));
    final mark = tester.widget<Text>(find.byKey(const ValueKey('trail-kept')));
    expect(mark.style, Tok.label.copyWith(color: Tok.gold));
    expect(tester.getTopLeft(find.byKey(const ValueKey('trail-kept'))).dx,
      greaterThan(tester.getCenter(find.byKey(const ValueKey('trail-stop-0'))).dx));
  });

  testWidgets('Escape cancels keeping and the root alone is the suggested name', (tester) async {
    _desktop(tester);
    final core = _KeepingCore();
    await core.startTrail(const TargetDto.search(query: 'Iona'));
    await tester.pumpWidget(MeretApp(core: core));
    await tester.pumpAndSettle();
    await _restoreTrail(tester);
    await _command(tester, LogicalKeyboardKey.keyS);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('trail-name'))).controller!.text, 'Iona');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('keep-trail-dialog')), findsNothing);
    expect(core.names, isEmpty);
    expect(tester.widget<TrailStrip>(find.byType(TrailStrip)).trail.kept, isFalse);
  });

  testWidgets('command 1 shows the Front over the trail, which stays open and keepable', (tester) async {
    _desktop(tester);
    final core = _KeepingCore();
    await tester.pumpWidget(MeretApp(core: core));
    await tester.pumpAndSettle();
    await _command(tester, LogicalKeyboardKey.keyL);
    expect(find.byType(TrailStrip), findsOneWidget);
    await _command(tester, LogicalKeyboardKey.digit1);
    expect(find.byType(TrailStrip), findsOneWidget, reason: 'the Front does not end a trail');
    expect(find.byType(NoTrailStrip), findsNothing);
    expect(find.byKey(const ValueKey('front-over-trail')), findsOneWidget);
    expect(find.text('Front · ⌘1 back to Everything'), findsOneWidget);
    await _command(tester, LogicalKeyboardKey.keyS);
    expect(find.byKey(const ValueKey('keep-trail-dialog')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(core.names, ['Everything']);
    expect(find.text('◆ Everything'), findsOneWidget);
  });

  testWidgets('a core with no trail history has only the plain strip line', (tester) async {
    _desktop(tester);
    final core = FakeCore.empty();
    await tester.pumpWidget(MeretApp(core: core));
    await tester.pumpAndSettle();
    expect(find.byType(NoTrailStrip), findsOneWidget);
    expect(find.text('no trail yet'), findsOneWidget);
    expect(find.descendant(of: find.byType(NoTrailStrip), matching: find.textContaining('to resume')), findsNothing);
    await _command(tester, LogicalKeyboardKey.keyS);
    expect(find.text("there's no trail to keep"), findsOneWidget);
  });

  testWidgets('no-trail memory refresh uses the kept name and a gold bracket', (tester) async {
    final core = FakeCore();
    Widget strip(int version, {CoreBridge? bridge}) => MaterialApp(home: Scaffold(body: SizedBox(
      height: 64, child: NoTrailStrip(core: bridge ?? core, memoryVersion: version),
    )));
    await tester.pumpWidget(strip(0));
    await tester.pumpAndSettle();
    expect(find.text('no trail yet'), findsOneWidget);
    await core.startTrail(const TargetDto.search(query: 'Iona'));
    await core.keepTrail(name: 'A kept tree');
    await tester.pumpWidget(strip(1));
    await tester.pumpAndSettle();
    const line = "[ to resume today's · A kept tree · 1 stop";
    final text = tester.widget<Text>(find.text(line));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    final bracket = (text.textSpan! as TextSpan).children!.whereType<TextSpan>().firstWhere((span) => span.text == '[');
    expect(bracket.style!.color, Tok.gold);
    await tester.pumpWidget(strip(1, bridge: FakeCore.empty()));
    await tester.pumpAndSettle();
    expect(find.text('no trail yet'), findsOneWidget);
  });

  testWidgets('command S does not keep while typing in the query line', (tester) async {
    _desktop(tester);
    final core = _KeepingCore();
    await core.startTrail(const TargetDto.search(query: 'Iona'));
    await tester.pumpWidget(MeretApp(core: core));
    await tester.pumpAndSettle();
    await _restoreTrail(tester);
    await tester.tap(find.byType(TextField));
    await _command(tester, LogicalKeyboardKey.keyS);
    expect(find.byKey(const ValueKey('keep-trail-dialog')), findsNothing);
    expect(core.names, isEmpty);
  });

  test('fake trail follows loop back instead of appending and keeps newer history', () async {
    final core = FakeCore();
    final root = await core.startTrail(const TargetDto.search(query: 'Iona'));
    final hit = (await core.search('Iona')).people.first;
    final person = await core.follow(root.current, TargetDto.person(id: hit.id), ThreadKind.matched, 'library');
    final release = (await core.person(hit.id)).releases.first;
    final album = await core.follow(person.current, release.to, release.kind, release.provider);
    final loop = await core.follow(album.current, TargetDto.person(id: hit.id), ThreadKind.albumArtist, 'local_tags');
    expect(loop.current, person.current);
    expect(loop.stops, hasLength(3));
    final current = await core.follow(person.current, TargetDto.person(id: hit.id), ThreadKind.workedWith, 'local_tags');
    expect(current.current, person.current);
    expect(current.stops, hasLength(3));
    await core.startTrail(const TargetDto.search(query: 'year:1998'));
    await core.trailBack();
    await core.startTrail(const TargetDto.search(query: 'year:2000'));
    expect((await core.trailBack())!.rootQuery, 'Iona');
    expect((await core.trailBack())!.current, 0);
    expect((await core.trailBack())!.rootQuery, 'year:1998');
    expect((await core.trailForward())!.rootQuery, 'Iona');
  });

  test('fake trail memory names and keeps the whole tree across history moves', () async {
    final core = FakeCore();
    final root = await core.startTrail(const TargetDto.search(query: 'year:2000'));
    final rows = await core.rows('', const ViewDto(sort: SortKeyDto.library_, descending: false, group: false), 0, 1);
    final row = (rows.items.single as ItemDto_Track).row;
    final hit = (id: row.releaseId, title: row.album);
    await core.follow(root.current, TargetDto.release(id: hit.id), ThreadKind.matched, 'library');
    await core.playRelease(id: hit.id, index: 0, fromStop: 1);
    await core.keepTrail(name: 'A kept tree');
    final saved = (await core.trailHistory(1)).single;
    expect(saved.title, 'year:2000 → ${hit.title}');
    expect(saved.stops, 2);
    expect(saved.played, 1);
    expect(saved.kept, isTrue);
    expect(saved.name, 'A kept tree');
    await core.startTrail(const TargetDto.search(query: 'year:2001'));
    await core.trailBack();
    await core.startTrail(const TargetDto.search(query: 'year:2002'));
    final history = await core.trailHistory(10);
    expect(history, hasLength(3));
    expect(history[1].uid, saved.uid);
    expect(history[1].name, saved.name);
    expect(await core.trailHistory(0), isEmpty);
  });
}

StopDto _stop(int index, int? parent, bool onPath, {bool peek = false}) => StopDto(
  index: index, parent: parent, target: TargetDto.search(query: 'Stop $index'),
  title: 'Stop $index', onPath: onPath, isFork: false, isPeek: peek,
);

TrailDto _longTrail(int count, int current) => TrailDto(
  rootQuery: '', current: current, kept: false,
  stops: List.generate(count, (index) => _stop(index, index == 0 ? null : index - 1, index <= current)),
  meetings: const [],
  branches: const [],
);

Widget _strip(TrailDto trail) => MaterialApp(home: Scaffold(body: Center(child: SizedBox(
  width: 360, height: 64, child: TrailStrip(trail: trail, onGo: (_) {}),
))));

List<String> _titles(WidgetTester tester) => tester.widget<PaneRow>(find.byType(PaneRow)).children
    .cast<Pane>().map((pane) => pane.title).toList();

void _desktop(WidgetTester tester) {
  tester.view.physicalSize = const Size(1800, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _command(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _restoreTrail(WidgetTester tester) async {
  await _command(tester, LogicalKeyboardKey.keyL);
  await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

class _KeepingCore extends FakeCore {
  final names = <String?>[];

  @override
  Stream<NowDto> now() => Stream.value(const NowDto(title: '', subtitle: '', path: []));

  @override
  Future<TrailDto> keepTrail({String? name}) {
    names.add(name);
    return super.keepTrail(name: name);
  }
}
