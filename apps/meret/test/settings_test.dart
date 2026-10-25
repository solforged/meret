import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/main.dart';
import 'package:meret/now/now_pane.dart';
import 'package:meret/now/zones.dart';
import 'package:meret/home/today.dart';
import 'package:meret/settings/settings_window.dart';
import 'package:meret/theme/light.dart';
import 'package:meret/theme/tokens.dart';

void main() {
  testWidgets('Command-comma opens Folders without touching the trail', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);
    await _command(tester, LogicalKeyboardKey.keyL);
    final trail = await core.trail();

    await _command(tester, LogicalKeyboardKey.comma);

    expect(find.byKey(const ValueKey('settings-window')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-section-folders')), findsOneWidget);
    expect(await core.trail(), trail);
  });

  testWidgets('showSettings opens each requested section', (tester) async {
    final core = FakeCore();
    await _surface(tester, core);

    for (final section in SettingsSection.values) {
      showSettings(tester.element(find.byType(Today)), section: section);
      await _settle(tester);
      expect(find.byKey(ValueKey('settings-section-${section.name}')), findsOneWidget);
      expect(await core.trail(), isNull);
      await tester.tap(find.byTooltip('Close Settings'));
      await _settle(tester);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('Escape, Command-W and the close button close Settings', (tester) async {
    await _surface(tester, FakeCore());
    await _command(tester, LogicalKeyboardKey.comma);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.byKey(const ValueKey('settings-window')), findsNothing);

    await _command(tester, LogicalKeyboardKey.comma);
    await _command(tester, LogicalKeyboardKey.keyW);
    expect(find.byKey(const ValueKey('settings-window')), findsNothing);

    await _command(tester, LogicalKeyboardKey.comma);
    await tester.tap(find.byTooltip('Close Settings'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('settings-window')), findsNothing);
  });

  testWidgets('Light changes reach Light.of live and persist in the core', (tester) async {
    final core = FakeCore();
    final now = await core.now().first;
    await _surface(tester, core);
    await _command(tester, LogicalKeyboardKey.digit1);
    Light currentLight() => Light.of(tester.element(find.byType(NowPane)));
    expect(currentLight().accent, Color(now.light!.light));
    expect(currentLight().wash, Colors.transparent);

    showSettings(tester.element(find.byType(Today)), section: SettingsSection.light);
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('settings-light-off')));
    await _settle(tester);
    expect(currentLight().accent, Tok.gold);
    expect(currentLight().wash, Colors.transparent);
    expect(currentLight().track, now.trackId!.toInt());
    expect(core.settings().light, LightLevelDto.off);

    await tester.tap(find.byKey(const ValueKey('settings-light-accentAndWash')));
    await _settle(tester);
    expect(currentLight().accent, Color(now.light!.light));
    expect(currentLight().wash, Color(now.light!.wash));
    expect(core.settings().light, LightLevelDto.accentAndWash);
    final nowBackground = tester.widgetList<Container>(find.descendant(of: find.byType(NowPane), matching: find.byType(Container))).first;
    expect(nowBackground.color, Color.alphaBlend(Color(now.light!.wash), Tok.panel));

    await tester.tap(find.byKey(const ValueKey('settings-light-accent')));
    await _settle(tester);
    expect(currentLight().accent, Color(now.light!.light));
    expect(currentLight().wash, Colors.transparent);
    expect(core.settings().light, LightLevelDto.accent);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Remove confirms that files stay and calls the bridge', (tester) async {
    final core = _RecordingCore();
    final root = (await core.front()).roots.first;
    await _surface(tester, core);
    await _command(tester, LogicalKeyboardKey.comma);

    final rootWidget = find.byKey(ValueKey('settings-root-${root.id}'));
    expect(find.descendant(of: rootWidget, matching: find.text(root.path)), findsOneWidget);
    await tester.tap(find.descendant(of: rootWidget, matching: find.text('Remove…')));
    await tester.pump();
    expect(find.text('Files stay on disk; re-adding this folder restores it.'), findsOneWidget);
    expect(core.removed, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(core.removed, isEmpty);

    await tester.tap(find.descendant(of: rootWidget, matching: find.text('Remove…')));
    await tester.pump();
    await tester.tap(find.text('Remove folder'));
    await _settle(tester);
    expect(core.removed, [root.id.toInt()]);
    expect(find.byKey(ValueKey('settings-root-${root.id}')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Playback saves the selected output and exclusive mode', (tester) async {
    final core = FakeCore();
    final devices = await core.outputDevices();
    await _surface(tester, core);
    showSettings(tester.element(find.byType(Today)), section: SettingsSection.playback);
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('settings-output')));
    await _settle(tester);
    await tester.tap(find.text(devices.first.name).last);
    await _settle(tester);
    expect(core.settings().outputDevice, devices.first.id);
    if (devices.first.canBeExclusive) {
      await tester.tap(find.byType(Switch));
      await _settle(tester);
      expect(core.settings().exclusive, isTrue);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('Playback saves each loudness level without changing the other settings', (tester) async {
    final core = FakeCore();
    final before = core.settings();
    await _surface(tester, core);
    showSettings(tester.element(find.byType(Today)), section: SettingsSection.playback);
    await _settle(tester);
    for (final (level, label) in [
      (LevelDto.track, 'Track'), (LevelDto.album, 'Album'), (LevelDto.off, 'Off'),
    ]) {
      final control = find.byKey(const ValueKey('settings-level'));
      await tester.ensureVisible(control);
      await tester.tap(control);
      await _settle(tester);
      await tester.tap(find.text(label).last);
      await _settle(tester);
      expect(core.settings().level, level);
      expect(tester.widget<DropdownButton<LevelDto>>(control).value, level);
      expect(core.settings().light, before.light);
      expect(core.settings().exclusive, before.exclusive);
      expect(core.settings().outputDevice, before.outputDevice);
      expect(core.settings().lookups, before.lookups);
    }
    expect(tester.takeException(), isNull);
  });

  for (final form in ['stage', 'pane', 'sheet']) {
    testWidgets('Settings updates the open Now $form output marker and verdicts without a restart', (tester) async {
      final core = FakeCore();
      await _surface(tester, core);
      if (form != 'stage') await _command(tester, LogicalKeyboardKey.digit1);
      if (form == 'sheet') {
        // The sheet is the phone's; desktops open the Now panel from the LCD.
        tester.view.physicalSize = const Size(400, 900);
        await _settle(tester);
        await tester.tap(find.byKey(const ValueKey('now-bar-title')));
        await _settle(tester);
        // The sheet stays open over a wider window, where Settings fits.
        tester.view.physicalSize = const Size(1200, 900);
        await _settle(tester);
      }
      final zones = tester.state(find.byType(PlayOn));
      final item = (await core.now().first).anchor!.item;
      expect(_zoneMarkerColour(tester, 'speakers'), Light.of(tester.element(find.byType(PlayOn))).accent);
      expect(_zoneMarkerColour(tester, 'dac'), Colors.transparent);
      final dac = find.byKey(const ValueKey('now-zone-local:dac'));
      await tester.ensureVisible(dac);
      await tester.tap(dac);
      await _settle(tester);
      expect(core.settings().outputDevice, 'dac');

      showSettings(tester.element(find.byType(Today)), section: SettingsSection.playback);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('settings-output')));
      await _settle(tester);
      await tester.tap(find.text('System default').last);
      await _settle(tester);
      expect(core.settings().outputDevice, isNull);
      expect(_zoneMarkerColour(tester, 'speakers'), Light.of(tester.element(find.byType(PlayOn))).accent);
      expect(_zoneMarkerColour(tester, 'dac'), Colors.transparent);
      await tester.tap(find.byKey(const ValueKey('settings-output')));
      await _settle(tester);
      await tester.tap(find.text('RME ADI-2 DAC').last);
      await _settle(tester);
      expect(core.settings().outputDevice, 'dac');
      expect(_zoneMarkerColour(tester, 'speakers'), Colors.transparent);
      expect(_zoneMarkerColour(tester, 'dac'), Light.of(tester.element(find.byType(PlayOn))).accent);
      await tester.tap(find.byType(Switch));
      await _settle(tester);
      expect(find.text('● bit-perfect'), findsOneWidget);
      expect(find.text('◐ refuses above 96 kHz'), findsOneWidget);
      await tester.tap(find.byTooltip('Close Settings'));
      await _settle(tester);

      expect(tester.state(find.byType(PlayOn)), same(zones));
      expect((await core.now().first).anchor!.item, item);
      expect(await core.trail(), isNull);
      expect(core.settings().exclusive, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Sources and future sections do not offer unavailable actions', (tester) async {
    await _surface(tester, FakeCore());
    showSettings(tester.element(find.byType(Today)), section: SettingsSection.sources);
    await _settle(tester);
    for (final name in ['This Mac', 'MusicBrainz', 'Spotify', 'Music Assistant', 'Roon', 'Bandcamp', 'YouTube', 'Qobuz', 'ListenBrainz', 'Last.fm']) {
      expect(find.text(name), findsWidgets);
    }
    expect(find.text('Recordings and credits'), findsNothing);
    await tester.tap(find.text('MusicBrainz').last);
    await tester.pump();
    expect(find.text('Recordings and credits'), findsOneWidget);
    expect(find.textContaining('Connect…'), findsNothing);
    expect(find.textContaining('Sign in'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-nav-lookups')));
    await tester.pump();
    expect(find.byType(Switch), findsNothing);
    await tester.tap(find.byKey(const ValueKey('settings-nav-files')));
    await tester.pump();
    expect(find.byType(Switch), findsNothing);
  });
}

Color? _zoneMarkerColour(WidgetTester tester, String device) =>
  (tester.widget<Container>(find.byKey(ValueKey('now-zone-marker-local:$device'))).decoration! as BoxDecoration).color;

Future<void> _surface(WidgetTester tester, CoreBridge core) async {
  tester.view.physicalSize = const Size(1920, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MeretApp(core: core));
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _command(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await _settle(tester);
}

class _RecordingCore extends FakeCore {
  final removed = <int>[];

  @override
  Future<void> removeRoot(int id) async {
    removed.add(id);
    await super.removeRoot(id);
  }
}
