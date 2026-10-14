import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bridge.dart';
import '../core/playhead.dart';
import '../draw/constellation.dart';
import '../now/now_pane.dart';
import '../panes/front_pane.dart';
import '../panes/pane.dart';
import '../panes/table_pane.dart';
import '../theme/tokens.dart';
import 'pane_row.dart';
import 'query_line.dart';
import 'status_line.dart';
import 'width_class.dart';

/// The one surface: query line, trail strip, panes, Now, status line.
/// No tabs, no sidebar, no destinations.
class Surface extends StatefulWidget {
  const Surface({super.key, required this.core});
  final CoreBridge core;

  @override
  State<Surface> createState() => _SurfaceState();
}

class _SurfaceState extends State<Surface> with TickerProviderStateMixin {
  late final PlayheadClock _clock = PlayheadClock(this);
  late final AnimationController _slide = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  final _queryFocus = FocusNode();
  StreamSubscription<NowDto>? _nowSub;
  StreamSubscription<StatusDto>? _statusSub;
  NowDto? _now;
  StatusDto? _status;
  TrailDto? _trail;
  final _panes = <_PaneSpec>[const _PaneSpec(kind: 'FRONT', title: 'Front')];
  int _visibleEnd = 1;
  int _navigationVersion = 0;

  @override
  void initState() {
    super.initState();
    _nowSub = widget.core.now().listen((n) {
      if (!mounted) return;
      _clock.anchor(n.anchor);
      setState(() => _now = n);
    });
    _statusSub = widget.core.status().listen((s) {
      if (mounted) setState(() => _status = s);
    });
    final version = _navigationVersion;
    widget.core.trail().then((trail) {
      if (!mounted || version != _navigationVersion) return;
      setState(() {
        _trail = trail;
        if (trail != null) {
          for (final stop in trail.stops.where((stop) => stop.onPath)) {
            final separator = stop.entity.indexOf(':');
            final prefix = separator < 0 ? '' : stop.entity.substring(0, separator);
            _panes.add(_PaneSpec(
              kind: switch (prefix) { 'recording' => 'RECORDING', 'agent' => 'PERSON', 'release' => 'RELEASE', _ => prefix.toUpperCase() },
              title: separator < 0 ? stop.entity : stop.entity.substring(separator + 1),
              via: stop.via,
            ));
          }
          _visibleEnd = _panes.length;
        }
      });
    });
  }

