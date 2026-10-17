import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;

import '../core/bridge.dart';
import '../core/when.dart';
import '../theme/tokens.dart';

/// Listening in the last seven local calendar days, in Monday–Sunday order.
List<int> listeningByWeekday(List<ListenDto> history, {DateTime? now}) {
  now ??= DateTime.now();
  final start = DateTime(now.year, now.month, now.day - 6);
  final end = DateTime(now.year, now.month, now.day + 1);
  final days = List<int>.filled(7, 0);
  for (final listen in history) {
    final at = DateTime.fromMillisecondsSinceEpoch(listen.startedAtMs.toInt());
    if (!at.isBefore(start) && at.isBefore(end)) days[at.weekday - 1] += listen.playedMs.toInt();
  }
  return days;
}

/// The Front's memory is independent of the collection's scan snapshot.
class FrontMemory extends StatefulWidget {
  const FrontMemory({super.key, required this.core, required this.memoryVersion, this.libraryVersion, this.onTrail, this.onRelease});

  final CoreBridge core;
  final int memoryVersion;
  final BigInt? libraryVersion;
  final Future<void> Function(String)? onTrail;
  final Future<void> Function(PlatformInt64)? onRelease;

  @override
  State<FrontMemory> createState() => _FrontMemoryState();
}

class _FrontMemoryState extends State<FrontMemory> {
  List<TrailSummaryDto> _trails = [];
  List<ResumeDto> _resumes = [];
  List<ListenDto> _history = [];
  List<PlayedDto> _mostPlayed = [];
  List<DormantDto> _dormant = [];
  int _generation = 0;
  bool _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FrontMemory old) {
    super.didUpdateWidget(old);
    if (old.core != widget.core || old.memoryVersion != widget.memoryVersion || old.libraryVersion != widget.libraryVersion) _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final memory = await Future.wait<Object>([
        widget.core.trailHistory(20),
        widget.core.resumePoints(4),
        widget.core.history(500),
        widget.core.mostPlayed(7, 3),
        widget.core.dormant(3),
      ]);
      if (!mounted || generation != _generation) return;
      setState(() {
        _trails = memory[0] as List<TrailSummaryDto>;
        _resumes = memory[1] as List<ResumeDto>;
        _history = memory[2] as List<ListenDto>;
        _mostPlayed = memory[3] as List<PlayedDto>;
        _dormant = memory[4] as List<DormantDto>;
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
          Text(title, style: Tok.label),
          if (meta != null) Text(meta, style: Tok.label.copyWith(color: Tok.faint)),
        ]),
      ),
      ...rows,
    ],
  );

  Widget _trailSection(DateTime now) {
    final kept = _trails.where((trail) => trail.kept).toList();
    final rows = kept.isNotEmpty ? kept : _trails.take(4);
    return _section(kept.isEmpty && _trails.isNotEmpty ? 'Trails' : 'Kept trails', [
      for (final trail in rows)
        FrontDoor(
          key: ValueKey('front-trail-${trail.uid}'),
          onTap: widget.onTrail == null ? null : () => _report(widget.onTrail!(trail.uid)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(trail.name ?? trail.title, style: Tok.body)),
              const SizedBox(width: 8),
              Text('${trail.stops} ${trail.stops == 1 ? 'stop' : 'stops'}', style: Tok.monoSmall),
            ]),
            const SizedBox(height: 3),
            Text([
              dayWord(trail.whenMs.toInt(), now: now),
              '${trail.branches} ${trail.branches == 1 ? 'branch' : 'branches'}',
              if (trail.kept) 'kept',
            ].join(' · '), style: Tok.label),
          ]),
        ),
      if (_trails.isEmpty)
        const Padding(padding: EdgeInsets.only(top: 10), child: Text('Trails you follow and keep will be here', style: Tok.label)),
      if (kept.isEmpty && _trails.isNotEmpty)
        const Padding(padding: EdgeInsets.only(top: 8), child: Text('⌘S keeps a trail by name', style: Tok.label)),
    ]);
  }

  Widget _pickUp(DateTime now) => _section('Pick up', [
    for (final resume in _resumes)
      FrontDoor(
        key: ValueKey('front-pick-up-${resume.releaseId}'),
        onTap: () => _report(widget.core.pickUp(resume.releaseId)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(resume.recordingTitle, style: Tok.body),
          const SizedBox(height: 3),
          Text([resume.title, if (resume.credit?.isNotEmpty ?? false) resume.credit!].join(' · '), style: Tok.label),
          const SizedBox(height: 7),
          LinearProgressIndicator(
            value: resume.lengthMs != null && resume.lengthMs! > BigInt.zero ? (resume.positionMs.toDouble() / resume.lengthMs!.toDouble()).clamp(0, 1) : 0,
            minHeight: 3,
            color: Tok.gold2,
            backgroundColor: Tok.line,
          ),
          const SizedBox(height: 5),
          Row(children: [
            Expanded(child: Text('${clockLength(resume.positionMs.toInt())}${resume.lengthMs == null ? '' : ' of ${clockLength(resume.lengthMs!.toInt())}'}', style: Tok.monoSmall)),
            Text(dayWord(resume.updatedAt.toInt(), now: now), style: Tok.label),
          ]),
        ]),
      ),
  ]);

  Widget _log(List<int> days, DateTime now) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final total = days.fold<int>(0, (sum, day) => sum + day);
    final peak = days.fold<int>(1, (max, day) => day > max ? day : max);
    return _section('Your log', [
      const SizedBox(height: 10),
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (var i = 0; i < days.length; i++)
          Expanded(child: Semantics(
            label: '${names[i]}${now.weekday == i + 1 ? ' · today' : ''}',
            value: listeningTime(days[i]),
            excludeSemantics: true,
            child: Tooltip(
              message: '${names[i]} · ${listeningTime(days[i])}',
              child: Column(children: [
                SizedBox(height: 48, child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    key: ValueKey('front-log-${i + 1}'),
                    width: 18,
                    height: days[i] == 0 ? 1 : 48 * days[i] / peak,
                    color: now.weekday == i + 1 ? Tok.gold : Tok.gold2,
                  ),
                )),
                const SizedBox(height: 6),
                Text(names[i], style: Tok.label.copyWith(color: now.weekday == i + 1 ? Tok.gold : Tok.faint)),
              ]),
            ),
          )),
      ]),
    ], meta: 'this week · ${listeningTime(total)}');
  }

  Widget _played() => _section('Most played this week', [
    for (final played in _mostPlayed)
      FrontDoor(
        key: ValueKey('front-most-played-${played.trackId}'),
        onTap: widget.onRelease == null ? null : () => _report(widget.onRelease!(played.releaseId)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(played.title, style: Tok.body)),
            const SizedBox(width: 8),
            Text('${played.plays} ${played.plays == BigInt.one ? 'play' : 'plays'}', style: Tok.monoSmall),
          ]),
          Text(played.releaseTitle, style: Tok.label),
        ]),
      ),
  ]);

  Widget _dormantSection(DateTime now) => _section('Dormant', [
    for (final release in _dormant)
      FrontDoor(
        key: ValueKey('front-dormant-${release.releaseId}'),
        onTap: widget.onRelease == null ? null : () => _report(widget.onRelease!(release.releaseId)),
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
  ], meta: 'loved, then left');

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final days = listeningByWeekday(_history, now: now);
    final start = DateTime(now.year, now.month, now.day - 6).millisecondsSinceEpoch;
    final end = DateTime(now.year, now.month, now.day + 1).millisecondsSinceEpoch;
    final hasLog = _history.any((listen) => listen.startedAtMs.toInt() >= start && listen.startedAtMs.toInt() < end);
    final sections = [
      if (_error != null) Text(_error!, style: Tok.label.copyWith(color: Tok.warn)),
      if (_loaded) ...[
        _trailSection(now),
        if (_resumes.isNotEmpty) _pickUp(now),
        if (hasLog) _log(days, now),
        if (_mostPlayed.isNotEmpty) _played(),
        if (_dormant.isNotEmpty) _dormantSection(now),
      ] else if (_error == null)
        const Text('Reading your memory…', style: Tok.label),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < sections.length; i++) ...[
        if (i > 0) const SizedBox(height: 18),
        sections[i],
      ],
    ]);
  }
}

/// A Front row is a quiet door until you point at it.
class FrontDoor extends StatefulWidget {
  const FrontDoor({super.key, required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  State<FrontDoor> createState() => _FrontDoorState();
}

class _FrontDoorState extends State<FrontDoor> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: Semantics(
      button: widget.onTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
          decoration: BoxDecoration(color: _hover && widget.onTap != null ? Tok.panel2 : Tok.sky, border: const Border(bottom: BorderSide(color: Tok.line))),
          child: widget.child,
        ),
      ),
    ),
  );
}
