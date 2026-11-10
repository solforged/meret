import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;

import '../core/bridge.dart';
import '../core/when.dart';
import '../panes/row_menu.dart';
import '../panes/track_row.dart';
import '../theme/tokens.dart';

/// Listening in the last seven local calendar days, oldest first, up to now.
List<int> listeningByDay(List<ListenDto> history, {DateTime? now}) {
  now ??= DateTime.now();
  final start = DateTime(now.year, now.month, now.day - 6);
  final startDate = DateTime.utc(start.year, start.month, start.day);
  final days = List<int>.filled(7, 0);
  for (final listen in history) {
    final at = DateTime.fromMillisecondsSinceEpoch(listen.startedAtMs.toInt());
    if (!at.isBefore(start) && at.isBefore(now)) {
      // Compare calendar dates, so a daylight-saving transition cannot shift a bin.
      final index = DateTime.utc(at.year, at.month, at.day).difference(startDate).inDays;
      days[index] += listen.playedMs.toInt();
    }
  }
  return days;
}

/// Today's week: what you listened to, played most and left alone. It
/// is independent of the collection's scan snapshot.
class TodayWeek extends StatefulWidget {
  const TodayWeek({super.key, required this.core, required this.memoryVersion, this.libraryVersion, this.onRelease, this.now});

  final CoreBridge core;
  final int memoryVersion;
  final BigInt? libraryVersion;
  final Future<void> Function(PlatformInt64)? onRelease;
  final DateTime Function()? now;

  @override
  State<TodayWeek> createState() => _TodayWeekState();
}

class _TodayWeekState extends State<TodayWeek> {
  List<ListenDto> _history = [];
  List<PlayedDto> _mostPlayed = [];
  List<DormantDto> _dormant = [];
  int _generation = 0;
  bool _loaded = false;
  String? _error;
  DateTime _windowEnd = DateTime.now();
  Timer? _midnight;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(TodayWeek old) {
    super.didUpdateWidget(old);
    if (old.core != widget.core || old.memoryVersion != widget.memoryVersion || old.libraryVersion != widget.libraryVersion) _load();
  }

