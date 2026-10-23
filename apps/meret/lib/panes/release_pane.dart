import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;

import '../core/bridge.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';
import 'pane.dart';

/// A release's local edition, tracklist and sourced credits.
class ReleasePane extends StatefulWidget {
  const ReleasePane({super.key, required this.core, required this.id, required this.fromStop, required this.onFollow, this.libraryVersion, this.lookupsVersion});

  final CoreBridge core;
  final PlatformInt64 id;
  final int fromStop;
  final Future<void> Function(TargetDto, ThreadKind, String) onFollow;
  final BigInt? libraryVersion;
  final BigInt? lookupsVersion;

  @override
  State<ReleasePane> createState() => _ReleasePaneState();
}

class _ReleasePaneState extends State<ReleasePane> {
  final _focus = FocusNode();
  ReleaseDto? _release;
  String? _error;
  int? _selected;
  int _generation = 0;
  bool _allCredits = false;

  /// A compilation credits every track; past this many, the rest fold under one line.
  static const _credits = 8;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ReleasePane old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id || old.core != widget.core || old.libraryVersion != widget.libraryVersion || old.lookupsVersion != widget.lookupsVersion) _load();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _release = null;
    _selected = null;
    _allCredits = false;
    try {
      final release = await widget.core.release(widget.id);
      if (!mounted || generation != _generation) return;
      setState(() {
        _release = release;
        _error = null;
      });
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error.toString());
    }
  }

  Future<void> _play(int index) async {
    _focus.requestFocus();
    setState(() {
      _selected = index;
      _error = null;
    });
    try {
      await widget.core.playRelease(id: widget.id, index: index, fromStop: widget.fromStop);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _follow(ThreadDto thread) async {
    try {
      await widget.onFollow(thread.to, thread.kind, thread.provider);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter && _selected != null) {
      _play(_selected!);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _heading(String label) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 6),
    child: Container(
      padding: const EdgeInsets.only(bottom: 6),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.rule))),
      child: Text(label, style: Tok.label),
    ),
  );

  Widget _row(TrackRowDto row, int index, String? albumArtist, ThreadDto? work) {
    final light = Light.of(context);
    final lit = light.track == row.trackId.toInt();
    return Semantics(
      key: ValueKey('release-row-$index'),
      button: true,
      selected: _selected == index,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _play(index),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 5),
            decoration: BoxDecoration(
              color: lit ? light.wash : _selected == index ? Tok.panel2 : Colors.transparent,
              border: Border(
                bottom: const BorderSide(color: Tok.line),
                left: BorderSide(color: lit ? light.accent : Colors.transparent, width: 2),
              ),
            ),
            child: Row(children: [
              SizedBox(width: 42, child: Text(_position(row), style: Tok.monoSmall)),
              Expanded(child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(row.title, style: Tok.body.copyWith(color: lit ? light.accent : Tok.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (work != null) Semantics(
                    button: true,
                    child: GestureDetector(
                      key: ValueKey('release-work-$index'),
                      onTap: () => _follow(work),
                      child: Text(work.title, style: Tok.label.copyWith(color: Tok.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
              )),
              // Compilations credit each track; say who when it isn't the album artist.
              if (row.artist != null && row.artist != albumArtist)
                Flexible(child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(row.artist!, style: Tok.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                )),
              const SizedBox(width: 8),
              Text(_time(row.lengthMs), style: Tok.monoSmall),
            ]),
          ),
        ),
      ),
    );
  }

  /// `07`, or `2-07` when the release has more than one disc.
  String _position(TrackRowDto row) {
    if (row.number == 0) return '';
    final number = row.number.toString().padLeft(2, '0');
    return (_release?.discs ?? 1) > 1 ? '${row.disc}-$number' : number;
  }

  @override
  Widget build(BuildContext context) {
    final release = _release;
    if (release == null) return Text(_error ?? 'Reading release…', style: Tok.label.copyWith(color: _error == null ? Tok.faint : Tok.warn));
    final facts = [
      if (release.idiom != null) release.idiom!,
      if (release.year != null) '${release.year}',
      '${release.tracks} ${release.tracks == 1 ? 'track' : 'tracks'}',
      '${release.discs} ${release.discs == 1 ? 'disc' : 'discs'}',
      _time(release.lengthMs),
      playsFact(release.plays, release.lastPlayedMs),
    ];
    return Focus(
      focusNode: _focus,
      onKeyEvent: _key,
      child: CustomScrollView(slivers: [
        SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (release.cover case final cover?) ...[
              Image.file(File(cover), width: 120, height: 120, fit: BoxFit.contain, cacheWidth: 256),
              const SizedBox(width: 16),
            ],
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(release.title, style: Tok.title),
              if (release.artist case final artist?)
                WrittenCredit(written: artist, people: release.artistLinks, onFollow: _follow),
              const SizedBox(height: 8),
              Text(facts.join(' · '), style: Tok.label),
              if (release.formats.isNotEmpty)
                Text(release.formats.join(' · '), style: Tok.monoSmall.copyWith(color: Tok.muted)),
              const SizedBox(height: 10),
              PaneActions(
                primary: 'Play',
                onPrimary: release.rows.isEmpty ? null : () => _play(0),
                primaryKey: const ValueKey('release-play'),
              ),
            ])),
          ]),
          if (_error != null) Text(_error!, style: Tok.label.copyWith(color: Tok.warn)),
          // Credits before the tracklist, so their threads stay in reach on a long release.
          if (release.credits.isNotEmpty) _heading('Credits'),
        ])),
        SliverList(delegate: SliverChildBuilderDelegate(
          (_, i) => ThreadLine(thread: release.credits[i], onFollow: () => _follow(release.credits[i])),
          childCount: _allCredits ? release.credits.length : release.credits.length.clamp(0, _credits),
        )),
        if (!_allCredits && release.credits.length > _credits)
          SliverToBoxAdapter(child: Align(alignment: Alignment.centerLeft, child: TextButton(
            key: const ValueKey('release-more-credits'),
            onPressed: () => setState(() => _allCredits = true),
            child: Text('${release.credits.length - _credits} more', style: Tok.label.copyWith(color: Tok.gold)),
          ))),
        if (release.games.isNotEmpty) ...[
          SliverToBoxAdapter(child: _heading('Game')),
          SliverList(delegate: SliverChildBuilderDelegate(
            (_, i) => ThreadLine(thread: release.games[i], onFollow: () => _follow(release.games[i])),
            childCount: release.games.length,
          )),
        ],
        SliverToBoxAdapter(child: _heading('Tracklist')),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, i) => _row(release.rows[i], i, release.artist, release.rowWorks[i]),
            childCount: release.rows.length,
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
      ]),
    );
  }
}

