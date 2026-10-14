import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../theme/tokens.dart';
import 'add_folder.dart';
import 'pane.dart';

/// The Front is a flat set of doors the library can actually answer.
class FrontPane extends StatefulWidget {
  const FrontPane({super.key, required this.core, required this.onQuery, this.libraryVersion, this.jobs = const []});

  final CoreBridge core;
  final ValueChanged<String> onQuery;
  final BigInt? libraryVersion;
  final List<JobDto> jobs;

  @override
  State<FrontPane> createState() => _FrontPaneState();
}

class _FrontPaneState extends State<FrontPane> {
  FrontDto? _front;
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
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error.toString());
    }
  }

  Future<void> _addFolder() async {
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      final added = await addMusicFolder(widget.core, isMounted: () => mounted);
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

  Widget _door({String? query, required Widget child}) => _Door(
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
      _door(query: recent.query, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextButton(
                onPressed: _adding ? null : _addFolder,
                child: Text('Add a music folder', style: Tok.body.copyWith(color: Tok.gold, fontSize: 18, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 8),
              const Text('Meret reads files where they are and copies nothing.', style: Tok.body),
            ]),
          )
        else
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: box.maxWidth >= 1000 ? [
            _column([_collection(front)]),
            _column([_formats(front), _recent(front)]),
            _column([if (front.needsYou.isNotEmpty) _needs(front), _folders(front)], last: true),
          ] : box.maxWidth >= 620 ? [
            _column([_collection(front), _formats(front)]),
            _column([_recent(front), if (front.needsYou.isNotEmpty) _needs(front), _folders(front)], last: true),
          ] : [
            _column([_collection(front), _formats(front), _recent(front), if (front.needsYou.isNotEmpty) _needs(front), _folders(front)], last: true),
          ]),
      ])),
    );
  });
}

class _Door extends StatefulWidget {
  const _Door({required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_Door> createState() => _DoorState();
}

class _DoorState extends State<_Door> {
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
