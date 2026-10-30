import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/main.dart';
import 'package:meret/panes/pane.dart';
import 'package:meret/panes/threads.dart';
import 'package:meret/shell/pane_row.dart';

/// The threads between panes (docs/navigation.md, "Threads"): short, in the
/// gutter, and as strong as the panes they join are painted.
void main() {
  testWidgets('THREAD-2 a thread leaves the lit row at the pane edge and lands at the star, inside the gutter', (tester) async {
    final core = FakeCore();
    await _trail(core, stops: 3);
    await _surface(tester, core);
    final spans = _spans(tester);
    expect(spans, hasLength(2));
    final origin = tester.getTopLeft(find.byType(ThreadLines));
    for (final (i, span) in spans.indexed) {
      final src = tester.getRect(_pane(i)), dst = tester.getRect(_pane(i + 1));
      final star = tester.getCenter(find.descendant(of: _pane(i + 1), matching: find.byKey(const ValueKey('pane-star'))));
      final bounds = span.path.getBounds().shift(origin);
      expect(bounds.left, greaterThanOrEqualTo(src.right - 20), reason: 'thread $i leaves from inside the source pane\'s margin');
      expect(bounds.right, lessThan(star.dx), reason: 'and stops short of the star');
      expect(bounds.right, lessThanOrEqualTo(dst.left + 22), reason: 'never running on into the new pane');
      expect(span.end.dy + origin.dy, closeTo(star.dy, 0.5), reason: 'at the star\'s height');
      expect(span.alpha, 1);
    }
  });

  testWidgets('THREAD-3 a new pane takes its thread in with it: none at zero opacity, then as the pane is painted', (tester) async {
    final core = FakeCore();
    await _trail(core, release: true);
    await _surface(tester, core);
    expect(_spans(tester), isEmpty, reason: 'one pane, no thread');
    final release = await core.release(PlatformInt64Util.from(1));
    await tester.tap(find.byKey(ValueKey('thread-albumArtist-${release.artistLinks.first.to}')));
    await tester.pump();
    var shown = false;
    var last = 0.0;
    for (var ms = 0; ms <= 400; ms += 16) {
      final opacity = PaneRow.paintedOpacity(tester.renderObject(find.byType(Pane).last));
      final spans = _spans(tester);
      if (opacity == 0) {
        expect(spans, isEmpty, reason: 'no thread to a pane that is not painted, at $ms ms');
      } else {
        expect(spans, hasLength(1), reason: 'the thread comes with the pane, at $ms ms');
        expect(spans.single.alpha, greaterThanOrEqualTo(last), reason: 'it only strengthens as the pane enters, at $ms ms');
        expect(spans.single.alpha, lessThanOrEqualTo(opacity * 1.5 + 1e-9), reason: 'and is never ahead of it, at $ms ms');
        last = spans.single.alpha;
        shown = true;
      }
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(shown, isTrue);
    expect(last, 1);
  });

  testWidgets('THREAD-4 [ dims the thread with the pane ahead over the same 120 ms', (tester) async {
    final core = FakeCore();
    await _trail(core, stops: 3);
    await _surface(tester, core);
    expect(_spans(tester).map((span) => span.alpha), [1, 1]);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final mid = _spans(tester).last.alpha;
    expect(mid, allOf(lessThan(1), greaterThan(Pane.aheadOpacity)));
    await tester.pump(const Duration(milliseconds: 60));
    final dimmed = _spans(tester);
    expect(dimmed.first.alpha, 1, reason: 'the thread between the panes that stay is untouched');
    expect(dimmed.last.alpha, allOf(lessThan(mid), greaterThan(0.25)), reason: 'it stays readable, like the pane');
  });

  testWidgets('THREAD-5 a pane folded to a spine carries its thread from the spine, so the chain never breaks', (tester) async {
    final core = FakeCore();
    await _trail(core, stops: 4);
    await _surface(tester, core, width: 1000);
    final spans = _spans(tester);
    expect(spans, hasLength(2), reason: 'the stop before the spine is off the row; the rest are joined');
    final origin = tester.getTopLeft(find.byType(ThreadLines));
    final spine = tester.getRect(_pane(0));
    expect(spine.width, lessThan(60));
    expect(spans.first.start.dx + origin.dx, closeTo(spine.right - 3, 0.5));
    expect(spans.first.start.dy, closeTo(spans.first.end.dy, 0.5), reason: 'at header level, a straight tick');
    expect(spans.first.alpha, 1);
  });

  testWidgets('THREAD-6 a thread out of a pane that left the row stays where it was and fades with the pane', (tester) async {
    final core = FakeCore();
    await _trail(core, stops: 3);
    await _surface(tester, core);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pumpAndSettle();
    final left = _spans(tester).last;
    final game = find.byWidgetPredicate((w) => w is Semantics && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('thread-soundtrackOf'));
    await tester.tap(game);
    await tester.pump();
    final alphas = <double>[];
    for (var ms = 0; ms < 200; ms += 16) {
      await tester.pump(const Duration(milliseconds: 16));
      for (final span in _spans(tester)) {
        if (span.start.dy != left.start.dy) continue;
        expect(span.end.dy, closeTo(left.end.dy + 16, 17), reason: 'the old pane is still where it was, dropping');
        alphas.add(span.alpha);
      }
    }
    expect(alphas.length, greaterThan(3), reason: 'it stays while the pane fades, not gone in the first frame');
    expect(alphas.last, lessThan(alphas.first / 2), reason: 'and fades out with it');
    await tester.pumpAndSettle();
    expect(_spans(tester), hasLength(2), reason: 'only the threads of the row are left');
  });
}

List<ThreadSpan> _spans(WidgetTester tester) => tester.state<ThreadLinesState>(find.byType(ThreadLines)).spans();

Finder _pane(int i) => find.descendant(of: find.byType(ThreadLines), matching: find.byType(Pane)).at(i);

/// A search, its first release, that release's album artist, and the artist's
/// first collaborator, as far as [stops] goes; or, with [release], that release alone.
Future<void> _trail(FakeCore core, {int stops = 4, bool release = false}) async {
  final first = await core.release(PlatformInt64Util.from(1));
  var trail = await core.startTrail(release ? TargetDto.release(id: first.id) : const TargetDto.search(query: ''));
  if (release) return;
  trail = await core.follow(trail.current, TargetDto.release(id: first.id), ThreadKind.matched, 'library');
  if (stops >= 3) trail = await core.follow(trail.current, first.artistLinks.first.to, ThreadKind.albumArtist, first.artistLinks.first.provider);
  if (stops >= 4) {
    final next = (await core.person(PlatformInt64Util.from(1))).workedWith.first;
    await core.follow(trail.current, next.to, next.kind, next.provider);
  }
}

/// Paused, so `pumpAndSettle` is not kept awake by the playhead clock; shows the trail.
Future<void> _surface(WidgetTester tester, FakeCore core, {double width = 1728}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await core.transport(const TransportDto.pause());
  await tester.pumpWidget(MeretApp(core: core));
  await tester.pumpAndSettle();
  await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
  await tester.pumpAndSettle();
}
