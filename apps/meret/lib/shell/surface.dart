import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bridge.dart';
import '../core/playhead.dart';
import '../draw/constellation.dart';
import '../now/now_pane.dart';
import '../panes/front_pane.dart';
import '../panes/pane.dart';
import '../panes/person_pane.dart';
import '../panes/release_pane.dart';
import '../panes/search_pane.dart';
import '../settings/settings_window.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';
import 'pane_row.dart';
import 'query_line.dart';
import 'status_line.dart';
import 'width_class.dart';
import 'window_chrome.dart';

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
  bool _frontOnly = true;
  int _navigationVersion = 0;
  String? _navigationError;
  late SettingsDto _settings;
  BuildContext? _settingsContext;

  @override
  void initState() {
    super.initState();
    _settings = widget.core.settings();
    WindowChrome.instance.onSettings = _openSettings;
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
        _frontOnly = trail == null;
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
    WindowChrome.instance.onSettings = null;
    super.dispose();
  }

  void _openSettings() {
    final context = _settingsContext;
    if (context != null) showSettings(context);
  }

  void _toggle() => widget.core.transport(_clock.playing ? const TransportDto.pause() : const TransportDto.resume());

  void _animate(int direction) {
    _slide.value = direction.toDouble();
    _slide.animateTo(0, curve: Curves.easeOutCubic);
  }

  Future<void> _navigate(Future<TrailDto?> Function() call, {bool frontOnNull = false, int direction = 1}) async {
    final version = ++_navigationVersion;
    final trail = await call();
    if (!mounted || version != _navigationVersion) return;
    setState(() {
      _navigationError = null;
      if (trail != null) {
        _trail = trail;
        _frontOnly = false;
      } else if (frontOnNull) {
        _frontOnly = true;
      }
    });
    _animate(direction);
  }

  Future<void> _report(Future<void> call) async {
    try {
      await call;
    } catch (error) {
      if (mounted) setState(() => _navigationError = error.toString());
    }
  }

  Future<void> _move(int by) async {
    if (by > 0 && _frontOnly) return;
    await _navigate(by < 0 ? widget.core.trailBack : widget.core.trailForward, frontOnNull: by < 0, direction: by);
  }

  void _showFront() {
    _navigationVersion++;
    _slide.stop();
    _slide.value = 0;
    setState(() {
      _frontOnly = true;
      _navigationError = null;
    });
  }

  Future<void> _start(TargetDto to) => _navigate(() => widget.core.startTrail(to));

  Future<void> _submit(QueryDto query) async {
    if (query.kind == QueryKind.command) {
      await widget.core.runCommand(query.canonical);
    } else if (query.kind == QueryKind.search) {
      await _start(TargetDto.search(query: query.canonical));
    }
  }

  TargetDto _hitTarget(HitDto hit) => switch (hit.kind) {
    HitKind.release => TargetDto.release(id: hit.id),
    HitKind.person => TargetDto.person(id: hit.id),
    HitKind.track => throw 'A track plays without opening a pane',
  };

  Future<void> _search(SearchDto search, HitDto? hit) async {
    if (hit?.kind == HitKind.track) {
      final index = hit!.index;
      if (index == null) throw 'This track has no result index';
      await widget.core.playResults(hit.query, const ViewDto(sort: SortKeyDto.library_, descending: false, group: false), index.toInt());
      return;
    }
    final version = ++_navigationVersion;
    var trail = await widget.core.startTrail(TargetDto.search(query: search.query));
    if (!mounted || version != _navigationVersion) return;
    setState(() {
      _trail = trail;
      _frontOnly = false;
      _navigationError = null;
    });
    if (hit != null) {
      trail = await widget.core.follow(trail.current, _hitTarget(hit), ThreadKind.matched);
      if (!mounted || version != _navigationVersion) return;
      setState(() => _trail = trail);
    }
    _animate(1);
  }

  Future<void> _follow(int from, TargetDto to, ThreadKind via) =>
      _navigate(() => widget.core.follow(from, to, via));

  Widget _pane(StopDto stop) {
    final scanning = _status?.jobs.any((job) => job.verb == 'scanning' || job.verb == 'reading tags') ?? false;
    Future<void> follow(TargetDto to, ThreadKind via) => _follow(stop.index, to, via);
    final body = switch (stop.target) {
      TargetDto_Search(:final query) => SearchPane(
        core: widget.core,
        query: query,
        libraryVersion: _status?.libraryVersion,
        tracks: _status?.tracks,
        scanning: scanning,
        onFollow: follow,
        onHit: (hit) => _report(follow(_hitTarget(hit), ThreadKind.matched)),
      ),
      TargetDto_Release(:final id) => ReleasePane(core: widget.core, id: id, fromStop: stop.index, onFollow: follow),
      TargetDto_Person(:final id) => PersonPane(core: widget.core, id: id, onFollow: follow),
    };
    return Pane(
      key: ValueKey('stop-${stop.index}-${stop.target}'),
      kind: switch (stop.target) {
        TargetDto_Search() => 'Search',
        TargetDto_Release() => 'Release',
        TargetDto_Person() => 'Person',
      },
      title: stop.title,
      via: stop.via,
      source: stop.viaSource,
      body: body,
      showTitle: stop.target is! TargetDto_Release,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colours = _settings.light == LightLevelDto.off ? null : _now?.light;
    final wash = _settings.light == LightLevelDto.accentAndWash
        ? colours == null ? Light.brass.wash : Color(colours.wash)
        : Colors.transparent;
    final light = Light(
      accent: colours == null ? Light.brass.accent : Color(colours.light),
      wash: wash,
      dim: colours == null ? Light.brass.dim : Color(colours.dim),
      track: _now?.trackId?.toInt(),
      release: _now?.releaseId?.toInt(),
    );
    return SettingsScope(
      core: widget.core,
      onChanged: (settings) => setState(() => _settings = settings),
      child: LightScope(light: light, child: Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.slash): _Focus(),
        SingleActivator(LogicalKeyboardKey.space): _Toggle(),
        SingleActivator(LogicalKeyboardKey.bracketLeft): _Move(-1),
        SingleActivator(LogicalKeyboardKey.bracketRight): _Move(1),
        SingleActivator(LogicalKeyboardKey.digit1, meta: true): _Front(),
        SingleActivator(LogicalKeyboardKey.keyL, meta: true): _Table(),
        SingleActivator(LogicalKeyboardKey.comma, meta: true): _Settings(),
      },
      child: Actions(
        actions: {
          _Focus: CallbackAction<_Focus>(onInvoke: (_) => _queryFocus.requestFocus()),
          _Toggle: CallbackAction<_Toggle>(onInvoke: (_) => _toggle()),
          _Move: CallbackAction<_Move>(onInvoke: (i) => _report(_move(i.by))),
          _Front: CallbackAction<_Front>(onInvoke: (_) => _showFront()),
          _Table: CallbackAction<_Table>(onInvoke: (_) => _report(_start(const TargetDto.search(query: '')))),
          _Settings: CallbackAction<_Settings>(onInvoke: (_) => _openSettings()),
        },
        child: Focus(
          autofocus: true,
          child: ColoredBox(
            color: Tok.void_,
            child: LayoutBuilder(builder: (context, box) {
              _settingsContext = context;
              final wc = WidthClass.of(box.maxWidth);
              final panes = <Widget>[
                FrontPane(
                  key: const ValueKey('front'),
                  core: widget.core,
                  libraryVersion: _status?.libraryVersion,
                  jobs: _status?.jobs ?? const [],
                  onQuery: (query) => _report(_start(TargetDto.search(query: query))),
                  onRelease: (id) => _report(_start(TargetDto.release(id: id))),
                ),
                if (!_frontOnly && _trail != null)
                  for (final stop in _path(_trail!)) _pane(stop),
              ];
              final row = PaneRow(slide: _slide, visible: wc.panes.clamp(1, panes.length), children: panes);
              return Column(children: [
                QueryLine(core: widget.core, focus: _queryFocus, onSubmit: _submit, onSearch: _search),
                SizedBox(
                  height: wc == WidthClass.phone ? 44 : 64,
                  child: _trail == null
                      ? const NoTrailStrip()
                      : TrailStrip(trail: _trail!, onGo: (stop) => _report(_navigate(() => widget.core.trailGo(stop)))),
                ),
                if (_navigationError != null)
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Text(_navigationError!, style: Tok.label.copyWith(color: Tok.warn))),
                Expanded(
                  child: Row(children: [
                    Expanded(child: row),
                    if (wc.nowWidth case final width?)
                      SizedBox(width: width, child: NowPane(core: widget.core, now: _now, clock: _clock, onToggle: _toggle)),
                  ]),
                ),
                if (!wc.pinnedNow) NowBar(core: widget.core, now: _now, clock: _clock, onToggle: _toggle),
                if (wc != WidthClass.phone)
                  StatusLine(core: widget.core, status: _status, keys: [('/', 'search'), ('[ ]', 'along the trail'), ('␣', 'play'), if (wc == WidthClass.large) ...[('⌘1', 'Front'), ('⌘L', 'table')]]),
              ]);
            }),
          ),
        ),
      ),
    )));
  }
}

List<StopDto> _path(TrailDto trail) {
  final stops = {for (final stop in trail.stops.where((stop) => stop.onPath)) stop.index: stop};
  final path = <StopDto>[];
  StopDto? stop = stops[trail.current];
  while (stop != null) {
    path.add(stop);
    stop = stops[stop.parent];
  }
  return path.reversed.toList();
}

class _Settings extends Intent {
  const _Settings();
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
