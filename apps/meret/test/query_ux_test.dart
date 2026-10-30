import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/core/query_filters.dart';
import 'package:meret/draw/histogram_header.dart';
import 'package:meret/panes/search_pane.dart';
import 'package:meret/panes/table_pane.dart';
import 'package:meret/shell/query_line.dart';
import 'package:meret/theme/tokens.dart';

class _DelayedSearchCore extends FakeCore {
  final pending = <(String, Completer<SearchDto>)>[];

  @override
  Future<SearchDto> search(String input) {
    final result = Completer<SearchDto>();
    pending.add((input, result));
    return result.future;
  }

  Future<SearchDto> result(String input) => super.search(input);
}

Future<void> _query(WidgetTester tester, CoreBridge core, FocusNode focus,
    {Future<void> Function(SearchDto, HitDto?)? onSearch, Future<void> Function(QueryDto)? onSubmit}) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(
    alignment: Alignment.topRight,
    child: SizedBox(width: 560, child: QueryLine(core: core, focus: focus, onSearch: onSearch, onSubmit: onSubmit)),
  ))));
}

void main() {
  testWidgets('planned commands disclose availability before Enter and retain backend errors and drafts', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final core = FakeCore();
    final submitted = <String>[];
    await _query(tester, core, focus, onSubmit: (query) async {
      submitted.add(query.canonical);
      await core.runCommand(query.canonical);
    });
    final field = find.byType(TextField);
    for (final input in ['queue idiom:score', 'want by:Iona', 'crate add "Evening"', 'crate new "Evening" idiom:score']) {
      final verb = input.split(' ').first;
      final before = submitted.length;
      await tester.enterText(field, input);
      await tester.pumpAndSettle();
      expect(find.text('Coming later'), findsOneWidget);
      expect(find.text('The $verb command is not available yet.'), findsOneWidget);
      expect(find.text('↵ to run'), findsNothing);
      expect(submitted.length, before);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(submitted.length, before + 1);
      expect(find.text("$verb isn't built yet"), findsOneWidget);
      expect(tester.widget<TextField>(field).controller!.text, input);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, input);
    }
    for (final input in ['queue', 'WANT', 'crate']) {
      await tester.enterText(field, input);
      await tester.pumpAndSettle();
      expect(find.text('Coming later'), findsOneWidget);
      expect(find.text('↵ to run'), findsNothing);
    }
  });

  testWidgets('play stays runnable while quoted verbs and slash-prefixed input stay searches', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final core = FakeCore();
    final submitted = <String>[];
    await _query(tester, core, focus, onSubmit: (query) async => submitted.add(query.canonical));
    for (final input in ['"queue"', '-want', 'crates', '/play by:Iona']) {
      await tester.enterText(find.byType(TextField), input);
      await tester.pumpAndSettle();
      expect(find.text('Coming later'), findsNothing);
      expect(find.textContaining('command is not available yet'), findsNothing);
    }
    await tester.enterText(find.byType(TextField), 'play by:Iona');
    await tester.pumpAndSettle();
    expect(find.text('↵ to run'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(submitted, ['play by:Iona']);
  });

  test('editing one field preserves quoted text, other fields and negation', () {
    const query = 'Iona "dr:12" by:"Iona Brown" -release:"Live recording" idiom:work dr:8..12 lufs:<-14 -dr:20';
    expect(replaceQueryField(query, 'dr', 'dr:10..16'),
      'Iona "dr:12" by:"Iona Brown" -release:"Live recording" idiom:work lufs:<-14 dr:10..16');
    expect(replaceQueryField(query, 'dr', null),
      'Iona "dr:12" by:"Iona Brown" -release:"Live recording" idiom:work lufs:<-14');
    expect(clearQueryFilters(query), 'Iona "dr:12"');
    expect(removeQueryClause(query, 3),
      'Iona "dr:12" by:"Iona Brown" idiom:work dr:8..12 lufs:<-14 -dr:20');
  });

  test('existing range controls retain exact values and paint representable constraints', () {
    expect(queryNumberBounds('year:1940..1970', 'year', 1950, 2026), (1940, 1970));
    expect(queryNumberRange('year:1940..1970', 'year', 1950, 2026), (0, 20 / 76));
    expect(queryNumberBounds('year:1990s', 'year', 1950, 2026), (1990, 1999));
    expect(queryNumberRange('lufs:-30..-12', 'lufs', -60, 0), (.5, .8));
    expect(queryNumberRange('-dr:12', 'dr', 0, 30), isNull);
    expect(queryNumberRange('dr:>8 dr:<16', 'dr', 0, 30), isNull);
    expect(queryRecentDays('last:2w'), 14);
    expect(queryRecentRange('last:2y'), (0, 1));
  });

  testWidgets('compact filters retain active clauses and field brushing changes only that field', (tester) async {
    var query = 'Iona by:"Iona" dr:8..18 lufs:-30..-10';
    final core = FakeCore();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(builder: (context, setState) => TablePane(
      core: core, query: query, onQuery: (value) => setState(() => query = value),
    )))));
    await tester.pumpAndSettle();
    expect(find.byType(HistogramHeader), findsNothing);
    expect(find.text('dr:8..18'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('table-filters-toggle')));
    await tester.pumpAndSettle();
    final dr = find.byKey(const ValueKey('table-dr-histogram'));
    tester.widget<HistogramHeader>(dr).onBrush!((.4, .6));
    await tester.pumpAndSettle();
    expect(query, 'Iona by:"Iona" lufs:-30..-10 dr:12..18');
    expect(tester.widget<HistogramHeader>(dr).selection, (.4, .6));
    tester.widget<HistogramHeader>(dr).onBrush!(null);
    await tester.pumpAndSettle();
    expect(query, 'Iona by:"Iona" lufs:-30..-10');
    expect(tester.widget<HistogramHeader>(dr).selection, isNull);
    await tester.tap(find.byKey(const ValueKey('table-filters-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('lufs:-30..-10'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove lufs:-30..-10'));
    await tester.pumpAndSettle();
    expect(query, 'Iona by:"Iona"');
    await tester.tap(find.byKey(const ValueKey('table-clear-filters')));
    await tester.pumpAndSettle();
    expect(query, 'Iona');
    expect(find.byKey(const ValueKey('table-clear-filters')), findsNothing);
  });

  testWidgets('histogram selection clears when the effective query clears its field', (tester) async {
    final bins = Uint32List.fromList([1, 1]);
    Future<void> show((double, double)? selection) => tester.pumpWidget(MaterialApp(home: Center(child: SizedBox(
      width: 200, child: HistogramHeader(label: 'DR', bins: bins, selection: selection),
    ))));
    await show((0, .5));
    final paint = tester.renderObject(find.descendant(of: find.byType(HistogramHeader), matching: find.byType(CustomPaint)));
    expect(paint, paints..rect(color: Tok.gold2)..rect(color: Tok.dim)..rect());
    await show(null);
    expect(paint, paints..rect(color: Tok.gold2)..rect(color: Tok.gold2));
  });

  testWidgets('range dialogs validate, apply negative decimals and clear just their field', (tester) async {
    var query = 'by:Iona lufs:-30..-10 dr:8..18';
    final core = FakeCore();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(builder: (context, setState) => TablePane(
      core: core, query: query, onQuery: (value) => setState(() => query = value),
    )))));
    await tester.pumpAndSettle();
    final trigger = find.byTooltip('Set LUFS filter');
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    final minimum = find.byKey(const ValueKey('filter-minimum'));
    final maximum = find.byKey(const ValueKey('filter-maximum'));
    expect(tester.widget<TextField>(minimum).controller!.text, '-30');
    await tester.enterText(minimum, '-10');
    await tester.enterText(maximum, '-20');
    await tester.tap(find.text('Apply'));
    await tester.pump();
    expect(find.text('The minimum must be less than or equal to the maximum.'), findsOneWidget);
    expect(query, 'by:Iona lufs:-30..-10 dr:8..18');
    await tester.enterText(minimum, '-24.5');
    await tester.enterText(maximum, '-14.2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(query, 'by:Iona dr:8..18 lufs:-24.5..-14.2');
    expect(core.parse(query).kind, QueryKind.search);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(query, 'by:Iona dr:8..18');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Last played exposes an editable number of days and preserves other clauses', (tester) async {
    var query = 'idiom:score last:2w';
    final core = FakeCore();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(builder: (context, setState) => TablePane(
      core: core, query: query, onQuery: (value) => setState(() => query = value),
    )))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Set last played filter'));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('filter-minimum'));
    expect(tester.widget<TextField>(input).controller!.text, '14');
    await tester.enterText(input, '0');
    await tester.tap(find.text('Apply'));
    await tester.pump();
    expect(find.text('Enter a whole number of days greater than zero.'), findsOneWidget);
    await tester.enterText(input, '45');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(query, 'idiom:score last:45d');
  });

  testWidgets('search context, hits and table use the effective query and ignore late results', (tester) async {
    final core = _DelayedSearchCore();
    final initial = await core.result('Iona');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SearchPane(
      core: core, query: 'Iona', search: initial, onHit: (_) {},
    ))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-hit-strip')), findsOneWidget);
    tester.widget<TablePane>(find.byType(TablePane)).onQuery('Iona dr:8..18');
    await tester.pumpAndSettle();
    expect(core.pending.last.$1, 'Iona dr:8..18');
    expect(find.text('Results for: Iona dr:8..18'), findsOneWidget);
    expect(find.byKey(const ValueKey('search-hit-strip')), findsNothing);
    expect(find.text('Updating matches…'), findsOneWidget);
    tester.widget<TablePane>(find.byType(TablePane)).onQuery('Iona dr:29..30');
    await tester.pumpAndSettle();
    core.pending.last.$2.complete(await core.result('Iona dr:29..30'));
    await tester.pumpAndSettle();
    expect(find.text('No matching tracks'), findsOneWidget);
    expect(find.text('Results for: Iona dr:29..30'), findsOneWidget);
    core.pending.first.$2.complete(await core.result('Iona dr:8..18'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-hit-strip')), findsNothing);
    expect(tester.widget<TablePane>(find.byType(TablePane)).query, 'Iona dr:29..30');
    await tester.tap(find.byKey(const ValueKey('search-reset-filters')));
    await tester.pumpAndSettle();
    expect(core.pending.last.$1, 'Iona');
    core.pending.last.$2.complete(initial);
    await tester.pumpAndSettle();
    expect(find.text('Results for: Iona'), findsOneWidget);
    expect(find.byKey(const ValueKey('search-hit-strip')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-reset-filters')), findsNothing);
  });

  testWidgets('zero matches offer recovery without an active zero-track result', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var submissions = 0;
    await _query(tester, FakeCore(), focus, onSearch: (_, _) async => submissions++);
    await tester.enterText(find.byType(TextField), 'no-such-recording-xyz');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('query-no-results')), findsOneWidget);
    expect(find.text('All 0 tracks ↵'), findsNothing);
    expect(find.text('↵ as a table'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(submissions, 0);
    await tester.tap(find.text('Clear search'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '');
    expect(focus.hasFocus, isTrue);
    expect(find.byKey(const ValueKey('query-hits')), findsNothing);
  });

  testWidgets('parse errors wrap in full and Escape preserves the draft until explicit clear', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final core = FakeCore();
    await _query(tester, core, focus);
    const input = 'year:invalid-year-that-does-not-parse';
    await tester.enterText(find.byType(TextField), input);
    await tester.pumpAndSettle();
    final error = find.text(core.parse(input).error!);
    expect(error, findsOneWidget);
    expect(tester.widget<Text>(error).maxLines, isNull);
    expect(tester.widget<Text>(error).overflow, isNot(TextOverflow.ellipsis));
    expect(find.text('For example, year:2017 or year:2000..2020.'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('query-error')), findsNothing);
    expect(focus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, input);
    await tester.tap(find.byKey(const ValueKey('query-clear')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '');
    expect(focus.hasFocus, isTrue);
    expect(find.byKey(const ValueKey('query-error')), findsNothing);
  });
}
