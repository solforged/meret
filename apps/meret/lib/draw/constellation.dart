import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../core/bridge.dart';
import '../core/when.dart';
import '../theme/tokens.dart';

class NoTrailStrip extends StatefulWidget {
  const NoTrailStrip({super.key, required this.core, required this.memoryVersion, this.onResume});
  final CoreBridge core;
  final int memoryVersion;

  /// Opens the last trail; the "[ to resume …" line is a door only when set.
  final VoidCallback? onResume;

  @override
  State<NoTrailStrip> createState() => _NoTrailStripState();
}

class _NoTrailStripState extends State<NoTrailStrip> {
  late Future<List<TrailSummaryDto>> _history;

  @override
  void initState() {
    super.initState();
    _history = widget.core.trailHistory(1);
  }

  @override
  void didUpdateWidget(NoTrailStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.core != oldWidget.core || widget.memoryVersion != oldWidget.memoryVersion) {
      _history = widget.core.trailHistory(1);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: Row(children: [
      Container(width: 9, height: 9, decoration: const BoxDecoration(shape: BoxShape.circle, color: Tok.gold)),
      const SizedBox(width: 8),
      Text('Today', style: Tok.body.copyWith(color: Tok.gold)),
      const SizedBox(width: 20),
      Expanded(child: FutureBuilder<List<TrailSummaryDto>>(
        future: _history,
        builder: (context, snapshot) {
          final trail = snapshot.data?.firstOrNull;
          if (snapshot.hasError) {
            return _line([
              TextSpan(text: "couldn't load trails · ${snapshot.error}", style: Tok.label.copyWith(color: Tok.warn)),
            ]);
          }
          if (trail == null) return _line([const TextSpan(text: 'no trail yet')]);
          return _ResumeDoor(
            onTap: widget.onResume,
            child: _line([
              TextSpan(text: '[', style: Tok.label.copyWith(color: Tok.gold)),
              TextSpan(text: ' to resume ${dayPossessive(trail.whenMs.toInt())} · ${trail.name ?? trail.title} · ${trail.stops} ${trail.stops == 1 ? 'stop' : 'stops'}'),
            ]),
          );
        },
      )),
    ]),
  );

  Widget _line(List<InlineSpan> spans) => Text.rich(
    TextSpan(children: spans),
    style: Tok.label,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
}

/// The resume line is a quiet door like a Today row: hand cursor and a panel tint on hover.
class _ResumeDoor extends StatefulWidget {
  const _ResumeDoor({required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_ResumeDoor> createState() => _ResumeDoorState();
}

class _ResumeDoorState extends State<_ResumeDoor> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Semantics(
        button: enabled,
        child: GestureDetector(
          key: const ValueKey('trail-resume'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            color: _hover && enabled ? Tok.panel2 : null,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class TrailStrip extends StatefulWidget {
  const TrailStrip({super.key, required this.trail, required this.onGo, this.onPlay});
  final TrailDto trail;
  final ValueChanged<int> onGo;
  final ValueChanged<bool>? onPlay;

  @override
  State<TrailStrip> createState() => _TrailStripState();
}

class _TrailStripState extends State<TrailStrip> {
  final _scroll = ScrollController();
  (TrailDto, Size)? _lastLayout;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _revealCurrent(Offset? current, Size viewport) {
    if (current == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      const inset = 44.0;
      final left = current.dx - inset;
      final right = current.dx + inset;
      final offset = _scroll.offset;
      final target = left < offset || right > offset + viewport.width ? current.dx - viewport.width / 2 : offset;
      final clamped = target.clamp(0.0, _scroll.position.maxScrollExtent);
      if (clamped != offset) _scroll.jumpTo(clamped);
    });
  }

  void _page(int direction) {
    final target = (_scroll.offset + direction * _scroll.position.viewportDimension * 0.75)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(target, duration: const Duration(milliseconds: 180), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: _tree()),
    if (widget.onPlay != null) Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        _playLabel('Play branch', false),
        if (widget.trail.branches.length > 1) _playLabel('Play tree', true),
      ]),
    ),
  ]);

  Widget _playLabel(String label, bool whole) => TextButton(
    key: ValueKey(whole ? 'trail-play-tree' : 'trail-play-branch'),
    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 20), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
    onPressed: () => widget.onPlay!(whole),
    child: Text(label, style: Tok.label.copyWith(color: Tok.gold)),
  );

