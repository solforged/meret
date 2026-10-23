import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64Util;
import 'package:meret/core/bridge.dart';
import 'package:meret/main.dart';
import 'package:meret/now/now_pane.dart';
import 'package:meret/now/now_stage.dart';
import 'package:meret/panes/pane.dart';
import 'package:meret/panes/table_pane.dart';
import 'package:meret/shell/pane_row.dart';
import 'package:meret/theme/tokens.dart';

void main() {
  testWidgets('WIDTH-3 folding keeps table selection, scroll and keyboard focus', (tester) async {
    final core = FakeCore();
    await _seedTrail(core, stops: 4);
    // Four stops remain in the trail; park at its second stop so the oldest
    // table fits at 1728, where pinned Now leaves room for only three panes.
    await core.trailGo(1);
    await _surface(tester, core);
    await _showTrail(tester);
    expect((await core.trail())!.stops, hasLength(4));
    final table = find.byType(TablePane);
    final row = find.descendant(of: table, matching: find.byKey(const ValueKey('table-row-1')));
    await tester.tapAt(tester.getTopLeft(row) + const Offset(80, 13));
    for (var i = 0; i < 32; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    final scroll = tester.widget<ListView>(find.descendant(
      of: table, matching: find.byKey(const ValueKey('table-rows')),
    )).controller!;
    final offset = scroll.offset;
    expect(offset, greaterThan(0));
    expect(_rowColour(tester, 33), Tok.panel2);

    await _resize(tester, 400);
    expect(find.byType(PaneSpine), findsOneWidget);
    expect(find.byType(TablePane), findsNothing);
    expect(find.byType(TablePane, skipOffstage: false), findsOneWidget);
    await _resize(tester, 1728);

    final restored = tester.widget<ListView>(find.byKey(const ValueKey('table-rows'))).controller!;
    expect(restored.offset, offset);
    expect(_rowColour(tester, 33), Tok.panel2);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(_rowColour(tester, 32), Tok.panel2);
    expect(_rowColour(tester, 33), Colors.transparent);
  });

  testWidgets('WIDTH-4 pinned Now keeps its scroll offset across the bar breakpoint', (tester) async {
    final core = _NowSubscriptionCore();
    await _surface(tester, core);
    tester.widget<NowStage>(find.byType(NowStage)).onLeave();
    await tester.pumpAndSettle();
    final details = find.descendant(of: find.byType(NowPane), matching: find.byType(SingleChildScrollView));
    final scrollable = find.descendant(of: details, matching: find.byType(Scrollable));
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(100));
    position.jumpTo(100);
    await tester.pumpAndSettle();
    final offset = position.pixels;

    await _resize(tester, 1300);
    expect(find.byType(NowPane), findsNothing);
    expect(find.byType(NowBar), findsOneWidget);
    final hidden = find.byType(NowPane, skipOffstage: false);
    expect(hidden, findsOneWidget);
    expect(TickerMode.valuesOf(tester.element(hidden)).enabled, isFalse);
    await _resize(tester, 1728);
    expect(tester.state<ScrollableState>(scrollable).position.pixels, offset);
    expect(core.nowSubscriptions, 1);
  });

  testWidgets('ANIM-2 [ past the window shifts the panes into place over 200 ms', (tester) async {
    final core = FakeCore();
    await _seedTrail(core, stops: 4);
    await _surface(tester, core);
    await _showTrail(tester);
    await _resize(tester, 1300);
    var before = _paneXs(tester);
    var shifted = false;
    for (var i = 0; i < 3 && !shifted; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final mid = _paneXs(tester);
      if (listEquals(mid, before)) {
        await tester.pumpAndSettle();
        expect(_paneXs(tester), before, reason: '[ within the window moves nothing');
        continue;
      }
      shifted = true;
      await tester.pump(const Duration(milliseconds: 100));
      final after = _paneXs(tester);
      for (var p = 0; p < mid.length; p++) {
        final (lo, hi) = before[p] < after[p] ? (before[p], after[p]) : (after[p], before[p]);
        expect(mid[p], inInclusiveRange(lo, hi), reason: 'pane $p is on its way at 100 ms');
      }
      expect(mid, isNot(after), reason: 'still moving halfway');
      await tester.pumpAndSettle();
      expect(_paneXs(tester), after, reason: 'in place by 200 ms');
      before = after;
    }
    expect(shifted, isTrue, reason: 'four stops at 1300 do not all fit at full width');
  });

  testWidgets('ANIM-3 ] at the last stop moves nothing', (tester) async {
    final core = _TerminalCore();
    await _seedTrail(core, stops: 3);
    await _surface(tester, core);
    await _showTrail(tester);
    final xs = _paneXs(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await tester.pump();
    expect((await core.trail())!.current, 2);
    expect(_paneXs(tester), xs);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_paneXs(tester), xs);
  });

  testWidgets('ANIM-1 leaving Now fades through over 200ms without restarting on Now updates', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    tester.widget<NowStage>(find.byType(NowStage)).onLeave();
    await tester.pump();
    final switcher = find.byWidgetPredicate((widget) => widget is AnimatedSwitcher &&
      widget.child?.key == const ValueKey('stage-trail'));
    expect(switcher, findsOneWidget);
    expect(_pageOpacity(tester, 'stage-now'), 1);
    expect(_pageOpacity(tester, 'stage-trail'), 0);
    await tester.pump(const Duration(milliseconds: 50));
    expect(_pageOpacity(tester, 'stage-now'), closeTo(0.5, 0.01));
    expect(_pageOpacity(tester, 'stage-trail'), 0);
    await tester.pump(const Duration(milliseconds: 50));
    expect(_pageOpacity(tester, 'stage-now'), 0, reason: 'the stage is gone before the trail shows');
    expect(_pageOpacity(tester, 'stage-trail'), 0);
    await core.transport(TransportDto.seek(ms: BigInt.from(227000)));
    await tester.pump();
    expect(_pageOpacity(tester, 'stage-trail'), 0, reason: 'a Now update does not restart the fade');
    await tester.pump(const Duration(milliseconds: 50));
    expect(_pageOpacity(tester, 'stage-now'), 0);
    expect(_pageOpacity(tester, 'stage-trail'), closeTo(0.5, 0.01));
    await tester.pump(const Duration(milliseconds: 50));
    expect(_pageOpacity(tester, 'stage-now'), 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(const ValueKey('stage-now')), findsNothing);
    expect(_pageOpacity(tester, 'stage-trail'), 1);
    expect(tester.getSize(switcher), tester.getSize(find.byKey(const ValueKey('stage-trail'))));
  });
}

