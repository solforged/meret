import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64, PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/home/week.dart';
import 'package:meret/home/today.dart';

void main() {
  for (final width in [1600.0, 800.0]) {
    testWidgets('Today lists what is partway, added lately and your week at ${width.toInt()} wide', (tester) async {
      _size(tester, width);
      final core = _MemoryCore();
      final resumes = await core.resumePoints(6);
      core.calls.clear();
      await _today(tester, core);

      for (final heading in ['Or play something', 'Pick up', 'Added lately', 'Your week', 'Most played this week', 'Dormant']) {
        expect(find.text(heading), findsOneWidget, reason: heading);
      }
      expect(find.text('14 plays'), findsOneWidget);
      expect(find.text('Sunday at the Village Vanguard'), findsOneWidget);
      for (final resume in resumes) {
        final row = find.byKey(ValueKey('now-pick-up-${resume.releaseId}'));
        expect(find.descendant(of: row, matching: find.text(resume.recordingTitle)), findsOneWidget);
      }
      // Plumbing never gets a door: no folders, formats or trails on Today.
      for (final gone in ['Folders', 'By format', 'Kept trails', 'Trails']) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      final listen = tester.getTopLeft(find.text('Or play something'));
      final recent = tester.getTopLeft(find.text('Added lately'));
      if (width >= 900) {
        expect(recent.dx, greaterThan(listen.dx));
      } else {
        expect(recent.dx, listen.dx);
        expect(recent.dy, greaterThan(listen.dy));
      }
      expect(core.calls, containsAll(['resume:6', 'history:500', 'most:7:3', 'dormant:3']));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Pick up resumes without starting a trail', (tester) async {
    _size(tester, 1600);
    final core = _MemoryCore();
    final point = (await core.resumePoints(6)).first;
    await _today(tester, core);
    await _tap(tester, find.byKey(ValueKey('now-pick-up-${point.releaseId}')));
    expect(core.pickedUp, [point.releaseId]);
    expect((await core.now().first).releaseId, point.releaseId);
    expect(await core.trail(), isNull);
  });

  testWidgets('Most played and Dormant open their releases', (tester) async {
    _size(tester, 1600);
    final core = _MemoryCore();
    final played = (await core.mostPlayed(7, 3)).first;
    final dormant = (await core.dormant(3)).first;
    await _today(tester, core);
    await _tap(tester, find.byKey(ValueKey('today-most-played-${played.trackId}')));
    expect((await core.trail())!.stops.single.target, TargetDto.release(id: played.releaseId));
    await _tap(tester, find.byKey(ValueKey('today-dormant-${dormant.releaseId}')));
    expect(core.startedTargets.last, TargetDto.release(id: dormant.releaseId));
  });

  testWidgets('Today without memory offers only the picks and what was added', (tester) async {
    _size(tester, 1600);
    final core = _MemoryCore()..blankMemory = true;
    await _today(tester, core);
    expect(find.text('Or play something'), findsOneWidget);
    for (final heading in ['Pick up', 'Your week', 'Most played this week', 'Dormant']) {
      expect(find.text(heading), findsNothing);
    }
  });

  test('Your week sums played time by weekday over seven local calendar days', () {
    final now = DateTime(2026, 10, 17, 12);
    final history = [
      _listen(DateTime(2026, 10, 11), 60000),
      _listen(DateTime(2026, 10, 12, 10), 60000),
      _listen(DateTime(2026, 10, 12, 23, 59), 90000, counted: false),
      _listen(DateTime(2026, 10, 13), 120000),
      _listen(DateTime(2026, 10, 14), 180000),
      _listen(DateTime(2026, 10, 15), 240000),
      _listen(DateTime(2026, 10, 16), 300000),
      _listen(DateTime(2026, 10, 17, 23, 59), 360000),
      _listen(DateTime(2026, 10, 10, 23, 59), 999999),
      _listen(DateTime(2026, 10, 18), 999999),
    ];
    expect(listeningByWeekday(history, now: now), [150000, 120000, 180000, 240000, 300000, 360000, 60000]);
  });

  testWidgets('Your week draws Monday–Sunday sums, total and today', (tester) async {
    _size(tester, 1600);
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day);
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    final core = _MemoryCore()..listens = [
      _listen(midnight, 60000),
      _listen(midnight, 120000, counted: false),
      _listen(yesterday, 60000),
    ];
    await _today(tester, core);
    expect(find.text('this week · 4 min'), findsOneWidget);
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    for (final day in weekdays) {
      expect(find.text(day), findsOneWidget);
    }
    final today = tester.widget<Container>(find.byKey(ValueKey('today-log-${now.weekday}')));
    final previous = tester.widget<Container>(find.byKey(ValueKey('today-log-${yesterday.weekday}')));
    expect(today.constraints!.maxHeight, 48);
    expect(previous.constraints!.maxHeight, 16);
    expect(find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == '${weekdays[now.weekday - 1]} · today' && widget.properties.value == '3 min'), findsOneWidget);
  });

  testWidgets('memory revisions reload the week without rereading the Front', (tester) async {
    _size(tester, 1600);
    final core = _MemoryCore();
    await _today(tester, core);
    expect(core.frontCalls, 1);
    final week = core.calls.where((call) => !call.startsWith('resume')).length;
    await _today(tester, core);
    expect(core.calls.where((call) => !call.startsWith('resume')).length, week);
    core.calls.clear();
    await _today(tester, core, memoryVersion: 1);
    expect(core.frontCalls, 1);
    expect(core.calls, ['history:500', 'most:7:3', 'dormant:3']);
    await _today(tester, core, memoryVersion: 1, libraryVersion: BigInt.two);
    expect(core.frontCalls, 2);
  });

  testWidgets('week requests start together and older generations cannot replace newer ones', (tester) async {
    _size(tester, 1600);
    final core = _DelayedCore();
    await _today(tester, core, settle: false);
    expect(find.text('Reading your week…'), findsOneWidget);
    await _today(tester, core, memoryVersion: 1, settle: false);
    final day = DateTime.now();
    core.requests[1].complete([_listen(DateTime(day.year, day.month, day.day), 120000)]);
    await tester.pumpAndSettle();
    expect(find.text('this week · 2 min'), findsOneWidget);
    core.requests[0].complete([_listen(DateTime(day.year, day.month, day.day), 600000)]);
    await tester.pumpAndSettle();
    expect(find.text('this week · 2 min'), findsOneWidget);
    expect(find.text('this week · 10 min'), findsNothing);
  });
}