  @override
  void dispose() {
    _nowSub?.cancel();
    _statusSub?.cancel();
    _clock.dispose();
    _slide.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  void _toggle() => widget.core.transport(_clock.playing ? const TransportDto.pause() : const TransportDto.resume());

  void _move(int by) {
    setState(() => _visibleEnd = (_visibleEnd + by).clamp(1, _panes.length));
    _slide.value = by > 0 ? 1 : -1;
    _slide.animateTo(0, curve: Curves.easeOutCubic);
  }

  void _showFront() {
    _navigationVersion++;
    _slide.stop();
    _slide.value = 0;
    setState(() => _visibleEnd = 1);
  }

  void _openTable(String query, int from) {
    _navigationVersion++;
    setState(() {
      _panes.removeRange(from + 1, _panes.length);
      _panes.add(_PaneSpec(kind: 'TABLE', title: query.isEmpty ? 'Everything' : query, query: query));
      _visibleEnd = _panes.length;
      if (from == 0) _trail = null;
    });
    _slide.value = 1;
    _slide.animateTo(0, curve: Curves.easeOutCubic);
  }

  Future<void> _submit(QueryDto query) async {
    if (query.kind == QueryKind.command) {
      await widget.core.runCommand(query.canonical);
    } else if (query.kind == QueryKind.search) {
      _openTable(query.canonical, 0);
    }
    if (mounted) _queryFocus.unfocus();
  }

  Widget _pane(_PaneSpec spec, int index) {
    if (index == 0) {
      return FrontPane(
        key: const ValueKey('front'),
        core: widget.core,
        libraryVersion: _status?.libraryVersion,
        jobs: _status?.jobs ?? const [],
        onQuery: (query) => _openTable(query, 0),
      );
    }
    return Pane(
      key: ValueKey('pane-$index'),
      kind: spec.kind,
      title: spec.title,
      via: spec.via,
      body: spec.query == null ? null : TablePane(
        core: widget.core,
        query: spec.query!,
        libraryVersion: _status?.libraryVersion,
        tracks: _status?.tracks,
        scanning: _status?.jobs.any((job) => job.verb == 'scanning' || job.verb == 'reading tags') ?? false,
        onQuery: (query) => setState(() => _panes[index] = _PaneSpec(kind: 'TABLE', title: query.isEmpty ? 'Everything' : query, query: query)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.slash): _Focus(),
        SingleActivator(LogicalKeyboardKey.space): _Toggle(),
        SingleActivator(LogicalKeyboardKey.bracketLeft): _Move(-1),
        SingleActivator(LogicalKeyboardKey.bracketRight): _Move(1),
        SingleActivator(LogicalKeyboardKey.digit1, meta: true): _Front(),
        SingleActivator(LogicalKeyboardKey.keyL, meta: true): _Table(),
      },
      child: Actions(
        actions: {
          _Focus: CallbackAction<_Focus>(onInvoke: (_) => _queryFocus.requestFocus()),
          _Toggle: CallbackAction<_Toggle>(onInvoke: (_) => _toggle()),
          _Move: CallbackAction<_Move>(onInvoke: (i) => _move(i.by)),
          _Front: CallbackAction<_Front>(onInvoke: (_) => _showFront()),
          _Table: CallbackAction<_Table>(onInvoke: (_) => _openTable('', _visibleEnd - 1)),
        },
        child: Focus(
          autofocus: true,
          child: ColoredBox(
            color: Tok.void_,
            child: LayoutBuilder(builder: (context, box) {
              final wc = WidthClass.of(box.maxWidth);
              final panes = [for (var i = 0; i < _visibleEnd; i++) _pane(_panes[i], i)];
              final row = PaneRow(slide: _slide, visible: wc.panes.clamp(1, panes.length), children: panes);
              return Column(children: [
                QueryLine(core: widget.core, focus: _queryFocus, onSubmit: _submit),
                SizedBox(
                  height: wc == WidthClass.phone ? 44 : 64,
                  child: _trail == null
                      ? const NoTrailStrip()
                      : CustomPaint(painter: ConstellationPainter(_trail!), size: Size.infinite),
                ),
                Expanded(
                  child: Row(children: [
                    Expanded(child: row),
                    if (wc.pinnedNow)
                      SizedBox(width: 380, child: NowPane(now: _now, clock: _clock, onToggle: _toggle)),
                  ]),
                ),
                if (!wc.pinnedNow) _NowBar(now: _now, clock: _clock, onToggle: _toggle),
                if (wc != WidthClass.phone)
                  StatusLine(status: _status, keys: [('/', 'search'), ('[ ]', 'along the trail'), ('␣', 'play'), if (wc == WidthClass.large) ...[('⌘1', 'Front'), ('⌘L', 'table')]]),
              ]);
            }),
          ),
        ),
      ),
    );
  }
}

class _PaneSpec {
  const _PaneSpec({required this.kind, required this.title, this.via, this.query});
  final String kind;
  final String title;
  final String? via;
  final String? query;
}

class _Front extends Intent {
  const _Front();
}

class _Table extends Intent {
  const _Table();
}

class _Focus extends Intent {
  const _Focus();
}

class _Toggle extends Intent {
  const _Toggle();
}

class _Move extends Intent {
  const _Move(this.by);
  final int by;
}

/// Now as a bar, below the panes, on smaller screens.
class _NowBar extends StatelessWidget {
  const _NowBar({required this.now, required this.clock, required this.onToggle});
  final NowDto? now;
  final PlayheadClock clock;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final length = now?.lengthMs?.toDouble() ?? 1;
    return GestureDetector(
      onTap: onToggle,
      child: Container(
        height: 48,
        color: Tok.panel,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(now?.title ?? '', style: Tok.body, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(now?.subtitle ?? '', style: Tok.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          SizedBox(
            width: 120,
            height: 2,
            child: CustomPaint(painter: _Progress(clock, length)),
          ),
        ]),
      ),
    );
  }
}

class _Progress extends CustomPainter {
  _Progress(this.clock, this.length) : super(repaint: clock);
  final PlayheadClock clock;
  final double length;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Tok.line);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width * (clock.positionMs / length).clamp(0, 1), size.height), Paint()..color = Tok.light);
  }

  @override
  bool shouldRepaint(_Progress old) => old.length != length;
}