Future<void> _seedTrail(FakeCore core, {required int stops}) async {
  var trail = await core.startTrail(const TargetDto.search(query: ''));
  final release = await core.release(PlatformInt64Util.from(1));
  trail = await core.follow(trail.current, TargetDto.release(id: release.id), ThreadKind.matched, 'library');
  if (stops >= 3) {
    trail = await core.follow(trail.current, release.artistLinks.first.to, ThreadKind.albumArtist, release.artistLinks.first.provider);
  }
  if (stops >= 4) {
    await core.follow(trail.current, TargetDto.release(id: PlatformInt64Util.from(2)), ThreadKind.appearsOn, 'local_tags');
  }
}

Future<void> _surface(WidgetTester tester, FakeCore core) async {
  tester.view.physicalSize = const Size(1728, 900);
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

Future<void> _resize(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 900);
  await tester.pumpAndSettle();
}

/// Where each pane on the row starts.
List<double> _paneXs(WidgetTester tester) => [
  for (final pane in find.descendant(of: find.byType(PaneRow), matching: find.byType(Pane)).evaluate())
    (pane.findRenderObject()! as RenderBox).localToGlobal(Offset.zero).dx,
];

/// The opacity of the nearest fade over the widget keyed [key].
double _pageOpacity(WidgetTester tester, String key) => tester.widget<FadeTransition>(
  find.ancestor(of: find.byKey(ValueKey(key)), matching: find.byType(FadeTransition)).first,
).opacity.value;

Color? _rowColour(WidgetTester tester, int index) => (tester.widget<Container>(find.descendant(
  of: find.byKey(ValueKey('table-row-$index')), matching: find.byType(Container),
).first).decoration! as BoxDecoration).color;

class _TerminalCore extends FakeCore {
  @override
  Future<TrailDto?> trailForward() => trail();
}

class _NowSubscriptionCore extends FakeCore {
  int nowSubscriptions = 0;

  @override
  Stream<NowDto> now() {
    nowSubscriptions++;
    return super.now();
  }
}
