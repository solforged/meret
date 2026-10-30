import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/home/home.dart';
import 'package:meret/home/trail_browser.dart';
import 'package:meret/main.dart';
import 'package:meret/panes/table_pane.dart';
import 'package:meret/theme/action_target.dart';

/// A library whose Scores are mostly offline: one release is playable, the
/// idiom holds 761 tracks, and a second idiom has none playable at all.
class _CountsCore extends FakeCore {
  @override
  Future<FrontDto> front() async {
    final base = await super.front();
    return FrontDto(
      tracks: BigInt.from(844), releases: base.releases, formats: base.formats, addedLately: base.addedLately,
      needsYou: [
        FrontLineDto(label: 'Missing files', count: BigInt.from(3), note: '', missingFiles: true),
        FrontLineDto(label: 'Offline folders', count: BigInt.one, note: '', missingFiles: false),
      ],
      roots: base.roots, lookups: base.lookups,
      idioms: [
        IdiomLineDto(label: 'Scores', releases: BigInt.one, tracks: BigInt.from(761), query: 'idiom:score'),
        IdiomLineDto(label: 'Albums', releases: BigInt.zero, tracks: BigInt.from(67), query: 'idiom:album'),
        IdiomLineDto(label: 'Sessions', releases: BigInt.zero, tracks: BigInt.zero, query: 'idiom:session'),
      ],
    );
  }
}

/// Every trail but the newest was last visited a month ago.
class _AgedCore extends FakeCore {
  @override
  Future<List<TrailSummaryDto>> trailHistory(int limit) async {
    final all = await super.trailHistory(limit);
    final old = DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch;
    return [
      for (final (i, t) in all.indexed)
        i == 0 ? t : TrailSummaryDto(uid: t.uid, title: t.title, stops: t.stops, branches: t.branches, whenMs: PlatformInt64Util.from(old),
          kept: t.kept, name: t.name, played: t.played, wanted: t.wanted, route: t.route),
    ];
  }
}

Future<HomeDoors> _doors(WidgetTester tester, CoreBridge core, {String? current, double width = 800}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final doors = HomeDoors();
  addTearDown(doors.dispose);
  await doors.load(core, libraryVersion: BigInt.zero, memoryVersion: 0);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.topLeft, child: SizedBox(
    width: Home.column, child: Home(doors: doors, open: true, onDoor: (_) {}, currentTrail: current),
  )))));
  await tester.pumpAndSettle();
  return doors;
}

DoorKind? _kind(HomeDoors doors, String id) =>
  [for (final (_, entries) in doors.sections) ...entries].where((door) => door.id == id).firstOrNull?.kind;

String _count(WidgetTester tester, String id) => tester
  .widgetList<Text>(find.descendant(of: find.byKey(ValueKey('home-$id')), matching: find.byType(Text)))
  .map((text) => text.data)
  .whereType<String>()
  .firstWhere((text) => text.contains(RegExp(r'^\d')), orElse: () => '');