  @override
  void dispose() {
    _midnight?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final now = widget.now?.call() ?? DateTime.now();
    final start = DateTime(now.year, now.month, now.day - 6);
    _midnight?.cancel();
    _midnight = Timer(DateTime(now.year, now.month, now.day + 1).difference(now), _load);
    try {
      final memory = await Future.wait<Object>([
        widget.core.listeningWindow(start.millisecondsSinceEpoch, now.millisecondsSinceEpoch),
        widget.core.dormant(3),
      ]);
      if (!mounted || generation != _generation) return;
      setState(() {
        final window = memory[0] as ListeningWindowDto;
        _history = window.listens;
        _mostPlayed = window.mostPlayed;
        _dormant = memory[1] as List<DormantDto>;
        _windowEnd = now;
        _loaded = true;
        _error = null;
      });
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error.toString());
    }
  }

  Future<void> _report(Future<void> call) async {
    try {
      await call;
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Widget _section(String title, List<Widget> rows, {String? meta}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        padding: const EdgeInsets.only(bottom: 6),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.rule))),
        child: Wrap(alignment: WrapAlignment.spaceBetween, spacing: 8, runSpacing: 3, children: [
          Text(title, style: Tok.heading),
          if (meta != null) Text(meta, style: Tok.label),
        ]),
      ),
      ...rows,
    ],
  );

  Widget _log(List<int> days, DateTime now) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final dates = List.generate(7, (i) => DateTime(now.year, now.month, now.day - 6 + i));
    String day(int i) => '${names[dates[i].weekday - 1]} ${dates[i].month}/${dates[i].day}';
    final total = days.fold<int>(0, (sum, day) => sum + day);
    final peak = days.fold<int>(1, (max, day) => day > max ? day : max);
    return _section('Last 7 days', [
      const SizedBox(height: 10),
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (var i = 0; i < days.length; i++)
          Expanded(child: Semantics(
            label: '${day(i)}${i == 6 ? ' · today' : ''}',
            value: listeningTime(days[i]),
            excludeSemantics: true,
            child: Tooltip(
              message: '${day(i)}${i == 6 ? ' · today' : ''} · ${listeningTime(days[i])}',
              child: Column(children: [
                SizedBox(height: 48, child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    key: ValueKey('today-log-${i + 1}'),
                    width: 18,
                    height: days[i] == 0 ? 1 : 48 * days[i] / peak,
                    color: i == 6 ? Tok.gold : Tok.gold2,
                  ),
                )),
                const SizedBox(height: 6),
                Text(names[dates[i].weekday - 1], style: Tok.label.copyWith(color: i == 6 ? Tok.gold : Tok.faint)),
              ]),
            ),
          )),
      ]),
    ], meta: '${dates.first.month}/${dates.first.day}–${now.month}/${now.day} · ${listeningTime(total)}');
  }

  Widget _played() => _section('Most played in the last 7 days', [
    for (final played in _mostPlayed)
      TodayDoor(
        key: ValueKey('today-most-played-${played.trackId}'),
        onTap: widget.onRelease == null ? null : () => _report(widget.onRelease!(played.releaseId)),
        actions: () => trackActions(context, widget.core, played.trackId,
          onOpen: widget.onRelease == null ? null : () => _report(widget.onRelease!(played.releaseId))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(played.title, style: Tok.body)),
            const SizedBox(width: 8),
            Text('${played.plays} ${played.plays == BigInt.one ? 'play' : 'plays'}', style: Tok.labelMuted),
          ]),
          Text(played.releaseTitle, style: Tok.label),
        ]),
      ),
  ]);

  Widget _dormantSection(DateTime now) => _section('Dormant', [
    for (final release in _dormant)
      TodayDoor(
        key: ValueKey('today-dormant-${release.releaseId}'),
        onTap: widget.onRelease == null ? null : () => _report(widget.onRelease!(release.releaseId)),
        actions: () => releaseActions(context, widget.core, release.releaseId,
          onOpen: widget.onRelease == null ? null : () => _report(widget.onRelease!(release.releaseId))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(release.title, style: Tok.body)),
            const SizedBox(width: 8),
            Text(agoShort(release.lastPlayedMs.toInt(), now: now), style: Tok.monoSmall),
          ]),
          const SizedBox(height: 3),
          Text('${release.plays} plays, then none since ${DateTime.fromMillisecondsSinceEpoch(release.lastPlayedMs.toInt()).year}', style: Tok.label),
        ]),
      ),
  ]);

  @override
  Widget build(BuildContext context) {
    final now = _windowEnd;
    final days = listeningByDay(_history, now: now);
    final sections = [
      if (_error != null) Text(_error!, style: Tok.label.copyWith(color: Tok.warn)),
      if (_loaded) ...[
        if (_history.isNotEmpty) _log(days, now),
        if (_mostPlayed.isNotEmpty) _played(),
        if (_dormant.isNotEmpty) _dormantSection(now),
      ] else if (_error == null)
        const Text('Reading the last 7 days…', style: Tok.label),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < sections.length; i++) ...[
        if (i > 0) const SizedBox(height: 18),
        sections[i],
      ],
    ]);
  }
}

/// A Today row is a quiet door until you point at it.
class TodayDoor extends StatefulWidget {
  const TodayDoor({super.key, required this.child, this.onTap, this.actions});
  final Widget child;
  final VoidCallback? onTap;

  /// The row's right-click menu, built when it opens.
  final List<RowAction?> Function()? actions;

  @override
  State<TodayDoor> createState() => _TodayDoorState();
}

class _TodayDoorState extends State<TodayDoor> {
  bool _hover = false;
  bool _pressed = false;

  Color get _fill {
    if (widget.onTap == null) return Tok.sky;
    if (_pressed) return Tok.line;
    return _hover ? Tok.panel2 : Tok.sky;
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: widget.actions == null ? _door() : RowMenu(actions: widget.actions!, child: _door()),
  );

  Widget _door() => Semantics(
      button: widget.onTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
          decoration: BoxDecoration(color: _fill, border: const Border(bottom: BorderSide(color: Tok.line))),
          child: widget.child,
        ),
      ),
  );
}
