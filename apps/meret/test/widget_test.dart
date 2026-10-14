import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64, PlatformInt64Util;
import 'package:meret/core/bridge.dart';
import 'package:meret/core/playhead.dart';
import 'package:meret/draw/body_painter.dart';
import 'package:meret/draw/constellation.dart';
import 'package:meret/main.dart';
import 'package:meret/now/now_pane.dart';
import 'package:meret/panes/front_pane.dart';
import 'package:meret/panes/pane.dart';
import 'package:meret/panes/search_pane.dart';
import 'package:meret/panes/person_pane.dart';
import 'package:meret/panes/release_pane.dart';
import 'package:meret/panes/table_pane.dart';
import 'package:meret/shell/pane_row.dart';
import 'package:meret/shell/query_line.dart';
import 'package:meret/theme/light.dart';
import 'package:meret/theme/tokens.dart';

const _libraryView = ViewDto(sort: SortKeyDto.library_, descending: false, group: false);
const _groupedView = ViewDto(sort: SortKeyDto.library_, descending: false, group: true);

void main() {
  testWidgets('the fake library opens at the Front without a trail', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);

    expect(find.byType(FrontPane), findsOneWidget);
    expect(find.byType(TablePane), findsNothing);
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(1));
    expect(await core.trail(), isNull);
  });

  testWidgets('on a phone, one pane is visible and Now is a bar', (tester) async {
    await _surface(tester, FakeCore(), size: const Size(400, 860));

    expect(tester.widget<PaneRow>(find.byType(PaneRow)).visible, 1);
    expect(find.byType(NowPane), findsNothing);
    expect(find.text('Small Two of Pieces ~Broken Pieces~'), findsOneWidget);
  });

  testWidgets('the body takes the playing release light from Now', (tester) async {
    final core = FakeCore();
    final now = await core.now().first;
    await _surface(tester, core);

    final light = tester.widget<LightScope>(find.byType(LightScope)).light;
    expect(light.accent, Color(now.light!.light));
    expect(light.wash, Color(now.light!.wash));
    expect(light.dim, Color(now.light!.dim));
    expect(light.track, now.trackId!.toInt());
    expect(light.release, now.releaseId!.toInt());
    final body = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((paint) => paint.painter).whereType<BodyPainter>().single;
    expect(body.light, light.accent);
    await core.transport(const TransportDto.pause());
    await tester.pump();
    expect(tester.widget<LightScope>(find.byType(LightScope)).light, light);
  });

  testWidgets('a null Now light leaves the body brass and keeps playing identities', (tester) async {
    final core = _ArtworkCore(NowDto(
      trackId: PlatformInt64Util.from(3),
      releaseId: PlatformInt64Util.from(1),
      title: 'Small Two of Pieces ~Broken Pieces~',
      subtitle: '',
      path: const [],
    ));
    await _surface(tester, core);

    final light = tester.widget<LightScope>(find.byType(LightScope)).light;
    expect(light.accent, Light.brass.accent);
    expect(light.wash, Light.brass.wash);
    expect(light.dim, Light.brass.dim);
    expect(light.track, 3);
    expect(light.release, 1);
    final body = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((paint) => paint.painter).whereType<BodyPainter>().single;
    expect(body.light, Tok.gold);
  });

  testWidgets('the release lights the playing row without inventing a cover', (tester) async {
    final core = FakeCore();
    final releaseId = (await core.now().first).releaseId!;
    await core.playRelease(id: releaseId, index: 2);
    final now = await core.now().first;
    await core.startTrail(TargetDto.release(id: now.releaseId!));
    await _surface(tester, core);
    await tester.pump();

    final row = find.byKey(const ValueKey('release-row-2'));
    final box = tester.widgetList<Container>(find.descendant(of: row, matching: find.byType(Container))).single;
    final decoration = box.decoration! as BoxDecoration;
    expect(decoration.color, Color(now.light!.wash));
    expect((decoration.border! as Border).left, BorderSide(color: Color(now.light!.light), width: 2));
    expect(tester.widget<Text>(find.descendant(of: row, matching: find.text(now.title))).style!.color, Color(now.light!.light));
    expect(find.descendant(of: find.byType(ReleasePane), matching: find.byType(Image)), findsNothing);
    expect(find.descendant(of: find.byType(NowPane), matching: find.byType(Image)), findsNothing);
    expect((await core.release(now.releaseId!)).cover, isNull);
  });

  testWidgets('release and Now draw their cover with a 256 pixel decode', (tester) async {
    final dir = Directory.systemTemp.createTempSync('meret-widget-cover-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/cover.png')..writeAsBytesSync(base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGO4P60IAAQ/AejzxrCDAAAAAElFTkSuQmCC',
    ));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    // Start disk I/O outside the test's fake clock, before Image.file shares it.
    await tester.runAsync(() => precacheImage(
      ResizeImage(FileImage(file), width: 256),
      tester.element(find.byType(SizedBox)),
    ));
    final core = _ArtworkCore(NowDto(
      trackId: PlatformInt64Util.from(3),
      releaseId: PlatformInt64Util.from(1),
      cover: file.path,
      title: 'Small Two of Pieces ~Broken Pieces~',
      subtitle: '',
      path: const [],
    ));
    await core.startTrail(TargetDto.release(id: core.state.releaseId!));
    await _surface(tester, core);
    await tester.pump();

    for (final pane in [find.byType(ReleasePane), find.byType(NowPane)]) {
      final image = tester.widget<Image>(find.descendant(of: pane, matching: find.byType(Image)));
      final resize = image.image as ResizeImage;
      expect(resize.width, 256);
      expect((resize.imageProvider as FileImage).file.path, file.path);
    }
    expect(tester.widget<Image>(find.descendant(of: find.byType(ReleasePane), matching: find.byType(Image))).width, 120);
    expect(find.descendant(of: find.byType(ReleasePane), matching: find.text('Xenogears Original Soundtrack')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Front shows the fake idiom doors and Scores opens its table', (tester) async {
    await _surface(tester, FakeCore());
    await _commandKey(tester, LogicalKeyboardKey.digit1);

    for (final label in ['Albums', 'Songs', 'Works', 'Sessions', 'Scores', 'Sets', 'Spoken']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('212 releases'), findsOneWidget);
    await tester.tap(find.text('Scores'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final table = tester.widget<TablePane>(find.byType(TablePane));
    expect(table.query, 'idiom:score');
    expect(find.text('idiom:score'), findsOneWidget);
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(2));
  });

  testWidgets('an empty library opens only the add-folder door and fills after adding', (tester) async {
    final core = FakeCore.empty();
    await _surface(tester, core);

    expect(find.text('Add a music folder'), findsOneWidget);
    expect(find.byType(TablePane), findsNothing);
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(1));
    expect((await core.rows('', _libraryView, 0, 20)).total, BigInt.zero);

    await core.addRoot('/New music');
    await tester.pump();
    await tester.pump();
    expect(find.text('Add a music folder'), findsNothing);
    expect(find.text('/New music'), findsOneWidget);
    expect(find.text('Scores'), findsOneWidget);
  });

  testWidgets('Enter opens the canonical search pane and roots its trail', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    await tester.enterText(find.byType(TextField), '  idiom:score  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.widget<TablePane>(find.byType(TablePane)).query, 'idiom:score');
    expect(tester.widget<SearchPane>(find.byType(SearchPane)).query, 'idiom:score');
    final trail = (await core.trail())!;
    expect(trail.stops.single.target, const TargetDto.search(query: 'idiom:score'));
    final painter = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((widget) => widget.painter).whereType<ConstellationPainter>().single;
    expect(painter.semanticsBuilder(const Size(1000, 64)).single.properties.label, 'idiom:score');
    expect(find.byKey(const ValueKey('query-hits')), findsNothing);
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(2));
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children.skip(1).cast<Pane>().map((pane) => pane.title), ['idiom:score']);
  });

  testWidgets('the dropdown groups hits, highlights with arrows and closes on Escape', (tester) async {
    final core = FakeCore();
    final hits = await core.search('o');
    await _surface(tester, core);
    await tester.enterText(find.byType(TextField), 'o');
    await tester.pump();
    final dropdown = find.byKey(const ValueKey('query-hits'));
    expect(dropdown, findsOneWidget);
    for (final (label, shown) in [
      ('People · ${hits.peopleTotal}', hits.people.isNotEmpty),
      ('Releases · ${hits.releasesTotal}', hits.releases.isNotEmpty),
      ('Tracks · ${hits.trackHitsTotal}', hits.trackHits.isNotEmpty),
      ('All ${hits.tracks} tracks ↵', true),
    ]) {
      expect(find.descendant(of: dropdown, matching: find.text(label)), shown ? findsOneWidget : findsNothing, reason: label);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(tester.widget<Semantics>(find.byKey(const ValueKey('query-hit-0'))).properties.selected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(tester.widget<Semantics>(find.byKey(const ValueKey('query-hit-1'))).properties.selected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(tester.widget<Semantics>(find.byKey(const ValueKey('query-hit-0'))).properties.selected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(dropdown, findsNothing);
    expect(find.byType(SearchPane), findsNothing);
  });

  testWidgets('commands, invalid input, an empty field and lost focus hide hits', (tester) async {
    await _surface(tester, FakeCore());
    for (final input in ['play o', 'colour:red', 'by:"unclosed', '']) {
      await tester.enterText(find.byType(TextField), 'o');
      await tester.pump();
      expect(find.byKey(const ValueKey('query-hits')), findsOneWidget);
      await tester.enterText(find.byType(TextField), input);
      await tester.pump();
      expect(find.byKey(const ValueKey('query-hits')), findsNothing);
    }
    await tester.enterText(find.byType(TextField), 'o');
    await tester.pump();
    tester.widget<QueryLine>(find.byType(QueryLine)).focus.unfocus();
    await tester.pump();
    expect(find.byKey(const ValueKey('query-hits')), findsNothing);
  });

  testWidgets('late search responses never replace the current dropdown', (tester) async {
    final core = _DelayedSearchCore();
    await _surface(tester, core);
    await tester.enterText(find.byType(TextField), 'o');
    await tester.enterText(find.byType(TextField), 'Iona');
    core.pending.last.$2.complete(await core.result('Iona'));
    await tester.pump();
    expect(find.text('People · 1'), findsOneWidget);
    core.pending.first.$2.complete(await core.result('o'));
    await tester.pump();
    expect(find.text('People · 1'), findsOneWidget);
    expect(find.text('Open Sky'), findsNothing);
  });

  testWidgets('the highlighted all-tracks line opens the search rather than a person', (tester) async {
    await _surface(tester, FakeCore());
    await tester.enterText(find.byType(TextField), 'Iona');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SearchPane), findsOneWidget);
    expect(tester.widget<TablePane>(find.byType(TablePane)).query, 'Iona');
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(2));
  });

  testWidgets('a highlighted person opens to the right of the rooted search', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    await tester.enterText(find.byType(TextField), 'Iona');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widgetList<TablePane>(find.byType(TablePane)).map((table) => table.query), ['Iona']);
    expect(find.byType(PersonPane), findsOneWidget);
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(3));
    final trail = (await core.trail())!;
    expect(trail.stops.first.target, const TargetDto.search(query: 'Iona'));
    expect(trail.stops.last.target, isA<TargetDto_Person>());
  });

  testWidgets('clicking a release hit opens the search then its release pane', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    await tester.enterText(find.byType(TextField), 'Open');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('query-hit-0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widgetList<TablePane>(find.byType(TablePane)).map((table) => table.query), ['Open']);
    final release = tester.widget<ReleasePane>(find.byType(ReleasePane));
    final trail = (await core.trail())!;
    expect(trail.stops.first.target, const TargetDto.search(query: 'Open'));
    expect(trail.stops.last.target, TargetDto.release(id: release.id));
    expect(trail.stops.last.title, 'Open Sky');
    expect(trail.stops.last.via, 'matched');
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(3));
  });

  testWidgets('a person in the search strip follows without starting another trail', (tester) async {
    final core = FakeCore();
    final hit = (await core.search('Iona')).people.single;
    await _surface(tester, core);
    await tester.enterText(find.byType(TextField), 'Iona');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final trail = await core.trail();
    await tester.tap(find.byKey(ValueKey('search-hit-person-${hit.id}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widgetList<TablePane>(find.byType(TablePane)).map((table) => table.query), ['Iona']);
    expect(find.byType(PersonPane), findsOneWidget);
    final followed = (await core.trail())!;
    expect(followed.rootQuery, trail!.rootQuery);
    expect(followed.stops.first.target, trail.stops.first.target);
    expect(followed.stops.last.target, TargetDto.person(id: hit.id));
  });

  testWidgets('Enter on a track hit plays its result index without changing the trail', (tester) async {
    final core = _RecordingCore();
    final hits = await core.search('Woman Of Wisdom');
    final hit = hits.trackHits.first;
    final trail = await core.trail();
    await _surface(tester, core);
    await tester.enterText(find.byType(TextField), 'Woman Of Wisdom');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(core.played, [(hit.query, hit.index!.toInt())]);
    expect(find.descendant(of: find.byType(NowPane), matching: find.text('Woman Of Wisdom')), findsOneWidget);
    expect(find.byKey(const ValueKey('query-hits')), findsNothing);
    expect(find.byType(SearchPane), findsNothing);
    expect(await core.trail(), trail);
  });

  test('fake search totals, paging and hit indices describe the same result', () async {
    final core = FakeCore();
    final hits = await core.search('wómán of wisdom');
    expect(hits.people, isEmpty);
    expect(hits.releases, isEmpty);
    expect(hits.trackHits, hasLength(8));
    final rows = await core.rows(hits.query, _libraryView, 0, 8);
    expect(rows.total, hits.tracks);
    expect((rows.items.first as ItemDto_Track).row.title, hits.trackHits.first.title);
    expect(hits.trackHits.first.index, BigInt.zero);
    expect(hits.trackHitsTotal, hits.tracks);
    expect((await core.search('ona')).tracks, BigInt.zero);
    expect((await core.search('by:mitsuda')).people.single.title, 'Yasunori Mitsuda');
    final empty = await FakeCore.empty().search('Iona');
    expect(empty.tracks, BigInt.zero);
    expect([...empty.people, ...empty.releases, ...empty.trackHits], isEmpty);
  });

  testWidgets('command errors stay in the query hint until the text changes', (tester) async {
    await _surface(tester, FakeCore());
    await tester.enterText(find.byType(TextField), 'queue idiom:score');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    final error = find.text("queue isn't built yet");
    expect(error, findsOneWidget);
    expect(tester.widget<Text>(error).style?.color, Tok.ox);
    expect(find.byType(TablePane), findsNothing);
    await tester.enterText(find.byType(TextField), 'play idiom:score');
    await tester.pump();
    expect(error, findsNothing);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('The Beginning and the End'), findsOneWidget);
    expect(find.byType(TablePane), findsNothing);
  });

  testWidgets('Command-L roots Everything and Command-1 leaves forward navigation on Front', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    await _commandKey(tester, LogicalKeyboardKey.keyL);
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(2));
    expect(tester.widget<TablePane>(find.byType(TablePane)).query, '');
    final trail = await core.trail();
    expect(trail!.stops.single.target, const TargetDto.search(query: ''));

    await _commandKey(tester, LogicalKeyboardKey.digit1);
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(1));
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(1));
    expect(await core.trail(), same(trail));

    await _commandKey(tester, LogicalKeyboardKey.keyL);
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(2));
  });

  testWidgets('the Front reloads on a library revision but not on an unchanged one', (tester) async {
    final core = _RecordingCore();
    Widget front(BigInt version) => MaterialApp(home: Scaffold(body: FrontPane(core: core, libraryVersion: version, onQuery: (_) {})));
    await tester.pumpWidget(front(BigInt.one));
    await tester.pumpAndSettle();
    await tester.pumpWidget(front(BigInt.one));
    await tester.pumpAndSettle();
    expect(core.frontCalls, 1);
    await tester.pumpWidget(front(BigInt.two));
    await tester.pumpAndSettle();
    expect(core.frontCalls, 2);
  });

  testWidgets('scan progress is visible on the empty Front', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: FrontPane(
      core: FakeCore.empty(),
      jobs: [JobDto(verb: 'reading tags', done: BigInt.from(5), total: BigInt.from(10))],
      onQuery: (_) {},
    ))));
    await tester.pumpAndSettle();
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.5);
    expect(find.text('Add a music folder'), findsOneWidget);
  });

  testWidgets('the playhead extrapolates while playing and holds when paused', (tester) async {
    late PlayheadClock clock;
    await tester.pumpWidget(_Host(onClock: (c) => clock = c));

    clock.anchor(AnchorDto(item: BigInt.one, positionMs: 1000, rate: 1));
    expect(clock.playing, isTrue);
    expect(clock.positionMs, closeTo(1000, 50));

    clock.anchor(AnchorDto(item: BigInt.one, positionMs: 5000, rate: 0));
    final held = clock.positionMs;
    await tester.pump(const Duration(milliseconds: 200));
    expect(clock.positionMs, held);
  });

  testWidgets('the table starts grouped and its headers cycle the view', (tester) async {
    final core = _RecordingCore();
    final group = (await FakeCore().rows('', _groupedView, 0, 1)).items.single as ItemDto_Group;
    await tester.pumpWidget(_table(core));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey('table-row-0')), matching: find.text(group.field0.title)), findsOneWidget);
    expect(find.byKey(const ValueKey('table-sort-album')), findsNothing);
    expect(core.views.single, _groupedView);

    await tester.tap(find.byKey(const ValueKey('table-sort-title')));
    await tester.pumpAndSettle();
    expect(core.views.last, const ViewDto(sort: SortKeyDto.title, descending: false, group: true));
    expect(find.text('Title ↑'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('table-sort-title')));
    await tester.pumpAndSettle();
    expect(core.views.last, const ViewDto(sort: SortKeyDto.title, descending: true, group: true));
    expect(find.text('Title ↓'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('table-sort-title')));
    await tester.pumpAndSettle();
    expect(core.views.last, _groupedView);
    expect(core.offsets, [0, 0, 0, 0]);

    await tester.tap(find.byKey(const ValueKey('table-group-false')));
    await tester.pumpAndSettle();
    expect(core.views.last, _libraryView);
    expect(find.byKey(const ValueKey('table-sort-album')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('table-sort-album')));
    await tester.pumpAndSettle();
    expect(core.views.last, const ViewDto(sort: SortKeyDto.album, descending: false, group: false));
    await tester.tap(find.byKey(const ValueKey('table-sort-library_')));
    await tester.pumpAndSettle();
    expect(core.views.last, _libraryView);
  });

  testWidgets('facet entries and All use the queries supplied by the core', (tester) async {
    final core = FakeCore();
    const query = 'idiom:score by:"Yasunori Mitsuda"';
    final facets = await core.facets(query);
    final selected = facets.people.entries.firstWhere((entry) => entry.selected);
    final queries = <String>[];
    await tester.pumpWidget(_table(core, query: query, onQuery: queries.add));
    await tester.pumpAndSettle();
    final entry = find.byKey(ValueKey('facet-People-${selected.id}'));
    expect(tester.widget<Semantics>(entry).properties.selected, isTrue);
    await tester.tap(entry);
    expect(queries.last, selected.query);
    await tester.tap(find.byKey(const ValueKey('facet-People-all')));
    expect(queries.last, facets.people.allQuery);
    final idiom = facets.idioms.entries.first;
    await tester.tap(find.byKey(ValueKey('facet-Idiom-${idiom.id}')));
    expect(queries.last, idiom.query);
  });

  testWidgets('Enter on a group uses its first track ordinal, not its item index', (tester) async {
    final core = _RecordingCore();
    final page = await FakeCore().rows('', _groupedView, 0, 1);
    final first = (page.items.single as ItemDto_Group).field0;
    final index = first.tracks + 1;
    await tester.pumpWidget(_table(core));
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(find.byKey(const ValueKey('table-rows')));
    list.controller!.jumpTo(index * 26);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('table-row-$index')));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(core.played, [('', first.tracks)]);
    expect(core.playedViews.single, _groupedView);
    final header = find.byKey(ValueKey('table-row-$index'));
    await tester.tap(header);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(core.played, [('', first.tracks), ('', first.tracks)]);
    expect(core.playedViews.last, _groupedView);
  });

  testWidgets('the playing track row uses the scoped light', (tester) async {
    final core = FakeCore();
    final page = await core.rows('', _groupedView, 1, 1);
    final row = (page.items.single as ItemDto_Track).row;
    final light = Light(accent: const Color(0xFF90AACC), wash: const Color(0x1490AACC), track: row.trackId.toInt());
    await tester.pumpWidget(_table(core, light: light));
    await tester.pumpAndSettle();
    final playing = find.byKey(const ValueKey('table-row-1'));
    final box = tester.widget<Container>(find.descendant(of: playing, matching: find.byType(Container)).first);
    expect((box.decoration as BoxDecoration).color, light.wash);
    expect(((box.decoration as BoxDecoration).border as Border).left.color, light.accent);
    final title = tester.widget<Text>(find.descendant(of: playing, matching: find.text(row.title)));
    expect(title.style!.color, light.accent);
  });

  testWidgets('the table fetches only pages near the viewport', (tester) async {
    final core = _RecordingCore();
    await tester.pumpWidget(_table(core));
    await tester.pumpAndSettle();

    expect(find.text('8 releases · 48210 tracks · sorted by library order'), findsOneWidget);
    expect(core.offsets, [0]);
    final list = tester.widget<ListView>(find.byKey(const ValueKey('table-rows')));
    list.controller!.jumpTo(30000 * 26);
    await tester.pumpAndSettle();

    expect(core.offsets.length, lessThanOrEqualTo(4));
    expect(core.offsets.skip(1).every((offset) => offset >= 29900 && offset <= 30100), isTrue);
    expect(core.offsets.toSet().length, core.offsets.length);
    expect(find.byKey(const ValueKey('table-row-30000')), findsOneWidget);
  });

  testWidgets('Enter plays the selected row and arrows move selection', (tester) async {
    final core = _RecordingCore();
    await tester.pumpWidget(_table(core));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('table-row-2')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(core.played, [('', 2)]);
  });

  testWidgets('a double-tap plays its table row', (tester) async {
    final core = _RecordingCore();
    await tester.pumpWidget(_table(core));
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('table-row-4'));
    await tester.tap(row);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(core.played, [('', 3)]);
  });

  testWidgets('the table refetches when query or library version changes', (tester) async {
    final core = _RecordingCore();
    await tester.pumpWidget(_table(core, libraryVersion: BigInt.one));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_table(core, query: 'year:1990..1999', libraryVersion: BigInt.one));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_table(core, query: 'year:1990..1999', libraryVersion: BigInt.two));
    await tester.pumpAndSettle();
    expect(core.offsets, [0, 0, 0]);
  });

  testWidgets('the table shows row errors without crashing', (tester) async {
    await tester.pumpWidget(_table(_InvalidCore()));
    await tester.pumpAndSettle();
    expect(find.text('Invalid query'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('album and artist cells open typed panes and their titles stay on the strip', (tester) async {
    final core = FakeCore();
    final row = await _firstTrack(core);
    await _surface(tester, core);
    await _commandKey(tester, LogicalKeyboardKey.keyL);
    await tester.tap(find.byKey(ValueKey('table-release-${row.releaseId}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_paneTitles(tester), ['Everything', row.album]);
    expect(tester.widget<ReleasePane>(find.byType(ReleasePane)).id, row.releaseId);

    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(ValueKey('table-group-artist-${row.releaseId}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_paneTitles(tester), ['Everything', row.artist]);
    expect(tester.widget<PersonPane>(find.byType(PersonPane)).id, row.artistId);
    final trail = (await core.trail())!;
    expect(trail.stops.map((stop) => stop.title), ['Everything', row.album, row.artist]);
    final labels = _trailPainter(tester).semanticsBuilder(const Size(1000, 64)).map((node) => node.properties.label);
    expect(labels, containsAll(['Everything', row.album, row.artist]));
  });

  testWidgets('following from an earlier pane branches and replaces its later panes', (tester) async {
    final core = FakeCore();
    final row = await _firstTrack(core);
    await _surface(tester, core);
    await _commandKey(tester, LogicalKeyboardKey.keyL);
    await tester.tap(find.byKey(ValueKey('table-release-${row.releaseId}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    final release = await core.release(row.releaseId);
    final credit = release.credits.first;
    await tester.tap(find.byKey(ValueKey('thread-${credit.kind.name}-${credit.to}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_paneTitles(tester), ['Everything', row.album, credit.title]);

    await tester.tap(find.byKey(ValueKey('table-group-artist-${row.releaseId}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_paneTitles(tester), ['Everything', row.artist]);
    expect(find.byType(ReleasePane), findsNothing);
    final trail = (await core.trail())!;
    expect(trail.stops.where((stop) => !stop.onPath), hasLength(2));
    expect(trail.stops.first.isFork, isTrue);
  });

  testWidgets('back and forward round trip, then back at the root shows only Front', (tester) async {
    final core = FakeCore();
    final row = await _firstTrack(core);
    await _surface(tester, core);
    await _commandKey(tester, LogicalKeyboardKey.keyL);
    await tester.tap(find.byKey(ValueKey('table-release-${row.releaseId}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_paneTitles(tester), ['Everything']);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_paneTitles(tester), ['Everything', row.album]);
    for (var i = 0; i < 2; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(1));
    expect(find.byType(FrontPane), findsOneWidget);
  });

  testWidgets('a release row and Enter play the release from that index', (tester) async {
    final core = _RecordingCore();
    final row = await _firstTrack(core);
    await core.startTrail(TargetDto.release(id: row.releaseId));
    await _surface(tester, core);
    await tester.pump();
    final credit = (await core.release(row.releaseId)).credits.first;
    await tester.widget<ReleasePane>(find.byType(ReleasePane)).onFollow(credit.to, credit.kind);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('release-row-2')));
    await tester.pump();
    expect(core.releasesPlayed, [(row.releaseId.toInt(), 2, 0)]);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(core.releasesPlayed, [(row.releaseId.toInt(), 2, 0), (row.releaseId.toInt(), 2, 0)]);
    await tester.tap(find.widgetWithText(TextButton, 'Play'));
    await tester.pump();
    expect(core.releasesPlayed.last, (row.releaseId.toInt(), 0, 0));
    expect((await core.trail())!.current, 1);
  });

  testWidgets('Command-Enter follows the selected table row and a strip star goes back', (tester) async {
    final core = FakeCore();
    final row = await _firstTrack(core);
    await _surface(tester, core);
    await _commandKey(tester, LogicalKeyboardKey.keyL);
    await tester.tapAt(tester.getTopLeft(find.byKey(const ValueKey('table-row-0'))) + const Offset(8, 13));
    await _commandKey(tester, LogicalKeyboardKey.enter);
    expect(_paneTitles(tester), ['Everything', row.album]);
    await tester.tap(find.byKey(const ValueKey('trail-stop-0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_paneTitles(tester), ['Everything']);
    expect((await core.trail())!.current, 0);
  });

  test('fake releases, people, recent doors and hits share row identities', () async {
    final core = FakeCore();
    final row = await _firstTrack(core, offset: 2);
    final release = await core.release(row.releaseId);
    final person = await core.person(row.artistId!);
    expect(release.title, row.album);
    expect(release.rows.every((track) => track.releaseId == release.id), isTrue);
    expect(person.name, row.artist);
    expect(person.appearsOn.single.to, TargetDto.release(id: row.releaseId));
    expect(person.workedWith, isNotEmpty);
    final hit = (await core.search(row.artist!)).people.single;
    expect(hit.id, row.artistId);
    for (final recent in (await core.front()).addedLately) {
      expect((await core.release(recent.releaseId)).title, recent.title);
    }
    await expectLater(FakeCore.empty().release(row.releaseId), throwsA(isA<String>()));
  });

}

Future<void> _surface(WidgetTester tester, CoreBridge core, {Size size = const Size(2560, 1440)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MeretApp(core: core));
  await tester.pump();
}

List<String> _paneTitles(WidgetTester tester) => tester.widget<PaneRow>(find.byType(PaneRow)).children.skip(1).cast<Pane>().map((pane) => pane.title).toList();

ConstellationPainter _trailPainter(WidgetTester tester) => tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((widget) => widget.painter).whereType<ConstellationPainter>().single;

Future<void> _commandKey(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<TrackRowDto> _firstTrack(CoreBridge core, {int offset = 0}) async =>
    ((await core.rows('', _libraryView, offset, 1)).items.single as ItemDto_Track).row;

Widget _table(CoreBridge core, {String query = '', BigInt? libraryVersion, ValueChanged<String>? onQuery, Light light = Light.brass}) => MaterialApp(
  home: Scaffold(body: LightScope(light: light, child: TablePane(core: core, query: query, libraryVersion: libraryVersion, onQuery: onQuery ?? (_) {}))),
);

class _RecordingCore extends FakeCore {
  final offsets = <int>[];
  final played = <(String, int)>[];
  final views = <ViewDto>[];
  final playedViews = <ViewDto>[];
  int frontCalls = 0;
  final releasesPlayed = <(int, int, int?)>[];

  @override
  Future<FrontDto> front() {
    frontCalls++;
    return super.front();
  }

  @override
  Future<RowsDto> rows(String query, ViewDto view, int offset, int limit) {
    offsets.add(offset);
    views.add(view);
    return super.rows(query, view, offset, limit);
  }

  @override
  Future<void> playResults(String query, ViewDto view, int index) {
    played.add((query, index));
    playedViews.add(view);
    return super.playResults(query, view, index);
  }
  @override
  Future<void> playRelease({required PlatformInt64 id, required int index, int? fromStop}) {
    releasesPlayed.add((id.toInt(), index, fromStop));
    return super.playRelease(id: id, index: index, fromStop: fromStop);
  }

}

class _InvalidCore extends FakeCore {
  @override
  Future<RowsDto> rows(String query, ViewDto view, int offset, int limit) async => throw 'Invalid query';
}

class _DelayedSearchCore extends FakeCore {
  final pending = <(String, Completer<SearchDto>)>[];

  @override
  Future<SearchDto> search(String input) {
    final completer = Completer<SearchDto>();
    pending.add((input, completer));
    return completer.future;
  }

  Future<SearchDto> result(String input) => super.search(input);
}

class _ArtworkCore extends FakeCore {
  _ArtworkCore(this.state);
  final NowDto state;

  @override
  Stream<NowDto> now() => Stream.value(state);

  @override
  Future<ReleaseDto> release(PlatformInt64 id) async {
    final release = await super.release(id);
    return ReleaseDto(
      id: release.id,
      title: release.title,
      cover: state.cover,
      artist: release.artist,
      year: release.year,
      idiom: release.idiom,
      tracks: release.tracks,
      discs: release.discs,
      lengthMs: release.lengthMs,
      formats: release.formats,
      rows: release.rows,
      credits: release.credits,
    );
  }
}

class _Host extends StatefulWidget {
  const _Host({required this.onClock});
  final ValueChanged<PlayheadClock> onClock;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SingleTickerProviderStateMixin {
  late final clock = PlayheadClock(this);

  @override
  void initState() {
    super.initState();
    widget.onClock(clock);
  }

  @override
  void dispose() {
    clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