void _size(WidgetTester tester, double width) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _today(WidgetTester tester, _MemoryCore core, {int memoryVersion = 0, BigInt? libraryVersion, bool settle = true}) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: Today(
    core: core,
    memoryVersion: memoryVersion,
    libraryVersion: libraryVersion,
    onRelease: (id) async { await core.startTrail(TargetDto.release(id: id)); },
  ))));
  settle ? await tester.pumpAndSettle() : await tester.pump();
}

Future<void> _tap(WidgetTester tester, Finder row) async {
  await tester.ensureVisible(row);
  await tester.tap(row);
  await tester.pumpAndSettle();
}

ListenDto _listen(DateTime at, int playedMs, {bool counted = true}) => ListenDto(
  uid: '${at.millisecondsSinceEpoch}-$playedMs',
  recordingId: PlatformInt64Util.from(1),
  title: 'A recording',
  startedAtMs: PlatformInt64Util.from(at.millisecondsSinceEpoch),
  playedMs: BigInt.from(playedMs),
  counted: counted,
);

class _MemoryCore extends FakeCore {
  final calls = <String>[];
  final pickedUp = <PlatformInt64>[];
  final openedTrails = <String>[];
  final startedTargets = <TargetDto>[];
  int frontCalls = 0;
  bool blankMemory = false;
  List<ListenDto>? listens;

  @override
  Future<FrontDto> front() {
    frontCalls++;
    return super.front();
  }

  @override
  Future<List<TrailSummaryDto>> trailHistory(int limit) {
    calls.add('trails:$limit');
    return blankMemory ? Future.value([]) : super.trailHistory(limit);
  }

  @override
  Future<List<ResumeDto>> resumePoints(int limit) {
    calls.add('resume:$limit');
    return blankMemory ? Future.value([]) : super.resumePoints(limit);
  }

  @override
  Future<List<ListenDto>> history(int limit) {
    calls.add('history:$limit');
    if (blankMemory) return Future.value([]);
    final rows = listens;
    return rows == null ? super.history(limit) : Future.value(rows);
  }

  @override
  Future<List<PlayedDto>> mostPlayed(int days, int limit) {
    calls.add('most:$days:$limit');
    return blankMemory ? Future.value([]) : super.mostPlayed(days, limit);
  }

  @override
  Future<List<DormantDto>> dormant(int limit) {
    calls.add('dormant:$limit');
    return blankMemory ? Future.value([]) : super.dormant(limit);
  }

  @override
  Future<void> pickUp(PlatformInt64 releaseId) {
    pickedUp.add(releaseId);
    return super.pickUp(releaseId);
  }

  @override
  Future<TrailDto> startTrail(TargetDto to) {
    startedTargets.add(to);
    return super.startTrail(to);
  }

  @override
  Future<TrailDto> openTrail(String uid) {
    openedTrails.add(uid);
    return super.openTrail(uid);
  }
}

class _DelayedCore extends _MemoryCore {
  final requests = <Completer<List<ListenDto>>>[];

  @override
  Future<List<ListenDto>> history(int limit) {
    calls.add('history:$limit');
    if (limit == 0) return Future.value([]);
    final request = Completer<List<ListenDto>>();
    requests.add(request);
    return request.future;
  }
}
