import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64, PlatformInt64Util;
import 'package:meret/core/bridge.dart';
import 'package:meret/core/playhead.dart';
import 'package:meret/draw/body_painter.dart';
import 'package:meret/draw/constellation.dart';
import 'package:meret/main.dart';
import 'package:meret/now/now_pane.dart';
import 'package:meret/now/now_stage.dart';
import 'package:meret/now/picks.dart';
import 'package:meret/now/zones.dart';
import 'package:meret/panes/front_pane.dart';
import 'package:meret/panes/pane.dart';
import 'package:meret/panes/search_pane.dart';
import 'package:meret/panes/person_pane.dart';
import 'package:meret/panes/release_pane.dart';
import 'package:meret/panes/table_pane.dart';
import 'package:meret/panes/work_pane.dart';
import 'package:meret/shell/pane_row.dart';
import 'package:meret/shell/query_line.dart';
import 'package:meret/theme/light.dart';
import 'package:meret/theme/tokens.dart';

const _libraryView = ViewDto(sort: SortKeyDto.library_, descending: false, group: false);
const _groupedView = ViewDto(sort: SortKeyDto.library_, descending: false, group: true);

void main() {
  testWidgets('the Now stage lists output devices with current rings and core verdict colours', (tester) async {
    await _surface(tester, FakeCore());
    await tester.pump();
    expect(find.byType(PlayOn), findsOneWidget);
    expect(find.text('MacBook Pro Speakers'), findsOneWidget);
    expect(find.text('RME ADI-2 DAC'), findsOneWidget);
    expect(find.text('This Mac · default output'), findsOneWidget);
    expect(find.descendant(
      of: find.byKey(const ValueKey('now-zone-local:dac')), matching: find.text('This Mac'),
    ), findsOneWidget);
    final speakers = _zoneMarker(tester, 'speakers');
    final dac = _zoneMarker(tester, 'dac');
    expect(speakers.shape, BoxShape.circle);
    expect(speakers.color, Light.of(tester.element(find.byType(PlayOn))).accent);
    expect(dac.color, Colors.transparent);
    expect(tester.getSize(find.byKey(const ValueKey('now-zone-marker-local:speakers'))), const Size(9, 9));
    expect(tester.widget<Text>(find.text('◐ refuses above 96 kHz')).style!.color, Tok.warn);
    expect(tester.widget<Text>(find.text('● bit-perfect')).style!.color, Tok.ok);
    expect(tester.widget<Text>(find.text('● bit-perfect')).style!.fontSize, 11);
    expect(tester.getTopLeft(find.byType(PlayOn)).dy, lessThan(tester.getTopLeft(find.byType(UpNext)).dy));
  });

  testWidgets('Play on switches to the DAC and does not navigate or replay the current device', (tester) async {
    final core = _ZonesCore();
    await _surface(tester, core);
    await tester.pump();
    final before = await core.now().first;
    await tester.tap(find.byKey(const ValueKey('now-zone-local:speakers')));
    await tester.pump();
    expect(core.outputs, isEmpty);
    await tester.tap(find.byKey(const ValueKey('now-zone-local:dac')));
    await tester.pump();
    await tester.pump();
    expect(core.outputs, ['local:dac']);
    expect(core.settings().outputDevice, 'dac');
    expect(_zoneMarker(tester, 'speakers').color, Colors.transparent);
    expect(_zoneMarker(tester, 'dac').color, Light.of(tester.element(find.byType(PlayOn))).accent);
    expect((await core.now().first).anchor!.item, before.anchor!.item);
    expect(await core.trail(), isNull);
    expect(find.byType(TrailStrip), findsNothing);
    expect(find.byType(NowStage), findsOneWidget);
  });

  testWidgets('Play on draws the shared-mode verdict verbatim for both devices', (tester) async {
    final core = FakeCore();
    await core.setSettings(SettingsDto(light: core.settings().light, exclusive: false, lookups: core.settings().lookups));
    await _surface(tester, core);
    await tester.pump();
    final verdicts = find.text('◐ shared with macOS');
    expect(verdicts, findsNWidgets(2));
    for (final text in tester.widgetList<Text>(verdicts)) {
      expect(text.style!.color, Tok.warn);
    }
  });

  testWidgets('Play on shows a switch failure under its list without moving the marker', (tester) async {
    final core = _FailingZoneCore();
    await _surface(tester, core);
    await tester.pump();
    final dac = find.byKey(const ValueKey('now-zone-local:dac'));
    await tester.tap(dac);
    await tester.pump();
    expect(core.outputs, ['local:dac']);
    final error = find.text('The DAC is unavailable.');
    expect(error, findsOneWidget);
    expect(tester.widget<Text>(error).style!.color, Tok.warn);
    expect(tester.getTopLeft(error).dy, greaterThan(tester.getBottomLeft(dac).dy));
    expect(_zoneMarker(tester, 'speakers').color, Light.of(tester.element(find.byType(PlayOn))).accent);
    expect(_zoneMarker(tester, 'dac').color, Colors.transparent);
    expect(core.settings().outputDevice, isNull);
  });

  testWidgets('the pinned Now pane puts Play on after the signal path and before Up next', (tester) async {
    await _surface(tester, FakeCore());
    await _commandKey(tester, LogicalKeyboardKey.digit1);
    await tester.pump();
    final pane = find.byType(NowPane);
    final zones = find.descendant(of: pane, matching: find.byType(PlayOn));
    final path = find.descendant(of: pane, matching: find.text('SIGNAL PATH'));
    final fidelity = find.descendant(of: pane, matching: find.byType(NowFidelity));
    final next = find.descendant(of: pane, matching: find.byType(UpNext));
    expect(zones, findsOneWidget);
    expect(find.descendant(of: zones, matching: find.text('Play on')), findsOneWidget);
    expect(tester.getTopLeft(zones).dy, greaterThan(tester.getBottomLeft(path).dy));
    expect(tester.getTopLeft(zones).dy, greaterThan(tester.getBottomLeft(fidelity).dy));
    expect(tester.getBottomLeft(zones).dy, lessThan(tester.getTopLeft(next).dy));
  });

  testWidgets('a written joint credit opens each individual thread', (tester) async {
    final people = [
      for (final (id, name) in [(1, 'Roger Briggs'), (2, 'Mark Cromer')])
        ThreadDto(kind: ThreadKind.albumArtist, label: 'album artist', source: 'tags', provider: 'local_tags',
          to: TargetDto.person(id: PlatformInt64Util.from(id)), title: name, detail: ''),
    ];
    final followed = <ThreadDto>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WrittenCredit(
      written: 'Roger Briggs & Mark Cromer', people: people, onFollow: followed.add,
    ))));
    expect(find.text('Roger Briggs'), findsOneWidget);
    expect(find.text('Mark Cromer'), findsOneWidget);
    expect(find.byWidgetPredicate((widget) => widget is RichText && widget.text.toPlainText().contains(' & ')), findsOneWidget);
    await tester.tap(find.text('Mark Cromer'));
    await tester.tap(find.text('Roger Briggs'));
    expect(followed.map((p) => p.to), [people[1].to, people[0].to]);
  });

  testWidgets('Now reads device volume and sends the slider scalar to the core', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    await _commandKey(tester, LogicalKeyboardKey.digit1);
    await tester.pump();
    final slider = find.byKey(const ValueKey('now-volume'));
    await tester.ensureVisible(slider);
    expect(tester.widget<Slider>(slider).value, 0.5);
    await tester.drag(slider, const Offset(-70, 0));
    await tester.pump();
    final volume = await core.volume();
    expect(volume.scalar, lessThan(0.5));
    expect(tester.widget<Slider>(slider).value, closeTo(volume.scalar!, 0.001));
  });

  testWidgets('Now disables unsupported device volume and explains why', (tester) async {
    await _surface(tester, _FixedVolumeCore());
    await _commandKey(tester, LogicalKeyboardKey.digit1);
    await tester.pump();
    final slider = tester.widget<Slider>(find.byKey(const ValueKey('now-volume')));
    expect(slider.onChanged, isNull);
    expect(find.text('Use the amplifier on this output.'), findsOneWidget);
  });

  testWidgets('Now lists the queue after the playing row and next moves along it', (tester) async {
    final core = _RecordingCore();
    await _surface(tester, core);
    await _commandKey(tester, LogicalKeyboardKey.digit1);
    await tester.pump();
    // The fake's opening Now is a loose anchor with no queue behind it.
    expect(find.descendant(of: find.byType(UpNext), matching: find.text('then stop')), findsOneWidget);

    await core.playResults('', _libraryView, 0);
    await tester.pump();
    await tester.pump();
    final second = await _firstTrack(core, offset: 1);
    final third = await _firstTrack(core, offset: 2);
    // The fake's first queue takes tokens 2…; the second row is token 3.
    expect(find.byKey(const ValueKey('up-next-3')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('up-next-3')), matching: find.text(second.title)), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('now-next')));
    await tester.pump();
    await tester.pump();
    expect(find.descendant(of: find.byType(NowPane), matching: find.text(second.title)), findsAtLeastNWidgets(1));
    expect(find.byKey(const ValueKey('up-next-3')), findsNothing);
    expect(find.byKey(const ValueKey('up-next-4')), findsOneWidget);
    expect(find.descendant(of: find.byType(UpNext), matching: find.text(third.title)), findsAtLeastNWidgets(1));

    // Within three seconds, previous goes back a row rather than restarting.
    await tester.tap(find.byKey(const ValueKey('now-previous')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('up-next-3')), findsOneWidget);
  });

  testWidgets('dragging the seek bar sends the position and re-anchors the clock', (tester) async {
    final core = _RecordingCore();
    await _surface(tester, core);
    await _commandKey(tester, LogicalKeyboardKey.digit1);
    final now = await core.now().first;
    final seek = find.byKey(const ValueKey('now-seek'));
    final width = tester.getSize(seek).width;
    await tester.drag(seek, Offset(width, 0));
    await tester.pump();
    final after = await core.now().first;
    expect(after.anchor!.positionMs, closeTo(now.lengthMs!.toDouble(), 1));
    expect(core.seeks.single.toInt(), closeTo(now.lengthMs!.toInt(), 1));
  });

  testWidgets('Now is pinned from 1400 wide and a bar below', (tester) async {
    await _surface(tester, FakeCore(), size: const Size(1568, 984));
    await _commandKey(tester, LogicalKeyboardKey.digit1);
    expect(find.byType(NowPane), findsOneWidget);
    expect(find.byType(NowBar), findsNothing);
    expect(tester.getSize(find.byType(NowPane)).width, 360);

    tester.view.physicalSize = const Size(1380, 900);
    await tester.pump();
    expect(find.byType(NowPane), findsNothing);
    expect(find.byType(NowBar), findsOneWidget);
    expect(find.byKey(const ValueKey('now-toggle')), findsOneWidget);
  });

  testWidgets('opens to the Now stage when the fake Now is loaded', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);

    expect(find.byType(NowStage), findsOneWidget);
    expect(find.byType(FrontPane), findsOneWidget);
    expect(find.byType(PaneRow), findsNothing);
    expect(find.byType(NowPane), findsNothing);
    expect(find.byType(NowBar), findsNothing);
    expect(await core.trail(), isNull);
  });

  testWidgets('opens to the Front when nothing is loaded and decides only once', (tester) async {
    final core = FakeCore.empty();
    await _surface(tester, core);
    expect(find.byType(NowStage), findsNothing);
    expect(find.byType(FrontPane), findsOneWidget);
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(1));
    await core.addRoot('/New music');
    await core.playResults('', _libraryView, 0);
    await tester.pump();
    await tester.pump();
    expect(find.byType(NowStage), findsNothing);
  });

  testWidgets('Command-1 leaves the Now stage and later playback never re-enters it', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    await _commandKey(tester, LogicalKeyboardKey.digit1);
    expect(find.byType(NowStage), findsNothing);
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(1));
    await core.playResults('', _libraryView, 0);
    await tester.pump();
    expect(find.byType(NowStage), findsNothing);
  });

  testWidgets('Shift-Space plays the first pick and Now says the core why without opening a trail', (tester) async {
    final core = _RecordingCore();
    await _surface(tester, core);
    await _shiftSpace(tester);
    expect(core.playSomethingCalls, 1);
    expect(core.transports, isEmpty);
    final why = tester.widget<Text>(find.byKey(const ValueKey('now-why')));
    expect(why.data, 'Dormant · 2 years · 96 plays, then nothing for 2 years');
    expect(why.style!.color, Tok.gold);
    expect(why.maxLines, 1);
    expect(why.overflow, TextOverflow.ellipsis);
    expect(find.byType(NowStage), findsOneWidget);
    expect(find.byType(FrontPane), findsOneWidget);
    expect(find.byType(TrailStrip), findsNothing);
    expect(await core.trail(), isNull);
    expect(find.text('⇧␣'), findsOneWidget);
    expect(find.text('play something'), findsOneWidget);

    await _commandKey(tester, LogicalKeyboardKey.digit1);
    expect(find.descendant(of: find.byType(NowPane), matching: find.byKey(const ValueKey('now-why'))), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('now-why'))).data, why.data);
  });

  testWidgets('Space with no anchor asks for a pick and with an anchor still pauses and resumes', (tester) async {
    final core = _RecordingCore.empty();
    await _surface(tester, core);
    expect((await core.now().first).anchor, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(core.playSomethingCalls, 1);
    expect(core.transports, isEmpty);
    expect((await core.now().first).anchor, isNull);

    await core.addRoot('/New music');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.pump();
    expect(core.playSomethingCalls, 2);
    expect((await core.now().first).anchor?.rate, 1);
    expect(find.byType(NowStage), findsNothing, reason: 'playing a pick leaves the Front alone');
    expect(find.byType(FrontPane), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(core.transports, [const TransportDto.pause()]);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(core.transports, [const TransportDto.pause(), const TransportDto.resume()]);
    expect(core.playSomethingCalls, 2);
    expect(await core.trail(), isNull);
    expect(find.byType(TrailStrip), findsNothing);
  });

  for (final empty in [false, true]) {
    testWidgets('play keys leave a focused query alone with ${empty ? 'no anchor' : 'an anchor'}', (tester) async {
      final core = empty ? _RecordingCore.empty() : _RecordingCore();
      await _surface(tester, core);
      await tester.tap(find.byType(TextField));
      await _shiftSpace(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(core.playSomethingCalls, 0);
      expect(core.transports, isEmpty);
    });
  }

  testWidgets('the stage draws three core-ordered picks and marks only the first in gold', (tester) async {
    final core = _RecordingCore();
    final picks = await core.picks(3);
    core.pickLimits.clear();
    await _surface(tester, core);
    await tester.pump();
    expect(core.pickLimits, isNotEmpty);
    expect(core.pickLimits, everyElement(3));
    final section = find.descendant(of: find.byType(NowStage), matching: find.byType(PlaySomething));
    expect(tester.widgetList<NowDoor>(find.descendant(of: section, matching: find.byType(NowDoor))).map((door) => door.key),
      picks.map((pick) => ValueKey('now-pick-${pick.releaseId}')));
    for (final (index, pick) in picks.indexed) {
      final row = find.byKey(ValueKey('now-pick-${pick.releaseId}'));
      expect(find.descendant(of: row, matching: find.text(pick.title)), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text(pick.reason)), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text(pick.plan)), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text(pick.meta)), findsOneWidget);
      final label = tester.widget<Text>(find.descendant(of: row, matching: find.text(pick.label.toUpperCase())));
      expect(label.style!.color, index == 0 ? Tok.gold : Tok.faint);
      final cell = tester.widget<Container>(find.byKey(ValueKey('now-pick-cell-${pick.releaseId}')));
      final decoration = cell.decoration! as BoxDecoration;
      expect(decoration.color, Tok.panel2);
      expect((decoration.border! as Border).top, BorderSide(color: index == 0 ? Tok.gold : Tok.line, width: index == 0 ? 2 : 1));
      expect(find.descendant(of: row, matching: find.text('Play ⇧Space')), index == 0 ? findsOneWidget : findsNothing);
    }
    expect(tester.getTopLeft(find.byKey(ValueKey('now-pick-${picks[0].releaseId}'))).dy,
      lessThan(tester.getTopLeft(find.byKey(ValueKey('now-pick-${picks[1].releaseId}'))).dy));
    expect(tester.getTopLeft(find.byKey(ValueKey('now-pick-${picks[1].releaseId}'))).dy,
      lessThan(tester.getTopLeft(find.byKey(ValueKey('now-pick-${picks[2].releaseId}'))).dy));
  });

  testWidgets('pick clicks play that release with its why, refresh, and never change the stage or trail', (tester) async {
    final core = _RecordingCore();
    final picks = await core.picks(3);
    await _surface(tester, core);
    await tester.pump();
    final first = find.byKey(ValueKey('now-pick-${picks.first.releaseId}'));
    await tester.ensureVisible(first);
    await tester.tap(first);
    await tester.pump();
    await tester.pump();
    expect(core.picksPlayed, [picks.first.releaseId]);
    expect(core.playSomethingCalls, 0);
    expect(tester.widget<Text>(find.byKey(const ValueKey('now-why'))).data, 'Dormant · 2 years · 96 plays, then nothing for 2 years');
    core.pickLimits.clear();
    final second = find.byKey(ValueKey('now-pick-${picks[1].releaseId}'));
    await tester.ensureVisible(second);
    await tester.tap(second);
    await tester.pump();
    await tester.pump();
    expect(core.picksPlayed, [picks.first.releaseId, picks[1].releaseId]);
    expect(core.releasesPlayed, isEmpty);
    expect((await core.now().first).releaseId, picks[1].releaseId);
    expect(tester.widget<Text>(find.byKey(const ValueKey('now-why'))).data, startsWith('From your latest trail · '));
    expect(core.pickLimits, isNotEmpty);
    expect(core.pickLimits, everyElement(3));
    expect(core.started, isEmpty);
    expect(find.byType(NowStage), findsOneWidget);
    expect(find.byType(FrontPane), findsOneWidget);
    expect(find.byType(TrailStrip), findsNothing);
    expect(await core.trail(), isNull);
  });

  testWidgets('the pinned pane puts picks below Up next and above listening memory', (tester) async {
    await _surface(tester, FakeCore());
    await _commandKey(tester, LogicalKeyboardKey.digit1);
    final pane = find.byType(NowPane);
    final picks = find.descendant(of: pane, matching: find.byType(PlaySomething));
    final queue = find.descendant(of: pane, matching: find.byType(UpNext));
    final memory = find.descendant(of: pane, matching: find.byType(NowMemory));
    expect(tester.getTopLeft(picks).dy, greaterThan(tester.getBottomLeft(queue).dy));
    expect(tester.getBottomLeft(picks).dy, lessThan(tester.getTopLeft(memory).dy));
  });

  testWidgets('an empty library explains that there is nothing to pick', (tester) async {
    await _surface(tester, FakeCore.empty());
    final section = find.byType(PlaySomething);
    expect(section, findsOneWidget);
    expect(find.descendant(of: section, matching: find.text('Or play something')), findsOneWidget);
    final empty = find.descendant(of: section, matching: find.text('Nothing to play yet'));
    expect(empty, findsOneWidget);
    expect(tester.widget<Text>(empty).style, Tok.label);
    expect(find.descendant(of: section, matching: find.byType(NowDoor)), findsNothing);
  });

  testWidgets('Option-Space starts the current piece from the top without opening a trail', (tester) async {
    final core = _RecordingCore();
    await _surface(tester, core);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(core.transports.single, const TransportDto.fromStart());
    expect(find.byType(NowStage), findsOneWidget);
    expect(await core.trail(), isNull);
    await tester.tap(find.byType(TextField));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    expect(core.transports, hasLength(1));
  });

  testWidgets('H opens history and a play opens its release and leaves the stage', (tester) async {
    final core = _RecordingCore();
    final listen = (await core.history(200)).first;
    await _surface(tester, core);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('history-sheet')), findsOneWidget);
    expect(core.historyLimits, contains(200));
    await tester.tap(find.byKey(ValueKey('history-listen-${listen.uid}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(core.started.single, TargetDto.release(id: listen.releaseId!));
    expect(find.byKey(const ValueKey('history-sheet')), findsNothing);
    expect(find.byType(NowStage), findsNothing);
    expect(tester.widget<ReleasePane>(find.byType(ReleasePane)).id, listen.releaseId);
  });

  testWidgets('Escape closes history and H typed in the query never opens it', (tester) async {
    await _surface(tester, FakeCore());
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('history-sheet')), findsNothing);
    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.enterText(find.byType(TextField), 'h');
    await tester.pump();
    expect(find.byKey(const ValueKey('history-sheet')), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'h');
  });

  testWidgets('a stage Pick up row resumes its release without changing a trail', (tester) async {
    final core = _RecordingCore();
    final point = (await core.resumePoints(6)).first;
    await _surface(tester, core);
    await tester.pump();
    final row = find.byKey(ValueKey('now-pick-up-${point.releaseId}'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pump();
    expect(core.pickedUp, [point.releaseId]);
    expect(find.byType(NowStage), findsOneWidget);
    expect(await core.trail(), isNull);
  });

  testWidgets('the bar sheet scrolls its memory and device volume at 360 by 700', (tester) async {
    final core = _RecordingCore();
    await _surface(tester, core, size: const Size(360, 700));
    await _commandKey(tester, LogicalKeyboardKey.digit1);
    await tester.tap(find.byKey(const ValueKey('now-bar-title')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(NowPane), findsOneWidget);
    final pane = find.byType(NowPane);
    expect(find.descendant(of: pane, matching: find.text('Pick up')), findsOneWidget);
    expect(find.descendant(of: pane, matching: find.byType(PlaySomething)), findsOneWidget);
    expect(find.descendant(of: pane, matching: find.text('What was that?')), findsOneWidget);
    final memory = tester.widget<NowMemory>(find.byType(NowMemory));
    expect(memory.resumeLimit, 3);
    expect(memory.historyLimit, 3);
    final volume = find.byKey(const ValueKey('now-volume'));
    await tester.ensureVisible(volume);
    await tester.pump();
    expect(volume.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    final point = (await core.resumePoints(3)).first;
    final pickUp = find.byKey(ValueKey('now-pick-up-${point.releaseId}'));
    await tester.ensureVisible(pickUp);
    await tester.tap(pickUp);
    await tester.pump();
    await tester.pump();
    expect(core.pickedUp, [point.releaseId]);
    expect(tester.widget<NowPane>(find.byType(NowPane)).now!.title, (await core.now().first).title);
  });

  testWidgets('only the latest history attempt borrows the current pause position', (tester) async {
    final core = _RepeatedListenCore();
    await core.transport(const TransportDto.pause());
    await _surface(tester, core);
    await tester.pump();
    final latest = find.byKey(const ValueKey('now-listen-latest'));
    final older = find.byKey(const ValueKey('now-listen-older'));
    expect(find.descendant(of: latest, matching: find.textContaining('paused at 3:46')), findsOneWidget);
    expect(find.descendant(of: older, matching: find.textContaining('skipped at 0:02')), findsOneWidget);
  });

  testWidgets('the stage stands alone below 1000 and its Front doors leave it', (tester) async {
    await _surface(tester, FakeCore(), size: const Size(960, 900));
    expect(find.byType(FrontPane), findsNothing);
    expect(find.byType(NowStage), findsOneWidget);
    tester.view.physicalSize = const Size(1200, 900);
    await tester.pump();
    await tester.pump();
    expect(tester.getSize(find.byType(FrontPane)).width, 480);
    await tester.tap(find.text('Scores'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(NowStage), findsNothing);
    expect(tester.widget<TablePane>(find.byType(TablePane)).query, 'idiom:score');
  });

  testWidgets('on a phone, one pane is visible and Now is a bar', (tester) async {
    final core = FakeCore();
    await _surface(tester, core, size: const Size(400, 860));
    await _commandKey(tester, LogicalKeyboardKey.digit1);
    await _commandKey(tester, LogicalKeyboardKey.keyL);
    final hit = (await core.search('Iona')).people.first;
    await tester.widget<SearchPane>(find.byType(SearchPane)).onFollow!(TargetDto.person(id: hit.id), ThreadKind.matched);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final row = find.byType(PaneRow);
    expect(tester.widget<PaneRow>(row).children, hasLength(2));
    expect(tester.getSize(find.byType(PaneSpine)).width, 46, reason: 'the search folds to a spine');
    expect(tester.getSize(find.ancestor(of: find.byType(PersonPane), matching: find.byType(Pane))).width, 400 - 46);
    expect(find.byType(NowPane), findsNothing);
    expect(find.text('Small Two of Pieces ~Broken Pieces~'), findsOneWidget);
  });

  testWidgets('the body takes the playing release light from Now', (tester) async {
    final core = FakeCore();
    final now = await core.now().first;
    await _surface(tester, core);

    final light = tester.widget<LightScope>(find.byType(LightScope)).light;
    expect(light.accent, Color(now.light!.light));
    expect(light.wash, Colors.transparent);
    expect(light.dim, Color(now.light!.dim));
    expect(light.track, now.trackId!.toInt());
    expect(light.release, now.releaseId!.toInt());
    final body = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((paint) => paint.painter).whereType<BodyPainter>().single;
    expect(body.light, light.accent);
    await core.transport(const TransportDto.pause());
    await tester.pump();
    expect(tester.widget<LightScope>(find.byType(LightScope)).light, light);
  });

  testWidgets('a null Now light leaves the body brass and keeps playing identities', (tester) async {
    final core = _ArtworkCore(NowDto(
      trackId: PlatformInt64Util.from(3),
      releaseId: PlatformInt64Util.from(1),
      title: 'Small Two of Pieces ~Broken Pieces~',
      subtitle: '',
      path: const [],
    ));
    await _surface(tester, core);

    final light = tester.widget<LightScope>(find.byType(LightScope)).light;
    expect(light.accent, Light.brass.accent);
    expect(light.wash, Colors.transparent);
    expect(light.dim, Light.brass.dim);
    expect(light.track, 3);
    expect(light.release, 1);
    final body = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((paint) => paint.painter).whereType<BodyPainter>().single;
    expect(body.light, Tok.gold);
  });

  testWidgets('the release lights the playing row without inventing a cover', (tester) async {
    final core = FakeCore();
    await core.setSettings(const SettingsDto(light: LightLevelDto.accentAndWash, exclusive: true, lookups: LookupsDto.unasked));
    final releaseId = (await core.now().first).releaseId!;
    await core.playRelease(id: releaseId, index: 2);
    final now = await core.now().first;
    await core.startTrail(TargetDto.release(id: now.releaseId!));
    await _surface(tester, core);
    await tester.widget<FrontPane>(find.byType(FrontPane)).onRelease!(now.releaseId!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final row = find.byKey(const ValueKey('release-row-2'));
    final box = tester.widgetList<Container>(find.descendant(of: row, matching: find.byType(Container))).single;
    final decoration = box.decoration! as BoxDecoration;
    expect(decoration.color, Color(now.light!.wash));
    expect((decoration.border! as Border).left, BorderSide(color: Color(now.light!.light), width: 2));
    expect(tester.widget<Text>(find.descendant(of: row, matching: find.text(now.title))).style!.color, Color(now.light!.light));
    expect(find.descendant(of: find.byType(ReleasePane), matching: find.byType(Image)), findsNothing);
    expect(find.descendant(of: find.byType(NowPane), matching: find.byType(Image)), findsNothing);
    expect((await core.release(now.releaseId!)).cover, isNull);
  });

  testWidgets('release and Now draw their cover with a 256 pixel decode', (tester) async {
    final dir = Directory.systemTemp.createTempSync('meret-widget-cover-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/cover.png')..writeAsBytesSync(base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGO4P60IAAQ/AejzxrCDAAAAAElFTkSuQmCC',
    ));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    // Start disk I/O outside the test's fake clock, before Image.file shares it.
    await tester.runAsync(() => precacheImage(
      ResizeImage(FileImage(file), width: 256),
      tester.element(find.byType(SizedBox)),
    ));
    final core = _ArtworkCore(NowDto(
      trackId: PlatformInt64Util.from(3),
      releaseId: PlatformInt64Util.from(1),
      cover: file.path,
      title: 'Small Two of Pieces ~Broken Pieces~',
      subtitle: '',
      path: const [],
    ));
    await core.startTrail(TargetDto.release(id: core.state.releaseId!));
    await _surface(tester, core);
    await tester.widget<FrontPane>(find.byType(FrontPane)).onRelease!(core.state.releaseId!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    for (final pane in [find.byType(ReleasePane), find.byType(NowPane)]) {
      final image = tester.widget<Image>(find.descendant(of: pane, matching: find.byType(Image)));
      final resize = image.image as ResizeImage;
      expect(resize.width, 256);
      expect((resize.imageProvider as FileImage).file.path, file.path);
    }
    expect(tester.widget<Image>(find.descendant(of: find.byType(ReleasePane), matching: find.byType(Image))).width, 120);
    expect(find.descendant(of: find.byType(ReleasePane), matching: find.text('Xenogears Original Soundtrack')), findsOneWidget);
    expect(tester.takeException(), isNull);
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
    expect(find.descendant(of: find.ancestor(of: find.byType(SearchPane), matching: find.byType(Pane)), matching: find.text('idiom:score')), findsOneWidget);
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(1));
  });

  testWidgets('an empty library offers folders and fills after adding', (tester) async {
    final core = FakeCore.empty();
    await _surface(tester, core);

    expect(find.text('Choose a folder…'), findsOneWidget);
    expect(find.byType(TablePane), findsNothing);
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(1));
    expect((await core.rows('', _libraryView, 0, 20)).total, BigInt.zero);

    await core.addRoot('/New music');
    await tester.pump();
    await tester.pump();
    expect(find.text('Choose a folder…'), findsNothing);
    expect(find.text('/New music'), findsOneWidget);
    expect(find.text('Scores'), findsOneWidget);
  });

  testWidgets('Enter opens the canonical search pane and roots its trail', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    await tester.enterText(find.byType(TextField), '  idiom:score  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.widget<TablePane>(find.byType(TablePane)).query, 'idiom:score');
    expect(tester.widget<SearchPane>(find.byType(SearchPane)).query, 'idiom:score');
    final trail = (await core.trail())!;
    expect(trail.stops.single.target, const TargetDto.search(query: 'idiom:score'));
    final painter = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((widget) => widget.painter).whereType<ConstellationPainter>().single;
    expect(painter.semanticsBuilder(const Size(1000, 64)).single.properties.label, 'idiom:score');
    expect(find.byKey(const ValueKey('query-hits')), findsNothing);
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children.cast<Pane>().map((pane) => pane.title), ['idiom:score']);
  });

  testWidgets('the dropdown groups hits, highlights with arrows and closes on Escape', (tester) async {
    final core = FakeCore();
    final hits = await core.search('o');
    await _surface(tester, core);
    await tester.enterText(find.byType(TextField), 'o');
    await tester.pump();
    final dropdown = find.byKey(const ValueKey('query-hits'));
    expect(dropdown, findsOneWidget);
    for (final (label, shown) in [
      ('People · ${hits.peopleTotal}', hits.people.isNotEmpty),
      ('Releases · ${hits.releasesTotal}', hits.releases.isNotEmpty),
      ('Tracks · ${hits.trackHitsTotal}', hits.trackHits.isNotEmpty),
      ('All ${hits.tracks} tracks ↵', true),
    ]) {
      expect(find.descendant(of: dropdown, matching: find.text(label)), shown ? findsOneWidget : findsNothing, reason: label);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(tester.widget<Semantics>(find.byKey(const ValueKey('query-hit-0'))).properties.selected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(tester.widget<Semantics>(find.byKey(const ValueKey('query-hit-1'))).properties.selected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(tester.widget<Semantics>(find.byKey(const ValueKey('query-hit-0'))).properties.selected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(dropdown, findsNothing);
    expect(find.byType(SearchPane), findsNothing);
  });

  testWidgets('commands, invalid input, an empty field and lost focus hide hits', (tester) async {
    await _surface(tester, FakeCore());
    for (final input in ['play o', 'colour:red', 'by:"unclosed', '']) {
      await tester.enterText(find.byType(TextField), 'o');
      await tester.pump();
      expect(find.byKey(const ValueKey('query-hits')), findsOneWidget);
      await tester.enterText(find.byType(TextField), input);
      await tester.pump();
      expect(find.byKey(const ValueKey('query-hits')), findsNothing);
    }
    await tester.enterText(find.byType(TextField), 'o');
    await tester.pump();
    tester.widget<QueryLine>(find.byType(QueryLine)).focus.unfocus();
    await tester.pump();
    expect(find.byKey(const ValueKey('query-hits')), findsNothing);
  });

  testWidgets('late search responses never replace the current dropdown', (tester) async {
    final core = _DelayedSearchCore();
    await _surface(tester, core);
    await tester.enterText(find.byType(TextField), 'o');
    await tester.enterText(find.byType(TextField), 'Iona');
    core.pending.last.$2.complete(await core.result('Iona'));
    await tester.pump();
    expect(find.text('People · 1'), findsOneWidget);
    core.pending.first.$2.complete(await core.result('o'));
    await tester.pump();
    expect(find.text('People · 1'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('query-hits')), matching: find.text('Open Sky')), findsNothing);
  });

  testWidgets('the highlighted all-tracks line opens the search rather than a person', (tester) async {
    await _surface(tester, FakeCore());
    await tester.enterText(find.byType(TextField), 'Iona');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SearchPane), findsOneWidget);
    expect(tester.widget<TablePane>(find.byType(TablePane)).query, 'Iona');
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(1));
  });

  testWidgets('a highlighted person opens to the right of the rooted search', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    await tester.enterText(find.byType(TextField), 'Iona');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widgetList<TablePane>(find.byType(TablePane)).map((table) => table.query), ['Iona']);
    expect(find.byType(PersonPane), findsOneWidget);
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(2));
    final trail = (await core.trail())!;
    expect(trail.stops.first.target, const TargetDto.search(query: 'Iona'));
    expect(trail.stops.last.target, isA<TargetDto_Person>());
  });

  testWidgets('clicking a release hit opens the search then its release pane', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    await tester.enterText(find.byType(TextField), 'Open');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('query-hit-0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widgetList<TablePane>(find.byType(TablePane)).map((table) => table.query), ['Open']);
    final release = tester.widget<ReleasePane>(find.byType(ReleasePane));
    final trail = (await core.trail())!;
    expect(trail.stops.first.target, const TargetDto.search(query: 'Open'));
    expect(trail.stops.last.target, TargetDto.release(id: release.id));
    expect(trail.stops.last.title, 'Open Sky');
    expect(trail.stops.last.via, 'matched');
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(2));
  });

  testWidgets('a person in the search strip follows without starting another trail', (tester) async {
    final core = FakeCore();
    final hit = (await core.search('Iona')).people.single;
    await _surface(tester, core);
    await tester.enterText(find.byType(TextField), 'Iona');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final trail = await core.trail();
    await tester.tap(find.byKey(ValueKey('search-hit-person-${hit.id}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widgetList<TablePane>(find.byType(TablePane)).map((table) => table.query), ['Iona']);
    expect(find.byType(PersonPane), findsOneWidget);
    final followed = (await core.trail())!;
    expect(followed.rootQuery, trail!.rootQuery);
    expect(followed.stops.first.target, trail.stops.first.target);
    expect(followed.stops.last.target, TargetDto.person(id: hit.id));
  });

  testWidgets('Enter on a track hit plays its result index without changing the trail', (tester) async {
    final core = _RecordingCore();
    final hits = await core.search('Woman Of Wisdom');
    final hit = hits.trackHits.first;
    final trail = await core.trail();
    await _surface(tester, core);
    await tester.enterText(find.byType(TextField), 'Woman Of Wisdom');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(core.played, [(hit.query, hit.index!.toInt())]);
    expect(find.descendant(of: find.byType(NowPane), matching: find.text('Woman Of Wisdom')), findsOneWidget);
    expect(find.byKey(const ValueKey('query-hits')), findsNothing);
    expect(find.byType(SearchPane), findsNothing);
    expect(await core.trail(), trail);
  });

  test('fake search totals, paging and hit indices describe the same result', () async {
    final core = FakeCore();
    final hits = await core.search('wómán of wisdom');
    expect(hits.people, isEmpty);
    expect(hits.releases, isEmpty);
    expect(hits.trackHits, hasLength(8));
    final rows = await core.rows(hits.query, _libraryView, 0, 8);
    expect(rows.total, hits.tracks);
    expect((rows.items.first as ItemDto_Track).row.title, hits.trackHits.first.title);
    expect(hits.trackHits.first.index, BigInt.zero);
    expect(hits.trackHitsTotal, hits.tracks);
    expect((await core.search('ona')).tracks, BigInt.zero);
    expect((await core.search('by:mitsuda')).people.single.title, 'Yasunori Mitsuda');
    final empty = await FakeCore.empty().search('Iona');
    expect(empty.tracks, BigInt.zero);
    expect([...empty.people, ...empty.releases, ...empty.trackHits], isEmpty);
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
    expect(tester.widget<NowStage>(find.byType(NowStage)).now.title, 'The Beginning and the End');
    expect(find.byType(TablePane), findsNothing);
  });

  testWidgets('Command-L roots Everything; Command-1 shows the Front over the trail and ] returns', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    await _commandKey(tester, LogicalKeyboardKey.keyL);
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(1));
    expect(find.byType(FrontPane), findsNothing, reason: 'the Front is not a pane beside a trail');
    expect(tester.widget<TablePane>(find.byType(TablePane)).query, '');
    final trail = await core.trail();
    expect(trail!.stops.single.target, const TargetDto.search(query: ''));

    await _commandKey(tester, LogicalKeyboardKey.digit1);
    expect(find.byType(FrontPane), findsOneWidget);
    expect(find.byType(TablePane), findsNothing);
    expect(find.textContaining('back to Everything'), findsOneWidget);
    expect(find.byType(TrailStrip), findsOneWidget, reason: 'the trail stays open behind the Front');
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(TablePane), findsOneWidget);
    expect(find.byType(FrontPane), findsNothing);
    expect(await core.trail(), same(trail));

    await _commandKey(tester, LogicalKeyboardKey.digit1);
    expect(find.byType(FrontPane), findsOneWidget);
    await _commandKey(tester, LogicalKeyboardKey.digit1);
    expect(find.byType(FrontPane), findsNothing, reason: 'Command-1 toggles');
    expect(tester.widget<TablePane>(find.byType(TablePane)).query, '');
  });

  testWidgets('the Front reloads on a library revision but not on an unchanged one', (tester) async {
    final core = _RecordingCore();
    Widget front(BigInt version) => MaterialApp(home: Scaffold(body: FrontPane(core: core, memoryVersion: 0, libraryVersion: version, onQuery: (_) {})));
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
      memoryVersion: 0,
      jobs: [JobDto(verb: 'reading tags', done: BigInt.from(5), total: BigInt.from(10))],
      onQuery: (_) {},
    ))));
    await tester.pumpAndSettle();
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.5);
    expect(find.text('Choose a folder…'), findsOneWidget);
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

  testWidgets('the table starts grouped and its headers cycle the view', (tester) async {
    final core = _RecordingCore();
    final group = (await FakeCore().rows('', _groupedView, 0, 1)).items.single as ItemDto_Group;
    await tester.pumpWidget(_table(core));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey('table-row-0')), matching: find.text(group.field0.title)), findsOneWidget);
    expect(find.byKey(const ValueKey('table-sort-album')), findsNothing);
    expect(core.views.single, _groupedView);

    await tester.tap(find.byKey(const ValueKey('table-sort-title')));
    await tester.pumpAndSettle();
    expect(core.views.last, const ViewDto(sort: SortKeyDto.title, descending: false, group: true));
    expect(find.text('Title ↑'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('table-sort-title')));
    await tester.pumpAndSettle();
    expect(core.views.last, const ViewDto(sort: SortKeyDto.title, descending: true, group: true));
    expect(find.text('Title ↓'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('table-sort-title')));
    await tester.pumpAndSettle();
    expect(core.views.last, _groupedView);
    expect(core.offsets, [0, 0, 0, 0]);

    await tester.tap(find.byKey(const ValueKey('table-group-false')));
    await tester.pumpAndSettle();
    expect(core.views.last, _libraryView);
    expect(find.byKey(const ValueKey('table-sort-album')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('table-sort-album')));
    await tester.pumpAndSettle();
    expect(core.views.last, const ViewDto(sort: SortKeyDto.album, descending: false, group: false));
    await tester.tap(find.byKey(const ValueKey('table-sort-library_')));
    await tester.pumpAndSettle();
    expect(core.views.last, _libraryView);
  });

  testWidgets('facet entries and All use the queries supplied by the core', (tester) async {
    final core = FakeCore();
    const query = 'idiom:score by:"Yasunori Mitsuda"';
    final facets = await core.facets(query);
    final selected = facets.people.entries.firstWhere((entry) => entry.selected);
    final queries = <String>[];
    await tester.pumpWidget(_table(core, query: query, onQuery: queries.add));
    await tester.pumpAndSettle();
    final entry = find.byKey(ValueKey('facet-People-${selected.id}'));
    expect(tester.widget<Semantics>(entry).properties.selected, isTrue);
    await tester.tap(entry);
    expect(queries.last, selected.query);
    await tester.tap(find.byKey(const ValueKey('facet-People-all')));
    expect(queries.last, facets.people.allQuery);
    final idiom = facets.idioms.entries.first;
    await tester.tap(find.byKey(ValueKey('facet-Idiom-${idiom.id}')));
    expect(queries.last, idiom.query);
  });

  testWidgets('Enter on a group uses its first track ordinal, not its item index', (tester) async {
    final core = _RecordingCore();
    final page = await FakeCore().rows('', _groupedView, 0, 1);
    final first = (page.items.single as ItemDto_Group).field0;
    final index = first.tracks + 1;
    await tester.pumpWidget(_table(core));
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(find.byKey(const ValueKey('table-rows')));
    list.controller!.jumpTo(index * 26);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('table-row-$index')));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(core.played, [('', first.tracks)]);
    expect(core.playedViews.single, _groupedView);
    final header = find.byKey(ValueKey('table-row-$index'));
    await tester.tap(header);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(core.played, [('', first.tracks), ('', first.tracks)]);
    expect(core.playedViews.last, _groupedView);
  });

  testWidgets('the playing track row uses the scoped light', (tester) async {
    final core = FakeCore();
    final page = await core.rows('', _groupedView, 1, 1);
    final row = (page.items.single as ItemDto_Track).row;
    final light = Light(accent: const Color(0xFF90AACC), wash: const Color(0x1490AACC), track: row.trackId.toInt());
    await tester.pumpWidget(_table(core, light: light));
    await tester.pumpAndSettle();
    final playing = find.byKey(const ValueKey('table-row-1'));
    final box = tester.widget<Container>(find.descendant(of: playing, matching: find.byType(Container)).first);
    expect((box.decoration as BoxDecoration).color, light.wash);
    expect(((box.decoration as BoxDecoration).border as Border).left.color, light.accent);
    final title = tester.widget<Text>(find.descendant(of: playing, matching: find.text(row.title)));
    expect(title.style!.color, light.accent);
  });

  testWidgets('the table fetches only pages near the viewport', (tester) async {
    final core = _RecordingCore();
    await tester.pumpWidget(_table(core));
    await tester.pumpAndSettle();

    expect(find.text('8 releases · 48210 tracks · sorted by library order'), findsOneWidget);
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
    expect(core.played, [('', 2)]);
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
    expect(core.played, [('', 3)]);
  });

  testWidgets('the table refetches when query or library version changes', (tester) async {
    final core = _RecordingCore();
    await tester.pumpWidget(_table(core, libraryVersion: BigInt.one));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_table(core, query: 'year:1990..1999', libraryVersion: BigInt.one));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_table(core, query: 'year:1990..1999', libraryVersion: BigInt.two));
    await tester.pumpAndSettle();
    expect(core.offsets, [0, 0, 0]);
  });

  testWidgets('the table shows row errors without crashing', (tester) async {
    await tester.pumpWidget(_table(_InvalidCore()));
    await tester.pumpAndSettle();
    expect(find.text('Invalid query'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('album and artist cells open typed panes and their titles stay on the strip', (tester) async {
    final core = FakeCore();
    final row = await _firstTrack(core);
    await _surface(tester, core);
    await _commandKey(tester, LogicalKeyboardKey.keyL);
    await tester.tap(find.byKey(ValueKey('table-release-${row.releaseId}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_paneTitles(tester), ['Everything', row.album]);
    expect(tester.widget<ReleasePane>(find.byType(ReleasePane)).id, row.releaseId);

    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(ValueKey('table-group-artist-${row.releaseId}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_paneTitles(tester), ['Everything', row.artist]);
    expect(tester.widget<PersonPane>(find.byType(PersonPane)).id, row.artistId);
    final trail = (await core.trail())!;
    expect(trail.stops.map((stop) => stop.title), ['Everything', row.album, row.artist]);
    final labels = _trailPainter(tester).semanticsBuilder(const Size(1000, 64)).map((node) => node.properties.label);
    expect(labels, containsAll(['Everything', row.album, row.artist]));
  });

  testWidgets('following from an earlier pane branches and replaces its later panes', (tester) async {
    final core = FakeCore();
    final row = await _firstTrack(core);
    await _surface(tester, core);
    await _commandKey(tester, LogicalKeyboardKey.keyL);
    await tester.tap(find.byKey(ValueKey('table-release-${row.releaseId}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    final release = await core.release(row.releaseId);
    final credit = release.credits.first;
    await tester.tap(find.byKey(ValueKey('thread-${credit.kind.name}-${credit.to}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_paneTitles(tester), ['Everything', row.album, credit.title]);

    final other = release.credits.firstWhere((thread) => thread.to != credit.to);
    await tester.widget<SearchPane>(find.byType(SearchPane)).onFollow!(other.to, other.kind);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_paneTitles(tester), ['Everything', other.title]);
    expect(find.byType(ReleasePane), findsNothing);
    final trail = (await core.trail())!;
    expect(trail.stops.where((stop) => !stop.onPath), hasLength(2));
    expect(trail.stops.first.isFork, isTrue);
  });

  testWidgets('back and forward round trip, then back at the root shows only Front', (tester) async {
    final core = FakeCore();
    final row = await _firstTrack(core);
    await _surface(tester, core);
    await _commandKey(tester, LogicalKeyboardKey.keyL);
    await tester.tap(find.byKey(ValueKey('table-release-${row.releaseId}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_paneTitles(tester), ['Everything']);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_paneTitles(tester), ['Everything', row.album]);
    for (var i = 0; i < 2; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children, hasLength(1));
    expect(find.byType(FrontPane), findsOneWidget);
  });

  testWidgets('a release row and Enter play the release from that index', (tester) async {
    final core = _RecordingCore();
    final row = await _firstTrack(core);
    await core.startTrail(TargetDto.release(id: row.releaseId));
    await _surface(tester, core);
    await tester.widget<FrontPane>(find.byType(FrontPane)).onRelease!(row.releaseId);
    await tester.pump();
    final credit = (await core.release(row.releaseId)).credits.first;
    await tester.widget<ReleasePane>(find.byType(ReleasePane)).onFollow(credit.to, credit.kind, credit.provider);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('release-row-2')));
    await tester.pump();
    expect(core.releasesPlayed, [(row.releaseId.toInt(), 2, 0)]);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(core.releasesPlayed, [(row.releaseId.toInt(), 2, 0), (row.releaseId.toInt(), 2, 0)]);
    await tester.tap(find.byKey(const ValueKey('release-play')));
    await tester.pump();
    expect(core.releasesPlayed.last, (row.releaseId.toInt(), 0, 0));
    expect((await core.trail())!.current, 1);
  });

  testWidgets('tag work links open recordings, play them and connect a composer’s roles and works', (tester) async {
    final core = _RecordingCore();
    final row = await _firstTrack(core);
    final release = await core.release(row.releaseId);
    final workThread = release.rowWorks.first!;
    final workId = (workThread.to as TargetDto_Work).id;
    await core.startTrail(TargetDto.release(id: release.id));
    await _surface(tester, core);
    await tester.widget<FrontPane>(find.byType(FrontPane)).onRelease!(release.id);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const ValueKey('release-work-0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<WorkPane>(find.byType(WorkPane)).id, workId);
    expect(core.releasesPlayed, isEmpty, reason: 'the work link does not play its release row');
    final work = await core.work(workId);
    await tester.tap(find.byKey(const ValueKey('work-row-0')));
    await tester.pump();
    expect(core.worksPlayed, [(workId, 0)]);
    expect((await core.now().first).trackId, work.rows.first.trackId);

    await tester.tap(find.byKey(ValueKey('work-album-${work.rows.first.trackId}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect((await core.trail())!.stops.firstWhere((stop) => stop.onPath && stop.index == 0).target,
      TargetDto.release(id: release.id));
    expect(find.byType(WorkPane), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final composer = work.composerLinks.single;
    await tester.tap(find.descendant(of: find.byType(WorkPane),
      matching: find.byKey(ValueKey('thread-${composer.kind.name}-${composer.to}'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final person = await core.person((composer.to as TargetDto_Person).id);
    expect(find.descendant(of: find.byType(PersonPane), matching: find.text(person.roles.single.title)), findsOneWidget);
    final role = person.roles.single.threads.single;
    expect(find.descendant(of: find.byType(PersonPane),
      matching: find.byKey(ValueKey('thread-${role.kind.name}-${role.to}'))), findsOneWidget);
    final personWork = person.works.single;
    await tester.tap(find.descendant(of: find.byType(PersonPane),
      matching: find.byKey(ValueKey('thread-${personWork.kind.name}-${personWork.to}'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<WorkPane>(find.byType(WorkPane)).id, workId);
    final trail = (await core.trail())!;
    expect(trail.stops.firstWhere((stop) => stop.index == trail.current).target, workThread.to);
  });

  testWidgets('Command-Enter follows the selected table row and a strip star goes back', (tester) async {
    final core = FakeCore();
    final row = await _firstTrack(core);
    await _surface(tester, core);
    await _commandKey(tester, LogicalKeyboardKey.keyL);
    await tester.tapAt(tester.getTopLeft(find.byKey(const ValueKey('table-row-0'))) + const Offset(8, 13));
    await _commandKey(tester, LogicalKeyboardKey.enter);
    expect(_paneTitles(tester), ['Everything', row.album]);
    await tester.tap(find.byKey(const ValueKey('trail-stop-0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_paneTitles(tester), ['Everything']);
    expect((await core.trail())!.current, 0);
  });

  test('fake releases, people, recent doors and hits share row identities', () async {
    final core = FakeCore();
    final row = await _firstTrack(core, offset: 2);
    final release = await core.release(row.releaseId);
    final person = await core.person(row.artistId!);
    expect(release.title, row.album);
    expect(release.rows.every((track) => track.releaseId == release.id), isTrue);
    expect(person.name, row.artist);
    expect(person.appearsOn.single.to, TargetDto.release(id: row.releaseId));
    expect(person.workedWith, isNotEmpty);
    final hit = (await core.search(row.artist!)).people.single;
    expect(hit.id, row.artistId);
    for (final recent in (await core.front()).addedLately) {
      expect((await core.release(recent.releaseId)).title, recent.title);
    }
    await expectLater(FakeCore.empty().release(row.releaseId), throwsA(isA<String>()));
  });

}

Future<void> _surface(WidgetTester tester, CoreBridge core, {Size size = const Size(2560, 1440)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MeretApp(core: core));
  await tester.pump();
  await tester.pump();
}

List<String> _paneTitles(WidgetTester tester) => tester.widget<PaneRow>(find.byType(PaneRow)).children.cast<Pane>().map((pane) => pane.title).toList();

ConstellationPainter _trailPainter(WidgetTester tester) => tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((widget) => widget.painter).whereType<ConstellationPainter>().single;

Future<void> _commandKey(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _shiftSpace(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.space);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pump();
  await tester.pump();
}

Future<TrackRowDto> _firstTrack(CoreBridge core, {int offset = 0}) async =>
    ((await core.rows('', _libraryView, offset, 1)).items.single as ItemDto_Track).row;

Widget _table(CoreBridge core, {String query = '', BigInt? libraryVersion, ValueChanged<String>? onQuery, Light light = Light.brass}) => MaterialApp(
  home: Scaffold(body: LightScope(light: light, child: TablePane(core: core, query: query, libraryVersion: libraryVersion, onQuery: onQuery ?? (_) {}))),
);

BoxDecoration _zoneMarker(WidgetTester tester, String device) =>
  tester.widget<Container>(find.byKey(ValueKey('now-zone-marker-local:$device'))).decoration! as BoxDecoration;

class _ZonesCore extends FakeCore {
  final outputs = <String>[];

  @override
  Future<void> playOn(String zone) {
    outputs.add(zone);
    return super.playOn(zone);
  }
}

class _FailingZoneCore extends _ZonesCore {
  @override
  Future<void> playOn(String zone) async {
    outputs.add(zone);
    throw 'The DAC is unavailable.';
  }
}

class _RecordingCore extends FakeCore {
  _RecordingCore();
  _RecordingCore.empty() : super.empty();

  int playSomethingCalls = 0;
  final pickLimits = <int>[];

  @override
  Future<PickDto?> playSomething() {
    playSomethingCalls++;
    return super.playSomething();
  }

  final picksPlayed = <PlatformInt64>[];

  @override
  Future<PickDto> playPick(PlatformInt64 releaseId) {
    picksPlayed.add(releaseId);
    return super.playPick(releaseId);
  }

  @override
  Future<List<PickDto>> picks(int limit) {
    pickLimits.add(limit);
    return super.picks(limit);
  }

  final offsets = <int>[];
  final played = <(String, int)>[];
  final views = <ViewDto>[];
  final playedViews = <ViewDto>[];
  int frontCalls = 0;
  final releasesPlayed = <(int, int, int?)>[];
  final worksPlayed = <(PlatformInt64, int)>[];
  final seeks = <BigInt>[];
  final transports = <TransportDto>[];
  final started = <TargetDto>[];
  final pickedUp = <PlatformInt64>[];
  final historyLimits = <int>[];

  @override
  Future<TrailDto> startTrail(TargetDto to) {
    started.add(to);
    return super.startTrail(to);
  }

  @override
  Future<void> pickUp(PlatformInt64 releaseId) {
    pickedUp.add(releaseId);
    return super.pickUp(releaseId);
  }

  @override
  Future<List<ListenDto>> history(int limit) {
    historyLimits.add(limit);
    return super.history(limit);
  }

  @override
  Future<void> transport(TransportDto cmd) {
    transports.add(cmd);
    if (cmd case TransportDto_Seek(:final ms)) seeks.add(ms);
    return super.transport(cmd);
  }

  @override
  Future<FrontDto> front() {
    frontCalls++;
    return super.front();
  }

  @override
  Future<RowsDto> rows(String query, ViewDto view, int offset, int limit) {
    offsets.add(offset);
    views.add(view);
    return super.rows(query, view, offset, limit);
  }

  @override
  Future<void> playResults(String query, ViewDto view, int index) {
    played.add((query, index));
    playedViews.add(view);
    return super.playResults(query, view, index);
  }
  @override
  Future<void> playRelease({required PlatformInt64 id, required int index, int? fromStop}) {
    releasesPlayed.add((id.toInt(), index, fromStop));
    return super.playRelease(id: id, index: index, fromStop: fromStop);
  }

  @override
  Future<void> playWork(PlatformInt64 id, int index) {
    worksPlayed.add((id, index));
    return super.playWork(id, index);
  }

}

class _InvalidCore extends FakeCore {
  @override
  Future<RowsDto> rows(String query, ViewDto view, int offset, int limit) async => throw 'Invalid query';
}

class _DelayedSearchCore extends FakeCore {
  final pending = <(String, Completer<SearchDto>)>[];

  @override
  Future<SearchDto> search(String input) {
    final completer = Completer<SearchDto>();
    pending.add((input, completer));
    return completer.future;
  }

  Future<SearchDto> result(String input) => super.search(input);
}

class _ArtworkCore extends FakeCore {
  _ArtworkCore(this.state);
  final NowDto state;

  @override
  Stream<NowDto> now() => Stream.value(state);

  @override
  Future<ReleaseDto> release(PlatformInt64 id) async {
    final release = await super.release(id);
    return ReleaseDto(
      id: release.id,
      title: release.title,
      cover: state.cover,
      artist: release.artist,
      artistLinks: release.artistLinks,
      year: release.year,
      idiom: release.idiom,
      tracks: release.tracks,
      discs: release.discs,
      lengthMs: release.lengthMs,
      formats: release.formats,
      rows: release.rows,
      rowWorks: release.rowWorks,
      credits: release.credits,
      plays: release.plays,
      lastPlayedMs: release.lastPlayedMs,
    );
  }
}

class _FixedVolumeCore extends FakeCore {
  @override
  Future<VolumeDto> volume() async => const VolumeDto(
    settable: false, reason: 'Use the amplifier on this output.',
  );
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

class _RepeatedListenCore extends FakeCore {
  @override
  Future<List<ListenDto>> history(int limit) async {
    final listen = (await super.history(1)).single;
    return [
      for (final (uid, played) in [('latest', 0), ('older', 2000)])
        ListenDto(
          uid: uid, trackId: listen.trackId, recordingId: listen.recordingId,
          releaseId: listen.releaseId, title: listen.title, credit: listen.credit,
          releaseTitle: listen.releaseTitle, startedAtMs: listen.startedAtMs,
          playedMs: BigInt.from(played), lengthMs: listen.lengthMs, counted: false,
        ),
    ].take(limit).toList();
  }
}
