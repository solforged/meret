import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64Util;
import 'package:meret/core/bridge.dart';
import 'package:meret/draw/constellation.dart';
import 'package:meret/main.dart';
import 'package:meret/now/now_pane.dart';
import 'package:meret/now/history_sheet.dart';
import 'package:meret/now/now_stage.dart';
import 'package:meret/panes/pane.dart';
import 'package:meret/panes/release_pane.dart';
import 'package:meret/panes/table_pane.dart';
import 'package:meret/panes/tree_pane.dart';
import 'package:meret/shell/pane_row.dart';
import 'package:meret/shell/query_line.dart';
import 'package:meret/theme/tokens.dart';

void main() {
  testWidgets('ANIM-A1 a trail step slides for kMotion, easing out', (tester) async {
    final core = FakeCore();
    await _seedTrail(core, stops: 3);
    await _surface(tester, core);
    await _showTrail(tester);
    expect(kMotion, const Duration(milliseconds: 200));
    await _key(tester, LogicalKeyboardKey.bracketLeft);
    final slide = tester.widget<PaneRow>(find.byType(PaneRow)).slide;
    expect(slide.value, -1);
    final width = tester.getSize(_paneOf<ReleasePane>()).width;
    final start = tester.getTopLeft(_paneOf<ReleasePane>()).dx;
    await tester.pump(const Duration(milliseconds: 100));
    expect(slide.value, closeTo(-0.125, 0.005), reason: 'easeOutCubic halfway through 200 ms');
    expect(tester.getTopLeft(_paneOf<ReleasePane>()).dx, closeTo(start + 0.875 * width, 0.5));
    await tester.pump(const Duration(milliseconds: 30));
    expect(slide.value, lessThan(-0.03), reason: 'still moving at 130 ms, where the halved slide used to end');
    await tester.pump(const Duration(milliseconds: 70));
    expect(slide.value, 0);
    expect(tester.getTopLeft(_paneOf<ReleasePane>()).dx, closeTo(start + width, 0.5));
  });

  testWidgets('ANIM-A3 a search from the Now stage fades the stage through and does not slide', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Iona');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    final slide = tester.widget<PaneRow>(find.byType(PaneRow)).slide;
    expect(slide.value, 0, reason: 'leaving the stage is a page change');
    for (final ms in [0, 50, 100, 150, 200]) {
      if (ms > 0) await tester.pump(const Duration(milliseconds: 50));
      final stage = find.byKey(const ValueKey('stage-now'));
      final outgoing = stage.evaluate().isEmpty ? 0.0 : _fadeOver(tester, stage);
      final incoming = _fadeOver(tester, find.byKey(const ValueKey('stage-trail')));
      expect(outgoing > 0.5 && incoming > 0.5, isFalse, reason: 'two pages visible at $ms ms');
      expect(slide.value, 0);
    }
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(const ValueKey('stage-now')), findsNothing);
    expect(find.byType(TablePane), findsOneWidget);
  });

  testWidgets('ANIM-A6 [ at the root, ], command 1, T and Escape all fade the page through, never slide', (tester) async {
    final core = FakeCore();
    await _seedTrail(core, stops: 2);
    await _surface(tester, core);
    await _showTrail(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pumpAndSettle();
    expect((await core.trail())!.current, 0);
    final slide = tester.widget<PaneRow>(find.byType(PaneRow)).slide;
    final table = tester.state(find.byType(TablePane));

    Future<void> fadesIn(LogicalKeyboardKey key, String page, {bool meta = false}) async {
      await _key(tester, key, meta: meta);
      expect(_rowCovered(tester), isTrue);
      expect(slide.value, 0);
      expect(_fadeOver(tester, find.byKey(ValueKey(page))), 0, reason: '$page at 0 ms');
      await tester.pump(const Duration(milliseconds: 100));
      expect(_fadeOver(tester, find.byKey(ValueKey(page))), 0, reason: '$page waits for the first half');
      await tester.pump(const Duration(milliseconds: 50));
      expect(_fadeOver(tester, find.byKey(ValueKey(page))), closeTo(0.5, 0.01));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_fadeOver(tester, find.byKey(ValueKey(page))), 1);
      expect(slide.value, 0);
    }

    Future<void> fadesOut(LogicalKeyboardKey key, String page, {bool meta = false}) async {
      await _key(tester, key, meta: meta);
      expect(_rowCovered(tester), isFalse);
      expect(_fadeOver(tester, find.byKey(ValueKey(page))), 1);
      await tester.pump(const Duration(milliseconds: 50));
      expect(_fadeOver(tester, find.byKey(ValueKey(page))), closeTo(0.5, 0.01));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_fadeOver(tester, find.byKey(ValueKey(page))), 0, reason: '$page is gone by 100 ms');
      await tester.pump(const Duration(milliseconds: 100));
      expect(_fadeOver(tester, find.byKey(ValueKey(page))), 0);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byKey(ValueKey(page)), findsNothing, reason: '$page is unmounted once its fade ends');
      expect(slide.value, 0, reason: 'the row was there all along');
      expect(tester.state(find.byType(TablePane)), same(table));
    }

    await fadesIn(LogicalKeyboardKey.bracketLeft, 'front-over-trail');
    expect(find.text('Front · ⌘1 or ] back to Everything'), findsOneWidget);
    expect(find.byType(TrailStrip), findsOneWidget);
    await fadesOut(LogicalKeyboardKey.bracketRight, 'front-over-trail');
    await fadesIn(LogicalKeyboardKey.digit1, 'front-over-trail', meta: true);
    await fadesOut(LogicalKeyboardKey.digit1, 'front-over-trail', meta: true);
    await fadesIn(LogicalKeyboardKey.keyT, 'tree');
    expect(find.byType(TreePane), findsOneWidget);
    await fadesOut(LogicalKeyboardKey.escape, 'tree');
    expect((await core.trail())!.current, 0, reason: 'none of this moved along the trail');
  });

  testWidgets('NAV-N2 a stop that leaves the path keeps its pane, data and scroll for [ then ]', (tester) async {
    final core = FakeCore();
    await _seedTrail(core, stops: 2);
    await _surface(tester, core, height: 600);
    await _showTrail(tester);
    final scrollable = find.descendant(of: find.byType(ReleasePane), matching: find.byType(Scrollable));
    final state = tester.state<ScrollableState>(scrollable);
    expect(state.position.maxScrollExtent, greaterThan(80));
    state.position.jumpTo(state.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final offset = state.position.pixels;
    final width = tester.getSize(_paneOf<ReleasePane>()).width;
    await tester.tap(find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('release-row-')).last);
    await core.transport(const TransportDto.pause());
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('surface'), reason: 'the tracklist took the focus');

    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'surface', reason: 'a parked pane cannot keep the keys');
    expect((await core.trail())!.current, 0);
    expect(find.byType(ReleasePane), findsNothing);
    final parked = find.byType(ReleasePane, skipOffstage: false);
    expect(parked, findsOneWidget, reason: 'parked, not disposed');
    expect(tester.state(find.descendant(of: parked, matching: find.byType(Scrollable, skipOffstage: false), skipOffstage: false)), same(state));
    expect(tester.getSize(_paneOf<ReleasePane>(offstage: true)).width, width, reason: 'parked at its last width, so the offset is not clamped');

    await _key(tester, LogicalKeyboardKey.bracketRight);
    expect(find.text('Reading release…'), findsNothing, reason: 'the pane comes back loaded on the first frame');
    expect(tester.state<ScrollableState>(scrollable), same(state));
    expect(state.position.pixels, offset);
    await tester.pumpAndSettle();
    expect(tester.state<ScrollableState>(scrollable), same(state));
    expect(state.position.pixels, offset);
    expect(find.byType(ReleasePane, skipOffstage: false), findsOneWidget);
  });

  testWidgets('NAV-N2 command 1 and ] return the same pane with its scroll', (tester) async {
    final core = FakeCore();
    await _seedTrail(core, stops: 2);
    await _surface(tester, core, height: 600);
    await _showTrail(tester);
    final scrollable = find.descendant(of: find.byType(ReleasePane), matching: find.byType(Scrollable));
    final state = tester.state<ScrollableState>(scrollable);
    state.position.jumpTo(80);
    await tester.pumpAndSettle();
    await _key(tester, LogicalKeyboardKey.digit1, meta: true);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('front-over-trail')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('front-over-trail')), findsNothing);
    expect(tester.state<ScrollableState>(scrollable), same(state));
    expect(state.position.pixels, 80);
    expect(find.text('Reading release…'), findsNothing);
  });

  testWidgets('NAV-N2 the parked set keeps the last six stops and empties for another trail', (tester) async {
    final core = FakeCore();
    var trail = await core.startTrail(const TargetDto.search(query: ''));
    for (var i = 1; i <= 8; i++) {
      trail = await core.follow(trail.current, TargetDto.release(id: PlatformInt64Util.from(i)), ThreadKind.appearsOn, 'local_tags');
    }
    await _surface(tester, core);
    await _showTrail(tester);
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await tester.pumpAndSettle();
    }
    expect((await core.trail())!.current, 0);
    expect(find.byType(ReleasePane, skipOffstage: false), findsNWidgets(6));
    await _key(tester, LogicalKeyboardKey.keyL, meta: true);
    await tester.pumpAndSettle();
    expect(find.byType(ReleasePane, skipOffstage: false), findsNothing, reason: 'a new trail parks nothing from the old one');
  });

  testWidgets('WIDTH-W4 the status line never overflows at 600 wide with a trail open', (tester) async {
    final core = FakeCore();
    await _seedTrail(core, stops: 3);
    await _surface(tester, core, width: 600, height: 900);
    await _showTrail(tester);
    await core.transport(const TransportDto.resume());
    await tester.pump();
    await tester.pump();
    expect(_hints(tester), contains('␣ pause'));
    expect(tester.takeException(), isNull);
    final hints = tester.widget<Text>(find.byKey(const ValueKey('status-keys')));
    expect(hints.maxLines, 1);
    expect(hints.overflow, TextOverflow.ellipsis);
    expect(find.ancestor(of: find.byKey(const ValueKey('status-keys')), matching: find.byType(Expanded)), findsWidgets);
    tester.view.physicalSize = const Size(640, 900);
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('KEYS-K3 command 1 and command L hints show from the laptop class', (tester) async {
    final core = FakeCore();
    await _surface(tester, core, width: 999);
    expect(find.textContaining('⌘1 Front'), findsNothing);
    tester.view.physicalSize = const Size(1000, 900);
    await tester.pumpAndSettle();
    expect(find.textContaining('⌘1 Front'), findsOneWidget);
    expect(find.textContaining('⌘L table'), findsOneWidget);
  });

  testWidgets('KEYS-K5 the Space hint says pause while playing', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    expect(_hints(tester), contains('  ␣ play  '));
    expect(_hints(tester), isNot(contains('  ␣ pause  ')));
    await core.transport(const TransportDto.resume());
    await tester.pump();
    await tester.pump();
    expect(_hints(tester), contains('  ␣ pause  '));
    expect(_hints(tester), isNot(contains('  ␣ play  ')));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.pump();
    expect(_hints(tester), contains('  ␣ play  '));
    expect(_hints(tester), isNot(contains('  ␣ pause  ')));
  });

  testWidgets('KEYS-K6 the query hint promises Enter only while focused', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    final field = find.byType(TextField);
    final focus = tester.widget<QueryLine>(find.byType(QueryLine)).focus;
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    await tester.enterText(field, 'xen');
    await tester.pump();
    expect(find.text('↵ as a table'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isFalse);
    expect(tester.widget<TextField>(field).controller!.text, 'xen', reason: 'a search keeps its words on the line');
    expect(find.text('↵ as a table'), findsNothing);
    expect(find.text('Search or type a command'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    expect(find.text('↵ as a table'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    if (focus.hasFocus) {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
    }
    expect(focus.hasFocus, isFalse);
    expect(tester.widget<TextField>(field).controller!.text, '');
    expect(find.text('Search or type a command'), findsOneWidget);
  });

  testWidgets('KEYS-K8 Tab and Shift-Tab move focus nowhere on the surface', (tester) async {
    final core = _TransportCore();
    await _seedTrail(core, stops: 2);
    await _surface(tester, core);
    await _key(tester, LogicalKeyboardKey.digit1, meta: true);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'surface');
    for (final page in ['front-over-trail', 'panes']) {
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'surface', reason: 'Tab $i over $page');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'surface', reason: 'Shift-Tab $i over $page');
      }
      await _key(tester, LogicalKeyboardKey.bracketRight);
      await tester.pumpAndSettle();
    }
    expect(core.backs, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pump();
    expect(core.backs, 1, reason: 'the keys still land after tabbing');
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    expect(tester.widget<QueryLine>(find.byType(QueryLine)).focus.hasFocus, isTrue);
  });

  testWidgets('KEYS-K4 a sheet opened while the query has focus keeps it; Space is dead behind it and Escape closes it', (tester) async {
    final core = _TransportCore();
    await _surface(tester, core, width: 1100);
    await _key(tester, LogicalKeyboardKey.digit1, meta: true);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    final focus = tester.widget<QueryLine>(find.byType(QueryLine)).focus;
    expect(focus.hasFocus, isTrue);
    final sheet = showHistorySheet(tester.element(find.byType(QueryLine)), core, (_) async {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('history-sheet')), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('surface'));
    core.transports.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(core.transports, isEmpty, reason: 'nothing toggles behind the sheet');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('history-sheet')), findsNothing);
    await sheet;
    await tester.pump();
    expect(focus.hasFocus, isTrue, reason: 'focus returns where it was, to the query line');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pump();
    expect(core.backs, 1, reason: 'the surface has its keys back once the sheet is gone');
  });

  testWidgets('LAUNCH-L4 before the first Now the strip and the bar draw nothing', (tester) async {
    final core = _LateNowCore();
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MeretApp(core: core));
    await tester.pump();
    expect(find.byType(NowBar), findsNothing);
    expect(find.byType(NoTrailStrip), findsNothing);
    expect(find.byType(TrailStrip), findsNothing);
    expect(find.text('no trail yet'), findsNothing);
    expect(find.byType(NowStage), findsNothing);
    core.gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byType(NowStage), findsOneWidget);
    expect(find.byType(NowBar), findsNothing);
  });
}

