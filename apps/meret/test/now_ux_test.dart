import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/core/playhead.dart';
import 'package:meret/core/when.dart';
import 'package:meret/main.dart';
import 'package:meret/now/history_sheet.dart';
import 'package:meret/now/now_pane.dart';
import 'package:meret/now/now_stage.dart';
import 'package:meret/now/signal_path.dart';

void main() {
  test('the when voice: just now, today, yesterday, the weekday, then the date', () {
    final now = DateTime(2026, 10, 23, 6, 30); // a Friday
    int at(DateTime t) => t.millisecondsSinceEpoch;
    expect(dayAndTime(at(now.subtract(const Duration(seconds: 59))), now: now), 'just now');
    expect(dayAndTime(at(now.add(const Duration(seconds: 5))), now: now), 'just now');
    expect(dayAndTime(at(now.subtract(const Duration(seconds: 60))), now: now), 'today 06:29');
    expect(dayAndTime(at(DateTime(2026, 10, 23, 0, 2)), now: now), 'today 00:02');
    expect(dayAndTime(at(DateTime(2026, 10, 22, 21, 57)), now: now), 'yesterday 21:57');
    expect(dayAndTime(at(DateTime(2026, 10, 21, 8, 5)), now: now), 'Wed 08:05');
    expect(dayAndTime(at(DateTime(2026, 10, 17, 23, 14)), now: now), 'Sat 23:14');
    expect(dayAndTime(at(DateTime(2026, 10, 16, 23, 14)), now: now), '16 Oct 23:14');
    expect(dayAndTime(at(DateTime(2025, 3, 1, 9, 0)), now: now), '1 Mar 09:00');
  });

  test('the verdict names what altered, and shared mode in the zone words', () {
    const level = StageDto(name: 'Level', detail: 'levelled -3.2 dB', alters: true);
    const out = StageDto(name: 'Out', detail: 'Speakers · 48', alters: true);
    NowDto altered(List<StageDto> path) => NowDto(title: '', subtitle: '', fidelity: FidelityDto.altered, path: path);
    expect(signalVerdict(altered([out]), exclusive: false), '◐ Altered · shared with macOS');
    expect(signalVerdict(altered([out]), exclusive: true), '◐ Altered · Speakers · 48');
    expect(signalVerdict(altered([out])), '◐ Altered');
    expect(signalVerdict(altered([level, out]), exclusive: false), '◐ Altered · levelled -3.2 dB · shared with macOS');
    expect(signalVerdict(const NowDto(title: '', subtitle: '', path: [])), isNull);
  });

  testWidgets('the stage says where Resume starts, when it stopped, and never repeats the loaded release in Pick up', (tester) async {
    final core = FakeCore();
    final loaded = await core.now().first;
    final points = await core.resumePoints(6);
    final mine = points.firstWhere((point) => point.releaseId == loaded.releaseId);
    final other = points.firstWhere((point) => point.releaseId != loaded.releaseId);
    await _app(tester, core);
    expect(find.byType(NowStage), findsOneWidget);
    expect(find.byKey(ValueKey('now-pick-up-${mine.releaseId}')), findsNothing);
    expect(find.byKey(ValueKey('now-pick-up-${other.releaseId}')), findsOneWidget);

    final rule = tester.widget<Text>(find.byKey(const ValueKey('now-stage-rule')));
    expect(rule.data, resumeRule(mine.idiom));
    expect(tester.getTopLeft(find.byKey(const ValueKey('now-stage-rule'))).dy,
      greaterThan(tester.getBottomLeft(find.byKey(const ValueKey('now-stage-resume'))).dy));
    final where = tester.widget<Text>(find.byKey(const ValueKey('now-stage-where'))).data!;
    expect(where, startsWith('Playing at '));
    expect(where, contains(' of ${clockLength(loaded.lengthMs!.toInt())}'));
    await core.transport(const TransportDto.pause());
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const ValueKey('now-stage-where'))).data,
      startsWith('Paused ${dayAndTime(mine.updatedAt.toInt())} at '));
    final row = find.byKey(ValueKey('now-pick-up-${other.releaseId}'));
    expect(find.descendant(of: row, matching: find.text(dayAndTime(other.updatedAt.toInt()))), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text(positionOf(other.positionMs.toInt(), other.lengthMs?.toInt()))), findsOneWidget);
    expect(find.descendant(of: row, matching: find.textContaining(' / ')), findsNothing);

    await _commandKey(tester, LogicalKeyboardKey.digit1);
    await tester.pump();
    final pane = find.byType(NowPane);
    expect(pane, findsOneWidget);
    expect(find.descendant(of: pane, matching: find.byKey(ValueKey('now-pick-up-${mine.releaseId}'))), findsNothing);
    expect(find.descendant(of: pane, matching: find.byKey(ValueKey('now-pick-up-${other.releaseId}'))), findsOneWidget);
    expect(find.descendant(of: pane, matching: find.text('Up next')), findsOneWidget);
    expect(find.descendant(of: pane, matching: find.text('UP NEXT')), findsNothing);
  });

  testWidgets('the stage dial never shrinks when the window grows', (tester) async {
    final core = FakeCore();
    await _app(tester, core, size: const Size(1400, 900));
    final at1400 = tester.getSize(find.byType(NowDial)).width;
    tester.view.physicalSize = const Size(1728, 1000);
    await tester.pump();
    await tester.pump();
    expect(tester.getSize(find.byType(NowDial)).width, greaterThanOrEqualTo(at1400));
    tester.view.physicalSize = const Size(500, 700);
    await tester.pump();
    await tester.pump();
    expect(tester.getSize(find.byType(NowDial)).width, lessThan(at1400));
  });

  testWidgets('the bar plays something when nothing is loaded and answers when there is nothing', (tester) async {
    final core = FakeCore.empty();
    final clock = PlayheadClock(tester);
    addTearDown(clock.dispose);
    var toggles = 0;
    Future<void> bar({required bool nothingToPlay}) => tester.pumpWidget(MaterialApp(home: Scaffold(
      body: Align(alignment: Alignment.bottomCenter, child: NowBar(
        core: core, now: const NowDto(title: '', subtitle: '', path: []), clock: clock,
        onToggle: () => toggles++, nothingToPlay: nothingToPlay,
      )),
    )));
    await bar(nothingToPlay: false);
    final toggle = find.byKey(const ValueKey('now-toggle'));
    expect(tester.widget<IconButton>(find.descendant(of: toggle, matching: find.byType(IconButton))).onPressed, isNotNull);
    expect(tester.widget<IconButton>(find.descendant(of: find.byKey(const ValueKey('now-next')), matching: find.byType(IconButton))).onPressed, isNull);
    await tester.tap(toggle);
    expect(toggles, 1);
    expect(find.text('Nothing playing'), findsOneWidget);
    await bar(nothingToPlay: true);
    expect(find.text('Nothing to play yet'), findsOneWidget);
    expect(find.text('Nothing playing'), findsNothing);
  });

  testWidgets('the pinned pane reserves the why slot so the transport never moves', (tester) async {
    final core = FakeCore();
    final now = await core.now().first;
    final clock = PlayheadClock(tester);
    addTearDown(clock.dispose);
    Future<void> pane(NowDto n) => tester.pumpWidget(MaterialApp(home: Scaffold(
      body: SizedBox(width: 360, height: 900, child: NowPane(core: core, now: n, clock: clock, onToggle: () {})),
    )));
    await pane(now);
    final before = tester.getTopLeft(find.byType(Transport));
    await pane(NowDto(
      trackId: now.trackId, releaseId: now.releaseId, title: now.title, subtitle: now.subtitle, anchor: now.anchor,
      lengthMs: now.lengthMs, path: now.path, fidelity: now.fidelity, dr: now.dr, loudnessLufs: now.loudnessLufs,
      why: 'Never played · In your library for 1 week, never played through. The whole score, in order, twice over.',
    ));
    expect(tester.getTopLeft(find.byType(Transport)), before);
    final why = tester.widget<Text>(find.byKey(const ValueKey('now-why')));
    expect(why.maxLines, 2);
    expect(why.overflow, TextOverflow.ellipsis);
  });

  testWidgets('Space toggles inside the Now sheet, which fits a small window', (tester) async {
    final core = FakeCore();
    final now = await core.now().first;
    final clock = PlayheadClock(tester);
    addTearDown(clock.dispose);
    var toggles = 0;
    tester.view.physicalSize = const Size(500, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: Align(alignment: Alignment.bottomCenter, child: NowBar(core: core, now: now, clock: clock, onToggle: () => toggles++)),
    )));
    await tester.tap(find.byKey(const ValueKey('now-bar-title')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final pane = find.byType(NowPane);
    expect(pane, findsOneWidget);
    final size = tester.getSize(pane);
    expect(size.width, lessThanOrEqualTo(500 - 32));
    expect(size.height, lessThanOrEqualTo(400 - 32));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(toggles, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(pane, findsNothing);
  });

  testWidgets('Space toggles inside the history sheet and h closes it', (tester) async {
    final core = FakeCore();
    var toggles = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
      onPressed: () => showHistorySheet(context, core, (_) async {}, onToggle: () => toggles++),
      child: const Text('open'),
    )))));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final sheet = find.byKey(const ValueKey('history-sheet'));
    expect(sheet, findsOneWidget);
    final listen = (await core.history(1)).single;
    expect(find.descendant(of: sheet, matching: find.text(dayAndTime(listen.startedAtMs.toInt()))), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(toggles, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(sheet, findsNothing);
  });

  testWidgets('Up next is a section whose count names tracks', (tester) async {
    final core = FakeCore();
    await core.playResults('', const ViewDto(sort: SortKeyDto.library_, descending: false, group: false), 0);
    final upNext = await core.upNext(8);
    await _app(tester, core);
    final section = find.descendant(of: find.byType(UpNext), matching: find.byType(NowSection));
    expect(section, findsOneWidget);
    expect(tester.widget<NowSection>(section).title, 'Up next');
    expect(tester.widget<NowSection>(section).meta, '${upNext.remaining} tracks');
  });
}

Future<void> _app(WidgetTester tester, CoreBridge core, {Size size = const Size(2560, 1440)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MeretApp(core: core));
  await tester.pump();
  await tester.pump();
}

Future<void> _commandKey(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
  await tester.pump();
}