  Widget _tree() => LayoutBuilder(builder: (context, box) {
    final painter = ConstellationPainter(widget.trail);
    final viewport = box.biggest;
    final size = Size(painter.contentWidth(viewport.width), viewport.height);
    final positions = painter.layoutPositions(size);
    if (_lastLayout != (widget.trail, viewport)) {
      _lastLayout = (widget.trail, viewport);
      _revealCurrent(positions[widget.trail.current], viewport);
    }
    final overflow = size.width > viewport.width;
    return Stack(children: [
      // The pager chevrons stand in for a scrollbar: a 44 px strip has no row left for a thumb.
      ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          key: const ValueKey('trail-scroll'),
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: Stack(children: [
              Positioned.fill(child: CustomPaint(painter: painter)),
              if (painter.root case final root? when widget.trail.kept)
                if (positions[root.index] case final position?)
                  Positioned(
                    left: position.dx + painter.rootTitleWidth(size) / 2 + 8,
                    top: position.dy - 22,
                    width: painter.keptLabelWidth,
                    child: Text(
                      painter.keptLabel,
                      key: const ValueKey('trail-kept'),
                      style: Tok.label.copyWith(color: Tok.gold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              for (final stop in widget.trail.stops)
                if (positions[stop.index] case final position?)
                  Positioned(
                    left: position.dx - 22,
                    top: (position.dy - 22).clamp(0.0, math.max(0.0, size.height - 44)),
                    width: 44,
                    height: 44,
                    child: Semantics(
                      key: ValueKey('trail-stop-${stop.index}'),
                      button: true,
                      selected: stop.index == widget.trail.current,
                      label: stop.title,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => widget.onGo(stop.index),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
            ]),
          ),
        ),
      ),
      if (overflow)
        AnimatedBuilder(
          animation: _scroll,
          builder: (context, _) => Stack(children: [
            if (_scroll.hasClients && _scroll.offset > 0)
              Positioned(left: 0, top: 0, bottom: 0, child: _overflowButton(-1)),
            if (!_scroll.hasClients || !_scroll.position.hasContentDimensions || _scroll.offset < _scroll.position.maxScrollExtent)
              Positioned(right: 0, top: 0, bottom: 0, child: _overflowButton(1)),
          ]),
        ),
    ]);
  });

  Widget _overflowButton(int direction) => ColoredBox(
    color: Tok.void_,
    child: IconButton(
      key: ValueKey(direction < 0 ? 'trail-more-left' : 'trail-more-right'),
      tooltip: direction < 0 ? 'Earlier trail stops' : 'More trail stops',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 24),
      onPressed: () => _page(direction),
      icon: Icon(direction < 0 ? Icons.chevron_left : Icons.chevron_right, size: 18, color: Tok.gold),
    ),
  );
}


/// One depth-and-lane layout for the strip and the whole tree.
class TrailTreeLayout {
  TrailTreeLayout(TrailDto trail, {bool includePeeks = false}) {
    final stops = {
      for (final stop in trail.stops)
        if (includePeeks || !stop.isPeek || stop.onPath) stop.index: stop,
    };
    int depth(StopDto stop) => depths.putIfAbsent(stop.index, () {
      final parent = stops[stop.parent];
      return parent == null ? 0 : depth(parent) + 1;
    });
    final ordered = stops.values.toList();
    for (final stop in ordered) {
      depth(stop);
    }
    ordered.sort((a, b) {
      final order = depth(a).compareTo(depth(b));
      return order == 0 ? a.index.compareTo(b.index) : order;
    });
    final continued = <int>{};
    var nextLane = 1;
    int lane() {
      final n = nextLane++;
      return n.isOdd ? (n + 1) ~/ 2 : -n ~/ 2;
    }
    for (final stop in ordered) {
      final parentLane = lanes[stop.parent];
      lanes[stop.index] = stop.onPath ? 0
          : parentLane != null && parentLane != 0 && continued.add(stop.parent!) && !stop.isPeek
              ? parentLane : lane();
    }
  }

  final depths = <int, int>{};
  static const rowSpacing = 88.0;
  static const topInset = 52.0;
  static const bottomInset = 44.0;
  final lanes = <int, int>{};
  int get maxDepth => depths.values.fold(0, math.max);
  int get topLane => lanes.values.fold(0, math.min);
  int get bottomLane => lanes.values.fold(0, math.max);
  double get expandedHeight => topInset + (bottomLane - topLane) * rowSpacing + bottomInset;

  double columnSpacing(double width, {required bool expanded, double keptSpace = 0}) =>
      ((width - keptSpace) / (maxDepth + 1)).clamp(expanded ? 224.0 : 144.0, expanded ? 280.0 : 264.0);

