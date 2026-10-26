import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;

import '../core/bridge.dart';
import '../core/playhead.dart';
import '../now/now_pane.dart';
import '../now/picks.dart';
import '../panes/add_folder.dart';
import '../panes/pane.dart';
import '../theme/tokens.dart';
import 'resume.dart';
import 'week.dart';

/// Home's own page, where Meret opens (navigation.md, "Home"; plate 01):
/// Resume first, then Play something with its reasons, what's partway
/// through, what's new and your week. It is not a stop on a trail; with an
/// empty library it is the first run instead.
class Today extends StatefulWidget {
  const Today({
    super.key, required this.core, required this.memoryVersion, this.now, this.clock,
    this.onToggle, this.onRelease, this.libraryVersion, this.jobs = const [], this.trailName,
  });

  final CoreBridge core;
  final int memoryVersion;
  final NowDto? now;
  /// Resume shows only with a clock to drive it.
  final PlayheadClock? clock;
  final VoidCallback? onToggle;
  final Future<void> Function(PlatformInt64)? onRelease;
  final BigInt? libraryVersion;
  final List<JobDto> jobs;

  /// The open trail Today lies over, which `]` returns to.
  final String? trailName;

  @override
  State<Today> createState() => _TodayState();
}

class _TodayState extends State<Today> {
  FrontDto? _front;
  List<FolderSuggestionDto>? _suggestions;

  /// The root paths [_suggestions] were found against; a 2 s disk look, so
  /// it runs again only when the roots change.
  List<String>? _suggestedFor;
  String? _error;
  bool _adding = false;
  bool _answeringLookups = false;

