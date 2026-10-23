import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bridge.dart';
import '../core/playhead.dart';
import '../draw/constellation.dart';
import '../now/history_sheet.dart';
import '../now/now_pane.dart';
import '../now/now_stage.dart';
import '../panes/front_pane.dart';
import '../panes/game_pane.dart';
import '../panes/pane.dart';
import '../panes/person_pane.dart';
import '../panes/release_pane.dart';
import '../panes/search_pane.dart';
import '../panes/tree_pane.dart';
import '../panes/work_pane.dart';
import '../settings/settings_window.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';
import 'keep_dialog.dart';
import 'outside.dart';
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

enum _Stage { undecided, now, front }

/// One pane per stop of the open trail; the key follows the stop off the
/// path and back, so its State does.
class _StopKey extends GlobalKey<State<StatefulWidget>> {
  const _StopKey(this.index, this.target) : super.constructor();
  final int index;
  final TargetDto target;

  @override
  bool operator ==(Object other) => other is _StopKey && other.index == index && other.target == target;

  @override
  int get hashCode => Object.hash(index, target);
}

/// Pages fade through: the outgoing page is gone before the incoming one shows.
Widget _fadeThrough(Widget child, Animation<double> animation) =>
    FadeTransition(opacity: CurvedAnimation(parent: animation, curve: const Interval(0.5, 1)), child: child);

Widget _stacked(Widget? current, List<Widget> previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]);

class _SurfaceState extends State<Surface> with TickerProviderStateMixin {
  late final PlayheadClock _clock = PlayheadClock(this);
  late final AnimationController _slide = AnimationController(vsync: this, value: 0, lowerBound: -1, duration: kMotion);
  final _queryFocus = FocusNode();
  final _surfaceFocus = FocusNode(debugLabel: 'surface');
  late final Outside _outside = Outside(widget.core);
  StreamSubscription<NowDto>? _nowSub;
  StreamSubscription<StatusDto>? _statusSub;
  NowDto? _now;
  StatusDto? _status;
  TrailDto? _trail;

  /// Stops that left the path, oldest first; their panes stay mounted off
  /// the row so they return as they were.
  final _parked = <_StopKey>[];
  static const _parkedCap = 6;
  bool _frontOnly = true;
  bool _treeOnly = false;
  _Stage _stage = _Stage.undecided;
  int _navigationVersion = 0;
  int _memoryVersion = 0;
  String? _navigationError;
  late SettingsDto _settings;
  final _settingsChanges = ValueNotifier(0);
  BuildContext? _settingsContext;

  /// Play something found nothing playable; the bar says so until an item loads.
  bool _nothingToPlay = false;

  @override
  void initState() {
    super.initState();
    _settings = widget.core.settings();
    _queryFocus.addListener(_queryFocusChanged);
    WindowChrome.instance.onSettings = _openSettings;
    _nowSub = widget.core.now().listen((n) {
      if (!mounted) return;
      _clock.anchor(n.anchor);
      _outside.now(n);
      setState(() {
        if (_now?.anchor?.item != n.anchor?.item) _memoryVersion++;
        if (n.anchor != null) _nothingToPlay = false;
        _now = n;
        if (_stage == _Stage.undecided) _stage = n.anchor == null ? _Stage.front : _Stage.now;
      });
    });
    _statusSub = widget.core.status().listen((s) {
      if (mounted) setState(() => _status = s);
    });
    final version = _navigationVersion;
    widget.core.trail().then((trail) {
      if (!mounted || version != _navigationVersion) return;
      setState(() {
        if (trail != null) _setTrail(trail);
      });
    });
  }

  @override
  void dispose() {
    _nowSub?.cancel();
    _statusSub?.cancel();
    _clock.dispose();
    _slide.dispose();
    _queryFocus.removeListener(_queryFocusChanged);
    _queryFocus.dispose();
    _surfaceFocus.dispose();
    _settingsChanges.dispose();
    WindowChrome.instance.onSettings = null;
    _outside.dispose();
    super.dispose();
  }

  /// When the query line lets focus go and nothing else takes it, the
  /// surface does, so `[` `]` `h` and Space work without a click first.
  void _queryFocusChanged() {
    if (!_queryFocus.hasFocus) _reclaimFocus();
  }

