import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/home/home.dart';
import 'package:meret/home/trail_browser.dart';
import 'package:meret/main.dart';
import 'package:meret/theme/action_target.dart';

class _TrailCore extends FakeCore {
  final limits = <int>[];
  bool failNext = false;

  @override
  Future<List<TrailSummaryDto>> trailHistory(int limit) {
    limits.add(limit);
    if (failNext) {
      failNext = false;
      return Future.error('Could not read saved trails');
    }
    return super.trailHistory(limit);
  }
}

const _oldName = 'An evening following long soundtrack titles and their composers';
const _oldQuery = 'Tyranny Official Soundtrack through the final extended edition';

Future<TrailSummaryDto> _seed(_TrailCore core) async {
  await core.startTrail(const TargetDto.search(query: _oldQuery));
  await core.keepTrail(name: _oldName);
  final oldest = (await core.trailHistory(1)).single;
  for (var i = 0; i < 7; i++) {
    await core.startTrail(TargetDto.search(query: 'Recent search $i'));
  }
  expect((await core.trailHistory(5)).any((trail) => trail.uid == oldest.uid), isFalse);
  return oldest;
}

Future<void> _browser(WidgetTester tester, CoreBridge core, {ValueChanged<String?>? onClose}) async {
  await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(body: TextButton(
    onPressed: () async {
      final uid = await showTrailBrowser(context, core);
      onClose?.call(uid);
    }, child: const Text('Browse trails'),
  )))));
  await tester.tap(find.text('Browse trails'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the complete archive finds a kept trail older than the five recent Home entries', (tester) async {
    final core = _TrailCore();
    final oldest = await _seed(core);
    String? selected;
    await _browser(tester, core, onClose: (uid) => selected = uid);
    expect(core.limits.last, 0xffffffff);
    await tester.tap(find.text('Kept'));
    await tester.pumpAndSettle();
    expect(find.text('1 trail · most recent first'), findsOneWidget);
    expect(find.text(_oldName), findsOneWidget);
    expect(find.text(_oldQuery), findsOneWidget);
    expect(tester.widget<Text>(find.text(_oldQuery)).maxLines, isNull);
    expect(find.text(trailSummaryContext(oldest)), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('trail-browser-search')), 'TYRANNY');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('trail-browser-${oldest.uid}')));
    await tester.pumpAndSettle();
    expect(selected, oldest.uid);
    expect(find.byKey(const ValueKey('trail-browser')), findsNothing);
  });

  testWidgets('Home opens an older saved trail through the archive without creating another trail', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = _TrailCore();
    final oldest = await _seed(core);
    await core.transport(const TransportDto.pause());
    await tester.pumpWidget(MeretApp(core: core));
    await tester.pumpAndSettle();
    final allTrails = find.byKey(const ValueKey('home-all-trails'));
    await tester.ensureVisible(allTrails);
    await tester.tap(allTrails);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('trail-browser')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('trail-browser-search')), _oldName);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('trail-browser-${oldest.uid}')));
    await tester.pumpAndSettle();
    final current = (await core.trail())!;
    expect(current.name, _oldName);
    expect(current.rootQuery, _oldQuery);
    expect((await core.trailHistory(100)).length, 8);
    expect(find.byKey(const ValueKey('trail-browser')), findsNothing);
  });

  testWidgets('recent trail context exposes the full name, route and precise time on focus', (tester) async {
    final core = _TrailCore();
    await core.startTrail(const TargetDto.search(query: _oldQuery));
    await core.keepTrail(name: _oldName);
    final summary = (await core.trailHistory(1)).single;
    final doors = HomeDoors();
    addTearDown(doors.dispose);
    await doors.load(core, libraryVersion: BigInt.zero, memoryVersion: 0);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Home(doors: doors, open: true, onDoor: (_) {}))));
    await tester.pumpAndSettle();
    final row = find.byKey(ValueKey('home-trail-${summary.uid}'));
    await tester.ensureVisible(row);
    final action = tester.widget<ActionTarget>(row);
    expect(action.semanticLabel, contains(_oldName));
    expect(action.semanticLabel, contains(_oldQuery));
    expect(action.semanticLabel, contains(trailSummaryContext(summary)));
    final target = find.descendant(of: row, matching: find.byType(GestureDetector));
    // Keyboard focus, as Tab leaves it: a pointer's focus shows no tooltip.
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
    Focus.of(tester.element(target)).requestFocus();
    await tester.pumpAndSettle();
    expect(find.text('$_oldName\n$_oldQuery\n${trailSummaryContext(summary)}'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty search and kept filters recover, and archive errors can retry', (tester) async {
    final core = _TrailCore()..failNext = true;
    await _browser(tester, core);
    expect(find.text('Could not read saved trails'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('No trails yet'), findsOneWidget);
    expect(find.text('Search or open a release to start a trail.'), findsOneWidget);
    await tester.tap(find.byTooltip('Close trails'));
    await tester.pumpAndSettle();
    await core.startTrail(const TargetDto.search(query: 'Iona'));
    await _browser(tester, core);
    await tester.tap(find.text('Kept'));
    await tester.pumpAndSettle();
    expect(find.text('No kept trails yet'), findsOneWidget);
    await tester.tap(find.text('Reset filters'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('trail-browser-search')), 'missing-name');
    await tester.pumpAndSettle();
    expect(find.text('No matching trails'), findsOneWidget);
    await tester.tap(find.text('Reset filters'));
    await tester.pumpAndSettle();
    expect(find.text('Iona'), findsOneWidget);
  });

  testWidgets('full trail titles and controls fit a narrow archive dialog', (tester) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = _TrailCore();
    await _seed(core);
    await _browser(tester, core);
    await tester.tap(find.text('Kept'));
    await tester.pumpAndSettle();
    expect(find.text(_oldName), findsOneWidget);
    expect(tester.getSize(find.text(_oldName)).height, greaterThan(30));
    expect(tester.takeException(), isNull);
  });
}
