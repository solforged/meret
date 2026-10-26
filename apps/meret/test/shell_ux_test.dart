import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64Util;
import 'package:meret/core/bridge.dart';
import 'package:meret/main.dart';
import 'package:meret/now/now_pane.dart';
import 'package:meret/now/history_sheet.dart';
import 'package:meret/home/resume.dart';
import 'package:meret/panes/pane.dart';
import 'package:meret/panes/person_pane.dart';
import 'package:meret/panes/release_pane.dart';
import 'package:meret/panes/table_pane.dart';
import 'package:meret/panes/threads.dart';
import 'package:meret/panes/tree_pane.dart';
import 'package:meret/shell/pane_row.dart';
import 'package:meret/shell/trail_chip.dart';
import 'package:meret/shell/query_line.dart';
import 'package:meret/theme/tokens.dart';

void main() {
  testWidgets('ANIM-A1 [ within the window moves no pane and dims the stop ahead over 120 ms', (tester) async {
    final core = FakeCore();
    await _seedTrail(core, stops: 3);
    await _surface(tester, core);
    await _showTrail(tester);
    final xs = _paneXs(tester);
    expect(xs, hasLength(3));
    await _key(tester, LogicalKeyboardKey.bracketLeft);
    expect((await core.trail())!.current, 1);
    expect(tester.widget<Pane>(_paneOf<PersonPane>()).ahead, isTrue, reason: '[ dims the stop ahead; it never removes it');
    expect(find.textContaining('⑂ →'), findsNothing, reason: 'the stop ahead is a dimmed pane, not a fork mark');
    expect(_fadeOver(tester, find.byType(PersonPane)), 1);
    await tester.pump(const Duration(milliseconds: 60));
    expect(_fadeOver(tester, find.byType(PersonPane)), closeTo((1 + Pane.aheadOpacity) / 2, 0.01));
    expect(_paneXs(tester), xs);
    await tester.pump(const Duration(milliseconds: 60));
    expect(_fadeOver(tester, find.byType(PersonPane)), Pane.aheadOpacity);
    expect(_paneXs(tester), xs);
    await _key(tester, LogicalKeyboardKey.bracketRight);
    await tester.pumpAndSettle();
    expect((await core.trail())!.current, 2);
    expect(tester.widget<Pane>(_paneOf<PersonPane>()).ahead, isFalse);
    expect(_fadeOver(tester, find.byType(PersonPane)), 1);
    expect(_paneXs(tester), xs);
  });

  testWidgets('ANIM-A1b a click on a dimmed pane goes to its stop and nothing inside it takes the click', (tester) async {
    final core = FakeCore();
    await _seedTrail(core, stops: 3);
    await _surface(tester, core);
    await _showTrail(tester);
    final xs = _paneXs(tester);
    final stops = (await core.trail())!.stops.length;
    await _key(tester, LogicalKeyboardKey.bracketLeft);
    await tester.pumpAndSettle();
    expect(tester.widget<Pane>(_paneOf<PersonPane>()).ahead, isTrue);
    await tester.tapAt(tester.getCenter(_paneOf<PersonPane>()));
    await tester.pumpAndSettle();
    final trail = (await core.trail())!;
    expect(trail.current, 2, reason: 'the click walks forward to the dimmed stop');
    expect(trail.stops, hasLength(stops), reason: 'and follows nothing from it');
    expect(tester.widget<Pane>(_paneOf<PersonPane>()).ahead, isFalse);
    expect(_paneXs(tester), xs);
  });

  testWidgets('ANIM-A3 a search from Today fades Today through and does not slide', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Iona');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    final xs = _paneXs(tester);
    for (final ms in [0, 50, 100, 150, 200]) {
      if (ms > 0) await tester.pump(const Duration(milliseconds: 50));
      final today = find.byKey(const ValueKey('today'));
      final outgoing = today.evaluate().isEmpty ? 0.0 : _fadeOver(tester, today);
      final incoming = _fadeOver(tester, find.byKey(const ValueKey('panes')));
      expect(outgoing > 0.5 && incoming > 0.5, isFalse, reason: 'two pages visible at $ms ms');
      expect(_paneXs(tester), xs, reason: 'a new tree arrives whole; nothing slides');
    }
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(const ValueKey('today')), findsNothing);
    expect(find.byType(TablePane), findsOneWidget);
  });

  testWidgets('ANIM-A6 [ at the root, ], command 1 twice, T and Escape all fade the page through, never slide', (tester) async {
    final core = FakeCore();
    await _seedTrail(core, stops: 2);
    await _surface(tester, core);
    await _showTrail(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pumpAndSettle();
    expect((await core.trail())!.current, 0);
    final xs = _paneXs(tester, offstage: true);
    final table = tester.state(find.byType(TablePane));

    Future<void> fadesIn(LogicalKeyboardKey key, String page, {bool meta = false}) async {
      await _key(tester, key, meta: meta);
      expect(_rowCovered(tester), isTrue);
      expect(_paneXs(tester, offstage: true), xs);
      expect(_fadeOver(tester, find.byKey(ValueKey(page))), 0, reason: '$page at 0 ms');
      await tester.pump(const Duration(milliseconds: 100));
      expect(_fadeOver(tester, find.byKey(ValueKey(page))), 0, reason: '$page waits for the first half');
      await tester.pump(const Duration(milliseconds: 50));
      expect(_fadeOver(tester, find.byKey(ValueKey(page))), closeTo(0.5, 0.01));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_fadeOver(tester, find.byKey(ValueKey(page))), 1);
      expect(_paneXs(tester, offstage: true), xs);
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
      expect(_paneXs(tester, offstage: true), xs, reason: 'the row was there all along');
      expect(tester.state(find.byType(TablePane)), same(table));
    }

    await fadesIn(LogicalKeyboardKey.bracketLeft, 'today');
    expect(find.text('] back to All tracks'), findsOneWidget);
    expect(find.byType(TrailChip), findsNothing, reason: 'the back line names the trail under Today');
    await fadesOut(LogicalKeyboardKey.bracketRight, 'today');
    expect(find.byType(TrailChip), findsOneWidget);
    // The first ⌘1 lays the Home column over the trail; the second shows Today.
    await _key(tester, LogicalKeyboardKey.digit1, meta: true);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-column')), findsOneWidget);
    expect(_rowCovered(tester), isTrue);
    expect(_paneXs(tester, offstage: true), xs, reason: 'the panes never move for Home');
    await fadesIn(LogicalKeyboardKey.digit1, 'today', meta: true);
    await fadesOut(LogicalKeyboardKey.bracketRight, 'today');
    await fadesIn(LogicalKeyboardKey.keyT, 'tree');
    expect(find.byType(TreePane), findsOneWidget);
    await fadesOut(LogicalKeyboardKey.escape, 'tree');
    expect((await core.trail())!.current, 0, reason: 'none of this moved along the trail');
  });

  testWidgets('NAV-N2 [ keeps the stop ahead on the row, dimmed, with its data and scroll, and ] brings it back', (tester) async {
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
    final box = tester.getRect(_paneOf<ReleasePane>());
    await tester.tap(find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('release-row-')).last);
    await core.transport(const TransportDto.pause());
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('surface'), reason: 'the tracklist took the focus');

    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pumpAndSettle();
    expect((await core.trail())!.current, 0);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'surface', reason: 'a dimmed pane cannot keep the keys');
    expect(find.byType(ReleasePane), findsOneWidget, reason: 'dimmed, not removed');
    expect(tester.widget<Pane>(_paneOf<ReleasePane>()).ahead, isTrue);
    expect(tester.getRect(_paneOf<ReleasePane>()), box, reason: 'nothing moved');
    expect(tester.state<ScrollableState>(scrollable), same(state));
    expect(state.position.pixels, offset);

    await _key(tester, LogicalKeyboardKey.bracketRight);
    expect(find.text('Reading release…'), findsNothing);
    await tester.pumpAndSettle();
    expect(tester.widget<Pane>(_paneOf<ReleasePane>()).ahead, isFalse);
    expect(tester.state<ScrollableState>(scrollable), same(state));
    expect(state.position.pixels, offset);
  });

  testWidgets('NAV-N2 a branch swapped away is parked with its scroll, and swaps back the same', (tester) async {
    final core = FakeCore();
    await core.startTrail(const TargetDto.search(query: ''));
    await core.follow(0, TargetDto.release(id: PlatformInt64Util.from(1)), ThreadKind.appearsOn, 'local_tags');
    await core.follow(0, TargetDto.release(id: PlatformInt64Util.from(2)), ThreadKind.appearsOn, 'local_tags');
    await _surface(tester, core);
    await _showTrail(tester);
    final scrollable = find.descendant(of: find.byType(ReleasePane), matching: find.byType(Scrollable));
    final state = tester.state<ScrollableState>(scrollable);
    expect(state.position.maxScrollExtent, greaterThan(60));
    state.position.jumpTo(60);
    await tester.pumpAndSettle();

    await _sibling(tester, 1);
    expect(find.byType(ReleasePane), findsOneWidget, reason: 'the other branch is on the row');
    expect(tester.state<ScrollableState>(scrollable), isNot(same(state)));
    final parked = find.byType(ReleasePane, skipOffstage: false);
    expect(parked, findsNWidgets(2), reason: 'parked, not disposed');

    await _sibling(tester, 1);
    expect(tester.state<ScrollableState>(scrollable), same(state));
    expect(state.position.pixels, 60);
    expect(find.text('Reading release…'), findsNothing);
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
    for (final presses in [1, 2]) {
      for (var i = 0; i < presses; i++) {
        await _key(tester, LogicalKeyboardKey.digit1, meta: true);
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const ValueKey('today')), presses == 2 ? findsOneWidget : findsNothing);
      expect(find.byKey(const ValueKey('home-column')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('today')), findsNothing);
      expect(find.byKey(const ValueKey('home-rail')), findsOneWidget);
      expect(tester.state<ScrollableState>(scrollable), same(state));
      expect(state.position.pixels, 80);
      expect(find.text('Reading release…'), findsNothing);
    }
  });

  testWidgets('HOME-1 the rail lights the door the trail started from, and its glyphs name their doors', (tester) async {
    final core = FakeCore();
    await core.startTrail(const TargetDto.search(query: 'idiom:score'));
    await _surface(tester, core);
    await _showTrail(tester);
    expect(find.byKey(const ValueKey('home-rail')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-column')), findsNothing);
    BoxDecoration fill(String id) => tester.widget<Container>(find.descendant(of: find.byKey(ValueKey('rail-$id')), matching: find.byType(Container)).first).decoration! as BoxDecoration;
    expect(fill('idiom-idiom:score').color, Tok.panel2, reason: 'Scores started this trail');
    expect(fill('idiom-idiom:album').color, isNull);
    expect(fill('today').color, isNull);
    final tip = tester.widget<Tooltip>(find.ancestor(of: find.byKey(const ValueKey('rail-idiom-idiom:score')), matching: find.byType(Tooltip)).first);
    expect(tip.message, startsWith('Scores · 212 · ⌘'));
  });

  testWidgets('HOME-2 the column over the trail dims the panes and Escape, ] or a click closes it', (tester) async {
    final core = FakeCore();
    await _seedTrail(core, stops: 2);
    await _surface(tester, core);
    await _showTrail(tester);
    final xs = _paneXs(tester, offstage: true);
    Future<void> open(Future<void> Function() how) async {
      await how();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('home-column')), findsOneWidget);
      expect(_rowCovered(tester), isTrue);
      expect(tester.widget<AnimatedOpacity>(find.ancestor(of: find.byType(PaneRow), matching: find.byType(AnimatedOpacity)).first).opacity, lessThan(1));
      expect(_paneXs(tester, offstage: true), xs, reason: 'the panes never move for Home');
    }
    Future<void> closed() async {
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('home-rail')), findsOneWidget);
      expect(_rowCovered(tester), isFalse);
      expect((await core.trail())!.current, 1, reason: 'closing Home never moves along the trail');
    }
    await open(() => tester.tap(find.byKey(const ValueKey('rail-today'))));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await closed();
    await open(() => _key(tester, LogicalKeyboardKey.digit1, meta: true));
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await closed();
    await open(() => _key(tester, LogicalKeyboardKey.digit1, meta: true));
    await tester.tapAt(tester.getCenter(find.byType(PaneRow)));
    await closed();
  });

  testWidgets('ANIM-4 a new tree and the previous one fade the row through, out then in, with nothing sliding', (tester) async {
    final core = FakeCore();
    await core.startTrail(const TargetDto.search(query: 'Iona'));
    await _surface(tester, core);
    await _showTrail(tester);
    final rows = find.byType(ThreadLines);
    expect(rows, findsOneWidget);
    double fade(int i) => _fadeOver(tester, rows.at(i));
    List<double> xs(int i) => [
      for (final pane in find.descendant(of: rows.at(i), matching: find.byType(Pane)).evaluate())
        (pane.findRenderObject()! as RenderBox).localToGlobal(Offset.zero).dx,
    ];

    Future<void> fadesThrough(String root) async {
      for (var i = 0; i < 5 && rows.evaluate().length < 2; i++) {
        await tester.pump();
      }
      expect(rows, findsNWidgets(2), reason: 'the old tree stays while it fades out');
      expect((fade(0), fade(1)), (1, 0));
      await tester.pump(const Duration(milliseconds: 50));
      expect(fade(0), closeTo(0.5, 0.01));
      expect(fade(1), 0);
      await tester.pump(const Duration(milliseconds: 50));
      expect(fade(0), 0, reason: 'the old tree is gone before the new one shows');
      final at = xs(1);
      await tester.pump(const Duration(milliseconds: 50));
      expect(fade(1), closeTo(0.5, 0.01));
      expect(xs(1), at, reason: 'the new tree fades in where it stands');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 1));
      expect(rows, findsOneWidget);
      expect(fade(0), 1);
      expect(tester.widget<TrailChip>(find.byType(TrailChip)).trail.stops.first.title, root);
      await tester.pumpAndSettle();
    }

    await _key(tester, LogicalKeyboardKey.keyL, meta: true);
    await fadesThrough('All tracks');
    // [ at a root steps back into the previous tree, which fades through too.
    await _key(tester, LogicalKeyboardKey.bracketLeft);
    await fadesThrough('Iona');
  });

  testWidgets('THREAD-1 the followed row is lit and threaded to the next star, and the chip names the trail', (tester) async {
    final core = FakeCore();
    await _seedTrail(core, stops: 3);
    await _surface(tester, core);
    await _showTrail(tester);
    final trail = (await core.trail())!;
    final panes = find.descendant(of: find.byType(PaneRow), matching: find.byType(Pane));
    expect(panes, findsNWidgets(3));
    expect(tester.widgetList<Pane>(panes).map((pane) => pane.current), [false, false, true]);
    expect(tester.widget<Pane>(panes.at(1)).via, trail.stops[1].via);

    // The release names the person it led to, and the person the release it came from.
    expect(find.descendant(of: panes.at(1), matching: find.byKey(const ValueKey('thread-went'))), findsWidgets);
    expect(find.descendant(of: panes.at(2), matching: find.byKey(const ValueKey('thread-went'))), findsNothing);
    expect(find.descendant(of: panes.at(2), matching: find.byKey(const ValueKey('arrow-came'))), findsWidgets);

    // A gold thread joins each pane to the star in the next one's header.
    final threads = <Offset>[];
    final lines = tester.renderObject(find.descendant(of: find.byType(ThreadLines), matching: find.byType(CustomPaint)).first);
    expect(lines, paints..everything((method, arguments) {
      if (method == #drawPath && (arguments[1] as Paint).strokeWidth == 1.25) {
        threads.add((arguments[0] as Path).getBounds().bottomRight);
      }
      return true;
    }));
    expect(threads, hasLength(2));
    for (final (i, end) in threads.indexed) {
      final star = tester.getCenter(find.descendant(of: panes.at(i + 1), matching: find.byKey(const ValueKey('pane-star'))));
      final origin = tester.getTopLeft(find.byType(ThreadLines));
      expect(end.dx, closeTo(star.dx - origin.dx, 0.5), reason: 'thread $i ends at the next star');
    }

    final chip = find.byKey(const ValueKey('trail-chip-name'));
    expect(tester.widget<Text>(chip).data, 'All tracks → ${trail.stops.last.title}');
    expect(find.textContaining('3 stops · T'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('trail-chip')));
    await tester.pumpAndSettle();
    expect(find.byType(TreePane), findsOneWidget);
  });

  testWidgets('HOME-3 a door starts a new tree and the old one moves to Trails; command 3 is the first Library door', (tester) async {
    final core = FakeCore();
    await _seedTrail(core, stops: 2);
    await _surface(tester, core);
    await _showTrail(tester);
    await tester.tap(find.byKey(const ValueKey('rail-idiom-idiom:score')));
    await tester.pumpAndSettle();
    final trail = (await core.trail())!;
    expect(trail.rootQuery, 'idiom:score');
    expect(trail.stops, hasLength(1), reason: 'a door never forks the current tree');
    await _key(tester, LogicalKeyboardKey.digit1, meta: true);
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey('home-column')), matching: find.textContaining('All tracks →')), findsOneWidget, reason: 'the old tree is in Trails');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // ⌘1 Today, ⌘2 Pick up, ⌘3 All tracks.
    await _key(tester, LogicalKeyboardKey.digit3, meta: true);
    await tester.pumpAndSettle();
    expect((await core.trail())!.rootQuery, '');
    expect(find.byType(TablePane), findsOneWidget);
  });

  testWidgets('HOME-4 Pick up plays the latest partway release, and Home shows no doors that open onto nothing', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    await _key(tester, LogicalKeyboardKey.digit1, meta: true);
    await tester.pumpAndSettle();
    final column = find.byKey(const ValueKey('home-column'));
    expect(find.descendant(of: column, matching: find.byKey(const ValueKey('home-pick-up'))), findsOneWidget);
    for (final dead in ['crates', 'leads', 'wants']) {
      expect(find.byKey(ValueKey('home-$dead')), findsNothing, reason: dead);
    }
    // The loaded release is already where it stopped; Pick up goes to the next.
    final loaded = (await core.now().first).releaseId;
    final latest = (await core.resumePoints(99)).firstWhere((point) => point.releaseId != loaded);
    await tester.tap(find.byKey(const ValueKey('home-pick-up')));
    await tester.pump();
    await tester.pump();
    expect((await core.now().first).trackId, latest.recordingId);
  });

  testWidgets('NAV-N2 the parked set keeps the last six stops and empties for another trail', (tester) async {
    final core = FakeCore();
    await core.startTrail(const TargetDto.search(query: ''));
    for (var i = 1; i <= 8; i++) {
      await core.follow(0, TargetDto.release(id: PlatformInt64Util.from(i)), ThreadKind.appearsOn, 'local_tags');
    }
    await _surface(tester, core);
    await _showTrail(tester);
    for (var i = 0; i < 8; i++) {
      await _sibling(tester, 1);
    }
    expect(find.byType(ReleasePane), findsOneWidget);
    expect(find.byType(ReleasePane, skipOffstage: false), findsNWidgets(7), reason: 'the one on the row and six parked');
    await _key(tester, LogicalKeyboardKey.keyL, meta: true);
    await tester.pumpAndSettle();
    expect(find.byType(ReleasePane, skipOffstage: false), findsNothing, reason: 'a new trail parks nothing from the old one');
  });

  testWidgets('TOP-1 the LCD holds the window centre and the query takes it while searching', (tester) async {
    final core = FakeCore();
    await _seedTrail(core, stops: 3);
    await _surface(tester, core, width: 1800);
    await _showTrail(tester);
    final lcd = find.byKey(const ValueKey('lcd'));
    final query = find.byType(QueryLine);
    expect(tester.getCenter(lcd).dx, moreOrLessEquals(900, epsilon: 1), reason: 'centred on the window, not on what the chip leaves');
    expect(tester.getTopLeft(query).dx, greaterThan(tester.getTopRight(lcd).dx), reason: 'the query waits docked at the right');
    final docked = tester.getSize(query).width;

    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pumpAndSettle();
    expect(tester.getSize(query).width, greaterThan(docked * 2));
    expect(tester.getCenter(query).dx, moreOrLessEquals(900, epsilon: 1), reason: 'the query has the centre');
    expect(tester.getSize(lcd).width, lessThan(240), reason: 'the LCD folds to a pill');
    expect(tester.getTopLeft(lcd).dx, greaterThan(tester.getTopRight(query).dx));
    expect(find.byKey(const ValueKey('lcd-toggle')), findsOneWidget, reason: 'the pill keeps play and pause');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.getCenter(lcd).dx, moreOrLessEquals(900, epsilon: 1));
    expect(tester.getSize(query).width, docked);
    expect(find.byKey(const ValueKey('top-now')), findsNothing, reason: 'the LCD opens Now');
  });

  testWidgets('WIDTH-W4 the top line never overflows at 600 wide with a trail open', (tester) async {
    final core = FakeCore();
    await _seedTrail(core, stops: 3);
    await _surface(tester, core, width: 600, height: 900);
    await _showTrail(tester);
    await core.transport(const TransportDto.resume());
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('activity')), findsOneWidget);
    expect(find.text('Search or type a command'), findsOneWidget);
    for (final width in [640.0, 1000.0, 1280.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '$width wide');
    }
    expect(find.byKey(const ValueKey('lcd')), findsOneWidget, reason: 'the LCD shows once there is room');
    tester.view.physicalSize = const Size(1800, 900);
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(const ValueKey('lcd'))).width, greaterThan(560), reason: 'wide, the LCD takes the room the chip leaves');
  });

  testWidgets('KEYS-K5 the LCD play button says pause while playing', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    String tip() => tester.widget<Tooltip>(find.descendant(of: find.byKey(const ValueKey('lcd-toggle')), matching: find.byType(Tooltip)).first).message!;
    expect(tip(), 'Play');
    await core.transport(const TransportDto.resume());
    await tester.pump();
    await tester.pump();
    expect(tip(), 'Pause');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.pump();
    expect(tip(), 'Play');
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

  testWidgets('LAUNCH-L4 before the first Now the chip and the bar draw nothing', (tester) async {
    final core = _LateNowCore();
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MeretApp(core: core));
    await tester.pump();
    expect(find.byType(NowBar), findsNothing);
    expect(find.byType(TrailChip), findsNothing);
    expect(find.byType(ResumeHeader), findsNothing);
    core.gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byType(ResumeHeader), findsOneWidget);
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

/// `⌥]` (1) or `⌥[` (-1), settled.
Future<void> _sibling(WidgetTester tester, int step) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(step > 0 ? LogicalKeyboardKey.bracketRight : LogicalKeyboardKey.bracketLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.pumpAndSettle();
}


/// Where each pane on the row starts.
List<double> _paneXs(WidgetTester tester, {bool offstage = false}) => [
  for (final pane in find.descendant(of: find.byType(PaneRow), matching: find.byType(Pane, skipOffstage: !offstage), skipOffstage: !offstage).evaluate())
    if ((pane.findRenderObject() as RenderBox?)?.hasSize ?? false) (pane.findRenderObject()! as RenderBox).localToGlobal(Offset.zero).dx,
];

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
