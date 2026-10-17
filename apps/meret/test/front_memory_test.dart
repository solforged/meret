import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64, PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/core/when.dart';
import 'package:meret/panes/front_memory.dart';
import 'package:meret/panes/front_pane.dart';

void main() {
  for (final width in [1600.0, 1100.0]) {
    testWidgets('the populated Front remembers at ${width.toInt()} wide', (tester) async {
      _size(tester, width);
      final core = _MemoryCore();
      await _keep(core);
      final resumes = await core.resumePoints(4);
      core.calls.clear();
      await _front(tester, core);

      for (final heading in ['Kept trails', 'Pick up', 'Your log', 'Most played this week', 'Dormant']) {
        expect(find.text(heading), findsOneWidget);
      }
      expect(find.text('A kept trail'), findsOneWidget);
      expect(find.text('14 plays'), findsOneWidget);
      expect(find.text('Sunday at the Village Vanguard'), findsOneWidget);
      expect(find.text('loved, then left'), findsOneWidget);
      for (final resume in resumes) {
        final row = find.byKey(ValueKey('front-pick-up-${resume.releaseId}'));
        expect(find.descendant(of: row, matching: find.text(resume.recordingTitle)), findsOneWidget);
        expect(find.descendant(of: row, matching: find.text('${clockLength(resume.positionMs.toInt())} of ${clockLength(resume.lengthMs!.toInt())}')), findsOneWidget);
      }
      expect(find.text('Leads'), findsOneWidget);
      expect(find.text('Music to follow'), findsOneWidget);
      expect(find.text('Wants'), findsOneWidget);
      expect(find.text('Crates'), findsOneWidget);
      final memory = tester.getTopLeft(find.text('Kept trails'));
      final recent = tester.getTopLeft(find.text('Added lately'));
      if (width >= 1200) {
        expect(memory.dx, greaterThan(recent.dx));
        expect(memory.dy, recent.dy);
      } else {
        expect(memory.dx, recent.dx);
        expect(memory.dy, greaterThan(tester.getTopLeft(find.text('Folders')).dy));
      }
      expect(tester.getTopLeft(find.text('Leads')).dy, greaterThan(tester.getTopLeft(find.text('Dormant')).dy));
      expect(core.calls, ['trails:20', 'resume:4', 'history:500', 'most:7:3', 'dormant:3']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Pick up resumes without starting a trail', (tester) async {
    _size(tester, 1600);
    final core = _MemoryCore();
    final point = (await core.resumePoints(4)).first;
    await _front(tester, core);
    await _tap(tester, find.byKey(ValueKey('front-pick-up-${point.releaseId}')));
    expect(core.pickedUp, [point.releaseId]);
    expect((await core.now().first).releaseId, point.releaseId);
    expect(await core.trail(), isNull);
  });

  testWidgets('a kept trail opens at its saved stop and stays kept', (tester) async {
    _size(tester, 1600);
    final core = _MemoryCore();
    final kept = await _keep(core);
    await core.startTrail(const TargetDto.search(query: 'year:2002'));
    await _front(tester, core);
    await _tap(tester, find.byKey(ValueKey('front-trail-${kept.uid}')));
    expect(core.openedTrails, [kept.uid]);
    final active = (await core.trail())!;
    expect(active.kept, isTrue);
    expect(active.name, 'A kept trail');
    expect(active.stops.single.target, const TargetDto.search(query: 'year:2000'));
  });

  testWidgets('Most played and Dormant open their releases', (tester) async {
    _size(tester, 1600);
    final core = _MemoryCore();
    final played = (await core.mostPlayed(7, 3)).first;
    final dormant = (await core.dormant(3)).first;
    await _front(tester, core);
    await _tap(tester, find.byKey(ValueKey('front-most-played-${played.trackId}')));
    expect((await core.trail())!.stops.single.target, TargetDto.release(id: played.releaseId));
    await _tap(tester, find.byKey(ValueKey('front-dormant-${dormant.releaseId}')));
    expect(core.startedTargets.last, TargetDto.release(id: dormant.releaseId));
  });

  testWidgets('unkept trails show the newest four and the keeping key', (tester) async {
    _size(tester, 1200);
    final core = _MemoryCore();
    for (var year = 2000; year < 2006; year++) {
      await core.startTrail(TargetDto.search(query: 'year:$year'));
    }
    await _front(tester, core);
    expect(find.text('Trails'), findsOneWidget);
    expect(find.text('Kept trails'), findsNothing);
    expect(find.text('⌘S keeps a trail by name'), findsOneWidget);
    for (var year = 2002; year < 2006; year++) {
      expect(find.text('year:$year'), findsOneWidget);
    }
    expect(find.text('year:2000'), findsNothing);
    expect(find.text('year:2001'), findsNothing);
    expect(tester.getTopLeft(find.text('year:2005')).dy, lessThan(tester.getTopLeft(find.text('year:2004')).dy));
  });

  testWidgets('a Front without memory only offers its quiet trail line', (tester) async {
    _size(tester, 1600);
    final core = _MemoryCore()..blankMemory = true;
    await _front(tester, core);
    expect(find.text('Kept trails'), findsOneWidget);
    expect(find.text('Trails you follow and keep will be here'), findsOneWidget);
    for (final heading in ['Pick up', 'Your log', 'Most played this week', 'Dormant']) {
      expect(find.text(heading), findsNothing);
    }
  });

  test('Your log sums played time by weekday over seven local calendar days', () {
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

  testWidgets('Your log draws Monday–Sunday sums, total and today', (tester) async {
    _size(tester, 1600);
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day);
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    final core = _MemoryCore()..listens = [
      _listen(midnight, 60000),
      _listen(midnight, 120000, counted: false),
      _listen(yesterday, 60000),
    ];
    await _front(tester, core);
    expect(find.text('this week · 4 min'), findsOneWidget);
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    for (final day in weekdays) {
      expect(find.text(day), findsOneWidget);
    }
    final today = tester.widget<Container>(find.byKey(ValueKey('front-log-${now.weekday}')));
    final previous = tester.widget<Container>(find.byKey(ValueKey('front-log-${yesterday.weekday}')));
    expect(today.constraints!.maxHeight, 48);
    expect(previous.constraints!.maxHeight, 16);
    expect(find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == '${weekdays[now.weekday - 1]} · today' && widget.properties.value == '3 min'), findsOneWidget);
  });

  testWidgets('memory revisions reload the five calls without rereading the Front', (tester) async {
    _size(tester, 1600);
    final core = _MemoryCore();
    await _front(tester, core);
    expect(core.frontCalls, 1);
    expect(core.calls, hasLength(5));
    await _front(tester, core);
    expect(core.calls, hasLength(5));
    await _keep(core);
    core.calls.clear();
    await _front(tester, core, memoryVersion: 1);
    expect(find.text('A kept trail'), findsOneWidget);
    expect(core.frontCalls, 1);
    expect(core.calls, ['trails:20', 'resume:4', 'history:500', 'most:7:3', 'dormant:3']);
    await _front(tester, core, memoryVersion: 1, libraryVersion: BigInt.two);
    expect(core.frontCalls, 2);
    expect(core.calls, hasLength(10));
  });

  testWidgets('memory requests start together and older generations cannot replace newer ones', (tester) async {
    _size(tester, 1600);
    final core = _DelayedCore();
    await _front(tester, core);
    expect(core.calls, ['trails:20', 'resume:4', 'history:500', 'most:7:3', 'dormant:3']);
    expect(find.text('Reading your memory…'), findsOneWidget);
    await _front(tester, core, memoryVersion: 1);
    core.requests[1].complete([_summary('Newer')]);
    await tester.pumpAndSettle();
    expect(find.text('Newer'), findsOneWidget);
    core.requests[0].complete([_summary('Older')]);
    await tester.pumpAndSettle();
    expect(find.text('Newer'), findsOneWidget);
    expect(find.text('Older'), findsNothing);
    final replacement = _MemoryCore();
    await _keep(replacement);
    await _front(tester, replacement, memoryVersion: 1);
    expect(find.text('A kept trail'), findsOneWidget);
    expect(find.text('Newer'), findsNothing);
  });
}

void _size(WidgetTester tester, double width) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _front(WidgetTester tester, _MemoryCore core, {int memoryVersion = 0, BigInt? libraryVersion}) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: FrontPane(
    core: core,
    memoryVersion: memoryVersion,
    libraryVersion: libraryVersion,
    onQuery: (_) {},
    onTrail: (uid) async { await core.openTrail(uid); },
    onRelease: (id) async { await core.startTrail(TargetDto.release(id: id)); },
  ))));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder row) async {
  await tester.ensureVisible(row);
  await tester.tap(row);
  await tester.pumpAndSettle();
}

Future<TrailSummaryDto> _keep(FakeCore core) async {
  await core.startTrail(const TargetDto.search(query: 'year:2000'));
  await core.keepTrail(name: 'A kept trail');
  return (await core.trailHistory(1)).first;
}

ListenDto _listen(DateTime at, int playedMs, {bool counted = true}) => ListenDto(
  uid: '${at.millisecondsSinceEpoch}-$playedMs',
  recordingId: PlatformInt64Util.from(1),
  title: 'A recording',
  startedAtMs: PlatformInt64Util.from(at.millisecondsSinceEpoch),
  playedMs: BigInt.from(playedMs),
  counted: counted,
);

TrailSummaryDto _summary(String title) => TrailSummaryDto(
  uid: title,
  title: title,
  stops: 1,
  branches: 1,
  whenMs: PlatformInt64Util.from(DateTime.now().millisecondsSinceEpoch),
  kept: true,
  played: 0,
  wanted: 0,
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
  final requests = <Completer<List<TrailSummaryDto>>>[];

  @override
  Future<List<TrailSummaryDto>> trailHistory(int limit) {
    calls.add('trails:$limit');
    final request = Completer<List<TrailSummaryDto>>();
    requests.add(request);
    return request.future;
  }
}