void main() {
  testWidgets('every count in the Library column is tracks, and an idiom door shows whenever its tracks do', (tester) async {
    await _doors(tester, _CountsCore());
    expect(_count(tester, 'all'), '844 tracks');
    // The Scores door says what its page lists, not how many releases are online.
    expect(_count(tester, 'idiom-idiom:score'), '761 tracks');
    expect(_count(tester, 'idiom-idiom:album'), '67 tracks');
    expect(find.byKey(const ValueKey('home-idiom-idiom:session')), findsNothing);
    // A door with a count and a key shows both.
    expect(find.descendant(of: find.byKey(const ValueKey('home-all')), matching: find.text('⌘3')), findsOneWidget);
  });

  testWidgets('Missing files gets its own door, and Play something says why when nothing plays', (tester) async {
    final doors = await _doors(tester, _CountsCore());
    expect(_kind(doors, 'need-0'), DoorKind.missing);
    expect(_kind(doors, 'need-1'), DoorKind.later);
    final play = find.byKey(const ValueKey('home-play-something'));
    expect(tester.widget<ActionTarget>(play).onTap, isNotNull);
    doors.nothingToPlay = const NothingToPlayDto(kind: NothingToPlayKind.foldersOffline, label: 'Folders offline');
    await tester.pump();
    await tester.pump();
    expect(tester.widget<ActionTarget>(play).onTap, isNull);
    final tip = tester.widget<Tooltip>(find.ancestor(of: play, matching: find.byType(Tooltip)).first);
    expect(tip.message, 'Play something · Folders offline');
  });

  testWidgets('the open trail is the lit row, and its door stops being lit for it', (tester) async {
    final core = FakeCore();
    await core.startTrail(const TargetDto.search(query: 'Iona'));
    await core.startTrail(const TargetDto.search(query: 'Skye'));
    final trails = await core.trailHistory(5);
    final older = trails.last;
    await _doors(tester, core, current: older.uid);
    bool lit(String uid) => tester.widget<ActionTarget>(find.byKey(ValueKey('home-trail-$uid'))).selected ?? false;
    expect(lit(older.uid), isTrue);
    expect(lit(trails.first.uid), isFalse);
  });

  testWidgets('Tab moves the tooltip from trail row to trail row, and none outlives the focus', (tester) async {
    final core = FakeCore();
    await core.startTrail(const TargetDto.search(query: 'Iona'));
    await core.startTrail(const TargetDto.search(query: 'Skye'));
    final trails = await core.trailHistory(5);
    await _doors(tester, core);
    String message(TrailSummaryDto trail) => '${trail.name ?? trail.title}\n${trailSummaryContext(trail)}';
    Focus.of(tester.element(find.descendant(of: find.byKey(ValueKey('home-trail-${trails[0].uid}')), matching: find.byType(GestureDetector)).first)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text(message(trails[1])), findsOneWidget);
    expect(find.text(message(trails[0])), findsNothing);
    // Focus leaving every row takes the tooltip with it.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text(message(trails[1])), findsNothing);
  });

  testWidgets('under 720 wide Today keeps the rail, and its Today glyph lays the column over the page', (tester) async {
    final core = FakeCore();
    await core.transport(const TransportDto.pause());
    for (final (width, column) in [(800.0, true), (650.0, false)]) {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MeretApp(core: core));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('home-column')), column ? findsOneWidget : findsNothing, reason: '$width wide');
      expect(find.byKey(const ValueKey('home-rail')), column ? findsNothing : findsOneWidget, reason: '$width wide');
    }
    await tester.tap(find.byKey(const ValueKey('rail-today')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-column')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-scrim')), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-rail')), findsOneWidget);
  });

  testWidgets('the Recent chip drops trails last visited over a week ago, and All brings them back', (tester) async {
    final core = _AgedCore();
    await core.startTrail(const TargetDto.search(query: 'Iona'));
    await core.startTrail(const TargetDto.search(query: 'Skye'));
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(body: TextButton(
      onPressed: () => showTrailBrowser(context, core), child: const Text('Browse trails'),
    )))));
    await tester.tap(find.text('Browse trails'));
    await tester.pumpAndSettle();
    expect(find.text('Skye'), findsOneWidget);
    expect(find.text('Iona'), findsOneWidget);
    await tester.tap(find.text('Recent'));
    await tester.pumpAndSettle();
    expect(find.text('Skye'), findsOneWidget);
    expect(find.text('Iona'), findsNothing);
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(find.text('Iona'), findsOneWidget);
  });

  testWidgets('an empty library shows an empty state with a real Add folder button, not a results spinner', (tester) async {
    final core = FakeCore.empty();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 900, height: 700, child: TablePane(
      core: core, query: '', onQuery: (_) {}, tracks: BigInt.zero,
    )))));
    await tester.pump();
    await tester.pump();
    expect(find.text('Loading results…'), findsNothing);
    final button = find.byKey(const ValueKey('table-add-folder'));
    expect(button, findsOneWidget);
    expect(find.descendant(of: button, matching: find.text('Add folder')), findsOneWidget);
    expect(tester.getSize(button).height, greaterThan(24));
  });
}
