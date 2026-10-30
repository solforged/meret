import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/draw/histogram_header.dart';
import 'package:meret/main.dart';
import 'package:meret/panes/pane.dart';
import 'package:meret/panes/table_pane.dart';
import 'package:meret/shell/query_line.dart';

Future<void> _surface(WidgetTester tester, FakeCore core) async {
  tester.view.physicalSize = const Size(1728, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await core.transport(const TransportDto.pause());
  await tester.pumpWidget(MeretApp(core: core));
  await tester.pumpAndSettle();
}

Future<void> _showTrail(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
  await tester.pumpAndSettle();
}

Future<void> _query(WidgetTester tester, CoreBridge core, FocusNode focus, {double width = 560, ValueNotifier<int>? clearOn,
    Future<void> Function(QueryDto)? onSubmit}) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(
    alignment: Alignment.topRight,
    child: SizedBox(width: width, child: QueryLine(core: core, focus: focus, onSubmit: onSubmit, clearOn: clearOn)),
  ))));
}

void main() {
  testWidgets('06 removing a filter chip rewrites the trail search: heading, trail and a return to the stop', (tester) async {
    final core = FakeCore();
    await core.startTrail(const TargetDto.search(query: 'Iona'));
    await _surface(tester, core);
    await _showTrail(tester);
    tester.widget<TablePane>(find.byType(TablePane)).onQuery('Iona dr:8..18');
    await tester.pumpAndSettle();
    var trail = (await core.trail())!;
    expect(trail.rootQuery, 'Iona dr:8..18');
    expect(trail.stops.first.title, 'Iona dr:8..18');
    expect(tester.widget<Pane>(find.byType(Pane)).title, 'Iona dr:8..18');
    expect(find.text('Results for: Iona dr:8..18'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove dr:8..18'));
    await tester.pumpAndSettle();
    trail = (await core.trail())!;
    expect(trail.rootQuery, 'Iona');
    expect(tester.widget<Pane>(find.byType(Pane)).title, 'Iona', reason: 'the heading follows the chip');
    expect(find.text('Results for: Iona'), findsOneWidget);

    // Q3: the stop keeps its filters when the app comes back to it.
    tester.widget<TablePane>(find.byType(TablePane)).onQuery('Iona year:1990s');
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MeretApp(core: core));
    await _showTrail(tester);
    expect(find.text('Results for: Iona year:1990s'), findsOneWidget);
  });

  testWidgets('S9 leaving a search for Library Table or Today empties the query line', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    Future<void> search() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Iona');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Iona');
    }

    Future<void> chord(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
    }

    await search();
    await chord(LogicalKeyboardKey.keyL);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '');

    await search();
    await chord(LogicalKeyboardKey.digit1);
    await chord(LogicalKeyboardKey.digit1);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '');
  });

  testWidgets('Q4 the suggestions popup starts at the line\'s left edge at any width', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    for (final width in [260.0, 420.0, 640.0]) {
      await _query(tester, FakeCore(), focus, width: width);
      focus.requestFocus();
      await tester.enterText(find.byType(TextField), 'Iona');
      await tester.pumpAndSettle();
      final line = tester.getRect(find.byType(QueryLine));
      final popup = tester.getRect(find.byKey(const ValueKey('query-hits')));
      expect(popup.left, line.left, reason: 'width $width');
      expect(popup.width, greaterThanOrEqualTo(line.width), reason: 'width $width');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('Q6 help with no matches lists the commands', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await _query(tester, FakeCore(), focus);
    await tester.enterText(find.byType(TextField), 'help');
    await tester.pumpAndSettle();
    expect(find.text('Commands'), findsWidgets);
    expect(find.text('play <query>'), findsOneWidget);
    expect(find.text('Try fewer words or remove a filter.'), findsNothing);
  });

  testWidgets('Q7 play with no matches says so and keeps the draft in the line', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final core = FakeCore();
    await _query(tester, core, focus, onSubmit: (query) => core.runCommand(query.canonical));
    await tester.enterText(find.byType(TextField), 'play zzzzqqq');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('No tracks match'), findsOneWidget);
    expect(focus.hasFocus, isTrue);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'play zzzzqqq');
  });

  testWidgets('F4 a search on an empty library offers a folder, not fewer words', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await _query(tester, FakeCore.empty(), focus);
    await tester.enterText(find.byType(TextField), 'blue');
    await tester.pumpAndSettle();
    expect(find.text('Library is empty'), findsWidgets);
    expect(find.byKey(const ValueKey('query-add-folder')), findsOneWidget);
    expect(find.text('Try fewer words or remove a filter.'), findsNothing);
  });

  testWidgets('Q1 a histogram shows the applied range and its text opens the dialog', (tester) async {
    final core = FakeCore();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TablePane(core: core, query: 'dr:11..13', onQuery: (_) {}))));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Set DR filter'), findsOneWidget);
    expect(find.text('0–30'), findsNothing);
    await tester.tap(find.text('11–13'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-range-dialog')), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('filter-minimum'))).controller!.text, '11');
  });

  testWidgets('Q2 an invalid Apply leaves the cursor in a field', (tester) async {
    final core = FakeCore();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TablePane(core: core, query: 'dr:11..13', onQuery: (_) {}))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Set DR filter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('filter-minimum')), '20');
    await tester.enterText(find.byKey(const ValueKey('filter-maximum')), '10');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('The minimum must be less than or equal to the maximum.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('filter-minimum'))).focusNode!.hasFocus, isTrue);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('filter-minimum'))).focusNode!.hasFocus, isTrue);
  });

  testWidgets('a narrow histogram keeps its range under its label', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Center(child: SizedBox(
      width: 120, child: HistogramHeader(label: 'Last played', range: '1 year ago–now', bins: Uint32List.fromList([1, 2]), onSetRange: () {}),
    ))));
    expect(find.text('LAST PLAYED'), findsOneWidget);
    expect(find.text('1 year ago–now'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
