import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;

import '../core/bridge.dart';
import '../settings/settings_window.dart';
import '../theme/tokens.dart';
import 'add_folder.dart';
import 'front_memory.dart';
import 'pane.dart';

/// The Front is a flat set of doors the library can actually answer.
class FrontPane extends StatefulWidget {
  const FrontPane({super.key, required this.core, required this.memoryVersion, required this.onQuery, this.onTrail, this.onRelease, this.libraryVersion, this.jobs = const []});

  final CoreBridge core;
  final int memoryVersion;
  final ValueChanged<String> onQuery;
  final Future<void> Function(String)? onTrail;
  final Future<void> Function(PlatformInt64)? onRelease;
  final BigInt? libraryVersion;
  final List<JobDto> jobs;

  @override
  State<FrontPane> createState() => _FrontPaneState();
}

class _FrontPaneState extends State<FrontPane> {
  FrontDto? _front;
  List<FolderSuggestionDto>? _suggestions;
  String? _error;
  bool _adding = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FrontPane old) {
    super.didUpdateWidget(old);
    if (old.core != widget.core) _suggestions = null;
    if (old.core != widget.core || old.libraryVersion != widget.libraryVersion) _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final front = await widget.core.front();
      if (!mounted || generation != _generation) return;
      final needsSuggestions = front.roots.isEmpty && (_suggestions == null || _front?.roots.isNotEmpty == true);
      setState(() {
        _front = front;
        _error = null;
        if (needsSuggestions) _suggestions = null;
      });
      if (needsSuggestions) {
        final suggestions = await widget.core.suggestFolders();
        if (mounted && generation == _generation) setState(() => _suggestions = suggestions);
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

  Widget _bar(double share, {double width = 64}) => SizedBox(
    width: width,
    height: 5,
    child: Align(alignment: Alignment.centerLeft, child: FractionallySizedBox(widthFactor: share, heightFactor: 1, child: const ColoredBox(color: Tok.gold2))),
  );

  Widget _door({String? query, required Widget child}) => FrontDoor(
    onTap: query == null ? null : () => widget.onQuery(query),
    child: child,
  );

  Widget _section(String title, List<Widget> lines) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Container(
      padding: const EdgeInsets.only(bottom: 6),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.rule))),
      child: Text(title, style: Tok.label),
    ),
    ...lines,
  ]);

  Widget _collection(FrontDto front) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Text('Collection · ${_count(front.tracks, 'track')}', style: Tok.body.copyWith(fontSize: 18, fontWeight: FontWeight.w600)),
    const SizedBox(height: 12),
    for (final idiom in front.idioms)
      _door(query: idiom.query, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(idiom.label, style: Tok.body.copyWith(fontWeight: FontWeight.w600))),
          Text(_count(idiom.releases, 'release'), style: Tok.monoSmall),
        ]),
        const SizedBox(height: 3),
        Row(children: [
          Expanded(child: Text(_count(idiom.tracks, 'track'), style: Tok.label)),
          _bar(_share(idiom.tracks, front.tracks)),
        ]),
      ])),
  ]);

  Widget _formats(FrontDto front) => _section('By format', [
    for (final format in front.formats)
      _door(query: format.query, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(format.label, style: Tok.body.copyWith(color: Tok.muted))),
          const SizedBox(width: 8),
          Text(_n(format.count), style: Tok.monoSmall),
        ]),
        if (format.note.isNotEmpty) Text(format.note, style: Tok.label),
        const SizedBox(height: 6),
        LayoutBuilder(builder: (_, box) => _bar(_share(format.count, front.tracks), width: box.maxWidth)),
      ])),
  ]);

  Widget _recent(FrontDto front) => _section('Added lately', [
    for (final recent in front.addedLately)
      FrontDoor(onTap: widget.onRelease == null ? null : () async {
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

  Widget _needs(FrontDto front) => _section('Needs you', [
    for (final need in front.needsYou)
      _door(query: need.query, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(need.label, style: Tok.body)),
          const SizedBox(width: 8),
          Text(_n(need.count), style: Tok.monoSmall.copyWith(color: Tok.warn)),
        ]),
        if (need.note.isNotEmpty) Text(need.note, style: Tok.label),
      ])),
  ]);

  Widget _folders(FrontDto front) => _section('Folders', [
    for (final root in front.roots)
      _door(child: Row(children: [
        Semantics(
          label: root.online ? 'Online' : 'Offline',
          child: Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: root.online ? Tok.ok : Tok.warn)),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(root.path, style: Tok.monoSmall)),
      ])),
    Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: _adding ? null : _addFolder, child: const Text('+ Add folder', style: Tok.label))),
  ]);

  Widget _column(List<Widget> sections, {bool last = false}) => Expanded(
    child: Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      decoration: BoxDecoration(border: last ? null : const Border(right: BorderSide(color: Tok.line))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < sections.length; i++) ...[
          if (i > 0) const SizedBox(height: 18),
          sections[i],
        ],
      ]),
    ),
  );

  Widget _suggestion(FolderSuggestionDto suggestion) {
    final files = suggestion.audioFiles;
    final detail = suggestion.asksPermission ? 'macOS will ask for access'
      : files == null ? null
      : '${suggestion.more ? 'At least ' : ''}${_count(files, 'audio file')}';
    return FrontDoor(
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
      if (_suggestions == null && _error == null)
        const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Looking for music folders…', style: Tok.label)),
      for (final suggestion in _suggestions ?? <FolderSuggestionDto>[]) _suggestion(suggestion),
      FrontDoor(
        onTap: _adding ? null : _addFolder,
        child: Row(children: [
          const Expanded(child: Text('Choose a folder…', style: Tok.body)),
          Text('Browse →', style: Tok.label.copyWith(color: _adding ? Tok.faint : Tok.gold)),
        ]),
      ),
      const SizedBox(height: 12),
      FrontDoor(
        onTap: () => showSettings(context, section: SettingsSection.sources),
        child: Text('Connect a service', style: Tok.body.copyWith(color: Tok.gold)),
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
        ]),
      ),
    ]),
  );

  Widget _quietLine(String title) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Text(title, style: Tok.body.copyWith(color: Tok.faint)),
  );

  Widget _quietPanel(List<Widget> children) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(border: Border.all(color: Tok.line.withValues(alpha: 0.65))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
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

  Widget _quietLeadsAndCrates() => _quietPanel([
    Text('Leads', style: Tok.body.copyWith(fontSize: 16, fontWeight: FontWeight.w600, color: Tok.faint)),
    _quietLine('Music to follow'),
    const Divider(height: 1, color: Tok.line),
    _quietLine('Wants'),
    const Divider(height: 1, color: Tok.line),
    const SizedBox(height: 16),
    Text('Crates', style: Tok.body.copyWith(fontSize: 16, fontWeight: FontWeight.w600, color: Tok.faint)),
    _quietLine('Sets you make'),
  ]);

  Widget _memory() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    FrontMemory(
      key: const ValueKey('front-memory'),
      core: widget.core,
      memoryVersion: widget.memoryVersion,
      libraryVersion: widget.libraryVersion,
      onTrail: widget.onTrail,
      onRelease: widget.onRelease,
    ),
    const SizedBox(height: 24),
    _quietLeadsAndCrates(),
  ]);

  Widget _emptyFront(double width) {
    final count = _suggestions?.length ?? 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.line))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Front', style: Tok.label),
          const SizedBox(height: 10),
          Text(count > 0 ? 'Meret found $count ${count == 1 ? 'place' : 'places'} with music' : 'Start with a music folder', style: Tok.title),
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

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    if (box.maxWidth < 60) return const Pane(kind: 'FRONT', title: 'Front');
    final front = _front;
    final scans = widget.jobs.where((job) => job.verb == 'scanning' || job.verb == 'reading tags');
    return Container(
      decoration: const BoxDecoration(color: Tok.sky, border: Border(right: BorderSide(color: Tok.line))),
      child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final job in scans)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${job.verb[0].toUpperCase()}${job.verb.substring(1)} · ${_n(job.done)} of ${_n(job.total)}', style: Tok.label.copyWith(color: Tok.gold)),
              const SizedBox(height: 6),
              LinearProgressIndicator(value: job.total > BigInt.zero ? _share(job.done, job.total) : null, minHeight: 2, color: Tok.gold2, backgroundColor: Tok.line),
            ]),
          ),
        if (_error != null)
          Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 0), child: Text(_error!, style: Tok.body.copyWith(color: Tok.ox))),
        if (front == null)
          const Padding(padding: EdgeInsets.all(20), child: Text('Reading collection…', style: Tok.label))
        else if (front.roots.isEmpty)
          _emptyFront(box.maxWidth)
        else
          // Three columns once each gets 400 px; beside a pinned Now that is a 1600 px window.
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: box.maxWidth >= 1200 ? [
            _column([_collection(front), _formats(front)]),
            _column([_recent(front), if (front.needsYou.isNotEmpty) _needs(front), _folders(front)]),
            _column([_memory()], last: true),
          ] : box.maxWidth >= 620 ? [
            _column([_collection(front), _formats(front)]),
            _column([_recent(front), if (front.needsYou.isNotEmpty) _needs(front), _folders(front), _memory()], last: true),
          ] : [
            _column([_collection(front), _formats(front), _recent(front), if (front.needsYou.isNotEmpty) _needs(front), _folders(front), _memory()], last: true),
          ]),
      ])),
    );
  });
}