  /// Labels take the room between neighbouring stars, less a gutter, up to a reading width.
  double labelWidth(double width, {required bool expanded, double keptSpace = 0}) =>
      (columnSpacing(width, expanded: expanded, keptSpace: keptSpace) - 24).clamp(expanded ? 190.0 : 128.0, 240.0);

  Map<int, Offset> positions(TrailDto trail, Size size, {required bool expanded, double keptSpace = 0}) {
    final step = columnSpacing(size.width, expanded: expanded, keptSpace: keptSpace);
    final middle = expanded
        ? topInset - topLane * rowSpacing
        : size.height * 0.55;
    final laneStep = expanded
        ? rowSpacing
        : math.min(
            topLane == 0 ? double.infinity : (middle - 10) / -topLane,
            bottomLane == 0 ? double.infinity : (size.height - middle - 10) / bottomLane,
          );
    return {
      for (final stop in trail.stops)
        if (depths[stop.index] case final depth?)
          stop.index: Offset(
            step * (depth + 0.5 - (expanded && stop.isPeek && !stop.onPath ? 0.45 : 0)) + (depth == 0 ? 0 : keptSpace),
            middle + lanes[stop.index]! * (laneStep.isFinite ? laneStep : 0),
          ),
    };
  }
}

String trailActions(List<String> actions) {
  final counts = <String, int>{};
  for (final action in actions) {
    counts.update(action, (count) => count + 1, ifAbsent: () => 1);
  }
  return counts.entries.map((entry) {
    final label = entry.key == 'wanted' ? '♥ want' : entry.key;
    return entry.value == 1 ? label : '$label ×${entry.value}';
  }).join(' · ');
}

/// The whole tree uses the strip's layout and painter at a reading size.
class TrailTree extends StatefulWidget {
  const TrailTree({super.key, required this.trail, required this.onGo});
  final TrailDto trail;
  final ValueChanged<int> onGo;

  @override
  State<TrailTree> createState() => _TrailTreeState();
}

class _TrailTreeState extends State<TrailTree> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final painter = ConstellationPainter(widget.trail, expanded: true);
    final size = Size(painter.contentWidth(box.maxWidth), painter.contentHeight);
    final positions = painter.layoutPositions(size);
    return DecoratedBox(
      decoration: BoxDecoration(color: Tok.void_, border: Border.all(color: Tok.line)),
      child: Scrollbar(
        controller: _scroll,
        thumbVisibility: size.width > box.maxWidth,
        child: SingleChildScrollView(
          key: const ValueKey('tree-drawing-scroll'),
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: size.width, height: size.height,
            child: Stack(children: [
              Positioned.fill(child: CustomPaint(painter: painter)),
              for (final stop in widget.trail.stops)
                if (positions[stop.index] case final position?)
                  Positioned(
                    left: position.dx - 22, top: position.dy - 22, width: 44, height: 44,
                    child: Semantics(
                      key: ValueKey('tree-stop-${stop.index}'),
                      label: stop.isPeek && !stop.onPath ? 'peeked: ${stop.title}' : stop.title,
                      button: true, selected: stop.index == widget.trail.current,
                      child: Tooltip(
                        message: stop.title,
                        excludeFromSemantics: true,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => widget.onGo(stop.index),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                  ),
            ]),
          ),
        ),
      ),
    );
  });
}

/// Current stops run along the gold line; earlier branches get their own lanes.
class ConstellationPainter extends CustomPainter {
  ConstellationPainter(this.trail, {this.expanded = false});

  final TrailDto trail;
  final bool expanded;
  late final _layout = TrailTreeLayout(trail, includePeeks: expanded);
  final _labels = <(String, TextStyle, double), TextPainter>{};

