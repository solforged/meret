import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bridge.dart';
import '../core/playhead.dart';
import '../home/home.dart';
import '../home/today.dart';
import '../home/trail_browser.dart';
import '../now/folder_error.dart';
import '../now/history_sheet.dart';
import '../now/lcd.dart';
import '../now/missing_sheet.dart';
import '../now/now_pane.dart';
import '../panes/game_pane.dart';
import '../panes/pane.dart';
import '../panes/person_pane.dart';
import '../panes/release_pane.dart';
import '../panes/search_pane.dart';
import '../panes/threads.dart';
import '../panes/tree_pane.dart';
import '../panes/work_pane.dart';
import '../settings/settings_window.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';
import 'activity.dart';
import 'keep_dialog.dart';
import 'keys_sheet.dart';
import 'outside.dart';
import 'pane_row.dart';
import 'query_line.dart';
import 'top_line.dart';
import 'trail_chip.dart';
import 'width_class.dart';
import 'window_chrome.dart';

/// The one surface: top line, Home, trail strip, panes, Now.
/// No tabs and no destinations: Home's entries are doors.
class Surface extends StatefulWidget {
  const Surface({super.key, required this.core});
  final CoreBridge core;

  @override
  State<Surface> createState() => _SurfaceState();
}

/// One pane per stop of the open trail; the key follows the stop off the
/// path and back, so its State does. A new tree fades in while the old one
/// fades out, so each tree has keys of its own.
class _StopKey extends GlobalKey<State<StatefulWidget>> {
  const _StopKey(this.tree, this.index, this.target) : super.constructor();
  final int tree;
  final int index;
  final TargetDto target;

  // A search stop keeps its pane as its filters rewrite the query.
  Object get _identity => target is TargetDto_Search ? #search : target;

  @override
  bool operator ==(Object other) => other is _StopKey && other.tree == tree && other.index == index && other._identity == _identity;

  @override
  int get hashCode => Object.hash(tree, index, _identity);
}

/// Pages fade through: the outgoing page is gone before the incoming one shows.
Widget _fadeThrough(Widget child, Animation<double> animation) =>
    FadeTransition(opacity: CurvedAnimation(parent: animation, curve: const Interval(0.5, 1)), child: child);

Widget _stacked(Widget? current, List<Widget> previous) => Stack(fit: StackFit.expand, children: [
  for (final child in previous) ExcludeFocus(child: child),
  ?current,
]);

class _SurfaceState extends State<Surface> with TickerProviderStateMixin {
  late final PlayheadClock _clock = PlayheadClock(this);
  final _queryFocus = FocusNode();
  final _surfaceFocus = FocusNode(debugLabel: 'surface');
  FocusNode? _homeReturnFocus;
  FocusNode? _treeReturnFocus;
  late final Outside _outside = Outside(widget.core);
  StreamSubscription<NowDto>? _nowSub;
  StreamSubscription<StatusDto>? _statusSub;
  NowDto? _now;
  StatusDto? _status;
  TrailDto? _trail;

  /// Stops that left the row, oldest first; their panes stay mounted off
  /// it so they return as they were.
  final _parked = <_StopKey>[];
  static const _parkedCap = 6;

  /// 1 or -1 while the latest move swapped branches, so the row brings the
  /// new one up from below or down from above.
  int _swap = 0;

  /// Counts trees; a new one gets a new row, which arrives whole instead of
  /// pane by pane.
  int _tree = 0;
  /// Today over the trail (or alone, with no trail open).
  bool _frontOnly = true;
  bool _treeOnly = false;

  /// Bumped when `[` has nowhere to go (the first stop of a trail); the chip flashes.
  final _chipCue = ValueNotifier<int>(0);

  /// The Home column laid over the trail (plate 06 C); the panes dim and never move.
  bool _homeOver = false;
  final _doors = HomeDoors();
  /// Each tree's thread ends; the old tree keeps its own while it fades out.
  var _anchors = ThreadAnchors();

  /// Nothing draws until the first Now, so the opening never flickers.
  bool _decided = false;
  bool _phone = false;
  int _navigationVersion = 0;
  int _memoryVersion = 0;
  String? _navigationError;
  late SettingsDto _settings;
  final _settingsChanges = ValueNotifier(0);
  /// Bumped when the app leaves a search for a page the query line's draft isn't about.
  final _queryReset = ValueNotifier(0);
  BuildContext? _settingsContext;

