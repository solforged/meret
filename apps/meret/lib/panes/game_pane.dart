import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;

import '../core/bridge.dart';
import '../core/when.dart';
import '../draw/facts.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';
import 'pane.dart';
import 'release_pane.dart';
import 'row_menu.dart';
import 'track_row.dart';

class GamePane extends StatefulWidget {
  const GamePane({super.key, required this.core, required this.id, required this.onFollow, this.title, this.libraryVersion, this.lookupsVersion});

  final CoreBridge core;
  final PlatformInt64 id;
  final Future<void> Function(TargetDto, ThreadKind, String) onFollow;

  /// The stop's title, shown over the placeholder until the game arrives.
  final String? title;
  final BigInt? libraryVersion;
  final BigInt? lookupsVersion;

  @override
  State<GamePane> createState() => _GamePaneState();
}

class _GamePaneState extends State<GamePane> {
  final _focus = FocusNode();
  GameDto? _game;
  String? _error;
  int? _selected;
  final _cursor = RowCursor();
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(GamePane old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id || old.core != widget.core) {
      _game = null;
      _selected = null;
      _cursor.clear();
      _load();
    } else if (old.libraryVersion != widget.libraryVersion || old.lookupsVersion != widget.lookupsVersion) {
      // Facts filled in: refetch in place, keeping what is shown until the new DTO lands.
      _load();
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final game = await widget.core.game(widget.id);
      if (!mounted || generation != _generation) return;
      setState(() {
        _game = game;
        _error = null;
        if (_selected case final selected? when selected >= game.rows.length) _selected = null;
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
      await widget.core.playGame(widget.id, index);
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

  void _queue(TrackRowDto row, {required bool next}) =>
      queueAndSay(context, () => widget.core.queueTracks([row.trackId], next: next), next: next);

  /// The soundtrack a row is on, as the thread the game gives it.
  ThreadDto _album(TrackRowDto row) => ThreadDto(
    kind: ThreadKind.soundtrack, label: 'soundtrack', source: 'Wikidata', provider: 'wikidata',
    to: TargetDto.release(id: row.releaseId), title: row.album, detail: '',
  );

  List<RowAction?> _actions(TrackRowDto row, int index) => musicActions(
    play: () => _play(index),
    playNext: () => _queue(row, next: true),
    addToQueue: () => _queue(row, next: false),
    goTo: [
      RowAction('Go to ${row.album}', () => _follow(_album(row)), shortcut: RowKeys.open),
      if (row.artistId != null) RowAction('Go to ${row.artist ?? 'artist'}', () => _follow(artistThread(row))),
    ],
    reveal: row.path == null ? null : () => revealInFinder(row.path!),
  );

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final game = _game;
    if (game == null) return KeyEventResult.ignored;
    if (_cursor.move(event, _selected, game.rows.length) case final moved?) {
      setState(() => _selected = moved);
      return KeyEventResult.handled;
    }
    final index = _selected;
    final row = index == null ? null : game.rows.elementAtOrNull(index);
    if (index == null || row == null) return KeyEventResult.ignored;
    return RowKeys.handle(event,
      play: () => _play(index),
      playNext: () => _queue(row, next: true),
      addToQueue: () => _queue(row, next: false),
      open: () => _follow(_album(row)),
      reveal: row.path == null ? null : () => revealInFinder(row.path!),
    );
  }

  Widget _heading(String title) => Container(
    margin: const EdgeInsets.only(top: 18, bottom: 6),
    padding: const EdgeInsets.only(bottom: 6),
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.rule))),
    child: Text(title, style: Tok.heading),
  );

  List<Widget> _section(String title, List<ThreadDto> threads) => threads.isEmpty ? [] : [
    SliverToBoxAdapter(child: _heading(title)),
    SliverList(delegate: SliverChildBuilderDelegate(
      (_, i) => ThreadLine(thread: threads[i], onFollow: () => _follow(threads[i])),
      childCount: threads.length,
    )),
  ];

  Widget _row(TrackRowDto row, int index) {
    final light = Light.of(context);
    // A soundtrack's artist and album show where they change, not under every track.
    final before = index > 0 ? _game!.rows[index - 1] : null;
    final newAlbum = before == null || before.releaseId != row.releaseId;
    final artist = row.artist != null && (newAlbum || before.artist != row.artist) ? row.artist : null;
    final album = newAlbum ? _album(row) : null;
    return Semantics(
      key: ValueKey('game-row-$index'),
      button: true,
      selected: _selected == index,
      child: TrackRow(
        key: _cursor.key(index),
        title: row.title,
        under: [?artist],
        thread: album,
        onFollow: album == null ? null : () => _follow(album),
        followKey: ValueKey('game-album-${row.trackId}'),
        arrowSlot: true,
        length: _time(row.lengthMs),
        playing: light.track == row.trackId.toInt(),
        selected: _selected == index,
        onPlay: () => _play(index),
        actions: () => _actions(row, index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final game = _game;
    if (game == null) return paneReading(widget.title, _error ?? 'Reading game…', error: _error != null);
    final facts = [
      if (game.year case final year?) '$year',
      ?game.developers,
      ?game.platforms,
      ?game.series,
    ];
    return Focus(
      focusNode: _focus,
      onKeyEvent: _key,
      child: CustomScrollView(slivers: [
        SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(game.title, style: Tok.title),
          if (facts.isNotEmpty) ...[
            const SizedBox(height: 8),
            Facts(facts, style: Tok.label),
          ],
          const SizedBox(height: 10),
          PaneActions(primary: 'Play', onPrimary: game.rows.isEmpty ? null : () => _play(0), primaryKey: const ValueKey('game-play')),
          if (_error != null) Text(_error!, style: Tok.label.copyWith(color: Tok.warn)),
        ])),
        ..._section('Composers', game.composers),
        ..._section('Soundtracks', game.soundtracks),
        ..._section('Same series', game.sameSeries),
        SliverToBoxAdapter(child: _heading('Tracklist')),
        SliverList(delegate: SliverChildBuilderDelegate(
          (_, i) => _row(game.rows[i], i), childCount: game.rows.length,
        )),
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
      ]),
    );
  }
}

String _time(BigInt? milliseconds) => milliseconds == null ? '' : clockLength(milliseconds.toInt());
