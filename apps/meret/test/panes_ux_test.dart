import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64, PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/panes/pane.dart';
import 'package:meret/panes/release_pane.dart';
import 'package:meret/theme/light.dart';
import 'package:meret/theme/tokens.dart';

void main() {
  testWidgets('NAV-N1 a lookups landing refetches a release pane in place: tracklist, scroll and selection stay', (tester) async {
    final core = _GatedCore();
    _desktop(tester);
    final id = PlatformInt64Util.from(1);
    Widget pane(BigInt lookups) => _pane(ReleasePane(
      core: core, id: id, fromStop: 0, onFollow: (_, _, _) async {}, lookupsVersion: lookups,
    ));
    await tester.pumpWidget(pane(BigInt.zero));
    await tester.pump();
    expect(find.byKey(const ValueKey('release-row-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('release-row-2')));
    await tester.pump();
    final scrollable = find.byType(Scrollable).first;
    await tester.drag(scrollable, const Offset(0, -300));
    await tester.pump();
    final position = tester.state<ScrollableState>(scrollable).position;
    final offset = position.pixels;
    expect(offset, greaterThan(0));
    expect(tester.widget<Semantics>(find.byKey(const ValueKey('release-row-2'))).properties.selected, isTrue);

    // Lookups bump the version; the second fetch stays in flight.
    core.gate = Completer<void>();
    await tester.pumpWidget(pane(BigInt.one));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(core.fetches, 2);
    expect(find.text('Reading release…'), findsNothing);
    expect(find.byType(Scrollable).first, findsOneWidget);
    expect(tester.state<ScrollableState>(find.byType(Scrollable).first).position, same(position));
    expect(position.pixels, offset);
    expect(tester.widget<Semantics>(find.byKey(const ValueKey('release-row-2'))).properties.selected, isTrue);

    core.gate!.complete();
    await tester.pump();
    await tester.pump();
    expect(tester.state<ScrollableState>(find.byType(Scrollable).first).position, same(position));
    expect(position.pixels, offset);
    expect(tester.widget<Semantics>(find.byKey(const ValueKey('release-row-2'))).properties.selected, isTrue);
  });

  testWidgets('ANIM-A8 thread rows, tracklist rows and pane action buttons tint on mouse hover', (tester) async {
    final core = FakeCore();
    _desktop(tester);
    await tester.pumpWidget(_pane(Column(children: [
      PaneActions(primary: 'Allow', onPrimary: () {}, secondary: 'Not now', onSecondary: () {}),
      Expanded(child: ReleasePane(core: core, id: PlatformInt64Util.from(1), fromStop: 0, onFollow: (_, _, _) async {})),
    ])));
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    Color tint(Finder door) => (tester.widget<Container>(find.descendant(of: door, matching: find.byType(Container)).first).decoration! as BoxDecoration).color!;
    for (final (name, door) in [
      ('tracklist row', find.byKey(const ValueKey('release-row-1'))),
      ('thread line', find.byType(ThreadLine).first),
      ('action button', find.byWidgetPredicate((widget) => widget is PaneActionButton && widget.label == 'Not now')),
    ]) {
      expect(tint(door), isNot(Tok.panel2), reason: 'untouched: $name');
      await mouse.moveTo(tester.getCenter(door));
      await tester.pump();
      expect(tint(door), Tok.panel2, reason: 'hovered: $name');
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(tint(door), isNot(Tok.panel2), reason: 'left: $name');
    }
  });

  testWidgets('ANIM-A9 a release pane shows the stop title while its body is read', (tester) async {
    final core = _GatedCore()..gate = Completer<void>();
    _desktop(tester);
    await tester.pumpWidget(_pane(ReleasePane(
      core: core, id: PlatformInt64Util.from(1), fromStop: 0, onFollow: (_, _, _) async {}, title: 'Xenogears Original Soundtrack',
    )));
    await tester.pump();
    expect(find.text('Xenogears Original Soundtrack'), findsOneWidget);
    expect(find.text('Reading release…'), findsOneWidget);
    core.gate!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Reading release…'), findsNothing);
    expect(find.text('Xenogears Original Soundtrack'), findsOneWidget);
  });
}

void _desktop(WidgetTester tester) {
  tester.view.physicalSize = const Size(1100, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _pane(Widget child) => MaterialApp(home: Scaffold(body: LightScope(light: Light.brass, child: child)));

/// A core whose release fetch waits on [gate] when one is set.
class _GatedCore extends FakeCore {
  Completer<void>? gate;
  int fetches = 0;

  @override
  Future<ReleaseDto> release(PlatformInt64 id) async {
    fetches++;
    if (gate case final gate?) await gate.future;
    return super.release(id);
  }
}
