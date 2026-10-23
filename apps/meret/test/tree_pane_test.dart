import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64Util;
import 'package:meret/core/bridge.dart';
import 'package:meret/draw/constellation.dart';
import 'package:meret/main.dart';
import 'package:meret/now/now_pane.dart';
import 'package:meret/panes/pane.dart';
import 'package:meret/panes/tree_pane.dart';
import 'package:meret/shell/pane_row.dart';
import 'package:meret/theme/tokens.dart';

void main() {
  testWidgets('T toggles the open trail and Escape restores panes with strip and Now retained', (tester) async {
    await _surface(tester);
    await _key(tester, LogicalKeyboardKey.keyT);
    expect(find.byType(TreePane), findsOneWidget);
    expect(find.byType(TrailStrip), findsOneWidget);
    expect(find.byType(NowPane), findsOneWidget);
    expect(_rowCovered(tester), isTrue, reason: 'the panes stay under the tree, out of reach');
    await _key(tester, LogicalKeyboardKey.keyT);
    expect(find.byType(TreePane), findsNothing);
    expect(_rowCovered(tester), isFalse);
    await _key(tester, LogicalKeyboardKey.keyT);
    await _key(tester, LogicalKeyboardKey.escape);
    expect(find.byType(TreePane), findsNothing);
    expect(_rowCovered(tester), isFalse);
  });

  testWidgets('T ignores modifiers, text editing and the absence of a trail', (tester) async {
    await _surface(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await _key(tester, LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    expect(find.byType(TreePane), findsNothing);
    await tester.tap(find.byType(TextField));
    await _key(tester, LogicalKeyboardKey.keyT);
    expect(find.byType(TreePane), findsNothing);
    await tester.enterText(find.byType(TextField), 't');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 't');
    await tester.pumpWidget(MeretApp(key: UniqueKey(), core: FakeCore.empty()));
    await tester.pumpAndSettle();
    await _key(tester, LogicalKeyboardKey.keyT);
    expect(find.byType(TreePane), findsNothing);
    expect(find.byType(NoTrailStrip), findsOneWidget);
  });

  testWidgets('a branch row opens its leaf and restores that path of panes', (tester) async {
    final core = await _surface(tester);
    await _key(tester, LogicalKeyboardKey.keyT);
    final branch = find.byKey(const ValueKey('tree-branch-2'));
    await tester.ensureVisible(branch);
    await tester.tap(branch);
    await tester.pumpAndSettle();
    expect(core.visited, [2]);
    expect((await core.trail())!.current, 2);
    expect(find.byType(TreePane), findsNothing);
    expect(tester.widget<PaneRow>(find.byType(PaneRow)).children.cast<Pane>().map((pane) => pane.title),
      ['Mira Fen', 'Copper gardens', 'Dusk lattice']);
  });

  testWidgets('nodes and folded peek rows both open their stop and leave the tree', (tester) async {
    final core = await _surface(tester);
    await _key(tester, LogicalKeyboardKey.keyT);
    await tester.tap(find.byKey(const ValueKey('tree-stop-2')));
    await tester.pumpAndSettle();
    expect(core.visited, [2]);
    expect(find.byType(TreePane), findsNothing);
    await _key(tester, LogicalKeyboardKey.keyT);
    final peek = find.byKey(const ValueKey('tree-peek-4'));
    await tester.ensureVisible(peek);
    await tester.tap(peek);
    await tester.pumpAndSettle();
    expect(core.visited, [2, 4]);
    expect((await core.trail())!.current, 4);
    expect(find.byType(TreePane), findsNothing);
  });

  testWidgets('facts count all stops, folded peeks and repeated actions, then refresh after pruning', (tester) async {
    final core = await _surface(tester);
    await _key(tester, LogicalKeyboardKey.keyT);
    var facts = tester.widget<TreePaneFacts>(find.byType(TreePaneFacts));
    expect((facts.stops, facts.branches, facts.peeks, facts.wants, facts.played), (6, 3, 1, 2, 3));
    final tree = find.byType(TreePane);
    expect(find.descendant(of: tree, matching: find.text('played ×2 · ♥ want ×2')), findsOneWidget);
    expect(find.descendant(of: tree, matching: find.text('open for 4s')), findsOneWidget);
    final prune = find.byKey(const ValueKey('tree-prune-5'));
    expect(find.byKey(const ValueKey('tree-prune-2')), findsNothing);
    expect(find.byKey(const ValueKey('tree-prune-3')), findsNothing);
    await tester.ensureVisible(prune);
    await tester.tap(prune);
    await tester.pumpAndSettle();
    expect(core.pruned, [5]);
    expect(core.visited, isEmpty);
    expect(find.byType(TreePane), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-branch-5')), findsNothing);
    expect(find.byKey(const ValueKey('tree-stop-5')), findsNothing);
    expect(find.byKey(const ValueKey('trail-stop-5')), findsNothing);
    facts = tester.widget<TreePaneFacts>(find.byType(TreePaneFacts));
    expect((facts.stops, facts.branches, facts.peeks), (5, 2, 1));
    expect(tester.widget<TrailStrip>(find.byType(TrailStrip)).trail.stops, hasLength(5));
  });

  testWidgets('playback stays in the tree and naming and Keep share the keep dialog', (tester) async {
    final core = await _surface(tester);
    await _key(tester, LogicalKeyboardKey.keyT);
    await tester.tap(find.byKey(const ValueKey('tree-play-branch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tree-play-whole')));
    await tester.pumpAndSettle();
    expect(core.played, [false, true]);
    expect(core.visited, isEmpty);
    expect(find.byType(TreePane), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tree-name')));
    await tester.pumpAndSettle();
    final name = find.byKey(const ValueKey('trail-name'));
    expect(tester.widget<TextField>(name).controller!.text, 'Mira Fen → Lantern water');
    await tester.enterText(name, 'Reeds after dusk');
    await _key(tester, LogicalKeyboardKey.enter);
    expect(core.names, ['Reeds after dusk']);
    expect(tester.widget<PaneActionButton>(find.byKey(const ValueKey('tree-keep'))).label, 'Kept');
    expect(tester.widget<TreePane>(find.byType(TreePane)).trail.name, 'Reeds after dusk');
    await tester.tap(find.byKey(const ValueKey('tree-keep')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(name).controller!.text, 'Reeds after dusk');
    await _key(tester, LogicalKeyboardKey.escape);
    expect(find.byType(TreePane), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await _key(tester, LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect(find.byKey(const ValueKey('keep-trail-dialog')), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.escape);
  });

  test('strip and large tree share depth columns while only the large tree includes peeks', () {
    final trail = _fixture();
    final large = ConstellationPainter(trail, expanded: true);
    final size = Size(large.contentWidth(1200), large.contentHeight);
    final positions = large.layoutPositions(size);
    final compact = ConstellationPainter(trail).layoutPositions(const Size(1000, 64));
    expect(positions.keys, containsAll([0, 1, 2, 3, 4, 5]));
    expect(compact, isNot(contains(4)));
    expect(positions[2]!.dx, positions[3]!.dx);
    expect(positions[0]!.dx, lessThan(positions[1]!.dx));
    expect(positions[1]!.dx, lessThan(positions[3]!.dx));
    expect(positions[0]!.dy, positions[1]!.dy);
    expect(positions[1]!.dy, positions[3]!.dy);
    expect(positions[2]!.dy, isNot(positions[3]!.dy));
    expect(positions[4]!.dy, isNot(positions[5]!.dy));
    expect(positions.values.every((position) => (Offset.zero & size).contains(position)), isTrue);
  });

  test('two branch rows stay 88 pixels apart even in a taller canvas', () {
    final source = _fixture();
    final trail = TrailDto(
      current: source.current, kept: false, meetings: source.meetings,
      stops: source.stops.where((stop) => stop.index < 4).toList(),
      branches: source.branches.take(2).toList(),
    );
    final painter = ConstellationPainter(trail, expanded: true);
    final width = painter.contentWidth(1195);
    final positions = painter.layoutPositions(Size(width, painter.contentHeight));
    expect(positions[2]!.dy - positions[3]!.dy, 88);
    expect(painter.contentHeight, 184);
    expect(painter.layoutPositions(Size(width, 900))[2]!.dy, positions[2]!.dy);
  });

  testWidgets('the large drawing paints fork rings, meeting dots and clickable peek ticks', (tester) async {
    await _surface(tester);
    await _key(tester, LogicalKeyboardKey.keyT);
    final drawing = find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter is ConstellationPainter && (widget.painter as ConstellationPainter).expanded);
    final paint = tester.renderObject<RenderCustomPaint>(drawing);
    expect(paint, paints..something((method, arguments) => method == #drawCircle && arguments[1] == 9.0 && (arguments[2] as Paint).color.toARGB32() == Tok.gold2.toARGB32()));
    expect(paint, paints..something((method, arguments) => method == #drawCircle && arguments[1] == 1.0 && (arguments[2] as Paint).color.toARGB32() == Tok.gold2.toARGB32()));
    final painter = tester.widget<CustomPaint>(drawing).painter as ConstellationPainter;
    final positions = painter.layoutPositions(paint.size);
    final label = TextPainter(
      text: TextSpan(text: 'on', style: Tok.label.copyWith(fontSize: 10.5, fontStyle: FontStyle.italic, color: Tok.gold2)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 190);
    for (final index in [1, 2]) {
      final stop = painter.trail.stops.firstWhere((stop) => stop.index == index);
      final middle = (positions[stop.index]! + positions[stop.parent]!) / 2;
      final origin = middle - Offset(label.width / 2, label.height + 8);
      expect(paint, paints..something((method, arguments) => method == #drawParagraph && arguments[1] == origin));
    }
    label.dispose();
    expect(find.byKey(const ValueKey('tree-stop-4')), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('tree-stop-4'))), const Size(44, 44));
  });

  testWidgets('long node titles ellipsize within their columns and stay clear of edge labels', (tester) async {
    const longTitle = 'Reeds Beyond the Copper Meridian Original Soundtrack';
    final trail = TrailDto(
      current: 2, kept: false, branches: const [], meetings: const [],
      stops: [
        _stop(0, null, 'Mira Fen', TargetDto.person(id: PlatformInt64Util.from(1)), onPath: true),
        _stop(1, 0, longTitle, TargetDto.release(id: PlatformInt64Util.from(1)), onPath: true),
        _stop(2, 1, 'Lyra Vale', TargetDto.person(id: PlatformInt64Util.from(2)), onPath: true, via: 'album artist'),
      ],
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(
      child: SizedBox(width: 700, child: TrailTree(trail: trail, onGo: (_) {})),
    ))));
    final drawing = find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter is ConstellationPainter);
    final render = tester.renderObject<RenderCustomPaint>(drawing);
    final painter = tester.widget<CustomPaint>(drawing).painter as ConstellationPainter;
    final positions = painter.layoutPositions(render.size);
    final column = positions[1]!.dx - positions[0]!.dx;
    final paragraphs = <(ui.Paragraph, Offset)>[];
    expect(render, paints..everything((method, arguments) {
      if (method == #drawParagraph) paragraphs.add((arguments[0] as ui.Paragraph, arguments[1] as Offset));
      return true;
    }));
    expect(paragraphs, hasLength(8));
    final titles = <Rect>[];
    for (final index in [2, 4, 6]) {
      final (paragraph, origin) = paragraphs[index];
      expect(paragraph.width, lessThanOrEqualTo(column - 24));
      titles.add(origin & Size(paragraph.longestLine, paragraph.height));
    }
    expect(paragraphs[4].$1.didExceedMaxLines, isTrue);
    for (final (paragraph, origin) in paragraphs.take(2)) {
      final edge = origin & Size(paragraph.longestLine, paragraph.height);
      expect(titles.every((title) => !title.overlaps(edge)), isTrue);
    }
    final node = find.byKey(const ValueKey('tree-stop-1'));
    expect(tester.widget<Semantics>(node).properties.label, longTitle);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(node));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text(longTitle), findsOneWidget);
    await mouse.removePointer();
  });

  testWidgets('phone trees keep actions reachable and fit branch facts without horizontal scrolling', (tester) async {
    final core = await _surface(tester, size: const Size(390, 844));
    await _key(tester, LogicalKeyboardKey.keyT);
    expect(find.byType(TreePane), findsOneWidget);
    final drawing = tester.widget<SingleChildScrollView>(find.byKey(const ValueKey('tree-drawing-scroll'))).controller!;
    expect(drawing.position.maxScrollExtent, greaterThan(0));
    final table = find.byKey(const ValueKey('tree-branches'));
    expect(find.descendant(of: table, matching: find.byType(SingleChildScrollView)), findsNothing);
    expect(tester.getRect(table).right, lessThanOrEqualTo(tester.getRect(find.byType(TreePane)).right));
    final whole = find.byKey(const ValueKey('tree-play-whole'));
    await tester.ensureVisible(whole);
    await tester.tap(whole);
    await tester.pumpAndSettle();
    expect(core.played, [true]);
    final prune = find.byKey(const ValueKey('tree-prune-5'));
    await tester.ensureVisible(prune);
    await tester.tap(prune);
    await tester.pumpAndSettle();
    expect(core.pruned, [5]);
    expect(find.byType(TreePane), findsOneWidget);
  });

  for (final width in [1195.0, 900.0]) {
    testWidgets('branch columns fit at width $width with unbroken Stops and time cells', (tester) async {
      await _surface(tester, size: Size(width, 896));
      await _key(tester, LogicalKeyboardKey.keyT);
      final table = find.byKey(const ValueKey('tree-branches'));
      final bounds = tester.getRect(table);
      final pane = tester.getRect(find.byType(TreePane));
      expect(bounds.left, greaterThanOrEqualTo(pane.left));
      expect(bounds.right, lessThanOrEqualTo(pane.right));
      expect(find.descendant(of: table, matching: find.byType(SingleChildScrollView)), findsNothing);
      for (final (index, length) in [(2, 5), (3, 4)]) {
        final header = find.byKey(ValueKey('tree-branches-header-$index'));
        final paragraph = tester.renderObject<RenderParagraph>(header);
        expect(paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: length)), hasLength(1));
      }
      final branch = find.byKey(const ValueKey('tree-branch-2'));
      final when = find.descendant(of: branch, matching: find.text('18:02–18:02'));
      expect(tester.renderObject<RenderParagraph>(when).getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 11),
      ), hasLength(1));
      final state = find.descendant(of: branch, matching: find.text('kept: it has a want'));
      expect(tester.getRect(state).right, lessThanOrEqualTo(bounds.right));
      expect(tester.getRect(find.byKey(const ValueKey('tree-branches-header-5'))).right, lessThanOrEqualTo(bounds.right));
      if (width == 900) {
        final title = find.descendant(of: branch, matching: find.text('→ Dusk lattice'));
        expect(tester.renderObject<RenderParagraph>(title).getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 14),
        ).length, greaterThan(1));
        final actions = find.descendant(of: branch, matching: find.text('played ×2 · ♥ want ×2'));
        expect(tester.renderObject<RenderParagraph>(actions).getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 21),
        ).length, greaterThan(1));
      }
    });
  }

  for (final input in ['wheel', 'trackpad', 'drag']) {
    testWidgets('$input over the diagram scrolls the whole pane to its branches at a small size', (tester) async {
      await _surface(tester, size: const Size(700, 560));
      await _key(tester, LogicalKeyboardKey.keyT);
      final pane = find.byKey(const ValueKey('tree-pane-scroll'));
      final controller = tester.widget<SingleChildScrollView>(pane).controller!;
      final viewport = tester.getRect(pane);
      final branch = find.byKey(const ValueKey('tree-branch-5'));
      expect(tester.getTopLeft(branch).dy, greaterThan(viewport.bottom));
      final drawing = tester.getRect(find.byType(TrailTree)).intersect(viewport);
      final position = drawing.center;
      if (input == 'wheel') {
        await tester.sendEventToBinding(PointerScrollEvent(
          position: position, scrollDelta: const Offset(0, 600), kind: PointerDeviceKind.mouse,
        ));
      } else if (input == 'trackpad') {
        final gesture = await tester.createGesture(kind: PointerDeviceKind.trackpad);
        await gesture.panZoomStart(position);
        await gesture.panZoomUpdate(position, pan: const Offset(0, -20));
        await gesture.panZoomUpdate(position, pan: const Offset(0, -300));
        await gesture.panZoomUpdate(position, pan: const Offset(0, -600));
        await gesture.panZoomEnd();
      } else {
        await tester.dragFrom(position, const Offset(0, -600));
      }
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
      expect(viewport.contains(tester.getCenter(branch)), isTrue,
        reason: 'offset ${controller.offset}, branch ${tester.getRect(branch)}, viewport $viewport');
      expect(branch.hitTestable(), findsOneWidget);
      final horizontal = tester.widget<SingleChildScrollView>(find.byKey(const ValueKey('tree-drawing-scroll'))).controller!;
      expect(horizontal.offset, 0);
    });
  }

  testWidgets('facts omit folded peek counts when the trail has none', (tester) async {
    final source = _fixture();
    await tester.pumpWidget(MaterialApp(home: TreePaneFacts(trail: source)));
    expect(tester.widget<TreePaneFacts>(find.byType(TreePaneFacts)).peeks, 1);
    expect(find.text('3 branches · 1 peek'), findsOneWidget);
    final withoutPeeks = TrailDto(
      current: source.current, kept: false, meetings: source.meetings, branches: source.branches,
      stops: source.stops.where((stop) => !stop.isPeek).toList(),
    );
    await tester.pumpWidget(MaterialApp(home: TreePaneFacts(trail: withoutPeeks)));
    final facts = tester.widget<TreePaneFacts>(find.byType(TreePaneFacts));
    expect((facts.stops, facts.branches, facts.peeks), (5, 3, 0));
    expect(find.text('3 branches'), findsOneWidget);
    expect(find.textContaining('0 peeks'), findsNothing);
  });

  test('FakeCore keeps visit facts and repeated played actions through navigation', () async {
    final core = FakeCore();
    await core.startTrail(TargetDto.release(id: PlatformInt64Util.from(1)));
    final root = (await core.trail())!.stops.single;
    expect(root.openedMs.toInt(), greaterThan(0));
    expect(root.dwellMs.toInt(), greaterThanOrEqualTo(0));
    await core.playRelease(id: PlatformInt64Util.from(1), index: 0, fromStop: 0);
    await core.playRelease(id: PlatformInt64Util.from(1), index: 0, fromStop: 0);
    await core.follow(0, TargetDto.person(id: PlatformInt64Util.from(1)), ThreadKind.by, 'local_tags');
    final trail = (await core.trail())!;
    expect(trail.stops.first.actions, ['played', 'played']);
    expect(trail.stops.first.openedMs, root.openedMs);
    expect(trail.branches.single.actions, ['played', 'played']);
  });
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

