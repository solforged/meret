import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/core/playhead.dart';
import 'package:meret/main.dart';
import 'package:meret/panes/table_pane.dart';
import 'package:meret/shell/width_class.dart';

void main() {
  testWidgets('the surface comes up on fake data at desktop width', (tester) async {
    tester.view.physicalSize = const Size(2560, 1440);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MeretApp(core: FakeCore()));
    await tester.pump();

    expect(find.text('Iona'), findsWidgets);
    expect(find.text('NOW'), findsOneWidget);
    expect(find.text('● Bit-perfect'), findsOneWidget);
    expect(find.textContaining('≈ 312 to identify'), findsOneWidget);
  });

  testWidgets('on a phone, one pane and Now as a bar', (tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MeretApp(core: FakeCore()));
    await tester.pump();

    expect(WidthClass.of(400), WidthClass.phone);
    expect(find.text('NOW'), findsNothing);
    expect(find.text('Small Two of Pieces ~Broken Pieces~'), findsOneWidget);
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

  testWidgets('the table fetches only pages near the viewport', (tester) async {
    final core = _RecordingCore();
    await tester.pumpWidget(_table(core));
    await tester.pumpAndSettle();

    expect(find.text('48210 rows'), findsOneWidget);
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
    expect(core.played, [('', 3)]);
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
    expect(core.played, [('', 4)]);
  });

  testWidgets('the table refetches when query or library version changes', (tester) async {
    final core = _RecordingCore();
    await tester.pumpWidget(_table(core, libraryVersion: BigInt.one));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_table(core, query: 'year:1990s', libraryVersion: BigInt.one));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_table(core, query: 'year:1990s', libraryVersion: BigInt.two));
    await tester.pumpAndSettle();
    expect(core.offsets, [0, 0, 0]);
  });

  testWidgets('the table shows row errors without crashing', (tester) async {
    await tester.pumpWidget(_table(_InvalidCore()));
    await tester.pumpAndSettle();
    expect(find.text('Invalid query'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty library offers a music folder', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TablePane(
      core: _RecordingCore(),
      query: '',
      tracks: BigInt.zero,
      onQuery: (_) {},
    ))));
    await tester.pumpAndSettle();
    expect(find.text('Add a music folder'), findsOneWidget);
    expect(find.byKey(const ValueKey('table-rows')), findsNothing);
  });
}

Widget _table(CoreBridge core, {String query = '', BigInt? libraryVersion}) => MaterialApp(
  home: Scaffold(body: TablePane(core: core, query: query, libraryVersion: libraryVersion, onQuery: (_) {})),
);

class _RecordingCore extends FakeCore {
  final offsets = <int>[];
  final played = <(String, int)>[];

  @override
  Future<RowsDto> rows(String query, int offset, int limit) {
    offsets.add(offset);
    return super.rows(query, offset, limit);
  }

  @override
  Future<void> playResults(String query, int index) {
    played.add((query, index));
    return super.playResults(query, index);
  }
}

class _InvalidCore extends FakeCore {
  @override
  Future<RowsDto> rows(String query, int offset, int limit) async => throw 'Invalid query';
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
