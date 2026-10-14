import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bridge.dart';
import '../core/playhead.dart';
import '../draw/constellation.dart';
import '../now/now_pane.dart';
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
  String _tableQuery = 'last:30d';
  int _visibleEnd = 5;

  @override
  void initState() {
    super.initState();
    _nowSub = widget.core.now().listen((n) {
      _clock.anchor(n.anchor);
      setState(() => _now = n);
    });
    _statusSub = widget.core.status().listen((s) => setState(() => _status = s));
    widget.core.trail().then((t) => setState(() => _trail = t));
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
    setState(() => _visibleEnd = (_visibleEnd + by).clamp(1, _panes().length));
    _slide.value = by > 0 ? 1 : -1;
    _slide.animateTo(0, curve: Curves.easeOutCubic);
  }

  List<Widget> _panes() => [
        const Pane(kind: 'CUE · CHRONO TRIGGER', title: 'Corridors of Time'),
        const Pane(kind: 'PERSON · COMPOSER, ARRANGER', title: 'Yasunori Mitsuda', via: 'composed by', source: 'MusicBrainz · VGMdb'),
        const Pane(kind: 'SCORE · XENOGEARS · 1998', title: 'Xenogears Original Soundtrack', via: 'scored', source: 'MusicBrainz'),
        const Pane(kind: 'PERSON · VOCALIST', title: 'Joanne Hogg', via: 'sung by', source: 'VGMdb · Discogs'),
        const Pane(kind: 'GROUP · NOT OWNED', title: 'Iona', via: 'member of', source: 'MusicBrainz · Discogs'),
        Pane(
          kind: 'TABLE · EVERYTHING YOU OWN, STREAM OR WANT',
          title: 'Played in the last 30 days',
          body: TablePane(core: widget.core, query: _tableQuery, onQuery: (q) => setState(() => _tableQuery = q)),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.slash): _Focus(),
        SingleActivator(LogicalKeyboardKey.space): _Toggle(),
        SingleActivator(LogicalKeyboardKey.bracketLeft): _Move(-1),
        SingleActivator(LogicalKeyboardKey.bracketRight): _Move(1),
      },
      child: Actions(
        actions: {
          _Focus: CallbackAction<_Focus>(onInvoke: (_) => _queryFocus.requestFocus()),
          _Toggle: CallbackAction<_Toggle>(onInvoke: (_) => _toggle()),
          _Move: CallbackAction<_Move>(onInvoke: (i) => _move(i.by)),
        },
        child: Focus(
          autofocus: true,
          child: ColoredBox(
            color: Tok.void_,
            child: LayoutBuilder(builder: (context, box) {
              final wc = WidthClass.of(box.maxWidth);
              final panes = _panes().take(_visibleEnd).toList();
              final row = PaneRow(slide: _slide, visible: wc.panes.clamp(1, panes.length), children: panes);
              return Column(children: [
                QueryLine(core: widget.core, focus: _queryFocus),
                if (_trail case final t?)
                  SizedBox(
                    height: wc == WidthClass.phone ? 44 : 64,
                    child: CustomPaint(painter: ConstellationPainter(t), size: Size.infinite),
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
                  StatusLine(status: _status, keys: const [('/', 'search'), ('[ ]', 'along the trail'), ('␣', 'play')]),
              ]);
            }),
          ),
        ),
      ),
    );
  }
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
