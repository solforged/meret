import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/main.dart';
import 'package:meret/shell/trail_swipe.dart';

void main() {
  /// A two-finger swipe on a trackpad from the middle of [finder], by [pan].
  Future<void> swipe(WidgetTester tester, Finder finder, Offset pan, {int steps = 8}) async {
    final at = tester.getCenter(finder);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await gesture.panZoomStart(at);
    for (var i = 1; i <= steps; i++) {
      await gesture.panZoomUpdate(at, pan: pan * (i / steps));
      await tester.pump(const Duration(milliseconds: 8));
    }
    await gesture.panZoomEnd();
    await tester.pump();
  }

  Widget host(List<int> steps, Widget child) => MaterialApp(home: Scaffold(body: TrailSwipe(onStep: steps.add, child: child)));

  testWidgets('SWIPE-1 two fingers right go back, two fingers left go forward, once per swipe', (tester) async {
    final steps = <int>[];
    await tester.pumpWidget(host(steps, const SizedBox.expand(key: ValueKey('area'))));

    await swipe(tester, find.byKey(const ValueKey('area')), const Offset(140, 4));
    expect(steps, [-1]);
    await swipe(tester, find.byKey(const ValueKey('area')), const Offset(-140, -6));
    expect(steps, [-1, 1]);
  });

  testWidgets('SWIPE-2 a short drift does nothing and a long swipe keeps stepping', (tester) async {
    final steps = <int>[];
    await tester.pumpWidget(host(steps, const SizedBox.expand(key: ValueKey('area'))));

    await swipe(tester, find.byKey(const ValueKey('area')), const Offset(40, 0));
    expect(steps, isEmpty);
    await swipe(tester, find.byKey(const ValueKey('area')), const Offset(-520, 0), steps: 40);
    expect(steps, [1, 1, 1]);
  });

  testWidgets('SWIPE-3 scrolling a list up and down never steps, and still scrolls', (tester) async {
    final steps = <int>[];
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(host(steps, ListView.builder(
      key: const ValueKey('list'), controller: scroll, itemExtent: 30, itemCount: 200,
      itemBuilder: (_, i) => Text('row $i'),
    )));

    await swipe(tester, find.byKey(const ValueKey('list')), const Offset(12, -260));
    expect(steps, isEmpty);
    expect(scroll.offset, greaterThan(100));
  });

  testWidgets('SWIPE-4 a sideways swipe over a list steps and leaves the list where it was', (tester) async {
    final steps = <int>[];
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(host(steps, ListView.builder(
      key: const ValueKey('list'), controller: scroll, itemExtent: 30, itemCount: 200,
      itemBuilder: (_, i) => Text('row $i'),
    )));

    await swipe(tester, find.byKey(const ValueKey('list')), const Offset(-160, 10));
    expect(steps, [1]);
    expect(scroll.offset, 0);
  });

  testWidgets('SWIPE-5 what scrolls sideways under the pointer keeps the swipe', (tester) async {
    final steps = <int>[];
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(host(steps, Center(child: SizedBox(height: 40, child: ListView.builder(
      key: const ValueKey('strip'), controller: scroll, scrollDirection: Axis.horizontal, itemExtent: 120, itemCount: 60,
      itemBuilder: (_, i) => Text('hit $i'),
    )))));

    await swipe(tester, find.byKey(const ValueKey('strip')), const Offset(-200, 0));
    expect(steps, isEmpty);
    expect(scroll.offset, greaterThan(100));
  });

  testWidgets('SWIPE-6 a sideways wheel steps once per gesture', (tester) async {
    final steps = <int>[];
    await tester.pumpWidget(host(steps, const SizedBox.expand(key: ValueKey('area'))));
    final at = tester.getCenter(find.byKey(const ValueKey('area')));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(at));
    for (var i = 0; i < 12; i++) {
      await tester.sendEventToBinding(pointer.scroll(const Offset(20, 0), timeStamp: Duration(milliseconds: 16 * i)));
    }
    expect(steps, [1], reason: 'the view goes right, so fingers went left: forward');
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 40), timeStamp: const Duration(milliseconds: 1000)));
    for (var i = 0; i < 6; i++) {
      await tester.sendEventToBinding(pointer.scroll(const Offset(-20, 0), timeStamp: Duration(milliseconds: 1400 + 16 * i)));
    }
    expect(steps, [1, -1]);
  });

  testWidgets('SWIPE-7 in the app a swipe walks the open trail like [ and ], whatever holds the keyboard', (tester) async {
    tester.view.physicalSize = const Size(1728, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = FakeCore();
    final row = ((await core.rows('', const ViewDto(sort: SortKeyDto.library_, descending: false, group: false), 0, 1)).items.single as ItemDto_Track).row;
    await core.startTrail(const TargetDto.search(query: ''));
    await core.follow(0, TargetDto.release(id: row.releaseId), ThreadKind.matched, 'library');
    await tester.pumpWidget(MeretApp(core: core));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    // Today lies over the restored trail; a swipe forward takes it away, as ] does.
    await swipe(tester, find.byType(TrailSwipe), const Offset(-160, 0));
    await tester.pump(const Duration(milliseconds: 400));
    expect((await core.trail())!.current, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    await swipe(tester, find.byType(TrailSwipe), const Offset(160, 0));
    await tester.pump(const Duration(milliseconds: 400));
    expect((await core.trail())!.current, 0, reason: 'fingers right is back, with the query line focused too');

    await swipe(tester, find.byType(TrailSwipe), const Offset(-160, 0));
    await tester.pump(const Duration(milliseconds: 400));
    expect((await core.trail())!.current, 1);
  });
}