  /// "Not now" on the Lookups prompt hides it for this run; the setting
  /// stays unasked, so a fresh State asks again.
  bool _lookupsDeferred = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(Today old) {
    super.didUpdateWidget(old);
    if (old.core != widget.core) {
      _suggestions = null;
      _suggestedFor = null;
    }
    if (old.core != widget.core || old.libraryVersion != widget.libraryVersion) _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final front = await widget.core.front();
      if (!mounted || generation != _generation) return;
      setState(() {
        _front = front;
        _error = null;
      });
      final rootPaths = [for (final root in front.roots) root.path];
      if (_suggestions == null || !listEquals(_suggestedFor, rootPaths)) {
        _suggestedFor = rootPaths;
        final suggestions = await widget.core.suggestFolders();
        if (mounted) setState(() => _suggestions = suggestions);
      }
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error.toString());
    }
  }

  Future<void> _addFolder([String? path]) async {
    if (_adding) return;
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      final added = await addMusicFolder(widget.core, path: path, isMounted: () => mounted);
      if (mounted && added) await _load();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _setLookups(LookupsDto setting) async {
    if (_answeringLookups) return;
    setState(() { _answeringLookups = true; _error = null; });
    try {
      await widget.core.setLookups(setting);
      if (mounted) await _load();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _answeringLookups = false);
    }
  }

  String _n(BigInt number) => number.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

  String _count(BigInt number, String noun) => '${_n(number)} $noun${number == BigInt.one ? '' : 's'}';

  double _share(BigInt count, BigInt total) => total == BigInt.zero ? 0 : (count.toDouble() / total.toDouble()).clamp(0, 1);

  String _age(RecentDto recent) {
    final elapsed = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(recent.addedMs.toInt()));
    if (elapsed.inDays >= 365) return '${elapsed.inDays ~/ 365}y ago';
    if (elapsed.inDays >= 30) return '${elapsed.inDays ~/ 30}mo ago';
    if (elapsed.inDays > 1) return '${elapsed.inDays} days ago';
    if (elapsed.inDays == 1) return 'Yesterday';
    if (elapsed.inHours > 0) return '${elapsed.inHours}h ago';
    return 'Just added';
  }

  Widget _section(String title, List<Widget> lines) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Container(
      padding: const EdgeInsets.only(bottom: 6),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.rule))),
      child: Text(title, style: Tok.label),
    ),
    ...lines,
  ]);

  Widget _recent(FrontDto front) => _section('Added lately', [
    for (final recent in front.addedLately)
      TodayDoor(onTap: widget.onRelease == null ? null : () async {
        try {
          await widget.onRelease!(recent.releaseId);
        } catch (error) {
          if (mounted) setState(() => _error = error.toString());
        }
      }, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text([recent.title, if (recent.artist?.isNotEmpty ?? false) recent.artist!].join(' · '), style: Tok.body),
        Text([if (recent.year != null) '${recent.year}', '${recent.tracks} ${recent.tracks == 1 ? 'track' : 'tracks'}', _age(recent)].join(' · '), style: Tok.label),
      ])),
  ]);

  /// The one question Today asks, until it is answered or deferred; the
  /// guesses themselves are Home's Needs you door.
  Widget _lookups(LookupStatusDto lookups) => _section('Needs you', [
    TodayDoor(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Lookups', style: Tok.body),
      Text([
        'Sends IDs, album titles and album artists to MusicBrainz, album titles to Wikidata',
        if (lookups.releases > BigInt.zero) _count(lookups.releases, 'release'),
        if (lookups.recordings > BigInt.zero) _count(lookups.recordings, 'track'),
        if (lookups.people > BigInt.zero) '${_n(lookups.people)} ${lookups.people == BigInt.one ? 'person' : 'people'}',
        if (lookups.unidentified > BigInt.zero) '${_n(lookups.unidentified)} to match by name',
      ].join(' · '), style: Tok.label),
      const SizedBox(height: 6),
      PaneActions(
        primary: 'Allow', onPrimary: _answeringLookups ? null : () => _setLookups(LookupsDto.allowed),
        secondary: 'Not now', onSecondary: _answeringLookups ? null : () => setState(() => _lookupsDeferred = true),
      ),
    ])),
  ]);

  Widget _suggestion(FolderSuggestionDto suggestion) {
    final files = suggestion.audioFiles;
    final detail = suggestion.asksPermission ? 'macOS will ask for access'
      : files == null ? null
      : '${suggestion.more ? 'At least ' : ''}${_count(files, 'audio file')}';
    return TodayDoor(
      onTap: _adding ? null : () => _addFolder(suggestion.path),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(suggestion.label, style: Tok.body)),
          const SizedBox(width: 8),
          Text('Add folder →', style: Tok.label.copyWith(color: _adding ? Tok.faint : Tok.gold)),
        ]),
        const SizedBox(height: 3),
        Text(suggestion.path, style: Tok.monoSmall.copyWith(fontSize: 10, color: Tok.faint)),
        if (detail != null) ...[
          const SizedBox(height: 4),
          Text(detail, style: Tok.body.copyWith(fontSize: 11, color: Tok.muted)),
        ],
        if (suggestion.note.isNotEmpty)
          Text(suggestion.note, style: Tok.body.copyWith(fontSize: 11, color: Tok.muted)),
      ]),
    );
  }

  Widget _emptyCollection() => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(border: Border.all(color: Tok.line)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Collection', style: Tok.body.copyWith(fontSize: 16, fontWeight: FontWeight.w600)),
      const SizedBox(height: 12),
      for (final suggestion in _suggestions ?? <FolderSuggestionDto>[]) _suggestion(suggestion),
      TodayDoor(
        onTap: _adding ? null : _addFolder,
        child: Row(children: [
          const Expanded(child: Text('Choose a folder…', style: Tok.body)),
          Text('Browse →', style: Tok.label.copyWith(color: _adding ? Tok.faint : Tok.gold)),
        ]),
      ),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(border: Border.all(color: Tok.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Coming later', style: Tok.label),
          const SizedBox(height: 6),
          Text('Bring your history', style: Tok.body.copyWith(color: Tok.muted)),
          const SizedBox(height: 4),
          Text('Apple Music, Last.fm, ListenBrainz', style: Tok.body.copyWith(fontSize: 11, color: Tok.faint)),
          const SizedBox(height: 10),
          Text('Connect a service', style: Tok.body.copyWith(color: Tok.muted)),
          const SizedBox(height: 4),
          Text('Spotify, Bandcamp, Qobuz, ListenBrainz…', style: Tok.body.copyWith(fontSize: 11, color: Tok.faint)),
        ]),
      ),
    ]),
  );

  Widget _quietLine(String title) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Text(title, style: Tok.body.copyWith(color: Tok.faint)),
  );

  /// Doors that aren't built yet, so a reader can tell them from empty ones.
  Widget _quietPanel(List<Widget> children) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(border: Border.all(color: Tok.line.withValues(alpha: 0.65))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Coming later', style: Tok.label),
      const SizedBox(height: 6),
      ...children,
    ]),
  );

  Widget _emptyLeads() => _quietPanel([
    Text('Leads', style: Tok.body.copyWith(fontSize: 16, fontWeight: FontWeight.w600, color: Tok.faint)),
    const SizedBox(height: 12),
    _quietLine('Music to follow'),
    const Divider(height: 1, color: Tok.line),
    _quietLine('Wants'),
    const Divider(height: 1, color: Tok.line),
    _quietLine('Needs you'),
  ]);

  Widget _emptyMemory() => _quietPanel([
    Text('Crates and trails', style: Tok.body.copyWith(fontSize: 16, fontWeight: FontWeight.w600, color: Tok.faint)),
    const SizedBox(height: 12),
    _quietLine('Sets you make'),
    const Divider(height: 1, color: Tok.line),
    const SizedBox(height: 28),
    Text('Pick up', style: Tok.body.copyWith(fontSize: 16, fontWeight: FontWeight.w600, color: Tok.faint)),
    const SizedBox(height: 12),
    _quietLine('Where you stopped'),
  ]);

  /// The headline waits for the disk look; only places with a counted file
  /// total are "found", a volume that still needs permission is not.
  String _welcome() {
    final suggestions = _suggestions;
    if (suggestions == null && _error == null) return 'Looking for music folders…';
    final found = suggestions?.where((suggestion) => suggestion.audioFiles != null).length ?? 0;
    return found > 0 ? 'Meret found $found ${found == 1 ? 'place' : 'places'} with music' : 'Start with a music folder';
  }

  Widget _emptyFront(double width) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.line))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Today', style: Tok.label),
          const SizedBox(height: 10),
          Text(_welcome(), style: Tok.title),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.all(20),
        child: width >= 1000
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 5, child: _emptyCollection()),
              const SizedBox(width: 16),
              Expanded(flex: 4, child: _emptyLeads()),
              const SizedBox(width: 16),
              Expanded(flex: 4, child: _emptyMemory()),
            ])
          : width >= 650
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _emptyCollection()),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _emptyLeads(),
                  const SizedBox(height: 16),
                  _emptyMemory(),
                ])),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _emptyCollection(),
                const SizedBox(height: 16),
                _emptyLeads(),
                const SizedBox(height: 16),
                _emptyMemory(),
              ]),
      ),
    ]);
  }

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(28, 18, 28, 0),
    child: Row(children: [
      const Expanded(child: Text('Today', style: Tok.label)),
      if (widget.trailName case final name?)
        Flexible(child: Text('] back to $name', key: const ValueKey('today-back'), style: Tok.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
    ]),
  );

  /// Resume, then the picks, then what's partway through.
  Widget _listen() => NowMemory(
    core: widget.core, now: widget.now, resumeLimit: 6, historyLimit: 0, onRelease: widget.onRelease,
    header: (points) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if ((widget.now, widget.clock) case (final now?, final clock?) when now.anchor != null)
        ResumeHeader(now: now, clock: clock, onToggle: widget.onToggle ?? () {}, points: points),
      PlaySomething(core: widget.core, now: widget.now),
      const SizedBox(height: 22),
    ]),
  );

  Widget _since(FrontDto front) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    if (front.addedLately.isNotEmpty) ...[_recent(front), const SizedBox(height: 18)],
    TodayWeek(
      key: const ValueKey('today-week'),
      core: widget.core,
      memoryVersion: widget.memoryVersion,
      libraryVersion: widget.libraryVersion,
      onRelease: widget.onRelease,
    ),
  ]);

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final front = _front;
    final scans = widget.jobs.where((job) => job.isScan);
    final lookups = front == null || _lookupsDeferred ? null : front.lookups;
    final gutter = box.maxWidth < 500 ? 18.0 : 28.0;
    return ColoredBox(
      color: Tok.sky,
      child: SingleChildScrollView(key: const ValueKey('today-scroll'), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (front?.roots.isNotEmpty ?? true) _header(),
        for (final job in scans)
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${job.verb[0].toUpperCase()}${job.verb.substring(1)} · ${_n(job.done)} of ${_n(job.total)}', style: Tok.label.copyWith(color: Tok.gold)),
              const SizedBox(height: 6),
              LinearProgressIndicator(value: job.total > BigInt.zero ? _share(job.done, job.total) : null, minHeight: 2, color: Tok.gold2, backgroundColor: Tok.line),
            ]),
          ),
        if (_error != null)
          Padding(padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 0), child: Text(_error!, style: Tok.body.copyWith(color: Tok.ox))),
        if (front == null)
          Padding(padding: EdgeInsets.all(gutter), child: const Text('Reading collection…', style: Tok.label))
        else if (front.roots.isEmpty)
          _emptyFront(box.maxWidth)
        else
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, 18, gutter, 28),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (lookups != null) ...[_lookups(lookups), const SizedBox(height: 22)],
              if (box.maxWidth >= 900)
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 6, child: _listen()),
                  const SizedBox(width: 36),
                  Expanded(flex: 5, child: _since(front)),
                ])
              else ...[_listen(), const SizedBox(height: 4), _since(front)],
            ]),
          ),
      ])),
    );
  });
}
