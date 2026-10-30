import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/panes/release_pane.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/home/today.dart';
import 'package:meret/main.dart';
import 'package:meret/now/missing_sheet.dart';
import 'package:meret/now/picks.dart';
import 'package:meret/settings/settings_window.dart';

void main() {
  testWidgets('with no music the LCD says so, play is off and Now offers a folder', (tester) async {
    await _app(tester, FakeCore.empty());
    expect(find.text('Add a music folder'), findsWidgets);
    expect(_button(tester, 'lcd-toggle').onPressed, isNull);
    expect(find.byKey(const ValueKey('nothing-add-folder')), findsWidgets);
  });

  testWidgets('offline folders: Play something names them and offers Check music folders', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: PlaySomething(core: _OfflineCore(), now: null),
    ))));
    await tester.pumpAndSettle();
    expect(find.text('Folders offline'), findsOneWidget);
    expect(find.text('Nothing to play yet'), findsNothing);
    expect(find.byKey(const ValueKey('nothing-check-folders')), findsOneWidget);
  });

  testWidgets('a queued track that is missing shows its error with Check music folders under Up next', (tester) async {
    final core = _MissingQueueCore();
    await core.playResults('', const ViewDto(sort: SortKeyDto.library_, descending: false, group: false), 0);
    await _app(tester, core);
    final item = (await core.upNext(8)).items.first;
    await tester.ensureVisible(find.byKey(ValueKey('up-next-play-${item.token}')));
    await tester.tap(find.byKey(ValueKey('up-next-play-${item.token}')));
    await _settle(tester);
    expect(find.text('08.flac is missing'), findsOneWidget);
    expect(find.byKey(const ValueKey('up-next-check-folders')), findsOneWidget);
  });

  testWidgets('Up next opens the release with the clicked track marked', (tester) async {
    final handle = tester.ensureSemantics();
    final core = FakeCore();
    await core.playResults('', const ViewDto(sort: SortKeyDto.library_, descending: false, group: false), 0);
    await _app(tester, core);
    final item = (await core.upNext(8)).items.last;
    final rows = (await core.release(item.releaseId!)).rows;
    final at = rows.indexWhere((row) => row.trackId == item.trackId);
    await tester.ensureVisible(find.byKey(ValueKey('up-next-${item.token}')));
    await tester.tap(find.byKey(ValueKey('up-next-${item.token}')));
    await _settle(tester);
    expect(find.byType(ReleasePane), findsOneWidget);
    final marked = tester.getSemantics(find.byKey(ValueKey('release-row-$at')));
    expect(marked.flagsCollection.isSelected, Tristate.isTrue);
    handle.dispose();
  });

  testWidgets('Settings ▸ Folders shows missing files and Rescan walks the folders again', (tester) async {
    final core = _LossCore();
    await _app(tester, core);
    showSettings(tester.element(find.byType(Today)), section: SettingsSection.folders);
    await _settle(tester);
    expect(find.textContaining('1 file missing'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-rescan')));
    await tester.pump();
    expect(core.rescans, 1);
  });

  testWidgets('the Missing files sheet lists each file with its folder and offers Rescan', (tester) async {
    final core = _LossCore();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
      onPressed: () => showMissingFiles(context, core, onCheckFolders: () {}),
      child: const Text('open'),
    )))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('08.flac'), findsOneWidget);
    expect(find.text('/music/Queue checks'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('missing-rescan')));
    await tester.pump();
    expect(core.rescans, 1);
  });
}

IconButton _button(WidgetTester tester, String key) =>
  tester.widget<IconButton>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(IconButton)));

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _app(WidgetTester tester, CoreBridge core) async {
  tester.view.physicalSize = const Size(2560, 1440);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MeretApp(core: core));
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

class _OfflineCore extends FakeCore {
  @override
  Future<List<PickDto>> picks(int limit) async => const [];

  @override
  Future<NothingToPlayDto?> nothingToPlay() async =>
    const NothingToPlayDto(kind: NothingToPlayKind.foldersOffline, label: 'Folders offline');
}

class _MissingQueueCore extends FakeCore {
  @override
  Future<void> jumpToQueued(BigInt token) async => throw '08.flac is missing';
}

class _LossCore extends FakeCore {
  _LossCore() {
    missing = [
      MissingFileDto(
        trackId: PlatformInt64Util.from(8), releaseId: PlatformInt64Util.from(1), title: 'Queue check 8',
        artist: 'Test Ensemble', album: 'Queue checks', file: '08.flac', folder: '/music/Queue checks',
      ),
    ];
  }
}
