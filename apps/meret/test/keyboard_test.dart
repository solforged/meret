import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;
import 'package:meret/core/bridge.dart';
import 'package:meret/main.dart';
import 'package:meret/panes/release_pane.dart';
import 'package:meret/panes/table_pane.dart';
import 'package:meret/shell/query_line.dart';
import 'package:meret/theme/light.dart';

void main() {
  testWidgets('KEYS-1 Escape dismisses suggestions then empties and unfocuses, or does so at once without suggestions', (tester) async {
    await _surface(tester, _KeysCore());
    final field = find.byType(TextField);
    final focus = tester.widget<QueryLine>(find.byType(QueryLine)).focus;
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    await tester.enterText(field, 'o');
    await tester.pump();
    expect(find.byKey(const ValueKey('query-hits')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('query-hits')), findsNothing);
    expect(focus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    expect(tester.widget<TextField>(field).controller!.text, '', reason: 'nothing stale promises an Enter');

    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    for (final input in ['', 'play o']) {
      await tester.enterText(field, input);
      await tester.pump();
      expect(find.byKey(const ValueKey('query-hits')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(focus.hasFocus, isFalse);
      expect(tester.widget<TextField>(field).controller!.text, '');
    }
  });

  testWidgets('KEYS-2 the query owns printable shortcuts and releases surface keys when unfocused', (tester) async {
    final core = _KeysCore();
    await _surface(tester, core);
    final field = find.byType(TextField);
    final focus = tester.widget<QueryLine>(find.byType(QueryLine)).focus;
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    core.historyCalls = 0;
    var text = '';
    for (final (key, character, modifier) in [
      (LogicalKeyboardKey.keyH, 'h', null),
      (LogicalKeyboardKey.bracketLeft, '[', null),
      (LogicalKeyboardKey.bracketRight, ']', null),
      (LogicalKeyboardKey.space, ' ', null),
      (LogicalKeyboardKey.keyO, 'o', null),
      (LogicalKeyboardKey.slash, '/', null),
      (LogicalKeyboardKey.space, ' ', LogicalKeyboardKey.shiftLeft),
      (LogicalKeyboardKey.space, ' ', LogicalKeyboardKey.altLeft),
    ]) {
      if (modifier != null) await tester.sendKeyDownEvent(modifier);
      final handled = await tester.sendKeyEvent(key);
      if (modifier != null) await tester.sendKeyUpEvent(modifier);
      // The engine delivers text only when the framework leaves the key unhandled.
      expect(handled, isFalse, reason: '$key must reach text input');
      text += character;
      tester.testTextInput.enterText(text);
      await tester.pump();
    }
    expect(tester.widget<TextField>(field).controller!.text, 'h[] o/  ');
    expect([core.backs, core.forwards, core.historyCalls, core.playSomethingCalls, core.transports.length], [0, 0, 0, 0, 0]);
    expect(find.byKey(const ValueKey('history-sheet')), findsNothing);

    focus.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
    await tester.pump();
    await _modified(tester, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyL);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await tester.pump();
    expect(core.forwards, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pump();
    expect(core.backs, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(core.transports, [const TransportDto.pause()]);
    await _modified(tester, LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.space);
    expect(core.playSomethingCalls, 1);
    await _modified(tester, LogicalKeyboardKey.altLeft, LogicalKeyboardKey.space);
    expect(core.transports.last, const TransportDto.fromStart());
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('history-sheet')), findsOneWidget);
    expect(core.historyCalls, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    expect(focus.hasFocus, isTrue);
  });

  testWidgets('Escape out of the query line hands focus back to the surface after a door was clicked', (tester) async {
    final core = _KeysCore();
    await _surface(tester, core);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Albums'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final focus = tester.widget<QueryLine>(find.byType(QueryLine)).focus;
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pump();
    expect(core.backs, 1);
  });

  testWidgets('KEYS-3 held Enter and playback shortcuts activate only once', (tester) async {
    final core = _KeysCore();
    final releaseId = (await core.now().first).releaseId!;
    _desktop(tester);
    await tester.pumpWidget(_pane(ReleasePane(
      core: core, id: releaseId, fromStop: 0, onFollow: (_, _, _) async {},
    )));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('release-row-0')));
    await tester.pump();
    core.releasePlays = 0;
    await _hold(tester, LogicalKeyboardKey.enter);
    final releasePlays = core.releasePlays;

    final opened = <TargetDto>[];
    await tester.pumpWidget(_pane(TablePane(
      core: core, query: '', onQuery: (_) {}, onFollow: (target, _) async { opened.add(target); },
    )));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('table-row-0')));
    await tester.pump(const Duration(milliseconds: 350));
    await _hold(tester, LogicalKeyboardKey.enter);
    final tablePlays = core.tablePlays;
    opened.clear();
    await _hold(tester, LogicalKeyboardKey.enter, modifier: LogicalKeyboardKey.metaLeft);

    await _surface(tester, core);
    core.transports.clear();
    await _hold(tester, LogicalKeyboardKey.space);
    final toggles = core.transports.length;
    await _hold(tester, LogicalKeyboardKey.space, modifier: LogicalKeyboardKey.shiftLeft);
    core.transports.clear();
    await _hold(tester, LogicalKeyboardKey.space, modifier: LogicalKeyboardKey.altLeft);
    expect([releasePlays, tablePlays, opened.length, toggles, core.playSomethingCalls, core.transports.length], [1, 1, 1, 1, 1, 1]);
    expect(core.transports.single, const TransportDto.fromStart());
  });

  testWidgets('KEYS-4 confirming an empty or whitespace name keeps an unnamed trail', (tester) async {
    final core = _KeysCore();
    await _surface(tester, core);
    await _modified(tester, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyL);
    for (final input in ['', '   \t ']) {
      await _modified(tester, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyS);
      final field = find.byKey(const ValueKey('trail-name'));
      expect(field, findsOneWidget);
      await tester.enterText(field, input);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('keep-trail-dialog')), findsNothing);
      final trail = (await core.trail())!;
      expect(trail.kept, isTrue);
      expect(trail.name, isNull);
    }
    expect(core.names, [null, null]);
  });
}

