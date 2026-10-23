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

  testWidgets('ANIM-2 reverse navigation starts at minus one and eases to zero', (tester) async {
    final core = FakeCore();
    await _seedTrail(core, stops: 3);
    await _surface(tester, core);
    await _showTrail(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pump();
    final slide = tester.widget<PaneRow>(find.byType(PaneRow)).slide;
    expect((await core.trail())!.current, 1);
    expect(slide.value, -1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(slide.value, allOf(greaterThan(-1), lessThan(0)));
    await tester.pump(const Duration(milliseconds: 200));
    expect(slide.value, 0);
  });

  testWidgets('ANIM-3 forward at the last stop does not start a slide', (tester) async {
    final core = _TerminalCore();
    await _seedTrail(core, stops: 3);
    await _surface(tester, core);
    await _showTrail(tester);
    final slide = tester.widget<PaneRow>(find.byType(PaneRow)).slide;
    expect(slide.value, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await tester.pump();
    expect((await core.trail())!.current, 2);
    expect(slide.value, 0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(slide.value, 0);
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
