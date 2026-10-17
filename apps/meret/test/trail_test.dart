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
    final trail = TrailDto(rootQuery: '', current: 2, stops: [
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
    final noMeeting = ConstellationPainter(TrailDto(rootQuery: '', current: 2, stops: trail.stops, meetings: const [(2, 4)]));
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
    final previous = await core.follow(first.current, TargetDto.person(id: hit.id), ThreadKind.matched);
    await core.startTrail(const TargetDto.search(query: 'year:1998'));
    await tester.pumpWidget(MeretApp(core: core));
    await tester.pump();
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

  test('fake trail follows loop back instead of appending and keeps newer history', () async {
    final core = FakeCore();
    final root = await core.startTrail(const TargetDto.search(query: 'Iona'));
    final hit = (await core.search('Iona')).people.first;
    final person = await core.follow(root.current, TargetDto.person(id: hit.id), ThreadKind.matched);
    final release = (await core.person(hit.id)).releases.first;
    final album = await core.follow(person.current, release.to, release.kind);
    final loop = await core.follow(album.current, TargetDto.person(id: hit.id), ThreadKind.albumArtist);
    expect(loop.current, person.current);
    expect(loop.stops, hasLength(3));
    final current = await core.follow(person.current, TargetDto.person(id: hit.id), ThreadKind.workedWith);
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
}

StopDto _stop(int index, int? parent, bool onPath, {bool peek = false}) => StopDto(
  index: index, parent: parent, target: TargetDto.search(query: 'Stop $index'),
  title: 'Stop $index', onPath: onPath, isFork: false, isPeek: peek,
);

TrailDto _longTrail(int count, int current) => TrailDto(
  rootQuery: '', current: current,
  stops: List.generate(count, (index) => _stop(index, index == 0 ? null : index - 1, index <= current)),
  meetings: const [],
);

Widget _strip(TrailDto trail) => MaterialApp(home: Scaffold(body: Center(child: SizedBox(
  width: 360, height: 64, child: TrailStrip(trail: trail, onGo: (_) {}),
))));

List<String> _titles(WidgetTester tester) => tester.widget<PaneRow>(find.byType(PaneRow)).children
    .skip(1).cast<Pane>().map((pane) => pane.title).toList();
