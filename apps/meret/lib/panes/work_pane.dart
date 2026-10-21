import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;

import '../core/bridge.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';
import 'pane.dart';
import 'release_pane.dart';

class WorkPane extends StatefulWidget {
  const WorkPane({super.key, required this.core, required this.id, required this.onFollow});

  final CoreBridge core;
  final PlatformInt64 id;
  final Future<void> Function(TargetDto, ThreadKind) onFollow;

  @override
  State<WorkPane> createState() => _WorkPaneState();
}

class _WorkPaneState extends State<WorkPane> {
  final _focus = FocusNode();
  WorkDto? _work;
  String? _error;
  int? _selected;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(WorkPane old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id || old.core != widget.core) _load();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _work = null;
    _selected = null;
    try {
      final work = await widget.core.work(widget.id);
      if (!mounted || generation != _generation) return;
      setState(() {
        _work = work;
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
      await widget.core.playWork(widget.id, index);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _follow(ThreadDto thread) async {
    try {
      await widget.onFollow(thread.to, thread.kind);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.enter && _selected != null) {
      _play(_selected!);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _heading(String title) => Container(
    margin: const EdgeInsets.only(top: 18, bottom: 6),
    padding: const EdgeInsets.only(bottom: 6),
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.rule))),
    child: Text(title, style: Tok.label),
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
    final lit = light.track == row.trackId.toInt();
    return Semantics(
      key: ValueKey('work-row-$index'),
      button: true,
      selected: _selected == index,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _play(index),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: lit ? light.wash : _selected == index ? Tok.panel2 : Colors.transparent,
              border: Border(
                bottom: const BorderSide(color: Tok.line),
                left: BorderSide(color: lit ? light.accent : Colors.transparent, width: 2),
              ),
            ),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(row.title, style: Tok.body.copyWith(color: lit ? light.accent : Tok.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
                if (row.artist case final artist?) Text(artist, style: Tok.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                Semantics(
                  button: true,
                  child: GestureDetector(
                    key: ValueKey('work-album-${row.trackId}'),
                    onTap: () => _follow(ThreadDto(
                      kind: ThreadKind.appearsOn, label: 'on', source: 'tags',
                      to: TargetDto.release(id: row.releaseId), title: row.album, detail: '',
                    )),
                    child: Text(row.album, style: Tok.label.copyWith(color: Tok.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ])),
              const SizedBox(width: 8),
              Text(_time(row.lengthMs), style: Tok.monoSmall),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final work = _work;
    if (work == null) return Text(_error ?? 'Reading work…', style: Tok.label.copyWith(color: _error == null ? Tok.faint : Tok.warn));
    final facts = [
      '${work.rows.length} ${work.rows.length == 1 ? 'recording' : 'recordings'}',
      _time(work.lengthMs),
      if (work.plays > BigInt.zero) playsFact(work.plays, work.lastPlayedMs),
    ];
    return Focus(
      focusNode: _focus,
      onKeyEvent: _key,
      child: CustomScrollView(slivers: [
        SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(work.title, style: Tok.title),
          if (work.composer case final composer?) Text(composer, style: Tok.body.copyWith(color: Tok.muted)),
          const SizedBox(height: 8),
          Text(facts.join(' · '), style: Tok.label),
          const SizedBox(height: 10),
          PaneActions(primary: 'Play', onPrimary: work.rows.isEmpty ? null : () => _play(0), primaryKey: const ValueKey('work-play')),
          if (_error != null) Text(_error!, style: Tok.label.copyWith(color: Tok.warn)),
        ])),
        ..._section('Credits', work.composerLinks),
        if (work.partOf case final parent?) ..._section('Part of', [parent]),
        ..._section('Parts', work.parts),
        SliverToBoxAdapter(child: _heading('Recordings')),
        SliverList(delegate: SliverChildBuilderDelegate(
          (_, i) => _row(work.rows[i], i), childCount: work.rows.length,
        )),
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
      ]),
    );
  }
}

String _time(BigInt? milliseconds) {
  if (milliseconds == null) return '';
  final seconds = milliseconds.toInt() ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
