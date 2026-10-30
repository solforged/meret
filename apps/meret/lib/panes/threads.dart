import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../shell/pane_row.dart';
import '../theme/tokens.dart';

/// What a thread is drawn between: a pane, the star in its header, and the
/// row in it that was followed to the next pane.
enum ThreadEnd { pane, star, went }

/// Where each stop's thread ends are on screen, so [ThreadLines] can join
/// them (plate 02). Ends register while they're built; the first one that
/// is laid out wins.
class ThreadAnchors extends ChangeNotifier {
  final _ends = <(ThreadEnd, int), List<State>>{};
  bool _scheduled = false;
  bool _disposed = false;

  RenderBox? box(ThreadEnd end, int stop) => boxes(end, stop).firstOrNull;

  /// Every laid-out end of this kind for [stop], in the order they were built.
  Iterable<RenderBox> boxes(ThreadEnd end, int stop) sync* {
    for (final state in _ends[(end, stop)] ?? const <State>[]) {
      final box = state.context.findRenderObject();
      if (box is RenderBox && box.attached && box.hasSize) yield box;
    }
  }

  /// The colour the first end of this kind for [stop] gave, if any.
  Color? color(ThreadEnd end, int stop) {
    for (final state in _ends[(end, stop)] ?? const <State>[]) {
      if (state.widget case ThreadAnchor(:final color?)) return color;
    }
    return null;
  }

  void _add(ThreadEnd end, int stop, State state) {
    (_ends[(end, stop)] ??= []).add(state);
    _changed();
  }

  void _remove(ThreadEnd end, int stop, State state) {
    final states = _ends[(end, stop)];
    states?.remove(state);
    if (states != null && states.isEmpty) _ends.remove((end, stop));
    _changed();
  }