  /// Keys live on the surface: take focus back when nothing holds it, or
  /// when what holds it was parked or covered. Never from under a sheet.
  void _reclaimFocus() {
    final context = _surfaceFocus.context;
    if (context == null || ModalRoute.of(context)?.isCurrent == false) return;
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || primary is FocusScopeNode || !primary.canRequestFocus) _surfaceFocus.requestFocus();
  }

  void _reclaimFocusAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reclaimFocus();
    });
  }

  void _openSettings() {
    final context = _settingsContext;
    if (context != null) showSettings(context);
  }

  void _toggle() {
    if (_now?.anchor == null) {
      _report(_playSomething());
    } else {
      widget.core.transport(_clock.playing ? const TransportDto.pause() : const TransportDto.resume());
    }
  }

  Future<void> _playSomething() async {
    if (_queryFocus.hasFocus) return;
    final pick = await widget.core.playSomething();
    if (mounted) setState(() => _nothingToPlay = pick == null);
  }

  Future<void> _keep() async {
    final trail = _trail;
    if (trail == null) {
      setState(() => _navigationError = "there's no trail to keep");
      return;
    }
    final root = trail.stops.firstWhere((stop) => stop.parent == null).title;
    final leaf = trail.stops.firstWhere((stop) => stop.index == trail.current).title;
    final version = _navigationVersion;
    final name = await askTrailName(context, suggested: trail.name ?? (root == leaf ? root : '$root → $leaf'));
    if (name == null || !mounted || version != _navigationVersion) return;
    final kept = await widget.core.keepTrail(name: name.name);
    if (!mounted || version != _navigationVersion) return;
    setState(() {
      _setTrail(kept);
      _navigationError = null;
      _memoryVersion++;
    });
  }

  void _fromStart() {
    if (!_queryFocus.hasFocus) widget.core.transport(const TransportDto.fromStart());
  }

  void _history() {
    final context = _settingsContext;
    if (!_queryFocus.hasFocus && context != null) {
      showHistorySheet(context, widget.core, (id) => _report(_start(TargetDto.release(id: id))), onToggle: _toggle);
    }
  }

  void _leaveStage() {
    if (_stage != _Stage.front) setState(() => _stage = _Stage.front);
  }

  void _animate(int direction) {
    _slide.value = direction.toDouble();
    _slide.animateTo(0, duration: kMotion, curve: Curves.easeOutCubic);
  }

  /// Same tree, or a different one from the history? Stops never change
  /// target inside a trail, so a clash at any index means another trail.
  static bool _sameTrail(TrailDto a, TrailDto b) {
    final targets = {for (final stop in a.stops) stop.index: stop.target};
    return b.stops.every((stop) => (targets[stop.index] ?? stop.target) == stop.target);
  }

  /// Install [trail]; stops that just left the path join the parked set,
  /// newest last, capped at [_parkedCap]. Another trail empties it.
  void _setTrail(TrailDto trail) {
    final old = _trail;
    _trail = trail;
    if (old == null || !_sameTrail(old, trail)) {
      _parked.clear();
      return;
    }
    final onPath = {for (final stop in _path(trail)) stop.index};
    final targets = {for (final stop in trail.stops) stop.index: stop.target};
    for (final stop in _path(old)) {
      if (onPath.contains(stop.index)) continue;
      final key = _StopKey(stop.index, stop.target);
      _parked..remove(key)..add(key);
    }
    _parked.removeWhere((key) => onPath.contains(key.index) || targets[key.index] != key.target);
    if (_parked.length > _parkedCap) _parked.removeRange(0, _parked.length - _parkedCap);
  }

  Future<void> _navigate(Future<TrailDto?> Function() call, {bool frontOnNull = false, int direction = 1, bool closeTree = true}) async {
    // Leaving the Now stage is a page change: the stage fades, nothing slides.
    final fromNow = _stage == _Stage.now;
    _leaveStage();
    final version = ++_navigationVersion;
    final trail = await call();
    if (!mounted || version != _navigationVersion) return;
    final moved = trail != null && (trail.current != _trail?.current || trail.stops.length != _trail?.stops.length);
    setState(() {
      _navigationError = null;
      if (closeTree) _treeOnly = false;
      if (trail != null) {
        _memoryVersion++;
        _setTrail(trail);
        _frontOnly = false;
      } else if (frontOnNull) {
        _frontOnly = true;
      }
    });
    if (moved && !fromNow) _animate(direction);
    _reclaimFocusAfterFrame();
  }

  Future<void> _report(Future<void> call) async {
    try {
      await call;
    } catch (error) {
      if (mounted) setState(() => _navigationError = error.toString());
    }
  }

  bool get _editing {
    final focus = FocusManager.instance.primaryFocus?.context;
    return focus != null && (focus.widget is EditableText || focus.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  Future<void> _sibling(int step) async {
    if (_editing) return;
    await _navigate(() => widget.core.trailSibling(step), direction: step);
  }

  Future<void> _prune(int leaf) => _navigate(() => widget.core.pruneBranch(leaf), closeTree: false);

  Future<void> _pruneNewest() async {
    if (_editing) return;
    final branch = _trail?.branches.where((branch) => !branch.current && branch.prunable).firstOrNull;
    if (branch != null) await _prune(branch.leaf);
  }

  Future<void> _playTrail(bool whole) async {
    final version = _navigationVersion;
    await widget.core.playTrail(whole);
    final trail = await widget.core.trail();
    if (mounted && version == _navigationVersion) {
      setState(() {
        if (trail != null) _setTrail(trail);
        _navigationError = null;
        _memoryVersion++;
      });
    }
  }

  Future<void> _move(int by) async {
    if (_editing) return;
    if (by > 0 && _frontOnly) {
      // `]` from the Front over an open trail returns to it where it was.
      if (_trail != null) _showTrail();
      return;
    }
    await _navigate(by < 0 ? widget.core.trailBack : widget.core.trailForward, frontOnNull: by < 0, direction: by);
  }

  /// `⌘1`: the Front over the trail, and back again. The trail stays open.
  void _showFront() {
    if (_frontOnly && _trail != null && _stage != _Stage.now) {
      _showTrail();
      return;
    }
    _navigationVersion++;
    _slide.stop();
    _slide.value = 0;
    setState(() {
      _stage = _Stage.front;
      _frontOnly = true;
      _treeOnly = false;
      _navigationError = null;
    });
    _reclaimFocusAfterFrame();
  }

  /// The page over the row fades out; the row is where it was, so nothing slides.
  void _showTrail() {
    _navigationVersion++;
    setState(() {
      _frontOnly = false;
      _treeOnly = false;
      _navigationError = null;
    });
  }

  void _toggleTree() {
    if (_editing || _trail == null) return;
    _navigationVersion++;
    _slide.stop();
    _slide.value = 0;
    setState(() {
      _stage = _Stage.front;
      _frontOnly = false;
      _treeOnly = !_treeOnly;
      _navigationError = null;
    });
    _reclaimFocusAfterFrame();
  }

  void _closeTree() {
    if (_editing || !_treeOnly) return;
    setState(() => _treeOnly = false);
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
    final fromNow = _stage == _Stage.now;
    _leaveStage();
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
      _setTrail(trail);
      _frontOnly = false;
      _treeOnly = false;
      _navigationError = null;
    });
    if (hit != null) {
      trail = await widget.core.follow(trail.current, _hitTarget(hit), ThreadKind.matched, 'library');
      if (!mounted || version != _navigationVersion) return;
      setState(() => _setTrail(trail));
    }
    if (!fromNow) _animate(1);
    _reclaimFocusAfterFrame();
  }

  Future<void> _follow(int from, TargetDto to, ThreadKind via, String provider) =>
      _navigate(() => widget.core.follow(from, to, via, provider));

  Widget _pane(StopDto stop) {
    final scanning = _status?.jobs.any((job) => job.isScan) ?? false;
    Future<void> follow(TargetDto to, ThreadKind via, String provider) => _follow(stop.index, to, via, provider);
    final body = switch (stop.target) {
      TargetDto_Search(:final query) => SearchPane(
        core: widget.core,
        query: query,
        libraryVersion: _status?.libraryVersion,
        tracks: _status?.tracks,
        scanning: scanning,
        onFollow: (to, via) => follow(to, via, 'local_tags'),
        onHit: (hit) => _report(follow(_hitTarget(hit), ThreadKind.matched, 'library')),
      ),
      TargetDto_Release(:final id) => ReleasePane(core: widget.core, id: id, fromStop: stop.index, onFollow: follow, title: stop.title,
        libraryVersion: _status?.libraryVersion, lookupsVersion: _status?.lookupsVersion),
      TargetDto_Person(:final id) => PersonPane(core: widget.core, id: id, onFollow: follow,
        libraryVersion: _status?.libraryVersion, lookupsVersion: _status?.lookupsVersion),
      TargetDto_Work(:final id) => WorkPane(core: widget.core, id: id, onFollow: follow, title: stop.title,
        libraryVersion: _status?.libraryVersion, lookupsVersion: _status?.lookupsVersion),
      TargetDto_Game(:final id) => GamePane(core: widget.core, id: id, onFollow: follow, title: stop.title,
        libraryVersion: _status?.libraryVersion, lookupsVersion: _status?.lookupsVersion),
    };
    return Pane(
      key: _StopKey(stop.index, stop.target),
      kind: switch (stop.target) {
        TargetDto_Search() => 'Search',
        TargetDto_Release() => 'Release',
        TargetDto_Person() => 'Person',
        TargetDto_Work() => 'Work',
        TargetDto_Game() => 'Game',
      },
      title: stop.title,
      via: stop.via,
      source: stop.viaSource,
      body: TrailPaneScope(
        trail: _trail!, stop: stop,
        onGo: (leaf) => _report(_navigate(() => widget.core.trailGo(leaf))),
        onPrune: (leaf) => _report(_prune(leaf)),
        child: body,
      ),
      showTitle: stop.target is! TargetDto_Release && stop.target is! TargetDto_Work && stop.target is! TargetDto_Game,
      compact: stop.target is TargetDto_Search,
      onSpineTap: () => _report(_navigate(() => widget.core.trailGo(stop.index), direction: -1)),
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
    final playing = (_now?.anchor?.rate ?? 0) > 0;
    return SettingsScope(
      core: widget.core,
      onChanged: (settings) {
        setState(() => _settings = settings);
        _settingsChanges.value++;
      },
      // No Tab ring: every control has its key or its click. Traversal is
      // off below, and Tab itself is swallowed so it cannot walk focus out
      // of the surface to the route's scope, where the keys would die.
      child: LightScope(light: light, child: FocusTraversalGroup(descendantsAreTraversable: false, child: Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.slash): _Focus(),
        SingleActivator(LogicalKeyboardKey.space, includeRepeats: false): _Toggle(),
        SingleActivator(LogicalKeyboardKey.space, shift: true, includeRepeats: false): _PlaySomething(),
        SingleActivator(LogicalKeyboardKey.space, alt: true, includeRepeats: false): _FromStart(),
        SingleActivator(LogicalKeyboardKey.keyH): _History(),
        SingleActivator(LogicalKeyboardKey.keyT, includeRepeats: false): _Tree(),
        SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false): _CloseTree(),
        SingleActivator(LogicalKeyboardKey.bracketLeft): _Move(-1),
        SingleActivator(LogicalKeyboardKey.bracketRight): _Move(1),
        SingleActivator(LogicalKeyboardKey.bracketLeft, alt: true): _Sibling(-1),
        SingleActivator(LogicalKeyboardKey.bracketRight, alt: true): _Sibling(1),
        SingleActivator(LogicalKeyboardKey.backspace, meta: true, includeRepeats: false): _Prune(),
        SingleActivator(LogicalKeyboardKey.digit1, meta: true): _Front(),
        SingleActivator(LogicalKeyboardKey.keyL, meta: true): _Table(),
        SingleActivator(LogicalKeyboardKey.keyS, meta: true): _Keep(),
        SingleActivator(LogicalKeyboardKey.comma, meta: true): _Settings(),
        SingleActivator(LogicalKeyboardKey.tab): DoNothingAndStopPropagationIntent(),
        SingleActivator(LogicalKeyboardKey.tab, shift: true): DoNothingAndStopPropagationIntent(),
      },
      child: Actions(
        actions: {
          _Focus: CallbackAction<_Focus>(onInvoke: (_) => _queryFocus.requestFocus()),
          _Toggle: CallbackAction<_Toggle>(onInvoke: (_) { if (!_queryFocus.hasFocus) _toggle(); return null; }),
          _PlaySomething: CallbackAction<_PlaySomething>(onInvoke: (_) => _report(_playSomething())),
          _FromStart: CallbackAction<_FromStart>(onInvoke: (_) => _fromStart()),
          _History: CallbackAction<_History>(onInvoke: (_) => _history()),
          _Tree: CallbackAction<_Tree>(onInvoke: (_) => _toggleTree()),
          _CloseTree: CallbackAction<_CloseTree>(onInvoke: (_) => _closeTree()),
          _Move: CallbackAction<_Move>(onInvoke: (i) => _report(_move(i.by))),
          _Sibling: CallbackAction<_Sibling>(onInvoke: (i) => _report(_sibling(i.step))),
          _Prune: CallbackAction<_Prune>(onInvoke: (_) => _report(_pruneNewest())),
          _Front: CallbackAction<_Front>(onInvoke: (_) => _showFront()),
          _Table: CallbackAction<_Table>(onInvoke: (_) => _report(_start(const TargetDto.search(query: '')))),
          _Keep: CallbackAction<_Keep>(onInvoke: (_) => _report(_keep())),
          _Settings: CallbackAction<_Settings>(onInvoke: (_) => _openSettings()),
        },
        child: Focus(
          focusNode: _surfaceFocus,
          autofocus: true,
          child: ColoredBox(
            color: Tok.void_,
            child: LayoutBuilder(builder: (context, box) {
              _settingsContext = context;
              final wc = WidthClass.of(box.maxWidth);
              final front = FrontPane(
                key: const ValueKey('front'),
                core: widget.core,
                libraryVersion: _status?.libraryVersion,
                memoryVersion: _memoryVersion,
                jobs: _status?.jobs ?? const [],
                onQuery: (query) => _report(_start(TargetDto.search(query: query))),
                onRelease: (id) => _report(_start(TargetDto.release(id: id))),
                onTrail: (uid) => _report(_navigate(() => widget.core.openTrail(uid))),
              );
              final trail = _trail;
              final path = trail == null ? const <StopDto>[] : _path(trail);
              final stops = {for (final stop in trail?.stops ?? const <StopDto>[]) stop.index: stop};
              // The row holds the trail's path and its parked stops whatever
              // page lies over it, so nothing is thrown away by a page.
              final row = PaneRow(
                slide: _slide,
                maxVisible: wc.panes,
                minPane: box.maxWidth >= 1000 ? 440 : 300,
                wide: {for (var i = 0; i < path.length; i++) if (path[i].target is TargetDto_Search) i},
                parked: [for (final key in _parked) _pane(stops[key.index]!)],
                children: [for (final stop in path) _pane(stop)],
              );
              // Plate 01: the Front is a page of its own, never a pane beside a trail.
              final Widget? page = trail == null
                  ? front
                  : _treeOnly
                      ? TreePane(
                          key: const ValueKey('tree'),
                          trail: trail,
                          onGo: (stop) => _report(_navigate(() => widget.core.trailGo(stop))),
                          onPrune: (leaf) => _report(_prune(leaf)),
                          onKeep: () => _report(_keep()),
                          onPlay: (whole) => _report(_playTrail(whole)),
                        )
                      : _frontOnly
                          ? Column(key: const ValueKey('front-over-trail'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              Container(
                                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                                color: Tok.sky,
                                child: Text('Front · ⌘1 or ] back to ${trail.name ?? path.first.title}', style: Tok.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                              Expanded(child: front),
                            ])
                          : null;
              return Column(children: [
                QueryLine(core: widget.core, focus: _queryFocus, onSubmit: _submit, onSearch: _search),
                SizedBox(
                  height: wc == WidthClass.phone ? 44 : 64,
                  // Nothing until the first Now says which stage opens.
                  child: _stage == _Stage.undecided
                      ? null
                      : trail == null
                          ? NoTrailStrip(core: widget.core, memoryVersion: _memoryVersion, onResume: () => _report(_move(-1)))
                          : TrailStrip(
                              trail: trail,
                              onGo: (stop) => _report(_navigate(() => widget.core.trailGo(stop))),
                              onPlay: (whole) => _report(_playTrail(whole)),
                            ),
                ),
                if (_navigationError != null)
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Text(_navigationError!, style: Tok.label.copyWith(color: Tok.warn))),
                Expanded(
                  // Install after the initial Now snapshot, without a launch transition.
                  child: _stage == _Stage.undecided ? const SizedBox.expand() : AnimatedSwitcher(
                    duration: kMotion,
                    transitionBuilder: _fadeThrough,
                    layoutBuilder: _stacked,
                    child: _stage == _Stage.now
                    ? Row(key: const ValueKey('stage-now'), children: [
                        if (box.maxWidth >= 1000)
                          SizedBox(
                            width: (box.maxWidth * 0.4).clamp(0.0, 560.0),
                            child: Opacity(opacity: 0.8, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              Container(
                                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                                color: Tok.sky,
                                child: const Text('Front', style: Tok.label),
                              ),
                              Expanded(child: front),
                            ])),
                          ),
                        Expanded(child: NowStage(
                          core: widget.core, now: _now!, clock: _clock, onToggle: _toggle,
                          settingsChanges: _settingsChanges,
                          onRelease: (id) => _report(_start(TargetDto.release(id: id))), onLeave: _showFront,
                        )),
                      ])
                    : Row(key: const ValueKey('stage-trail'), children: [
                        Expanded(child: Stack(fit: StackFit.expand, children: [
                          ExcludeFocus(excluding: page != null, child: IgnorePointer(ignoring: page != null, child: row)),
                          AnimatedSwitcher(
                            duration: kMotion,
                            transitionBuilder: _fadeThrough,
                            layoutBuilder: _stacked,
                            child: page ?? const SizedBox.shrink(key: ValueKey('panes')),
                          ),
                        ])),
                        // Retain loaded details: async remounts clamp a restored scroll offset.
                        Visibility(
                          visible: wc.pinnedNow, maintainState: true, maintainAnimation: false, maintainSize: false,
                          child: SizedBox(width: wc.nowWidth ?? 360, child: NowPane(
                            core: widget.core, now: _now, clock: _clock, onToggle: _toggle, nothingToPlay: _nothingToPlay,
                            settingsChanges: _settingsChanges,
                            onRelease: (id) => _report(_start(TargetDto.release(id: id))),
                          )),
                        ),
                      ]),
                  ),
                ),
                if (_stage == _Stage.front && !wc.pinnedNow) NowBar(
                  core: widget.core, now: _now, clock: _clock, onToggle: _toggle, nothingToPlay: _nothingToPlay,
                  settingsChanges: _settingsChanges,
                  onRelease: (id) => _report(_start(TargetDto.release(id: id))),
                ),
                if (wc != WidthClass.phone)
                  StatusLine(core: widget.core, status: _status, keys: [
                    ('/', 'search'), ('[ ]', 'along the trail'),
                    if (trail != null) ('T', _treeOnly ? 'panes' : 'tree'),
                    ('␣', playing ? 'pause' : 'play'), ('⇧␣', 'play something'),
                    if (wc.index >= WidthClass.laptop.index) ...[('⌘1', 'Front'), ('⌘L', 'table')],
                  ]),
              ]);
            }),
          ),
        ),
      ),
    ))));
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

class _Keep extends Intent {
  const _Keep();
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

class _PlaySomething extends Intent {
  const _PlaySomething();
}

class _FromStart extends Intent {
  const _FromStart();
}

class _History extends Intent {
  const _History();
}

class _Move extends Intent {
  const _Move(this.by);
  final int by;
}

class _Sibling extends Intent {
  const _Sibling(this.step);
  final int step;
}

class _Prune extends Intent {
  const _Prune();
}

class _Tree extends Intent {
  const _Tree();
}

class _CloseTree extends Intent {
  const _CloseTree();
}