  TextPainter _text(String s, TextStyle style, {required double width}) => _labels.putIfAbsent(
    (s, style, width),
    () => TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr, maxLines: 1, ellipsis: '…')
      ..layout(maxWidth: width),
  );

  Iterable<StopDto> get _visible => trail.stops.where((s) => expanded || !s.isPeek || s.onPath);

  StopDto? get root => trail.stops.where((stop) => stop.parent == null).firstOrNull;
  String get keptLabel => '◆ ${trail.name ?? root?.title ?? ''}';
  /// Measured before layout (it feeds the column spacing), so it stays at the narrowest label width.
  double get keptLabelWidth => trail.kept ? _text(keptLabel, Tok.label.copyWith(color: Tok.gold), width: 128).width : 0;
  double get _keptSpace => trail.kept && !expanded ? keptLabelWidth + 8 : 0;
  double labelWidth(Size size) => _layout.labelWidth(size.width, expanded: expanded, keptSpace: _keptSpace);
  double rootTitleWidth(Size size) => _text(root?.title ?? '', Tok.body.copyWith(fontSize: 11.5, color: Tok.muted), width: labelWidth(size)).width;
  double get contentHeight => _layout.expandedHeight;

  double contentWidth(double viewportWidth) => math.max(viewportWidth, (_layout.maxDepth + 1) * (expanded ? 224.0 : 144.0) + _keptSpace);

  Map<int, Offset> layoutPositions(Size size) => _layout.positions(trail, size, expanded: expanded, keptSpace: _keptSpace);

  @override
  void paint(Canvas canvas, Size size) {
    final stops = _visible.toList();
    final pos = layoutPositions(size);
    final width = labelWidth(size);
    final gold = Paint()..color = Tok.gold..strokeWidth = expanded ? 1.5 : 1.2;
    final grey = Paint()..color = Tok.dim..strokeWidth = 1;
    for (final s in stops) {
      final p = pos[s.index], q = pos[s.parent];
      if (p == null || q == null) continue;
      final peek = expanded && s.isPeek && !s.onPath;
      if (peek) {
        _dots(canvas, q, p, Tok.dim);
      } else {
        canvas.drawLine(q, p, s.onPath ? gold : grey);
      }
      if (s.via != null && !peek && (expanded || s.onPath)) {
        final t = _text(s.via!, Tok.label.copyWith(
          fontSize: expanded ? 10.5 : 9.5, fontStyle: FontStyle.italic, color: Tok.gold2,
        ), width: width);
        t.paint(canvas, Offset((p.dx + q.dx) / 2 - t.width / 2, (p.dy + q.dy) / 2 + (expanded ? -t.height - 8 : 8)));
      }
    }
    for (final (a, b) in trail.meetings) {
      final from = pos[a], to = pos[b];
      if (from != null && to != null) _dots(canvas, from, to, Tok.gold2);
    }
    for (final s in stops) {
      final p = pos[s.index];
      if (p == null) continue;
      final current = s.index == trail.current;
      final peek = expanded && s.isPeek && !s.onPath;
      if (peek) {
        canvas.drawLine(p + const Offset(-4, 4), p + const Offset(4, -4), grey..strokeWidth = 2);
      } else {
        if (current && expanded) canvas.drawCircle(p, 12, Paint()..color = Tok.gold3);
        canvas.drawCircle(p, current ? 4.5 : 3, Paint()..color = s.onPath ? Tok.gold : Tok.faint);
        if (s.isFork) {
          canvas.drawCircle(p, expanded ? 9 : 7, Paint()..color = Tok.gold2..style = PaintingStyle.stroke);
        }
      }
      if (expanded) {
        final title = _text(peek ? 'peeked: ${s.title}' : s.title, Tok.body.copyWith(
          fontSize: peek ? 11 : 13, color: current ? Tok.ink : s.onPath ? Tok.muted : Tok.faint,
        ), width: width);
        title.paint(canvas, p + Offset(-title.width / 2, -title.height - 28));
        final note = _text([
          clockTime(s.openedMs.toInt()),
          if (s.actions.isNotEmpty) trailActions(s.actions),
          if (current) 'now',
        ].join(' · '), Tok.label.copyWith(fontSize: 10, letterSpacing: 0), width: width);
        note.paint(canvas, p + Offset(-note.width / 2, 15));
      } else if (s.onPath) {
        final t = _text(s.title, Tok.body.copyWith(fontSize: 11.5, color: current ? Tok.ink : Tok.muted), width: width);
        t.paint(canvas, p + Offset(-t.width / 2, -22));
      } else {
        final t = _text(s.title, Tok.label.copyWith(fontSize: 9), width: width);
        t.paint(canvas, p + Offset(8, -t.height / 2));
      }
    }
  }

  void _dots(Canvas canvas, Offset from, Offset to, Color color) {
    final delta = to - from;
    final distance = delta.distance;
    final paint = Paint()..color = color;
    for (var d = 9.0; d < distance - 8; d += 6) {
      canvas.drawCircle(from + delta * (d / distance), 1, paint);
    }
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    final positions = layoutPositions(size);
    return [for (final stop in _visible)
      if (positions[stop.index] case final position?)
        CustomPainterSemantics(
          rect: Rect.fromCenter(center: position, width: 44, height: 44),
          properties: SemanticsProperties(label: stop.title, textDirection: TextDirection.ltr),
        ),
    ];
  };

  @override
  bool shouldRebuildSemantics(ConstellationPainter oldDelegate) => oldDelegate.trail != trail || oldDelegate.expanded != expanded;

  @override
  bool shouldRepaint(ConstellationPainter old) => old.trail != trail || old.expanded != expanded;
}
