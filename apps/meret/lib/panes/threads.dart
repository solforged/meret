import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

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

/// Marks [child] as one end of a thread for the stop [stop]. Turning it
/// off keeps the tree the same shape, so nothing under it remounts.
class ThreadAnchor extends StatefulWidget {
  const ThreadAnchor({super.key, required this.anchors, required this.end, required this.stop, this.on = true, required this.child});
  final ThreadAnchors anchors;
  final ThreadEnd end;
  final int stop;
  final bool on;
  final Widget child;

  @override
  State<ThreadAnchor> createState() => _ThreadAnchorState();
}

class _ThreadAnchorState extends State<ThreadAnchor> {
  @override
  void initState() {
    super.initState();
    if (widget.on) widget.anchors._add(widget.end, widget.stop, this);
  }

  @override
  void didUpdateWidget(ThreadAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ThreadAnchor(:anchors, :end, :stop, :on) = widget;
    if (oldWidget.anchors != anchors || oldWidget.end != end || oldWidget.stop != stop || oldWidget.on != on) {
      if (oldWidget.on) oldWidget.anchors._remove(oldWidget.end, oldWidget.stop, this);
      if (on) anchors._add(end, stop, this);
    }
  }

  // A pane moving between the row and the parked set is out of the tree
  // for a moment; its ends leave with it.
  @override
  void deactivate() {
    if (widget.on) widget.anchors._remove(widget.end, widget.stop, this);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    if (widget.on) widget.anchors._add(widget.end, widget.stop, this);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The trail's constellation drawn on the row itself (plate 02): a gold
/// thread from the row you followed in each pane to the star in the next
/// pane's header. Stops ahead get a fainter thread. A thread whose row has
/// scrolled away starts from the pane's own header instead.
class ThreadLines extends StatefulWidget {
  const ThreadLines({super.key, required this.anchors, required this.stops, required this.path, required this.child});
  final ThreadAnchors anchors;

  /// The row's stops in order; a thread joins each to the next.
  final List<int> stops;

  /// How many of [stops] are the path; the rest are ahead.
  final int path;
  final Widget child;

  /// How long the lines follow the panes after anything changes: the row's
  /// longest move, a shift then an entrance.
  static const settle = Duration(milliseconds: 600);

  @override
  State<ThreadLines> createState() => _ThreadLinesState();
}

class _ThreadLinesState extends State<ThreadLines> with SingleTickerProviderStateMixin {
  final _box = GlobalKey();
  final _repaint = _Repaint();
  late final Ticker _ticker = createTicker(_tick);
  Duration _elapsed = Duration.zero;
  Duration _until = Duration.zero;

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
  final _ThreadLinesState lines;

  /// Half the header's 34 pt: where a header's star sits.
  static const _header = 17.0;

  @override
  void paint(Canvas canvas, Size size) {
    final me = lines._box.currentContext?.findRenderObject();
    if (me is! RenderBox || !me.attached) return;
    final ThreadLines(:anchors, :stops, :path) = lines.widget;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var i = 0; i + 1 < stops.length; i++) {
      final from = anchors.box(ThreadEnd.pane, stops[i]);
      final to = anchors.box(ThreadEnd.pane, stops[i + 1]);
      final star = anchors.box(ThreadEnd.star, stops[i + 1]);
      // A pane folded to a spine has no header to draw to.
      if (from == null || to == null || star == null) continue;
      final pane = from.localToGlobal(Offset.zero, ancestor: me) & from.size;
      final end = star.localToGlobal(star.size.center(Offset.zero), ancestor: me);
      // The thread leaves the pane's right edge level with the lit row, so it
      // crosses only the gap. Of several lit rows, the one reaching furthest
      // right is the thread row with its arrow, not a name in a credit.
      Offset? row;
      for (final went in anchors.boxes(ThreadEnd.went, stops[i])) {
        final end = went.localToGlobal(Offset(went.size.width, went.size.height / 2), ancestor: me);
        if (row == null || end.dx > row.dx + 1) row = end;
      }
      // A row scrolled out of its pane starts from the nearest edge it left by.
      final start = Offset(pane.right - 6, row == null ? pane.top + _header : row.dy.clamp(pane.top + _header * 2, pane.bottom));
      if (end.dx <= start.dx) continue;
      final reach = ((end.dx - start.dx) / 2).clamp(12.0, 40.0);
      final thread = Path()
        ..moveTo(start.dx, start.dy)
        ..cubicTo(start.dx + reach, start.dy, end.dx - reach, end.dy, end.dx, end.dy);
      canvas.drawPath(thread, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.25
        ..color = Tok.gold.withValues(alpha: i + 1 < path ? 0.9 : 0.35));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ThreadPainter old) => old.lines != lines;
}