Future<void> _seedTrail(FakeCore core, {required int stops}) async {
  var trail = await core.startTrail(const TargetDto.search(query: ''));
  final release = await core.release(PlatformInt64Util.from(1));
  trail = await core.follow(trail.current, TargetDto.release(id: release.id), ThreadKind.matched, 'library');
  if (stops >= 3) {
    await core.follow(trail.current, release.artistLinks.first.to, ThreadKind.albumArtist, release.artistLinks.first.provider);
  }
}

/// Paused, so `pumpAndSettle` is not kept awake by the playhead clock.
Future<void> _surface(WidgetTester tester, FakeCore core, {double width = 1728, double height = 900}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await core.transport(const TransportDto.pause());
  await tester.pumpWidget(MeretApp(core: core));
  await tester.pumpAndSettle();
}

Future<void> _showTrail(WidgetTester tester) async {
  tester.widget<NowStage>(find.byType(NowStage)).onLeave();
  await tester.pumpAndSettle();
  await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
  await tester.pumpAndSettle();
}

/// A key press and the frame it changes, at the same clock time.
Future<void> _key(WidgetTester tester, LogicalKeyboardKey key, {bool meta = false}) async {
  if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
  await tester.pump();
}

String _hints(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('status-keys'))).textSpan!.toPlainText();

Finder _paneOf<T extends Widget>({bool offstage = false}) =>
    find.ancestor(of: find.byType(T, skipOffstage: !offstage), matching: find.byType(Pane, skipOffstage: !offstage)).first;

/// The opacity of the nearest fade over [finder].
double _fadeOver(WidgetTester tester, Finder finder) =>
    tester.widget<FadeTransition>(find.ancestor(of: finder, matching: find.byType(FadeTransition)).first).opacity.value;

bool _rowCovered(WidgetTester tester) =>
    tester.widget<IgnorePointer>(find.ancestor(of: find.byType(PaneRow), matching: find.byType(IgnorePointer)).first).ignoring;

class _TransportCore extends FakeCore {
  final transports = <TransportDto>[];
  int backs = 0;

  @override
  Future<void> transport(TransportDto cmd) {
    transports.add(cmd);
    return super.transport(cmd);
  }

  @override
  Future<TrailDto?> trailBack() {
    backs++;
    return super.trailBack();
  }
}

class _LateNowCore extends FakeCore {
  final gate = Completer<void>();

  @override
  Stream<NowDto> now() async* {
    await gate.future;
    yield* super.now();
  }
}
