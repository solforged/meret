import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/core/playhead.dart';
import 'package:meret/now/now_pane.dart';
import 'package:meret/now/zones.dart';
import 'package:meret/panes/row_menu.dart';

/// The Now panel's lower half: the output's block on few lines, then the queue.
void main() {
  Future<PlayheadClock> pane(WidgetTester tester, CoreBridge core, {double width = 360}) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await core.playResults('', const ViewDto(sort: SortKeyDto.library_, descending: false, group: false), 0);
    await core.transport(const TransportDto.pause());
    final clock = PlayheadClock(tester);
    addTearDown(clock.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: RowMenuHost(child: NowPane(
      core: core, now: await core.now().first, clock: clock, onToggle: () {}, onRelease: (_) async {},
    )))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return clock;
  }

  testWidgets('NOW-1 the signal path stays on one line in the narrow panel, with the volume under it and the queue next', (tester) async {
    final core = FakeCore();
    await pane(tester, core);
    final now = await core.now().first;
    expect(now.path.length, greaterThanOrEqualTo(3));

    final tops = {for (final stage in now.path) tester.getTopLeft(find.text(stage.name)).dy};
    expect(tops, hasLength(1), reason: 'every stage is on the same line');
    expect(tester.getTopRight(find.text(now.path.last.detail)).dx, lessThanOrEqualTo(360 - 16), reason: 'and the output stage gives way inside the panel');

    final volume = find.byKey(const ValueKey('now-volume'));
    final queue = find.byType(UpNext);
    expect(tester.getTopLeft(volume).dy, greaterThan(tester.getBottomLeft(find.text(now.path.last.detail)).dy));
    expect(tester.getBottomLeft(volume).dy, lessThan(tester.getTopLeft(queue).dy), reason: 'the volume is not below the queue');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('NOW-2 Play on waits for a second output; one output is already named by the signal path', (tester) async {
    await pane(tester, _OneOutput());
    expect(find.byType(PlayOn), findsOneWidget);
    expect(find.text('Play on'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());

    await pane(tester, FakeCore());
    expect(find.text('Play on'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('NOW-3 queued tracks are numbered two-line rows: a click plays from one and nothing else', (tester) async {
    final core = _Jumps();
    await pane(tester, core);
    final items = (await core.upNext(8)).items;
    final first = find.byKey(ValueKey('up-next-${items.first.token}'));
    await tester.ensureVisible(first);
    await tester.pump();
    expect(tester.getSize(first).height, lessThan(50), reason: 'a queue row is two lines, so the lower half holds a queue');
    expect(find.descendant(of: first, matching: find.text('1')), findsOneWidget);
    expect(find.descendant(of: find.byKey(ValueKey('up-next-${items[1].token}')), matching: find.text('2')), findsOneWidget);

    await tester.tap(find.descendant(of: first, matching: find.text(items.first.title)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(core.jumps, [items.first.token]);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _OneOutput extends FakeCore {
  @override
  Future<List<ZoneDto>> zones() async => (await super.zones()).where((zone) => zone.current).toList();
}

class _Jumps extends FakeCore {
  final jumps = <BigInt>[];

  @override
  Future<void> jumpToQueued(BigInt token) {
    jumps.add(token);
    return super.jumpToQueued(token);
  }
}
