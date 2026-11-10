import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64, PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/panes/pane.dart';
import 'package:meret/panes/release_pane.dart';
import 'package:meret/panes/row_menu.dart';
import 'package:meret/panes/table_pane.dart';
import 'package:meret/theme/light.dart';

void main() {
  testWidgets('ACT-1 a click anywhere on a tracklist row plays from it, and a double click plays it once', (tester) async {
    final core = _CountingCore();
    _desktop(tester);
    await tester.pumpWidget(_pane(ReleasePane(core: core, id: _release, fromStop: 0, onFollow: (_, _, _) async {})));
    await tester.pump();

    final row = find.byKey(const ValueKey('release-row-2'));
    await tester.tap(row);
    await tester.pump();
    expect(core.releasePlays, [2], reason: 'one click plays');
    expect(tester.widget<Semantics>(row).properties.selected, isTrue);

    // The line under the title names the work; a click on it still plays the track.
    final work = (await core.release(_release)).rowWorks[0]!;
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('release-row-0')), matching: find.text(work.title)).last);
    await tester.pump();
    expect(core.releasePlays, [2, 0]);

    await tester.pump(const Duration(milliseconds: 400));
    final other = find.byKey(const ValueKey('release-row-4'));
    await tester.tap(other);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(other);
    await tester.pump();
    expect(core.releasePlays, [2, 0, 4], reason: 'the second click of a double click does not start it again');
  });

  testWidgets('ACT-1b only the arrow at a row’s end goes somewhere, and it does not play', (tester) async {
    final core = _CountingCore();
    final followed = <TargetDto>[];
    _desktop(tester);
    await tester.pumpWidget(_pane(ReleasePane(core: core, id: _release, fromStop: 0, onFollow: (to, _, _) async => followed.add(to))));
    await tester.pump();

    final work = (await core.release(_release)).rowWorks[0]!;
    await tester.tap(find.byKey(const ValueKey('release-work-0')));
    await tester.pump();
    expect(followed, [work.to]);
    expect(core.releasePlays, isEmpty);
  });

  testWidgets('ACT-2 right-click on a tracklist row offers the play verbs, Go to and Show in Finder; Play next queues after the playing item', (tester) async {
    final core = _CountingCore();
    _desktop(tester);
    await core.playRelease(id: PlatformInt64Util.from(2), index: 0);
    final before = await core.upNext(50);
    await tester.pumpWidget(_pane(ReleasePane(core: core, id: _release, fromStop: 0, onFollow: (_, _, _) async {})));
    await tester.pump();

    final row = find.byKey(const ValueKey('release-row-1'));
    await tester.tap(row, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    for (final label in ['Play now', 'Play next', 'Add to queue', 'Show in Finder']) {
      expect(find.widgetWithText(MenuItemButton, label), findsOneWidget, reason: label);
    }
    expect(find.textContaining('Go to '), findsWidgets);
    expect(core.releasePlays, [0], reason: 'opening the menu plays nothing');

    await tester.tap(find.widgetWithText(MenuItemButton, 'Play next'));
    await tester.pumpAndSettle();
    final rows = (await core.release(_release)).rows;
    final after = await core.upNext(50);
    expect(after.items.first.trackId, rows[1].trackId);
    expect(after.items.skip(1).map((i) => i.trackId), before.items.map((i) => i.trackId).take(after.items.length - 1));
    expect(core.releasePlays, [0], reason: 'nothing replaced what was playing');
    expect(find.text('Playing 1 track next'), findsOneWidget);
  });

  testWidgets('ACT-2b a ⌃-click opens the same menu and does not play', (tester) async {
    final core = _CountingCore();
    _desktop(tester);
    await tester.pumpWidget(_pane(ReleasePane(core: core, id: _release, fromStop: 0, onFollow: (_, _, _) async {})));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('release-row-1'))));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MenuItemButton, 'Play next'), findsOneWidget);
    await gesture.cancel();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  testWidgets('ACT-3 arrows move the selection; ⇧↵ plays the selected row next and ⌥↵ adds it to the end', (tester) async {
    final core = _CountingCore();
    _desktop(tester);
    await tester.pumpWidget(_pane(ReleasePane(core: core, id: _release, fromStop: 0, onFollow: (_, _, _) async {})));
    await tester.pump();
    final rows = (await core.release(_release)).rows;

    await tester.tap(find.byKey(const ValueKey('release-row-2')));
    await tester.pump();
    final before = (await core.upNext(1)).remaining;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(tester.widget<Semantics>(find.byKey(const ValueKey('release-row-3'))).properties.selected, isTrue);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();

    final upNext = await core.upNext(1);
    expect(upNext.items.single.trackId, rows[3].trackId, reason: '⇧↵ goes first');
    expect(upNext.remaining, before + BigInt.two, reason: '⌥↵ goes in too, after everything');
    expect(core.releasePlays, [2], reason: 'queueing never replaces what plays');
  });

  testWidgets('ACT-4 a release heading in the table opens on a click and queues its whole tracklist from the menu', (tester) async {
    final core = _CountingCore();
    final followed = <TargetDto>[];
    _desktop(tester);
    await core.playRelease(id: PlatformInt64Util.from(2), index: 0);
    final before = (await core.upNext(1)).remaining;
    await tester.pumpWidget(_pane(TablePane(core: core, query: '', onQuery: (_) {}, onFollow: (to) async => followed.add(to))));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('table-row-0')));
    await tester.pump();
    expect(followed, [TargetDto.release(id: _release)]);
    expect(core.tablePlays, 0, reason: 'a heading is a door, not a track');

    await tester.tap(find.byKey(const ValueKey('table-row-0')), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.textContaining('Go to '), findsWidgets);
    await tester.tap(find.widgetWithText(MenuItemButton, 'Add to queue'));
    await tester.pumpAndSettle();

    final tracklist = (await core.release(_release)).rows;
    expect((await core.upNext(1)).remaining, before + BigInt.from(tracklist.length));
    expect(core.tablePlays, 0);
  });

  testWidgets('ACT-5 a table track row plays on one click wherever it lands, and its end arrow opens the release instead', (tester) async {
    final core = _CountingCore();
    final followed = <TargetDto>[];
    _desktop(tester);
    await tester.pumpWidget(_pane(TablePane(core: core, query: '', onQuery: (_) {}, onFollow: (to) async => followed.add(to))));
    await tester.pump();
    await tester.pump();
    final row = ((await core.rows('', const ViewDto(sort: SortKeyDto.library_, descending: false, group: true), 1, 1)).items.single as ItemDto_Track).row;

    // On the title, and on the artist's cell: both play.
    await tester.tapAt(tester.getTopLeft(find.byKey(const ValueKey('table-row-1'))) + const Offset(80, 13));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('table-row-1'))));
    await tester.pump();
    expect(core.tablePlays, 2);
    expect(followed, isEmpty, reason: 'nothing inside a track row navigates');

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.byKey(const ValueKey('table-row-1'))));
    addTearDown(mouse.removePointer);
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('table-go-track-${row.trackId}')));
    await tester.pump();
    expect(followed, [TargetDto.release(id: row.releaseId)]);
    expect(core.tablePlays, 2);
  });

  testWidgets('ROW-1 a playing row keeps its title clear of the lit edge in every tracklist', (tester) async {
    final core = FakeCore();
    _desktop(tester);
    final release = await core.release(_release);
    final playing = release.rows[1];
    final light = Light(track: playing.trackId.toInt());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LightScope(light: light,
      child: ReleasePane(core: core, id: _release, fromStop: 0, onFollow: (_, _, _) async {})))));
    await tester.pump();

    final row = find.byKey(const ValueKey('release-row-1'));
    final title = find.descendant(of: row, matching: find.text(playing.title));
    expect(tester.getTopLeft(title).dx - tester.getTopLeft(row).dx, greaterThanOrEqualTo(RowBox.edgeWidth + RowBox.inset));
    // Lit or not, a row's text sits in the same place: nothing shifts when it lights.
    final quiet = find.byKey(const ValueKey('release-row-2'));
    final quietTitle = find.descendant(of: quiet, matching: find.text(release.rows[2].title));
    expect(tester.getTopLeft(quietTitle).dx, tester.getTopLeft(title).dx);
  });

  testWidgets('ROW-2 a release lists its tracks before its credits, and Credits jumps to them on a long one', (tester) async {
    final core = FakeCore();
    _desktop(tester);
    await tester.pumpWidget(_pane(ReleasePane(core: core, id: _release, fromStop: 0, onFollow: (_, _, _) async {})));
    await tester.pump();
    final release = await core.release(_release);
    expect(release.credits, isNotEmpty);

    final tracklist = find.text('Tracklist');
    expect(tracklist, findsOneWidget);
    expect(find.byKey(const ValueKey('release-row-0')), findsOneWidget, reason: 'the first track is in view as the pane opens');
    expect(find.text('Credits'), findsNothing, reason: 'the credits wait below a long tracklist');

    await tester.tap(find.byKey(const ValueKey('release-credits')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    final credit = release.credits.first;
    expect(find.text('Credits'), findsOneWidget);
    expect(find.byKey(ValueKey('thread-${credit.kind.name}-${credit.to}')).hitTestable(), findsOneWidget);
  });
}

final PlatformInt64 _release = PlatformInt64Util.from(1);

void _desktop(WidgetTester tester) {
  tester.view.physicalSize = const Size(1100, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _pane(Widget child) => MaterialApp(home: Scaffold(body: RowMenuHost(child: LightScope(light: Light.brass, child: child))));

/// Counts the plays that replace the queue.
class _CountingCore extends FakeCore {
  final releasePlays = <int>[];
  int tablePlays = 0;

  @override
  Future<void> playRelease({required PlatformInt64 id, required int index, int? fromStop}) {
    releasePlays.add(index);
    return super.playRelease(id: id, index: index, fromStop: fromStop);
  }

  @override
  Future<void> playResults(String query, ViewDto view, int index) {
    tablePlays++;
    return super.playResults(query, view, index);
  }
}