/// Keeps the tag's punctuation and wording, with one thread per credited person.
class WrittenCredit extends StatelessWidget {
  const WrittenCredit({super.key, required this.written, required this.people, required this.onFollow});

  final String written;
  final List<ThreadDto> people;
  final void Function(ThreadDto) onFollow;

  @override
  Widget build(BuildContext context) {
    final matches = <({int start, int end, ThreadDto person})>[];
    for (final person in people) {
      final pattern = person.title.split(RegExp(r'\s+')).map(RegExp.escape).join(r'\s+').replaceAll(',', r'\s*,\s*');
      final match = RegExp(pattern, caseSensitive: false).firstMatch(written);
      if (match != null) matches.add((start: match.start, end: match.end, person: person));
    }
    matches.sort((a, b) => a.start.compareTo(b.start));
    final spans = <InlineSpan>[];
    var offset = 0;
    for (final match in matches) {
      if (match.start < offset) continue;
      if (match.start > offset) spans.add(TextSpan(text: written.substring(offset, match.start)));
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: Semantics(
          button: true,
          label: match.person.title,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => onFollow(match.person),
              child: Text(written.substring(match.start, match.end), style: Tok.body.copyWith(color: Tok.muted)),
            ),
          ),
        ),
      ));
      offset = match.end;
    }
    if (offset < written.length) spans.add(TextSpan(text: written.substring(offset)));
    return Text.rich(TextSpan(children: spans), style: Tok.body.copyWith(color: Tok.muted));
  }
}

String _time(BigInt? milliseconds) {
  if (milliseconds == null) return '';
  final seconds = milliseconds.toInt() ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// The same labelled, sourced thread grammar in release and person panes.
class ThreadLine extends StatelessWidget {
  const ThreadLine({super.key, required this.thread, required this.onFollow});

  final ThreadDto thread;
  final VoidCallback onFollow;

  /// Room for the longest label, "engineered by".
  static const _label = 108.0;

  @override
  Widget build(BuildContext context) => Semantics(
    key: ValueKey('thread-${thread.kind.name}-${thread.to}'),
    button: true,
    label: '${thread.label} · ${thread.title} · ${thread.source}',
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onFollow,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.line))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: _label, child: Text(thread.label, style: Tok.body.copyWith(color: Tok.gold2, fontStyle: FontStyle.italic))),
              Expanded(child: Text(thread.title, style: Tok.body, maxLines: 2, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              Text(thread.source, style: Tok.label.copyWith(color: Tok.dim, fontSize: 10)),
            ]),
            if (thread.detail.isNotEmpty) Padding(
              padding: const EdgeInsets.only(left: _label, top: 2),
              child: Text(thread.detail, style: Tok.label),
            ),
          ]),
        ),
      ),
    ),
  );
}
