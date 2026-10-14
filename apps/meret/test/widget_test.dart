import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/core/playhead.dart';
import 'package:meret/main.dart';
import 'package:meret/now/now_pane.dart';
import 'package:meret/panes/front_pane.dart';
import 'package:meret/panes/pane.dart';
import 'package:meret/panes/table_pane.dart';
import 'package:meret/shell/pane_row.dart';
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

  testWidgets('submitting a search replaces the trail with its canonical table', (tester) async {
    await _surface(tester, FakeCore());
    await tester.enterText(find.byType(TextField), '  idiom:score  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.widget<TablePane>(find.byType(TablePane)).query, 'idiom:score');
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(2));
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children.skip(1).cast<Pane>().map((pane) => pane.title), ['idiom:score']);
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
