import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;
import 'package:meret/core/bridge.dart';
import 'package:meret/core/playhead.dart';
import 'package:meret/now/now_pane.dart';
import 'package:meret/now/picks.dart';
import 'package:meret/settings/settings_window.dart';

void main() {
  testWidgets('a recommendation can be inspected without playback and has an explicit Play action', (tester) async {
    final core = _Core();
    final opened = <PlatformInt64>[];
    final pick = (await core.picks(3)).first;
    await _page(tester, PlaySomething(core: core, now: await core.now().first, onRelease: (id) async => opened.add(id)));
    final card = find.byKey(ValueKey('now-pick-${pick.releaseId}'));
    await tester.tap(find.descendant(of: card, matching: find.text(pick.title)));
    await tester.pumpAndSettle();
    expect(opened, [pick.releaseId]);
    expect(core.played, isEmpty);

    await tester.tap(find.byKey(ValueKey('now-pick-play-${pick.releaseId}')));
    await tester.pumpAndSettle();
    expect(core.played, [pick.releaseId]);
    expect(opened, [pick.releaseId], reason: 'the Play button does not also open the release');
  });

  testWidgets('recommendations refresh after an empty library gains music without a Now change', (tester) async {
    final core = FakeCore.empty();
    final now = await core.now().first;
    await _page(tester, PlaySomething(core: core, now: now));
    expect(find.text('Add a music folder'), findsOneWidget);
    await core.addRoot('/Imported music');
    await tester.pumpAndSettle();
    expect(find.text('Add a music folder'), findsNothing);
    expect(find.byType(NowDoor), findsNWidgets(3));
    expect((await core.now().first).anchor, now.anchor, reason: 'library status alone refreshed the picks');
  });

  testWidgets('Now opens the current release without changing playback', (tester) async {
    final core = _Core();
    final now = await core.now().first;
    final opened = <PlatformInt64>[];
    final clock = PlayheadClock(tester);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 380, child: NowPane(
      core: core, now: now, clock: clock, onToggle: () {}, onRelease: (id) async => opened.add(id),
    )))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('now-open-release')));
    await tester.pumpAndSettle();
    expect(opened, [now.releaseId]);
    expect((await core.now().first).anchor, now.anchor);
    await tester.pumpWidget(const SizedBox.shrink());
    clock.dispose();
  });

  testWidgets('queue rows open releases, expand beyond the preview, and jump directly to the selected item', (tester) async {
    final core = _Core();
    await core.playResults('', const ViewDto(sort: SortKeyDto.library_, descending: false, group: false), 0);
    final before = await core.upNext(50);
    final opened = <PlatformInt64>[];
    await _page(tester, UpNext(core: core, now: await core.now().first, limit: 2, onRelease: (id) async => opened.add(id)));
    final first = before.items.first;
    final row = find.byKey(ValueKey('up-next-${first.token}'));
    await tester.tap(find.descendant(of: row, matching: find.text(first.title)));
    await tester.pumpAndSettle();
    expect(opened, [first.releaseId]);
    expect(core.jumps, isEmpty);

    final third = before.items[2];
    expect(find.byKey(ValueKey('up-next-${third.token}')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('up-next-more')));
    await tester.pumpAndSettle();
    final play = find.byKey(ValueKey('up-next-play-${third.token}'));
    await tester.ensureVisible(play);
    await tester.tap(play);
    await tester.pumpAndSettle();
    expect(core.jumps, [third.token]);
    expect((await core.now().first).anchor!.item, third.token);
    expect((await core.upNext(50)).items.map((item) => item.token), before.items.skip(3).map((item) => item.token));
    expect(core.transports, isEmpty, reason: 'jumping never advances through intervening tracks');
  });

  testWidgets('a stale queue action reports its error without replacing playback', (tester) async {
    final core = _Core();
    await core.playResults('', const ViewDto(sort: SortKeyDto.library_, descending: false, group: false), 0);
    final stale = (await core.upNext(2)).items.first;
    await _page(tester, UpNext(core: core, now: await core.now().first, limit: 2));
    await core.playResults('', const ViewDto(sort: SortKeyDto.library_, descending: false, group: false), 20);
    final current = (await core.now().first).anchor!.item;
    await tester.tap(find.byKey(ValueKey('up-next-play-${stale.token}')));
    await tester.pumpAndSettle();
    expect((await core.now().first).anchor!.item, current);
    expect(find.textContaining('queue'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long playback error wraps and opens music folder settings', (tester) async {
    tester.view.physicalSize = const Size(600, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = _Core();
    final clock = PlayheadClock(tester);
    const error = "The zone can't play /Users/listener/Music/An album with a long name/01-aube.flac: io: No such file or directory (os error 2)";
    await tester.pumpWidget(MaterialApp(home: SettingsScope(core: core, onChanged: (_) {}, child: Scaffold(
      body: SizedBox(width: 380, child: NowPane(core: core, now: const NowDto(title: 'Zeta', subtitle: 'Fixture release', path: [], error: error),
        clock: clock, onToggle: () {})),
    ))));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SelectableText, error), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('now-check-folders')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-window')), findsOneWidget);
    expect(find.text('Folders'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    clock.dispose();
  });
}

Future<void> _page(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
    child: SizedBox(width: 420, child: child),
  ))));
  await tester.pumpAndSettle();
}

class _Core extends FakeCore {
  final played = <PlatformInt64>[];
  final jumps = <BigInt>[];
  final transports = <TransportDto>[];

  @override
  Future<PickDto> playPick(PlatformInt64 releaseId) {
    played.add(releaseId);
    return super.playPick(releaseId);
  }

  @override
  Future<void> jumpToQueued(BigInt token) {
    jumps.add(token);
    return super.jumpToQueued(token);
  }

  @override
  Future<void> transport(TransportDto command) {
    transports.add(command);
    return super.transport(command);
  }
}