bool _rowCovered(WidgetTester tester) =>
    tester.widget<IgnorePointer>(find.ancestor(of: find.byType(PaneRow), matching: find.byType(IgnorePointer)).first).ignoring;

Future<_TreeCore> _surface(WidgetTester tester, {Size size = const Size(1600, 1000)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final core = _TreeCore();
  await tester.pumpWidget(MeretApp(core: core));
  await tester.pumpAndSettle();
  return core;
}

TrailDto _fixture() => TrailDto(
  current: 3, kept: false,
  stops: [
    _stop(0, null, 'Mira Fen', TargetDto.person(id: PlatformInt64Util.from(1)), onPath: true, fork: true),
    _stop(1, 0, 'Copper gardens', TargetDto.release(id: PlatformInt64Util.from(1)), onPath: true, fork: true),
    _stop(2, 1, 'Dusk lattice', TargetDto.release(id: PlatformInt64Util.from(2)), actions: ['played', 'played', 'wanted', 'wanted']),
    _stop(3, 1, 'Lantern water', TargetDto.work(id: PlatformInt64Util.from(1)), onPath: true, actions: ['played']),
    _stop(4, 0, 'Veil moss', TargetDto.person(id: PlatformInt64Util.from(2)), peek: true),
    _stop(5, 0, 'Quiet spindle', TargetDto.release(id: PlatformInt64Util.from(3))),
  ],
  meetings: const [(2, 3)],
  branches: [
    _branch(1, 3, current: true, actions: ['played']),
    _branch(1, 2, actions: ['played', 'played', 'wanted', 'wanted']),
    _branch(0, 5, prunable: true),
  ],
);

StopDto _stop(int index, int? parent, String title, TargetDto target, {bool onPath = false, bool fork = false, bool peek = false, List<String> actions = const [], String via = 'on'}) => StopDto(
  index: index, parent: parent, target: target, title: title, via: parent == null ? null : via,
  onPath: onPath, isFork: fork, isPeek: peek,
  openedMs: PlatformInt64Util.from(DateTime(2026, 10, 20, 18, index).millisecondsSinceEpoch),
  dwellMs: PlatformInt64Util.from(peek ? 4000 : 60000), actions: actions,
);

BranchDto _branch(int fork, int leaf, {bool current = false, bool prunable = false, List<String> actions = const []}) => BranchDto(
  fork: fork, first: leaf, leaf: leaf, stops: 1,
  whenMs: PlatformInt64Util.from(DateTime(2026, 10, 20, 18, leaf).millisecondsSinceEpoch),
  actions: actions, current: current, prunable: prunable,
);

class _TreeCore extends FakeCore {
  TrailDto _tree = _fixture();
  final visited = <int>[];
  final pruned = <int>[];
  final played = <bool>[];
  final names = <String?>[];

  @override
  Stream<NowDto> now() => Stream.value(const NowDto(title: '', subtitle: '', path: []));

  @override
  Future<TrailDto?> trail() async => _tree;

  @override
  Future<TrailDto> trailGo(int stop) async {
    visited.add(stop);
    final nodes = {for (final node in _tree.stops) node.index: node};
    final path = <int>{};
    StopDto? node = nodes[stop];
    while (node != null) {
      path.add(node.index);
      node = nodes[node.parent];
    }
    return _tree = TrailDto(
      current: stop, kept: _tree.kept, name: _tree.name, meetings: _tree.meetings,
      stops: [for (final node in _tree.stops) StopDto(
        index: node.index, parent: node.parent, target: node.target, title: node.title, via: node.via,
        onPath: path.contains(node.index), isFork: node.isFork, isPeek: node.isPeek && node.index != stop,
        openedMs: node.openedMs, dwellMs: node.dwellMs, actions: node.actions,
      )],
      branches: [for (final branch in _tree.branches) BranchDto(
        fork: branch.fork, first: branch.first, leaf: branch.leaf, stops: branch.stops,
        whenMs: branch.whenMs, actions: branch.actions, current: branch.leaf == stop,
        prunable: branch.actions.isEmpty && branch.leaf != stop,
      )],
    );
  }

  @override
  Future<TrailDto> pruneBranch(int leaf) async {
    final branch = _tree.branches.firstWhere((branch) => branch.leaf == leaf);
    if (!branch.prunable) throw 'cannot prune this branch';
    pruned.add(leaf);
    return _tree = TrailDto(
      current: _tree.current, kept: _tree.kept, name: _tree.name,
      stops: _tree.stops.where((stop) => stop.index != leaf).toList(),
      branches: _tree.branches.where((branch) => branch.leaf != leaf).toList(),
      meetings: _tree.meetings.where((pair) => pair.$1 != leaf && pair.$2 != leaf).toList(),
    );
  }

  @override
  Future<int> playTrail(bool whole) async {
    played.add(whole);
    return 1;
  }

  @override
  Future<TrailDto> keepTrail({String? name}) async {
    names.add(name);
    return _tree = TrailDto(
      current: _tree.current, kept: true, name: name,
      stops: _tree.stops, branches: _tree.branches, meetings: _tree.meetings,
    );
  }
}