void _desktop(WidgetTester tester) {
  tester.view.physicalSize = const Size(1100, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _surface(WidgetTester tester, CoreBridge core) async {
  _desktop(tester);
  await tester.pumpWidget(MeretApp(core: core));
  await tester.pump();
}

Widget _pane(Widget child) => MaterialApp(home: Scaffold(body: LightScope(light: Light.brass, child: child)));

Future<void> _modified(WidgetTester tester, LogicalKeyboardKey modifier, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _hold(WidgetTester tester, LogicalKeyboardKey key, {LogicalKeyboardKey? modifier}) async {
  if (modifier != null) await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyDownEvent(key);
  for (var i = 0; i < 5; i++) {
    await tester.sendKeyRepeatEvent(key);
  }
  await tester.sendKeyUpEvent(key);
  if (modifier != null) await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

class _KeysCore extends FakeCore {
  int backs = 0;
  int forwards = 0;
  int historyCalls = 0;
  int playSomethingCalls = 0;
  int releasePlays = 0;
  int tablePlays = 0;
  final transports = <TransportDto>[];
  final names = <String?>[];

  @override
  Future<TrailDto?> trailBack() {
    backs++;
    return super.trailBack();
  }

  @override
  Future<TrailDto?> trailForward() {
    forwards++;
    return super.trailForward();
  }

  @override
  Future<List<ListenDto>> history(int limit) {
    historyCalls++;
    return super.history(limit);
  }

  @override
  Future<void> transport(TransportDto cmd) {
    transports.add(cmd);
    return super.transport(cmd);
  }

  @override
  Future<PickDto?> playSomething() {
    playSomethingCalls++;
    return super.playSomething();
  }

  @override
  Future<void> playRelease({required PlatformInt64 id, required int index, int? fromStop}) {
    releasePlays++;
    return super.playRelease(id: id, index: index, fromStop: fromStop);
  }

  @override
  Future<void> playResults(String query, ViewDto view, int index) {
    tablePlays++;
    return super.playResults(query, view, index);
  }

  @override
  Future<TrailDto> keepTrail({String? name}) {
    names.add(name);
    return super.keepTrail(name: name);
  }
}
