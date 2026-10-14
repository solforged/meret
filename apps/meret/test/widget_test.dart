import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/core/playhead.dart';
import 'package:meret/draw/constellation.dart';
import 'package:meret/main.dart';
import 'package:meret/now/now_pane.dart';
import 'package:meret/panes/front_pane.dart';
import 'package:meret/panes/pane.dart';
import 'package:meret/panes/search_pane.dart';
import 'package:meret/panes/table_pane.dart';
import 'package:meret/shell/pane_row.dart';
import 'package:meret/shell/query_line.dart';
import 'package:meret/theme/tokens.dart';

void main() {
  testWidgets('the fake trail opens after the Front without a table', (tester) async {
    await _surface(tester, FakeCore());

    expect(find.byType(FrontPane), findsOneWidget);
    expect(find.byType(TablePane), findsNothing);
    final panes = tester.widget<PaneRow>(find.byType(PaneRow));
    expect(panes.children, hasLength(6));
    expect(panes.children.skip(1).cast<Pane>().map((pane) => pane.kind), ['RECORDING', 'PERSON', 'RELEASE', 'PERSON', 'PERSON']);
    expect((panes.children.last as Pane).title, 'Iona');
  });

  testWidgets('on a phone, one pane is visible and Now is a bar', (tester) async {
    await _surface(tester, FakeCore(), size: const Size(400, 860));

    expect(tester.widget<PaneRow>(find.byType(PaneRow)).visible, 1);
    expect(find.byType(NowPane), findsNothing);
    expect(find.text('Small Two of Pieces ~Broken Pieces~'), findsOneWidget);
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
    expect((await core.rows('', 0, 20)).total, BigInt.zero);

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
    expect(tester.widget<SearchPane>(find.byType(SearchPane)).search.query, 'idiom:score');
    final trail = (await core.trail())!;
    expect(trail.stops.single.entity, 'search:idiom:score');
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

  testWidgets('a highlighted person opens its table to the right of the rooted search', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    await tester.enterText(find.byType(TextField), 'Iona');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widgetList<TablePane>(find.byType(TablePane)).map((table) => table.query), ['Iona', 'by:"Iona"']);
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(3));
    expect((await core.trail())!.stops.single.entity, 'search:Iona');
  });

  testWidgets('clicking a release hit opens the search then its release table', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    await tester.enterText(find.byType(TextField), 'Open');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('query-hit-0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widgetList<TablePane>(find.byType(TablePane)).map((table) => table.query), ['Open', 'release:"Open Sky"']);
    expect((await core.trail())!.stops.single.entity, 'search:Open');
  });

  testWidgets('a person in the search strip opens its table without starting another trail', (tester) async {
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
    expect(tester.widgetList<TablePane>(find.byType(TablePane)).map((table) => table.query), ['Iona', 'by:"Iona"']);
    expect(await core.trail(), same(trail));
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
    final rows = await core.rows(hits.query, 0, 8);
    expect(rows.total, hits.tracks);
    expect(rows.rows.first.title, hits.trackHits.first.title);
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

  testWidgets('Command-L opens a table and Command-1 keeps the forward panes', (tester) async {
    await _surface(tester, FakeCore());
    await _commandKey(tester, LogicalKeyboardKey.keyL);
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(7));
    expect(tester.widget<TablePane>(find.byType(TablePane)).query, '');

    await _commandKey(tester, LogicalKeyboardKey.digit1);
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(1));
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(7));
    expect(find.byType(TablePane), findsOneWidget);

    await _commandKey(tester, LogicalKeyboardKey.digit1);
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

  testWidgets('the table fetches only pages near the viewport', (tester) async {
    final core = _RecordingCore();
    await tester.pumpWidget(_table(core));
    await tester.pumpAndSettle();

    expect(find.text('48210 rows'), findsOneWidget);
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
    expect(core.played, [('', 3)]);
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
    expect(core.played, [('', 4)]);
  });

  testWidgets('the table refetches when query or library version changes', (tester) async {
    final core = _RecordingCore();
    await tester.pumpWidget(_table(core, libraryVersion: BigInt.one));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_table(core, query: 'year:1990s', libraryVersion: BigInt.one));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_table(core, query: 'year:1990s', libraryVersion: BigInt.two));
    await tester.pumpAndSettle();
    expect(core.offsets, [0, 0, 0]);
  });

  testWidgets('the table shows row errors without crashing', (tester) async {
    await tester.pumpWidget(_table(_InvalidCore()));
    await tester.pumpAndSettle();
    expect(find.text('Invalid query'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

}

Future<void> _surface(WidgetTester tester, CoreBridge core, {Size size = const Size(2560, 1440)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MeretApp(core: core));
  await tester.pump();
}

Future<void> _commandKey(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Widget _table(CoreBridge core, {String query = '', BigInt? libraryVersion}) => MaterialApp(
  home: Scaffold(body: TablePane(core: core, query: query, libraryVersion: libraryVersion, onQuery: (_) {})),
);

class _RecordingCore extends FakeCore {
  final offsets = <int>[];
  final played = <(String, int)>[];
  int frontCalls = 0;

  @override
  Future<FrontDto> front() {
    frontCalls++;
    return super.front();
  }

  @override
  Future<RowsDto> rows(String query, int offset, int limit) {
    offsets.add(offset);
    return super.rows(query, offset, limit);
  }

  @override
  Future<void> playResults(String query, int index) {
    played.add((query, index));
    return super.playResults(query, index);
  }
}

class _InvalidCore extends FakeCore {
  @override
  Future<RowsDto> rows(String query, int offset, int limit) async => throw 'Invalid query';
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
