import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/home/today.dart';
import 'package:meret/main.dart';
import 'package:meret/now/lcd.dart';
import 'package:meret/shell/pane_row.dart';
import 'package:meret/shell/query_line.dart';
import 'package:meret/shell/window_chrome.dart';

void main() {
  testWidgets('FOCUS-1 Tab runs the top line left to right, then Home, then the page', (tester) async {
    await _surface(tester, _Core());
    final query = tester.widget<QueryLine>(find.byType(QueryLine)).focus;
    final seen = <String>[];
    for (var i = 0; i < 60; i++) {
      await _tab(tester);
      seen.add(FocusManager.instance.primaryFocus == query ? 'query' : _who(FocusManager.instance.primaryFocus));
      if (i > 0 && seen[i] == seen.first) break;
    }
    expect(seen.take(7), ['lcd-previous', 'lcd-toggle', 'lcd-next', 'lcd-title', 'lcd-seek', 'query', 'activity']);
    final lap = seen.length - 1;
    final home = [for (var i = 7; i < lap; i++) if (seen[i].startsWith('home-')) i];
    expect(home, isNotEmpty);
    expect(home.last - home.first, home.length - 1, reason: 'the sidebar is one run, never interleaved with the page');
    expect(home.first, 7, reason: 'the sidebar follows the top line');
    expect(seen.skip(home.last + 1).take(lap - home.last - 1), isNot(contains(startsWith('home-'))));
    expect(seen.skip(home.last + 1).take(lap - home.last - 1), isNotEmpty, reason: 'then the page');
  });

  testWidgets('FOCUS-2 Shift+Tab reverses Tab exactly, through the query and its LCD swap', (tester) async {
    await _surface(tester, _Core());
    final forward = <FocusNode>[];
    for (var i = 0; i < 12; i++) {
      await _tab(tester);
      forward.add(FocusManager.instance.primaryFocus!);
    }
    for (var i = forward.length - 2; i >= 0; i--) {
      await _tab(tester, reverse: true);
      expect(FocusManager.instance.primaryFocus, same(forward[i]), reason: 'back to stop ${i + 1}');
    }
    // At the first stop, the dot is six Tabs on; Shift+Tab goes back through the query to the LCD, and Tab forward again.
    final query = tester.widget<QueryLine>(find.byType(QueryLine)).focus;
    for (var i = 0; i < 6; i++) {
      await _tab(tester);
    }
    expect(_who(FocusManager.instance.primaryFocus), 'activity');
    await _tab(tester, reverse: true);
    expect(FocusManager.instance.primaryFocus, same(query));
    await _tab(tester, reverse: true);
    expect(_who(FocusManager.instance.primaryFocus), 'lcd-seek');
    await _tab(tester);
    expect(FocusManager.instance.primaryFocus, same(query));
  });

  testWidgets('D7 Space plays or pauses from the LCD scrubber and the LCD, which Enter opens Now from', (tester) async {
    final core = _Core();
    await _surface(tester, core);
    bool open() => tester.widget<Lcd>(find.byType(Lcd)).open;
    // A seek click leaves the scrubber holding the focus.
    await tester.tap(find.byKey(const ValueKey('lcd-seek')));
    await tester.pumpAndSettle();
    expect(_who(FocusManager.instance.primaryFocus), 'lcd-seek');
    core.transports.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _settle(tester);
    expect(core.transports, [const TransportDto.resume()]);
    expect(open(), isFalse, reason: 'Space is not the LCD button');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _settle(tester);
    expect(core.transports.last, const TransportDto.pause());
    expect(open(), isFalse);

    // The scrubber takes the arrows.
    core.transports.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(core.transports.single, isA<TransportDto_Seek>());

    // On the LCD itself: Space is the transport, Enter opens Now.
    await _tab(tester, reverse: true);
    expect(_who(FocusManager.instance.primaryFocus), 'lcd-title');
    core.transports.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _settle(tester);
    expect(core.transports, [const TransportDto.resume()]);
    expect(open(), isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester);
    expect(open(), isTrue);
  });

  testWidgets('S8 behind the History sheet Play or Pause stays on; Help ▸ Keys toggles the Keys sheet', (tester) async {
    final core = _Core();
    await _surface(tester, core);
    List<String> on() => [for (final MapEntry(:key, :value) in WindowChrome.instance.menuState.entries) if (value) key];
    expect(on(), containsAll(['home', 'toggle', 'history', 'keys']));

    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('history-sheet')), findsOneWidget);
    expect(on(), ['toggle']);
    core.transports.clear();
    WindowChrome.instance.onMenu!('toggle');
    await _settle(tester);
    expect(core.transports, [const TransportDto.resume()]);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.byKey(const ValueKey('history-sheet')), findsNothing);
    expect(on(), containsAll(['home', 'toggle', 'history', 'keys']));

    WindowChrome.instance.onMenu!('keys');
    await _settle(tester);
    expect(find.byKey(const ValueKey('keys-sheet')), findsOneWidget);
    expect(on(), ['keys']);
    WindowChrome.instance.onMenu!('keys');
    await _settle(tester);
    expect(find.byKey(const ValueKey('keys-sheet')), findsNothing);
    expect(on(), containsAll(['home', 'toggle', 'history', 'keys']));
  });

  testWidgets('H1 clicking the docked search leaves the pointer over the field, not the LCD', (tester) async {
    await _surface(tester, _Core());
    final query = find.byType(QueryLine);
    final docked = tester.getRect(query);
    final point = Offset(docked.left + docked.width * 0.25, docked.center.dy);
    await tester.tapAt(point);
    await tester.pumpAndSettle();
    expect(tester.widget<QueryLine>(query).focus.hasFocus, isTrue);
    expect(tester.getRect(query).contains(point), isTrue);
    expect(tester.getRect(find.byKey(const ValueKey('lcd'))).contains(point), isFalse, reason: 'the LCD never slides under the pointer');
    // The same click again stays in the field.
    await tester.tapAt(point);
    await tester.pumpAndSettle();
    expect(tester.widget<QueryLine>(query).focus.hasFocus, isTrue);
    expect(find.byKey(const ValueKey('now-panel-position')).evaluate().isNotEmpty && tester.widget<Lcd>(find.byType(Lcd)).open, isFalse);
  });

  testWidgets('H2 Tab on the open activity popover goes into its rows and out past the last', (tester) async {
    await _surface(tester, _Core());
    for (var i = 0; i < 7; i++) {
      await _tab(tester);
    }
    expect(_who(FocusManager.instance.primaryFocus), 'activity');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('activity-settings')), findsOneWidget);
    await _tab(tester);
    expect(_who(FocusManager.instance.primaryFocus), startsWith('activity-'), reason: 'into the popover');
    expect(find.byKey(const ValueKey('activity-settings')), findsOneWidget);
    for (var i = 0; i < 12 && find.byKey(const ValueKey('activity-settings')).evaluate().isNotEmpty; i++) {
      await _tab(tester);
    }
    expect(find.byKey(const ValueKey('activity-settings')), findsNothing, reason: 'past the last row it closes');
    expect(_who(FocusManager.instance.primaryFocus), 'home-today', reason: 'and Tab goes on to the sidebar');
  });

  testWidgets('W1 the LCD stays on a trail page at 600 wide', (tester) async {
    final core = _Core();
    await _seedTrail(core);
    await _surface(tester, core, width: 600, height: 900);
    await _showTrail(tester);
    expect(find.byKey(const ValueKey('lcd-toggle')), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('lcd'))).width, greaterThanOrEqualTo(210));
    expect(tester.takeException(), isNull);
  });

  testWidgets('TR-14 the LCD stays put when the chip changes its words', (tester) async {
    Future<Rect> lcdAfter({required bool follow}) async {
      final core = _Core();
      await _seedTrail(core, follow: follow);
      await _surface(tester, core, width: 1100);
      await _showTrail(tester);
      return tester.getRect(find.byKey(const ValueKey('lcd')));
    }

    final two = await lcdAfter(follow: false);
    await tester.pumpWidget(const SizedBox());
    final three = await lcdAfter(follow: true);
    expect(three, two);
  });

  testWidgets('F12 Today draws nothing for the picks until they arrive', (tester) async {
    final core = _SlowPicks();
    await _surface(tester, core);
    expect(find.text('Finding something to play…'), findsNothing);
    expect(find.text('Or play something'), findsNothing);
    core.gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Or play something'), findsOneWidget);
  });

  testWidgets('F11 Go ▸ Home lays the column over the trail, again goes to Today, and the panes settle', (tester) async {
    final core = _Core();
    await _seedTrail(core);
    await _surface(tester, core);
    await _showTrail(tester);
    double panes() => tester.renderObject<RenderAnimatedOpacity>(
        find.ancestor(of: find.byType(PaneRow), matching: find.byType(AnimatedOpacity)).first).opacity.value;
    expect(panes(), 1);
    WindowChrome.instance.onMenu!('home');
    await tester.pumpAndSettle();
    expect(panes(), moreOrLessEquals(0.35));
    expect(tester.getSize(find.byKey(const ValueKey('home-column'))).width, 248);
    WindowChrome.instance.onMenu!('home');
    await tester.pumpAndSettle();
    expect(find.byType(Today), findsOneWidget);
    expect(panes(), 1);
  });
}

