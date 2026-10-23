import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/shell/pane_row.dart';

void main() {
  RowLayout layout(int count, {int? focus, int start = 0, double width = 1728, int maxVisible = 5, double minPane = 440, Set<int> wide = const {}}) =>
      PaneRow.layout(count: count, focus: focus ?? count - 1, start: start, width: width, maxVisible: maxVisible,
        minPane: minPane, maxPane: 560, wide: wide, spine: 46, ghostMin: 140);

  test('a pane keeps its width however many open beside it', () {
    expect({for (var n = 1; n <= 8; n++) layout(n).pane}, {560}, reason: 'three 560 pt panes and one spine fit 1728');
    expect(layout(1).widths, [560]);
    expect(layout(1).ghost, (560, 1168), reason: 'a lone pane leaves the rest to the ghost slot');
    expect(layout(2).ghost, (1120, 608));
    expect(layout(3).ghost, isNull, reason: '48 pt is too little for a ghost slot');
    expect(layout(3, width: 1300).pane, closeTo(560, 0.01));
    expect(layout(3, width: 1300).widths, [46, 560, 560], reason: 'two fit 1300; the oldest folds');
  });

  test('following past the window folds the oldest pane to a spine on the left', () {
    final row = layout(4);
    expect(row.start, 1);
    expect(row.widths, [46, 560, 560, 560]);
    expect(row.x, [0, 46, 606, 1166]);
  });

  test('the window shifts only when the focus would leave it', () {
    expect(layout(4, focus: 2, start: 1).start, 1, reason: '[ within the window moves nothing');
    expect(layout(4, focus: 1, start: 1).start, 1);
    final back = layout(4, focus: 0, start: 1);
    expect(back.start, 0, reason: '[ past the window shifts it by one pane');
    expect(back.widths, [560, 560, 560, 46], reason: 'the stop ahead folds to a spine on the right');
    expect(back.x, [0, 560, 1120, 1680]);
    expect(back.ghost, isNull, reason: 'no ghost while the last stop is out of the window');
    expect(layout(3, focus: 2, start: 5).start, 0, reason: 'a shorter row pulls the window back');
  });

  test('spines nearest the window show first when there is no room for them all', () {
    final row = layout(10);
    expect(row.start, 7);
    expect(row.x.take(6), everyElement(isNull));
    expect(row.x.skip(6), [0, 46, 606, 1166]);
    final middle = layout(10, focus: 4, start: 4, width: 1800);
    expect(middle.x.where((x) => x != null), hasLength(5), reason: 'three panes and one spine each side');
    expect(middle.widths[3], 46);
    expect(middle.widths[7], 46);
    expect(middle.x[3], 0);
    expect(middle.x[7], 46 + 3 * 560);
  });

  test('a table takes the leftover room and gives some back when a pane opens after it', () {
    expect(layout(1, wide: {0}).widths, [1728]);
    expect(layout(1, wide: {0}).ghost, isNull);
    expect(layout(2, wide: {0}).widths, [1168, 560]);
    expect(layout(4, wide: {0}).widths, [46, 560, 560, 560], reason: 'a folded table does not absorb width');
  });

  test('narrow rows hold one pane, and a lone pane takes the whole width', () {
    expect(layout(1, width: 375, minPane: 300).widths, [375]);
    expect(layout(2, width: 375, minPane: 300).widths, [46, 329]);
    expect(layout(4, width: 2080, maxVisible: 3).widths, [46, 560, 560, 560], reason: 'the width class caps full panes');
  });

  group('motion', () {
    final taps = <Key>[];
    setUp(taps.clear);

    void testMotion(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      tester.view.physicalSize = const Size(2000, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await body(tester);
    });

    Widget pane(Key key) => GestureDetector(key: key, behavior: HitTestBehavior.opaque, onTap: () => taps.add(key), child: const SizedBox.expand());

    Widget row(List<Key> keys, {List<Key> parked = const [], int? focus, int swap = 0, double width = 1728}) => Directionality(
      textDirection: TextDirection.ltr,
      child: Align(alignment: Alignment.topLeft, child: SizedBox(
        width: width, height: 200,
        child: PaneRow(
          focus: focus, swap: swap,
          ghost: const SizedBox.expand(key: ValueKey('ghost')),
          parked: [for (final key in parked) pane(key)],
          children: [for (final key in keys) pane(key)],
        ),
      )),
    );

    double x(WidgetTester tester, Key key) => tester.getTopLeft(find.byKey(key, skipOffstage: false)).dx;
    final a = GlobalKey(debugLabel: 'a'), b = GlobalKey(debugLabel: 'b'), c = GlobalKey(debugLabel: 'c'), d = GlobalKey(debugLabel: 'd');

    testMotion('a follow fades the new pane in from 12 pt to the left and moves nothing else', (tester) async {
      await tester.pumpWidget(row([a, b]));
      expect(x(tester, a), 0);
      expect(x(tester, b), 560);
      expect(tester.getTopLeft(find.byKey(const ValueKey('ghost'))).dx, 1120);
      await tester.pumpWidget(row([a, b, c]));
      await tester.pump();
      await tester.tapAt(const Offset(1300, 100));
      expect(taps, isEmpty, reason: 'not painted, so not hit, before it starts');
      await tester.pump(const Duration(milliseconds: 40));
      expect(x(tester, c), allOf(greaterThan(1108), lessThan(1120)));
      expect(x(tester, a), 0);
      expect(x(tester, b), 560);
      await tester.pump(const Duration(milliseconds: 120));
      expect(x(tester, c), 1120);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(1300, 100));
      expect(taps, [c]);
      expect(find.byKey(const ValueKey('ghost')), findsNothing);
    });

    testMotion('following past the window shifts the panes, then the new one enters', (tester) async {
      await tester.pumpWidget(row([a, b, c]));
      await tester.pumpWidget(row([a, b, c, d]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(x(tester, b), allOf(greaterThan(46), lessThan(560)), reason: 'sliding into place');
      await tester.tapAt(const Offset(1500, 100));
      expect(taps, isEmpty, reason: 'the new pane waits for the shift');
      await tester.pump(const Duration(milliseconds: 100));
      expect(x(tester, b), 46);
      expect(x(tester, c), 606);
      await tester.pumpAndSettle();
      expect(x(tester, d), 1166);
      expect(tester.getSize(find.byKey(a)).width, 46, reason: 'the oldest folded to a spine');
    });

    testMotion('[ within the window moves nothing; past it, the window shifts by one pane', (tester) async {
      await tester.pumpWidget(row([a, b, c, d]));
      await tester.pumpWidget(row([a, b, c, d], focus: 2));
      await tester.pump(const Duration(milliseconds: 50));
      expect([x(tester, a), x(tester, b), x(tester, c), x(tester, d)], [0, 46, 606, 1166]);
      await tester.pumpWidget(row([a, b, c, d], focus: 1));
      await tester.pumpWidget(row([a, b, c, d], focus: 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(x(tester, b), allOf(greaterThan(46), lessThan(560)));
      await tester.pumpAndSettle();
      expect([x(tester, a), x(tester, b), x(tester, c), x(tester, d)], [0, 560, 1120, 1680]);
      expect(tester.getSize(find.byKey(d)).width, 46, reason: 'the stop ahead folds to a spine on the right');
    });

    testMotion('a branch that leaves drops and fades, unhittable, and the new pane follows 120 ms later', (tester) async {
      await tester.pumpWidget(row([a, b, c], focus: 1));
      await tester.pumpWidget(row([a, b, d], parked: [c]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getTopLeft(find.byKey(c, skipOffstage: false)).dy, allOf(greaterThan(0), lessThan(16)));
      expect(tester.getTopLeft(find.byKey(c, skipOffstage: false)).dx, 1120);
      await tester.tapAt(const Offset(1300, 100));
      expect(taps, isEmpty, reason: 'a leaving pane takes no hits, and the new one has not started');
      await tester.pump(const Duration(milliseconds: 60));
      expect(x(tester, d), allOf(greaterThanOrEqualTo(1108), lessThan(1120)));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(1300, 100));
      expect(taps, [d]);
      expect(find.byKey(c), findsNothing, reason: 'parked, not painted');
      expect(find.byKey(c, skipOffstage: false), findsOneWidget, reason: 'but still mounted');
    });

    testMotion('a branch swap brings the next branch up from below', (tester) async {
      await tester.pumpWidget(row([a, b, c]));
      await tester.pumpWidget(row([a, b, d], parked: [c], swap: 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(tester.getTopLeft(find.byKey(d)).dy, closeTo(24, 0.5));
      expect(x(tester, d), 1120, reason: 'straight up, not from the left');
      await tester.pump(const Duration(milliseconds: 90));
      expect(tester.getTopLeft(find.byKey(c, skipOffstage: false)).dy, lessThan(0), reason: 'the old branch leaves upwards');
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(d)).dy, 0);
    });

    testMotion('a change mid-shift carries on from where the panes are painted', (tester) async {
      await tester.pumpWidget(row([a, b, c, d]));
      await tester.pumpWidget(row([a, b, c, d], focus: 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final mid = x(tester, b);
      expect(mid, allOf(greaterThan(46), lessThan(560)));
      await tester.pumpWidget(row([a, b, c, d], focus: 3));
      await tester.pump();
      expect(x(tester, b), closeTo(mid, 1), reason: 'no jump: the shift back starts where the pane is');
      await tester.pumpAndSettle();
      expect([x(tester, a), x(tester, b), x(tester, c), x(tester, d)], [0, 46, 606, 1166]);
    });

    testMotion('a pane still dropping when the row changes again keeps fading out', (tester) async {
      await tester.pumpWidget(row([a, b, c], focus: 1));
      await tester.pumpWidget(row([a, b, d], parked: [c]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final dropped = tester.getTopLeft(find.byKey(c)).dy;
      expect(dropped, allOf(greaterThan(0), lessThan(16)));
      await tester.pumpWidget(row([a, b], parked: [c, d]));
      await tester.pump();
      expect(find.byKey(c), findsOneWidget, reason: 'it does not vanish mid-fade');
      expect(tester.getTopLeft(find.byKey(c)).dy, greaterThanOrEqualTo(dropped));
      await tester.pumpAndSettle();
      expect(find.byKey(c), findsNothing);
      expect(find.byKey(c, skipOffstage: false), findsOneWidget);
    });

    testMotion('a branch that comes back while still fading rises from where it is', (tester) async {
      await tester.pumpWidget(row([a, b, c]));
      await tester.pumpWidget(row([a, b, d], parked: [c], swap: 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final leaving = tester.getTopLeft(find.byKey(c)).dy;
      expect(leaving, lessThan(0));
      await tester.pumpWidget(row([a, b, c], parked: [d], swap: -1));
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(c)).dy, closeTo(leaving, 1), reason: 'not restarted from above');
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(c)).dy, 0);
      expect(x(tester, c), 1120);
    });

    testMotion('a resize settles at once', (tester) async {
      await tester.pumpWidget(row([a, b, c, d]));
      await tester.pumpWidget(row([a, b, c, d], width: 1300));
      expect([x(tester, c), x(tester, d)], [46 + 46, 46 + 46 + 560]);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testMotion('hits follow the painted pane mid-shift', (tester) async {
      await tester.pumpWidget(row([a, b, c, d]));
      await tester.pumpWidget(row([a, b, c, d], focus: 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final bx = x(tester, b);
      await tester.tapAt(Offset(bx + 5, 100));
      expect(taps, [b]);
      await tester.tapAt(Offset(bx - 5, 100));
      expect(taps, [b, a]);
    });
  });
}
