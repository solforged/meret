import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64Util;
import 'package:meret/core/bridge.dart';
import 'package:meret/main.dart';
import 'package:meret/panes/pane.dart';
import 'package:meret/panes/release_pane.dart';
import 'package:meret/shell/keep_dialog.dart';
import 'package:meret/shell/query_line.dart';
import 'package:meret/theme/action_target.dart';
import 'package:meret/theme/tokens.dart';

void main() {
  testWidgets('custom controls expose actions, skip disabled controls, and show keyboard focus', (tester) async {
    final semantics = tester.ensureSemantics();
    var first = 0;
    var second = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      ActionTarget(key: const ValueKey('first'), semanticLabel: 'Open library', selected: true,
        excludeChildSemantics: true, onTap: () => first++, child: const Text('▦')),
      const ActionTarget(semanticLabel: 'Unavailable', child: Text('Disabled')),
      PaneActionButton(key: const ValueKey('second'), label: 'Play release', onTap: () => second++),
    ]))));

    await _tab(tester);
    expect(_focused(find.byKey(const ValueKey('first'))), isTrue);
    final node = tester.getSemantics(find.byKey(const ValueKey('first')));
    expect(node.label, 'Open library');
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.flagsCollection.isSelected, ui.Tristate.isTrue);
    expect(node.flagsCollection.isFocused, ui.Tristate.isTrue);
    expect(node.getSemanticsData().hasAction(ui.SemanticsAction.tap), isTrue);
    final ring = tester.widget<DecoratedBox>(find.descendant(
      of: find.byKey(const ValueKey('first')), matching: find.byType(DecoratedBox)).first);
    expect((ring.decoration as BoxDecoration).border, Border.all(color: Tok.gold, width: 2));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(first, 1);

    await _tab(tester);
    expect(_focused(find.byKey(const ValueKey('second'))), isTrue, reason: 'disabled controls do not take a Tab stop');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(second, 1);
    await _tab(tester, reverse: true);
    expect(_focused(find.byKey(const ValueKey('first'))), isTrue);
    semantics.dispose();
  });

  testWidgets('surface traversal reaches Home, query, and transport; Space activates the focused button', (tester) async {
    final core = _Core();
    await _surface(tester, core);
    await _tabTo(tester, find.byKey(const ValueKey('home-all')));
    final homeFocus = FocusManager.instance.primaryFocus;
    await _tab(tester);
    expect(FocusManager.instance.primaryFocus, isNot(same(homeFocus)));
    await _tab(tester, reverse: true);
    expect(FocusManager.instance.primaryFocus, same(homeFocus));

    await _tabTo(tester, find.byType(QueryLine));
    expect(tester.widget<QueryLine>(find.byType(QueryLine)).focus.hasFocus, isTrue);
    await _tabTo(tester, find.byKey(const ValueKey('lcd-next')));
    core.transports.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(core.transports, [const TransportDto.next()], reason: 'Space must not play or pause behind a focused button');

    final opener = FocusManager.instance.primaryFocus;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.pumpAndSettle();
    for (var i = 0; i < 8; i++) {
      await _tab(tester);
      expect(_focused(find.byKey(const ValueKey('history-sheet'))), isTrue, reason: 'dialog traversal stays inside the sheet');
    }
    await _tabTo(tester, find.widgetWithIcon(IconButton, Icons.close));
    core.transports.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('history-sheet')), findsNothing);
    expect(core.transports, isEmpty, reason: 'Space on Close must not toggle playback');
    expect(FocusManager.instance.primaryFocus, same(opener));
  });

  testWidgets('Home and tree return focus to the visible pane control that opened them', (tester) async {
    final core = _Core();
    final trail = await core.startTrail(const TargetDto.search(query: ''));
    await core.follow(trail.current, TargetDto.release(id: PlatformInt64Util.from(1)), ThreadKind.matched, 'library');
    await _surface(tester, core);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await tester.pumpAndSettle();
    final play = find.descendant(of: find.byType(ReleasePane), matching: find.byType(PaneActionButton)).first;
    await _tabTo(tester, play);
    final original = FocusManager.instance.primaryFocus;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(original!.canRequestFocus, isFalse, reason: 'covered panes are excluded from focus');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(original));

    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.pumpAndSettle();
    expect(original.canRequestFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(original));
  });

  testWidgets('Keep dialog Enter respects Cancel and returns focus to its opener', (tester) async {
    final opener = FocusNode();
    addTearDown(opener.dispose);
    var completed = false;
    ({String? name})? result;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => ActionTarget(
      focusNode: opener,
      semanticLabel: 'Keep trail',
      onTap: () async {
        result = await askTrailName(context, suggested: 'Evening');
        completed = true;
      },
      child: const Text('Keep trail'),
    )))));
    opener.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_focused(find.byKey(const ValueKey('trail-name'))), isTrue);
    await _tab(tester);
    expect(_focused(find.widgetWithText(TextButton, 'Cancel')), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNull, reason: 'Enter on Cancel must not keep the trail');
    expect(opener.hasFocus, isTrue);
  });

  testWidgets('transport icons expose distinct accessible button names', (tester) async {
    final semantics = tester.ensureSemantics();
    await _surface(tester, _Core());
    for (final (id, label) in [('previous', 'Previous'), ('toggle', 'Play'), ('next', 'Next')]) {
      final node = tester.getSemantics(find.descendant(
        of: find.byKey(ValueKey('lcd-$id')), matching: find.bySemanticsLabel(label)).first);
      expect(node.label, label);
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.getSemanticsData().hasAction(ui.SemanticsAction.tap), isTrue);
    }
    expect(find.bySemanticsLabel(RegExp('Hide Now|Show Now')), findsWidgets);
    semantics.dispose();
  });
}

bool _focused(Finder finder) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  final targets = finder.evaluate().toSet();
  var found = targets.contains(context);
  context.visitAncestorElements((element) {
    found = found || targets.contains(element);
    return !found;
  });
  return found;
}

Future<void> _tab(WidgetTester tester, {bool reverse = false}) async {
  if (reverse) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  if (reverse) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pumpAndSettle();
}

Future<void> _tabTo(WidgetTester tester, Finder finder) async {
  expect(finder, findsWidgets);
  for (var i = 0; i < 80 && !_focused(finder); i++) {
    await _tab(tester);
  }
  expect(_focused(finder), isTrue, reason: 'Tab must reach $finder');
}

Future<void> _surface(WidgetTester tester, FakeCore core) async {
  tester.view.physicalSize = const Size(1728, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await core.transport(const TransportDto.pause());
  await tester.pumpWidget(MeretApp(core: core));
  await tester.pumpAndSettle();
}

class _Core extends FakeCore {
  final transports = <TransportDto>[];

  @override
  Future<void> transport(TransportDto command) {
    transports.add(command);
    return super.transport(command);
  }
}