String _who(FocusNode? node) {
  if (node == null) return 'none';
  var label = '?';
  node.context?.visitAncestorElements((e) {
    final key = e.widget.key;
    if (key is ValueKey) {
      label = '${key.value}';
      return false;
    }
    return true;
  });
  return label;
}

Future<void> _tab(WidgetTester tester, {bool reverse = false}) async {
  if (reverse) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  if (reverse) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pumpAndSettle();
}

/// Playing, the playhead clock never lets `pumpAndSettle` finish: give the motions their time instead.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _seedTrail(FakeCore core, {bool follow = true}) async {
  var trail = await core.startTrail(const TargetDto.search(query: ''));
  final release = await core.release(PlatformInt64Util.from(1));
  trail = await core.follow(trail.current, TargetDto.release(id: release.id), ThreadKind.matched, 'library');
  if (follow) {
    await core.follow(trail.current, release.artistLinks.first.to, ThreadKind.albumArtist, release.artistLinks.first.provider);
  }
}

/// Paused, so `pumpAndSettle` is not kept awake by the playhead clock.
Future<void> _surface(WidgetTester tester, FakeCore core, {double width = 1728, double height = 900}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await core.transport(const TransportDto.pause());
  await tester.pumpWidget(MeretApp(core: core));
  await tester.pumpAndSettle();
}

Future<void> _showTrail(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
  await tester.pumpAndSettle();
}

class _Core extends FakeCore {
  final transports = <TransportDto>[];

  @override
  Future<void> transport(TransportDto cmd) {
    transports.add(cmd);
    return super.transport(cmd);
  }
}

class _SlowPicks extends FakeCore {
  final gate = Completer<void>();

  @override
  Future<List<PickDto>> picks(int limit) async {
    await gate.future;
    return super.picks(limit);
  }
}