  // Ends come and go while a frame builds; tell the lines once it's laid out.
  // The panes unregister as the surface goes, after this has been disposed.
  void _changed() {
    if (_scheduled || _disposed) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Marks [child] as one end of a thread for the stop [stop]. An end may give
/// the [color] its thread is drawn in.
class ThreadAnchor extends StatefulWidget {
  const ThreadAnchor({super.key, required this.anchors, required this.end, required this.stop, this.color, required this.child});
  final ThreadAnchors anchors;
  final ThreadEnd end;
  final int stop;
  final Color? color;
  final Widget child;

  @override
  State<ThreadAnchor> createState() => _ThreadAnchorState();
}

class _ThreadAnchorState extends State<ThreadAnchor> {
  @override
  void initState() {
    super.initState();
    widget.anchors._add(widget.end, widget.stop, this);
  }

  @override
  void didUpdateWidget(ThreadAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ThreadAnchor(:anchors, :end, :stop) = widget;
    if (oldWidget.anchors != anchors || oldWidget.end != end || oldWidget.stop != stop) {
      oldWidget.anchors._remove(oldWidget.end, oldWidget.stop, this);
      anchors._add(end, stop, this);
    }
  }

  // A pane moving between the row and the parked set is out of the tree
  // for a moment; its ends leave with it.
  @override
  void deactivate() {
    widget.anchors._remove(widget.end, widget.stop, this);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    widget.anchors._add(widget.end, widget.stop, this);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// One thread as it is drawn this frame, in the coordinates of its [ThreadLines].
///
/// It is a short elbow: out of the followed row (or the edge of a spine),
/// along the gutter, into the header of the pane it led to, in one colour,
/// the star's. [alpha] is the whole of its strength, already followed from
/// the panes' own fades.
@immutable
class ThreadSpan {
  const ThreadSpan({required this.start, required this.end, required this.rail, required this.alpha, this.color = Tok.gold});

  /// Where it leaves the source pane: the lit row's end, or a spine's edge.
  final Offset start;

  /// Where it lands: the edge of the star's halo, or a spine's edge.
  final Offset end;

  /// The x of its vertical run, between the two.
  final double rail;
  final double alpha;
  final Color color;

  /// How much it bends: a corner never rounds off more than this.
  static const bend = 8.0;

  /// The run is strongest this far from either end, and fades to [floor] of
  /// that between, so a long drop reads as two short links, not a tail.
  static const reach = 44.0;
  static const floor = 0.22;

  double get drop => (end.dy - start.dy).abs();
  bool get fades => drop > 2 * reach + 2 * bend;

  Path get path {
    final path = Path()..moveTo(start.dx, start.dy);
    final dy = end.dy - start.dy;
    if (dy.abs() < 1) return path..lineTo(end.dx, end.dy);
    final r = math.min(bend, math.min(dy.abs() / 2, (end.dx - start.dx) / 2));
    final x = rail.clamp(start.dx + r, end.dx - r);
    final up = dy.sign;
    return path
      ..lineTo(x - r, start.dy)
      ..quadraticBezierTo(x, start.dy, x, start.dy + up * r)
      ..lineTo(x, end.dy - up * r)
      ..quadraticBezierTo(x, end.dy, x + r, end.dy)
      ..lineTo(end.dx, end.dy);
  }

  void paint(Canvas canvas) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: alpha);
    if (fades) {
      final edge = reach / drop;
      final ends = color.withValues(alpha: alpha);
      final between = color.withValues(alpha: alpha * floor);
      paint.shader = ui.Gradient.linear(Offset(0, start.dy), Offset(0, end.dy), [ends, between, between, ends], [0, edge, 1 - edge, 1]);
    }
    canvas.drawPath(path, paint);
  }
}

/// The trail's constellation drawn on the row itself (plate 02): a gold
/// thread from the row you followed in each pane to the star in the next
/// pane's header. A folded pane carries it from the edge of its spine at
/// header level. Each thread follows the fades of the panes it joins.
class ThreadLines extends StatefulWidget {
  const ThreadLines({super.key, required this.anchors, required this.stops, required this.child});
  final ThreadAnchors anchors;

  /// The row's stops in order; a thread joins each to the next.
  final List<int> stops;
  final Widget child;

  /// How long the lines follow the panes after anything changes: the row's
  /// longest move, a shift then an entrance.
  static const settle = Duration(milliseconds: 600);

  @override
  State<ThreadLines> createState() => ThreadLinesState();
}

/// Where a thread came from, kept so a pane that leaves keeps it while it fades.
typedef _Came = ({int source, double dy});

class ThreadLinesState extends State<ThreadLines> with SingleTickerProviderStateMixin {
  final _box = GlobalKey();
  final _repaint = _Repaint();
  late final Ticker _ticker = createTicker(_tick);
  Duration _elapsed = Duration.zero;
  Duration _until = Duration.zero;

  /// By target stop: the source it was last threaded from and how far below that
  /// pane's top the thread left.
  final _came = <int, _Came>{};

  /// A header's star sits this far down its pane.
  static const _header = 17.0;

  /// A folded pane is a spine, not a pane to thread a row out of.
  static const _spine = 60.0;

  /// The star's halo reaches this far from its centre; a thread stops there.
  static const _halo = 9.0;

  @override
  void initState() {
    super.initState();
    widget.anchors.addListener(_kick);
  }

  @override
  void didUpdateWidget(ThreadLines oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.anchors != widget.anchors) {
      oldWidget.anchors.removeListener(_kick);
      widget.anchors.addListener(_kick);
    }
    _kick();
  }

  @override
  void dispose() {
    widget.anchors.removeListener(_kick);
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  /// Panes move by paint transforms and scroll without rebuilding this, so
  /// the lines repaint every frame for a moment after anything changes.
  void _kick() {
    if (!mounted) return;
    _until = _elapsed + ThreadLines.settle;
    if (!_ticker.isActive) _ticker.start();
    _repaint.ping();
  }

  void _tick(Duration elapsed) {
    _elapsed = elapsed;
    _repaint.ping();
    if (elapsed >= _until) {
      _ticker.stop();
      _elapsed = Duration.zero;
    }
  }

  /// Every thread to draw now: those of the row, and those of panes still
  /// fading out after leaving it.
  @visibleForTesting
  List<ThreadSpan> spans() {
    final me = _box.currentContext?.findRenderObject();
    if (me is! RenderBox || !me.attached) return const [];
    final stops = widget.stops;
    final row = {for (var i = 1; i < stops.length; i++) stops[i]: stops[i - 1]};
    final spans = <ThreadSpan>[
      for (final MapEntry(key: target, value: source) in row.entries) ?_span(me, source, target, null),
    ];
    for (final MapEntry(key: target, value: came) in _came.entries.toList()) {
      if (row.containsKey(target)) continue;
      if (_span(me, came.source, target, came.dy) case final span?) {
        spans.add(span);
      } else {
        _came.remove(target);
      }
    }
    return spans;
  }

  /// The thread from [source]'s pane to [target]'s, or null while either is
  /// unseen or unpainted. One whose pane has left the row is [leftAt] below
  /// the top of its source.
  ThreadSpan? _span(RenderBox me, int source, int target, double? leftAt) {
    final anchors = widget.anchors;
    final from = anchors.box(ThreadEnd.pane, source);
    final to = anchors.box(ThreadEnd.pane, target);
    if (from == null || to == null) return null;
    // It is as strong as the fainter of its two panes is painted: a pane
    // sliding in, dimmed or fading out takes its thread with it.
    final shown = math.min(PaneRow.paintedOpacity(from, upTo: me), PaneRow.paintedOpacity(to, upTo: me));
    if (shown <= 0) return null;
    final src = from.localToGlobal(Offset.zero, ancestor: me) & from.size;
    final dst = to.localToGlobal(Offset.zero, ancestor: me) & to.size;

    // A pane folded to a spine has no row and no star: its thread leaves, or
    // lands, at header level on the spine's edge.
    final spineStart = src.width < _spine, spineEnd = dst.width < _spine;
    final star = anchors.box(ThreadEnd.star, target);
    final landing = !spineEnd && star != null ? star.localToGlobal(star.size.center(Offset.zero), ancestor: me) : Offset(dst.left, dst.top + _header);
    final end = spineEnd ? Offset(dst.left + 3, landing.dy) : Offset(landing.dx - _halo, landing.dy);

    // It leaves level with the lit row. Of several lit rows the one reaching
    // furthest right is the thread row with its arrow, not a name in a credit,
    // and one in view beats one scrolled away. A row out of view, or gone from
    // the list, leaves the thread at the edge of the body it went out by.
    final body = Rect.fromLTRB(src.left, src.top + _header * 2, src.right, src.bottom);
    Offset? row;
    var rowInView = false;
    if (!spineStart && leftAt == null) {
      for (final went in anchors.boxes(ThreadEnd.went, source)) {
        final at = went.localToGlobal(Offset(went.size.width, went.size.height / 2), ancestor: me);
        final inView = at.dy >= body.top && at.dy <= body.bottom;
        if (row == null || (inView && !rowInView) || (inView == rowInView && at.dx > row.dx + 1)) {
          row = at;
          rowInView = inView;
        }
      }
    }
    final remembered = _came[target];
    final double startY;
    if (spineStart) {
      startY = src.top + _header;
    } else if (leftAt != null) {
      startY = (src.top + leftAt).clamp(body.top, body.bottom);
    } else {
      startY = (row?.dy ?? (remembered?.source == source ? src.top + remembered!.dy : body.top)).clamp(body.top, body.bottom);
    }
    if (leftAt == null) _came[target] = (source: source, dy: startY - src.top);
    final start = Offset(src.right + (spineStart ? -3 : -15), startY);
    if (end.dx <= start.dx) return null;

    // It ebbs while the pane it joins is still sliding in across a gap, and
    // while its row is out of view.
    final slide = 1 - 0.65 * _smooth((dst.left - src.right - 32) / 168);
    final quiet = spineStart || leftAt != null || rowInView ? 1.0 : 0.5;
    final alpha = shown * (1.5 - 0.5 * shown) * slide * quiet;
    return ThreadSpan(
      start: start, end: end, rail: start.dx + math.min((end.dx - start.dx) * 0.3, 9), alpha: alpha,
      color: anchors.color(ThreadEnd.star, target) ?? Tok.gold,
    );
  }

  static double _smooth(double t) {
    final x = t.clamp(0.0, 1.0);
    return x * x * (3 - 2 * x);
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollNotification>(
    onNotification: (_) {
      _kick();
      return false;
    },
    child: CustomPaint(
      key: _box,
      foregroundPainter: _ThreadPainter(this),
      child: widget.child,
    ),
  );
}

class _Repaint extends ChangeNotifier {
  void ping() => notifyListeners();
}

class _ThreadPainter extends CustomPainter {
  _ThreadPainter(this.lines) : super(repaint: lines._repaint);
  final ThreadLinesState lines;

  @override
  void paint(Canvas canvas, Size size) {
    final spans = lines.spans();
    if (spans.isEmpty) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final span in spans) {
      span.paint(canvas);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ThreadPainter old) => old.lines != lines;
}