  /// Why Play something has nothing to play (null while it has); read again
  /// when the library, the loaded item or the listening moves.
  NothingToPlayDto? _nothingToPlay;
  (BigInt?, int)? _nothingFor;

  /// A play or pick up that failed on a file: the core names it, Folders answers it.
  String? _fileError;

  /// `N` or the LCD: the Now panel shown or hidden; null keeps the width
  /// class's default (pinned from 1800 pt). [_nowShown] is the last build's answer.
  bool? _nowPanel;
  bool _nowShown = false;
  bool _nowOverlay = false;

  @override
  void initState() {
    super.initState();
    _settings = widget.core.settings();
    _queryFocus.addListener(_queryFocusChanged);
    FocusManager.instance.addListener(_focusManagerChanged);
    WindowChrome.instance.onSettings = _openSettings;
    WindowChrome.instance.onMenu = _menu;
    _nowSub = widget.core.now().listen((n) {
      if (!mounted) return;
      _clock.anchor(n.anchor);
      _outside.now(n);
      setState(() {
        if (_now?.anchor?.item != n.anchor?.item) _memoryVersion++;
        if (n.anchor != null) _fileError = null;
        _now = n;
        _decided = true;
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
    _queryFocus.removeListener(_queryFocusChanged);
    FocusManager.instance.removeListener(_focusManagerChanged);
    _queryFocus.dispose();
    _surfaceFocus.dispose();
    _settingsChanges.dispose();
    _queryReset.dispose();
    _doors.dispose();
    _chipCue.dispose();
    _anchors.dispose();
    WindowChrome.instance.onSettings = null;
    WindowChrome.instance.onMenu = null;
    _outside.dispose();
    super.dispose();
  }

  /// When the query line lets focus go and nothing else takes it, the
  /// surface does, so `[` `]` `h` and Space work without a click first.
  void _queryFocusChanged() {
    if (!_queryFocus.hasFocus) _reclaimFocus();
  }

  /// A control let go of the keyboard focus (a click outside the LCD): nothing
  /// holds it but a scope, so the surface takes it for its keys.
  void _focusManagerChanged() {
    if (FocusManager.instance.primaryFocus is! FocusScopeNode) return;
    _reclaimFocusAfterFrame();
    WidgetsBinding.instance.ensureVisualUpdate();
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

  void _restoreFocusAfterFrame(FocusNode? focus) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      if (focus?.context != null && focus!.canRequestFocus) {
        focus.requestFocus();
      } else {
        _reclaimFocus();
      }
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

  /// Space activates a focused control; on the surface it controls playback.
  void _space() {
    if (_queryFocus.hasFocus) return;
    final context = FocusManager.instance.primaryFocus?.context;
    const intent = ActivateIntent();
    final action = context == null ? null : Actions.maybeFind<ActivateIntent>(context);
    if (action != null && action.isEnabled(intent)) {
      Actions.invoke(context!, intent);
    } else {
      _toggle();
    }
  }

  Future<void> _playSomething() async {
    if (_queryFocus.hasFocus) return;
    setState(() => _fileError = null);
    try {
      final pick = await widget.core.playSomething();
      if (pick == null) await _readNothingToPlay();
    } catch (error) {
      if (mounted) setState(() => _fileError = error.toString());
    }
  }

  Future<void> _readNothingToPlay() async {
    final why = await widget.core.nothingToPlay();
    if (!mounted) return;
    _doors.nothingToPlay = why;
    setState(() => _nothingToPlay = why);
  }

  /// The Pick up door: the latest partway release that isn't loaded, from
  /// where it stopped; Today lists the rest.
  Future<void> _pickUpLatest() async {
    setState(() => _fileError = null);
    try {
      final points = await widget.core.resumePoints(99);
      final point = points.where((point) => point.releaseId != _now?.releaseId).firstOrNull ?? points.firstOrNull;
      if (point != null) await widget.core.pickUp(point.releaseId);
    } catch (error) {
      if (mounted) setState(() => _fileError = error.toString());
    }
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

  /// A sheet over the surface; the Controls and Help menu items it keeps stay on
  /// while it's open (`WindowChrome.menuState`), the rest wait for it to close.
  Future<void> _sheet(Set<String> keeps, Future<void> Function() show) {
    WindowChrome.instance.sheetKeeps = keeps;
    return show().whenComplete(() => WindowChrome.instance.sheetKeeps = const {});
  }

  void _history() {
    final context = _settingsContext;
    if (!_queryFocus.hasFocus && context != null) {
      _sheet({'toggle'}, () => showHistorySheet(context, widget.core, (id) => _report(_start(TargetDto.release(id: id))), onToggle: _toggle));
    }
  }

  bool _keysOpen = false;

  /// `?` or Help ▸ Keys: every key on one page; again, it closes.
  void _keys() {
    final context = _settingsContext;
    if (_keysOpen) {
      if (context != null) Navigator.of(context).pop();
    } else if (!_queryFocus.hasFocus && context != null) {
      _keysOpen = true;
      _sheet({'keys'}, () => showKeysSheet(context)).whenComplete(() => _keysOpen = false);
    }
  }

  /// Same tree, or a different one from the history?
  static bool _sameTrail(TrailDto a, TrailDto b) => a.uid == b.uid;

  /// Install [trail]; stops that just left the row join the parked set,
  /// newest last, capped at [_parkedCap]. Another trail empties it.
  void _setTrail(TrailDto trail) {
    final old = _trail;
    _trail = trail;
    _swap = 0;
    if (old == null || !_sameTrail(old, trail)) {
      _parked.clear();
      _tree++;
      _anchors = ThreadAnchors();
      return;
    }
    final onRow = {for (final stop in _row(trail)) stop.index};
    final targets = {for (final stop in trail.stops) stop.index: stop.target};
    for (final stop in _row(old)) {
      if (onRow.contains(stop.index)) continue;
      final key = _StopKey(_tree, stop.index, stop.target);
      _parked..remove(key)..add(key);
    }
    _parked.removeWhere((key) {
      final target = targets[key.index];
      return onRow.contains(key.index) || target == null || _StopKey(_tree, key.index, target) != key;
    });
    if (_parked.length > _parkedCap) _parked.removeRange(0, _parked.length - _parkedCap);
  }

  /// The search stop's filters changed: the trail's search takes them, in
  /// place, so the pane stays and the heading and trail name follow.
  Future<void> _refine(String query) async {
    final trail = await widget.core.refineSearch(query);
    if (!mounted) return;
    setState(() => _trail = trail);
  }

  /// Panes move themselves: the row animates whatever changed in it. False
  /// when the core had nowhere to go.
  Future<bool> _navigate(Future<TrailDto?> Function() call, {int swap = 0, bool closeTree = true}) async {
    final version = ++_navigationVersion;
    final trail = await call();
    if (!mounted || version != _navigationVersion) return true;
    setState(() {
      _navigationError = null;
      _homeOver = false;
      if (_nowOverlay) _nowPanel = false;
      if (closeTree) _treeOnly = false;
      if (trail != null) {
        _memoryVersion++;
        _setTrail(trail);
        _swap = swap;
        _frontOnly = false;
      }
    });
    _reclaimFocusAfterFrame();
    return trail != null;
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
    await _navigate(() => widget.core.trailSibling(step), swap: step);
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

  /// `[` and `]` move along the open trail, one stop. They never leave it:
  /// at the first stop `[` only flashes the chip. Over Today, Home, the tree
  /// or the narrow Now panel they just take that away, as Esc does.
  Future<void> _move(int by) async {
    if (_editing || _dismiss()) return;
    if (by > 0) {
      await _navigate(widget.core.trailForward);
    } else if (!await _navigate(widget.core.trailBack) && _trail != null && mounted) {
      _chipCue.value++;
    }
  }

  /// The Go, Controls and Help menus run what their keys run.
  void _menu(String id) {
    if (!mounted) return;
    switch (id) {
      case 'home': _showHome();
      case 'table': _report(_start(const TargetDto.search(query: '')));
      case 'search': _queryFocus.requestFocus();
      case 'back': _report(_move(-1));
      case 'forward': _report(_move(1));
      case 'previousBranch': _report(_sibling(-1));
      case 'nextBranch': _report(_sibling(1));
      case 'tree': _toggleTree();
      case 'keep': _report(_keep());
      case 'prune': _report(_pruneNewest());
      case 'toggle': _toggle();
      case 'playSomething': _report(_playSomething());
      case 'fromStart': _fromStart();
      case 'playBranch': _report(_playTrail(false));
      case 'playTree': _report(_playTrail(true));
      case 'now': _toggleNow();
      case 'history': _history();
      case 'keys': _keys();
    }
  }

  /// `N`: the Now panel beside the panes.
  void _toggleNow() {
    setState(() => _nowPanel = !_nowShown);
    _reclaimFocusAfterFrame();
  }

  /// `⌘1`: inside a trail, the Home column over it; again, Today. The
  /// trail stays open under both, and `]` returns to it.
  void _showHome() {
    if (_nowOverlay) setState(() => _nowPanel = false);
    if (_trail != null && !_frontOnly && !_treeOnly && !_homeOver && !_phone) {
      _openHome();
      return;
    }
    _showToday();
  }

  void _openHome() {
    _homeReturnFocus = FocusManager.instance.primaryFocus;
    setState(() => _homeOver = true);
    _reclaimFocusAfterFrame();
  }

  void _showToday() {
    _navigationVersion++;
    _queryReset.value++;
    setState(() {
      _frontOnly = true;
      _treeOnly = false;
      _homeOver = false;
      _navigationError = null;
    });
    _reclaimFocusAfterFrame();
  }

  /// Escape, `]` or a click on the dimmed panes.
  void _closeHome() {
    if (!_homeOver) return;
    setState(() => _homeOver = false);
    _restoreFocusAfterFrame(_homeReturnFocus);
    _homeReturnFocus = null;
  }

  Future<void> _allTrails({bool kept = false}) async {
    final context = _settingsContext;
    if (context == null) return;
    final uid = await showTrailBrowser(context, widget.core, kept: kept);
    if (mounted && uid != null) await _navigate(() => widget.core.openTrail(uid));
  }

  /// A Home door: Today, a play, or a new tree, as a search starts one.
  void _door(HomeDoor door) {
    switch (door.kind) {
      case DoorKind.today: _showToday();
      case DoorKind.pickUp: _report(_pickUpLatest());
      case DoorKind.history: _history();
      case DoorKind.playSomething: _report(_playSomething());
      case DoorKind.query: _report(_start(TargetDto.search(query: door.query!)));
      case DoorKind.trail: _report(_navigate(() => widget.core.openTrail(door.uid!)));
      case DoorKind.allTrails: _report(_allTrails());
      case DoorKind.keptTrails: _report(_allTrails(kept: true));
      case DoorKind.missing: showMissingFiles(context, widget.core, onCheckFolders: _openSettings);
      case DoorKind.later: break;
    }
  }

  /// `⌘2`–`⌘9`; `⌘1` is [_showHome].
  void _numbered(int n) {
    final doors = _doors.numbered;
    if (n <= doors.length) _door(doors[n - 1]);
  }

  /// The page over the row fades out; the row is where it was, so nothing slides.
  void _showTrail() {
    _navigationVersion++;
    setState(() {
      _frontOnly = false;
      _treeOnly = false;
      _homeOver = false;
      _navigationError = null;
    });
  }

  void _toggleTree() {
    if (_editing || _trail == null) return;
    final closing = _treeOnly;
    if (!closing) _treeReturnFocus = FocusManager.instance.primaryFocus;
    _navigationVersion++;
    setState(() {
      _frontOnly = false;
      _homeOver = false;
      if (_nowOverlay) _nowPanel = false;
      _treeOnly = !_treeOnly;
      _navigationError = null;
    });
    if (closing) {
      _restoreFocusAfterFrame(_treeReturnFocus);
      _treeReturnFocus = null;
    } else {
      _reclaimFocusAfterFrame();
    }
  }

  /// Something lies over the trail: the narrow Now overlay, Home, the tree,
  /// or Today above an open trail.
  bool get _overlaid => _nowOverlay || _homeOver || _treeOnly || (_frontOnly && _trail != null);

  /// Takes away whatever is laid over the trail and says whether it did.
  /// Esc, `[` and `]` all start here, so none of them also steps.
  bool _dismiss() {
    if (_editing) return false;
    if (_nowOverlay) {
      _toggleNow();
    } else if (_homeOver) {
      _closeHome();
    } else if (_treeOnly) {
      setState(() => _treeOnly = false);
      _restoreFocusAfterFrame(_treeReturnFocus);
      _treeReturnFocus = null;
    } else if (_frontOnly && _trail != null) {
      _showTrail();
    } else {
      return false;
    }
    return true;
  }

  Future<void> _start(TargetDto to) {
    _queryReset.value++;
    return _navigate(() => widget.core.startTrail(to));
  }

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
      _setTrail(trail);
      _frontOnly = false;
      _treeOnly = false;
      _homeOver = false;
      _navigationError = null;
    });
    if (hit != null) {
      trail = await widget.core.follow(trail.current, _hitTarget(hit), ThreadKind.matched, 'library');
      if (!mounted || version != _navigationVersion) return;
      setState(() => _setTrail(trail));
    }
    _reclaimFocusAfterFrame();
  }

  Future<void> _follow(int from, TargetDto to, ThreadKind via, String provider) =>
      _navigate(() => widget.core.follow(from, to, via, provider));

  Widget _pane(StopDto stop, {bool ahead = false, Set<int> aheadStops = const {}}) {
    final scanning = _status?.jobs.any((job) => job.isScan) ?? false;
    Future<void> follow(TargetDto to, ThreadKind via, String provider) => _follow(stop.index, to, via, provider);
    final body = switch (stop.target) {
      TargetDto_Search(:final query) => SearchPane(
        core: widget.core,
        query: query,
        libraryVersion: _status?.libraryVersion,
        tracks: _status?.tracks,
        scanning: scanning,
        onQuery: (query) => _report(_refine(query)),
        onFollow: (to) => follow(to, ThreadKind.matched, 'library'),
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
      key: _StopKey(_tree, stop.index, stop.target),
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
      current: stop.index == _trail!.current,
      fork: ForkControl.has(_trail!, stop) ? ForkControl(
        trail: _trail!, stop: stop,
        onGo: (leaf) => _report(_navigate(() => widget.core.trailGo(leaf))),
        onPrune: (leaf) => _report(_prune(leaf)),
      ) : null,
      anchors: _anchors,
      stop: stop.index,
      body: TrailPaneScope(
        trail: _trail!, stop: stop, ahead: aheadStops, anchors: _anchors, core: widget.core,
        onGo: (leaf) => _report(_navigate(() => widget.core.trailGo(leaf))),
        onPrune: (leaf) => _report(_prune(leaf)),
        child: body,
      ),
      showTitle: stop.target is! TargetDto_Release && stop.target is! TargetDto_Work && stop.target is! TargetDto_Game,
      compact: stop.target is TargetDto_Search,
      onSpineTap: () => _report(_navigate(() => widget.core.trailGo(stop.index))),
      ahead: ahead,
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
      onChanged: (settings) {
        setState(() => _settings = settings);
        _settingsChanges.value++;
      },
      child: LightScope(light: light, child: FocusTraversalGroup(
      // Tab runs top line, Home, the page, then Now, however their rects sit.
      policy: OrderedTraversalPolicy(),
      child: Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.slash): _Focus(),
        SingleActivator(LogicalKeyboardKey.space, includeRepeats: false): _Toggle(),
        SingleActivator(LogicalKeyboardKey.space, shift: true, includeRepeats: false): _PlaySomething(),
        SingleActivator(LogicalKeyboardKey.space, alt: true, includeRepeats: false): _FromStart(),
        SingleActivator(LogicalKeyboardKey.keyH): _History(),
        CharacterActivator('?'): _Keys(),
        SingleActivator(LogicalKeyboardKey.keyN, includeRepeats: false): _NowPanel(),
        SingleActivator(LogicalKeyboardKey.keyT, includeRepeats: false): _Tree(),
        SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false): _CloseTree(),
        SingleActivator(LogicalKeyboardKey.bracketLeft): _Move(-1),
        SingleActivator(LogicalKeyboardKey.bracketRight): _Move(1),
        SingleActivator(LogicalKeyboardKey.bracketLeft, alt: true): _Sibling(-1),
        SingleActivator(LogicalKeyboardKey.bracketRight, alt: true): _Sibling(1),
        SingleActivator(LogicalKeyboardKey.backspace, meta: true, includeRepeats: false): _Prune(),
        SingleActivator(LogicalKeyboardKey.digit1, meta: true): _Home(),
        SingleActivator(LogicalKeyboardKey.digit2, meta: true): _Door(2),
        SingleActivator(LogicalKeyboardKey.digit3, meta: true): _Door(3),
        SingleActivator(LogicalKeyboardKey.digit4, meta: true): _Door(4),
        SingleActivator(LogicalKeyboardKey.digit5, meta: true): _Door(5),
        SingleActivator(LogicalKeyboardKey.digit6, meta: true): _Door(6),
        SingleActivator(LogicalKeyboardKey.digit7, meta: true): _Door(7),
        SingleActivator(LogicalKeyboardKey.digit8, meta: true): _Door(8),
        SingleActivator(LogicalKeyboardKey.digit9, meta: true): _Door(9),
        SingleActivator(LogicalKeyboardKey.keyL, meta: true): _Table(),
        SingleActivator(LogicalKeyboardKey.keyS, meta: true): _Keep(),
        SingleActivator(LogicalKeyboardKey.comma, meta: true): _Settings(),
      },
      child: Actions(
        actions: {
          _Focus: CallbackAction<_Focus>(onInvoke: (_) => _queryFocus.requestFocus()),
          _Toggle: CallbackAction<_Toggle>(onInvoke: (_) { _space(); return null; }),
          _PlaySomething: CallbackAction<_PlaySomething>(onInvoke: (_) => _report(_playSomething())),
          _FromStart: CallbackAction<_FromStart>(onInvoke: (_) => _fromStart()),
          _History: CallbackAction<_History>(onInvoke: (_) => _history()),
          _Keys: CallbackAction<_Keys>(onInvoke: (_) => _keys()),
          _NowPanel: CallbackAction<_NowPanel>(onInvoke: (_) => _toggleNow()),
          _Tree: CallbackAction<_Tree>(onInvoke: (_) => _toggleTree()),
          _CloseTree: CallbackAction<_CloseTree>(onInvoke: (_) => _dismiss()),
          _Move: CallbackAction<_Move>(onInvoke: (i) => _report(_move(i.by))),
          _Sibling: CallbackAction<_Sibling>(onInvoke: (i) => _report(_sibling(i.step))),
          _Prune: CallbackAction<_Prune>(onInvoke: (_) => _report(_pruneNewest())),
          _Home: CallbackAction<_Home>(onInvoke: (_) => _showHome()),
          _Door: CallbackAction<_Door>(onInvoke: (i) => _numbered(i.n)),
          _Table: CallbackAction<_Table>(onInvoke: (_) => _report(_start(const TargetDto.search(query: '')))),
          _Keep: CallbackAction<_Keep>(onInvoke: (_) => _report(_keep())),
          _Settings: CallbackAction<_Settings>(onInvoke: (_) => _openSettings()),
        },
        child: Focus(
          focusNode: _surfaceFocus,
          autofocus: true,
          skipTraversal: true,
          child: ColoredBox(
            color: Tok.void_,
            child: LayoutBuilder(builder: (context, box) {
              _settingsContext = context;
              final wc = WidthClass.of(box.maxWidth);
              final trail = _trail;
              final path = trail == null ? const <StopDto>[] : _path(trail);
              final along = trail == null ? const <StopDto>[] : _row(trail);
              final stops = {for (final stop in trail?.stops ?? const <StopDto>[]) stop.index: stop};
              final aheadStops = {for (final stop in along.skip(path.length)) stop.index};
              final hasMusic = (_status?.tracks ?? BigInt.zero) > BigInt.zero;
              WindowChrome.instance.setMenuAvailability({
                'home': true, 'table': true, 'search': true,
                'back': trail != null && (_overlaid || path.length > 1),
                'forward': trail != null && (_overlaid || along.length > path.length),
                'previousBranch': path.any((stop) => stop.isFork),
                'nextBranch': path.any((stop) => stop.isFork),
                'tree': trail != null, 'keep': trail != null,
                'prune': trail?.branches.any((branch) => !branch.current && branch.prunable) ?? false,
                'toggle': _now?.anchor != null || hasMusic,
                'playSomething': hasMusic && _nothingToPlay == null,
                'fromStart': _now?.anchor != null,
                'playBranch': trail != null && hasMusic,
                'playTree': trail != null && hasMusic,
                'now': true, 'history': true, 'keys': true,
              });
              // The row holds the trail's path, the stops ahead and the parked
              // stops whatever page lies over it, so nothing is thrown away by a page.
              // A new tree, or the previous one, fades through like a page: the
              // old row is gone before the new one shows, and nothing slides.
              final row = AnimatedSwitcher(
                duration: kMotion,
                transitionBuilder: _fadeThrough,
                layoutBuilder: _stacked,
                child: ThreadLines(key: ValueKey(('row', _tree)), anchors: _anchors, stops: [for (final stop in along) stop.index], child: PaneRow(
                focus: path.length - 1,
                swap: _swap,
                maxVisible: wc.panes,
                minPane: box.maxWidth >= 1000 ? 440 : 300,
                wide: {for (var i = 0; i < along.length; i++) if (along[i].target is TargetDto_Search) i},
                ghost: const PaneGhost(),
                parked: [for (final key in _parked) _pane(stops[key.index]!, aheadStops: aheadStops)],
                children: [for (var i = 0; i < along.length; i++) _pane(along[i], ahead: i >= path.length, aheadStops: aheadStops)],
              )));
              final phone = wc == WidthClass.phone;
              _phone = phone;
              _doors.load(widget.core, libraryVersion: _status?.libraryVersion, memoryVersion: _memoryVersion);
              if ((_nothingFor ?? (null, -1)) != (_status?.libraryVersion, _memoryVersion)) {
                _nothingFor = (_status?.libraryVersion, _memoryVersion);
                _readNothingToPlay();
              }
              final today = Today(
                key: const ValueKey('today'),
                core: widget.core,
                memoryVersion: _memoryVersion,
                libraryVersion: _status?.libraryVersion,
                jobs: _status?.jobs ?? const [],
                now: _now, clock: _clock, onToggle: _toggle,
                onRelease: (id) => _report(_start(TargetDto.release(id: id))),
                // The chip waits under Today, so the back line carries a kept trail's mark.
                trailName: trail == null ? null : '${trail.kept ? '◆ ' : ''}${trail.name ?? path.first.title}',
              );
              // Plate 01: Today is Home's own page, never a pane beside a trail.
              final showToday = trail == null || (_frontOnly && !_treeOnly);
              final Widget? page = showToday
                  ? today
                  : _treeOnly
                      ? TreePane(
                          key: const ValueKey('tree'),
                          trail: trail,
                          onGo: (stop) => _report(_navigate(() => widget.core.trailGo(stop))),
                          onPrune: (leaf) => _report(_prune(leaf)),
                          onKeep: () => _report(_keep()),
                          onClose: _dismiss,
                          onPlay: (whole) => _report(_playTrail(whole)),
                        )
                      : null;
              _nowShown = !phone && (_nowPanel ?? wc.pinnedNow);
              _nowOverlay = _nowShown && wc == WidthClass.foldable;
              final nowWidth = wc.nowWidth ?? WidthClass.panel;
              // Plate 06: the column beside Today, the rail inside a trail, and
              // the column over the rail on ⌘1. The panes never move for Home.
              // Narrow windows keep the rail beside Today too, so the page keeps its room.
              final railOnly = !phone && box.maxWidth < Home.railBelow;
              final homeWidth = phone ? 0.0 : showToday && !railOnly ? Home.column : Home.rail;
              final homeOpen = (showToday && !railOnly) || _homeOver;
              final covered = page != null || _homeOver;
              return Column(children: [
                FocusTraversalOrder(order: const NumericFocusOrder(0), child: TopLine(
                  query: QueryLine(core: widget.core, focus: _queryFocus, onSubmit: _submit, onSearch: _search, clearOn: _queryReset),
                  queryFocus: _queryFocus,
                  // An open Now panel keeps the LCD, so the mouse can close it again.
                  showLcd: _now?.anchor != null || _nowShown,
                  lcd: ({folded = false}) => Lcd(
                    core: widget.core, now: _now, clock: _clock, onToggle: _toggle, nothingToPlay: _nothingToPlay,
                    open: _nowShown, onOpen: phone ? null : _toggleNow, folded: folded,
                  ),
                  activity: ({quiet = false}) => Activity(core: widget.core, status: _status, quiet: quiet),
                  onBack: trail == null || !(_overlaid || path.length > 1) ? null : () => _report(_move(-1)),
                  onForward: trail == null || !(_overlaid || along.length > path.length) ? null : () => _report(_move(1)),
                  // Under Home or Today the "] back to" line names the trail, so the chip waits.
                  chip: trail == null || !_decided || (!phone && (_homeOver || showToday)) ? null : ({compact = false, star = false}) => TrailChip(trail: trail, onTree: _toggleTree, compact: compact, star: star, cue: _chipCue),
                )),
                Expanded(child: Stack(fit: StackFit.expand, children: [
                  Positioned.fill(
                    right: _nowShown && !_nowOverlay ? nowWidth : 0,
                    child: ExcludeFocus(excluding: _nowOverlay,
                      child: ExcludeSemantics(excluding: _nowOverlay,
                        child: IgnorePointer(ignoring: _nowOverlay,
                          child: Stack(fit: StackFit.expand, children: [
                    FocusTraversalOrder(order: const NumericFocusOrder(2), child: FocusTraversalGroup(child: Padding(padding: EdgeInsets.only(left: homeWidth), child: Column(children: [
                      if (_navigationError != null)
                        Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Text(_navigationError!, style: Tok.label.copyWith(color: Tok.warn))),
                      if (_fileError != null)
                        Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: FolderError(message: _fileError!, actionKey: const ValueKey('surface-check-folders'), padding: const EdgeInsets.symmetric(vertical: 4))),
                      Expanded(child: !_decided ? const SizedBox.expand() : Stack(fit: StackFit.expand, clipBehavior: Clip.none, children: [
                        // The row keeps the rail's inset under any page, so Today
                        // beside the column never makes it reflow.
                        Positioned(top: 0, bottom: 0, right: 0, left: phone ? 0 : Home.rail - homeWidth, child: ExcludeFocus(
                          excluding: covered,
                          child: IgnorePointer(ignoring: covered, child: AnimatedOpacity(
                            opacity: _homeOver && page == null ? 0.35 : 1, duration: kMotion, child: row,
                          )),
                        )),
                        AnimatedSwitcher(
                          duration: kMotion,
                          transitionBuilder: _fadeThrough,
                          layoutBuilder: _stacked,
                          child: page ?? const SizedBox.shrink(key: ValueKey('panes')),
                        ),
                      ])),
                    ])))),
                    // A click on the dimmed panes closes the column over them.
                    if (_homeOver && (page == null || showToday))
                      Positioned.fill(left: Home.rail, child: GestureDetector(key: const ValueKey('home-scrim'), behavior: HitTestBehavior.opaque, onTap: _closeHome)),
                    if (!phone && _decided)
                      Positioned(left: 0, top: 0, bottom: 0, child: FocusTraversalOrder(order: const NumericFocusOrder(1), child: FocusTraversalGroup(child: AnimatedContainer(
                        duration: kMotion,
                        curve: Curves.easeOut,
                        width: homeOpen ? Home.column : Home.rail,
                        child: Home(
                          doors: _doors, open: homeOpen, onDoor: _door,
                          onOpen: _openHome,
                          litQuery: showToday ? null : trail.rootQuery,
                          currentTrail: showToday ? null : trail.uid,
                          todayLit: showToday,
                        ),
                      )))),
                  ]))))),
                  if (_nowOverlay)
                    Positioned.fill(child: GestureDetector(
                      key: const ValueKey('now-scrim'),
                      behavior: HitTestBehavior.opaque,
                      onTap: _toggleNow,
                      child: const ColoredBox(color: Colors.black54),
                    )),
                  // Retain loaded details: async remounts clamp a restored scroll offset.
                  Positioned(key: const ValueKey('now-panel-position'), top: 0, bottom: 0, right: 0, child: Visibility(
                    visible: _nowShown, maintainState: true, maintainAnimation: false, maintainSize: false,
                    child: SizedBox(width: nowWidth, child: FocusTraversalOrder(order: const NumericFocusOrder(3), child: FocusTraversalGroup(child: NowPane(
                      core: widget.core, now: _now, clock: _clock, onToggle: _toggle, nothingToPlay: _nothingToPlay,
                      settingsChanges: _settingsChanges,
                      onRelease: (id) => _report(_start(TargetDto.release(id: id))),
                    )))),
                  )),
                ])),
                // Phones keep a player bar under the thumb; desktops have the LCD.
                if (phone) FocusTraversalOrder(order: const NumericFocusOrder(3), child: FocusTraversalGroup(child: NowBar(
                  core: widget.core, now: _now, clock: _clock, onToggle: _toggle, nothingToPlay: _nothingToPlay,
                  settingsChanges: _settingsChanges,
                  onRelease: (id) => _report(_start(TargetDto.release(id: id))),
                ))),
              ]);
            }),
          ),
        ),
      ),
    ))));
  }
}

/// The path plus the stops ahead: from the current stop, the chain of most
/// recently entered children that `]` would walk (Trail::forward).
List<StopDto> _row(TrailDto trail) {
  final path = _path(trail);
  final children = <int, List<StopDto>>{};
  for (final stop in trail.stops) {
    if (stop.parent case final parent? when !stop.isPeek) (children[parent] ??= []).add(stop);
  }
  final row = [...path];
  var at = trail.current;
  while (true) {
    final next = children[at];
    if (next == null || next.isEmpty) break;
    final newest = next.reduce((a, b) => b.openedMs.toInt() >= a.openedMs.toInt() ? b : a);
    row.add(newest);
    at = newest.index;
  }
  return row;
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

class _NowPanel extends Intent {
  const _NowPanel();
}

class _Keep extends Intent {
  const _Keep();
}

class _Settings extends Intent {
  const _Settings();
}

class _Home extends Intent {
  const _Home();
}

class _Door extends Intent {
  const _Door(this.n);
  final int n;
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

class _Keys extends Intent {
  const _Keys();
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
