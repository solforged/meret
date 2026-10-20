import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../core/bridge.dart';
import '../core/when.dart';
import '../theme/tokens.dart';

class NoTrailStrip extends StatefulWidget {
  const NoTrailStrip({super.key, required this.core, required this.memoryVersion});
  final CoreBridge core;
  final int memoryVersion;

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
      Text('Front', style: Tok.body.copyWith(color: Tok.gold)),
      const SizedBox(width: 20),
      Expanded(child: FutureBuilder<List<TrailSummaryDto>>(
        future: _history,
        builder: (context, snapshot) {
          final trail = snapshot.data?.firstOrNull;
          return Text.rich(
            TextSpan(children: [
              if (snapshot.hasError)
                TextSpan(text: "couldn't load trails · ${snapshot.error}", style: Tok.label.copyWith(color: Tok.warn))
              else if (trail == null)
                const TextSpan(text: 'no trail yet')
              else ...[
                TextSpan(text: '[', style: Tok.label.copyWith(color: Tok.gold)),
                TextSpan(text: ' to resume ${dayPossessive(trail.whenMs.toInt())} · ${trail.name ?? trail.title} · ${trail.stops} ${trail.stops == 1 ? 'stop' : 'stops'}'),
              ],
            ]),
            style: Tok.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        },
      )),
    ]),
  );
}
class TrailStrip extends StatefulWidget {
  const TrailStrip({super.key, required this.trail, required this.onGo});
  final TrailDto trail;
  final ValueChanged<int> onGo;

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
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
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
      Scrollbar(
        controller: _scroll,
        thumbVisibility: overflow,
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
                    left: position.dx + painter.rootTitleWidth / 2 + 8,
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


/// The trail strip: a star per stop, a line per thread. The current branch
/// runs along the main line in gold; other branches sit above and below in
/// grey; forks are ringed; peeks are left out (plates 01, 06).
class ConstellationPainter extends CustomPainter {
  ConstellationPainter(this.trail);

  final TrailDto trail;
  final _labels = <String, TextPainter>{};

  TextPainter _text(String s, TextStyle style) => _labels.putIfAbsent(
        '$s/${style.color}',
        () => TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr, maxLines: 1, ellipsis: '…')..layout(maxWidth: 128),
      );

  Iterable<StopDto> get _visible => trail.stops.where((s) => !s.isPeek || s.onPath);

  StopDto? get root => trail.stops.where((stop) => stop.parent == null).firstOrNull;
  String get keptLabel => '◆ ${trail.name ?? root?.title ?? ''}';
  double get keptLabelWidth => trail.kept ? _text(keptLabel, Tok.label.copyWith(color: Tok.gold)).width : 0;
  double get _keptSpace => trail.kept ? keptLabelWidth + 8 : 0;
  double get rootTitleWidth => _text(root?.title ?? '', Tok.body.copyWith(fontSize: 11.5, color: Tok.muted)).width;

  double contentWidth(double viewportWidth) => math.max(viewportWidth, (_visible.length + 0.5) * 144 + _keptSpace);

  Map<int, Offset> layoutPositions(Size size) {
    final stops = {for (final stop in _visible) stop.index: stop};
    final depths = <int, int>{};
    int depth(StopDto stop) => depths.putIfAbsent(stop.index, () {
      final parent = stops[stop.parent];
      return parent == null ? 0 : depth(parent) + 1;
    });
    final step = ((size.width - _keptSpace) / (stops.length + 0.5)).clamp(144.0, 220.0);
    final middle = size.height * 0.55;
    final positions = <int, Offset>{};
    // The first branch goes below: titles on the main line sit above it.
    var flip = 1.0;
    var column = 0;
    for (final stop in stops.values.toList()..sort((a, b) {
      final order = depth(a).compareTo(depth(b));
      return order == 0 ? a.index.compareTo(b.index) : order;
    })) {
      final parent = positions[stop.parent];
      final y = stop.onPath ? middle : parent != null && !stops[stop.parent]!.onPath
          ? parent.dy : middle + flip * size.height * 0.28;
      positions[stop.index] = Offset(step * (column + 0.5) + (column == 0 ? 0 : _keptSpace), y);
      column++;
      if (!stop.onPath && (parent == null || stops[stop.parent]!.onPath)) flip = -flip;
    }
    return positions;
  }


  @override
  void paint(Canvas canvas, Size size) {
    final stops = _visible.toList();
    final pos = layoutPositions(size);

    final gold = Paint()
      ..color = Tok.gold
      ..strokeWidth = 1.2;
    final grey = Paint()
      ..color = Tok.dim
      ..strokeWidth = 1;
    for (final s in stops) {
      final p = pos[s.index], q = pos[s.parent];
      if (p == null || q == null) continue;
      canvas.drawLine(q, p, s.onPath ? gold : grey);
      // Only the main line names its threads; a grey branch's label would sit on the gold one's.
      if (s.via != null && s.onPath) {
        final t = _text(s.via!, Tok.label.copyWith(fontSize: 9.5, fontStyle: FontStyle.italic));
        t.paint(canvas, Offset((p.dx + q.dx) / 2 - t.width / 2, (p.dy + q.dy) / 2 + 8));
      }
    }
    final meeting = Paint()..color = Tok.gold2;
    for (final (a, b) in trail.meetings) {
      final from = pos[a], to = pos[b];
      if (from == null || to == null) continue;
      final delta = to - from;
      final distance = delta.distance;
      // Leave the stars clear, and draw individual dots rather than dashes.
      for (var d = 9.0; d < distance - 8; d += 6) {
        canvas.drawCircle(from + delta * (d / distance), 1, meeting);
      }
    }
    for (final s in stops) {
      final p = pos[s.index];
      if (p == null) continue;
      final current = s.index == trail.current;
      canvas.drawCircle(p, current ? 4.5 : 3, Paint()..color = s.onPath ? Tok.gold : Tok.faint);
      if (s.isFork) {
        canvas.drawCircle(p, 7, Paint()
          ..color = Tok.gold2
          ..style = PaintingStyle.stroke);
      }
      if (s.onPath) {
        final t = _text(s.title, Tok.body.copyWith(fontSize: 11.5, color: current ? Tok.ink : Tok.muted));
        t.paint(canvas, p + Offset(-t.width / 2, -22));
      } else {
        final t = _text(s.title, Tok.label.copyWith(fontSize: 9));
        t.paint(canvas, p + Offset(8, -t.height / 2));
      }
    }
  }


  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    final positions = layoutPositions(size);
    return [for (final stop in trail.stops)
      if (positions[stop.index] case final position?)
        CustomPainterSemantics(
          rect: Rect.fromCenter(center: position, width: 44, height: 44),
          properties: SemanticsProperties(label: stop.title, textDirection: TextDirection.ltr),
        ),
    ];
  };

  @override
  bool shouldRebuildSemantics(ConstellationPainter oldDelegate) => oldDelegate.trail != trail;

  @override
  bool shouldRepaint(ConstellationPainter old) => old.trail != trail;
}
