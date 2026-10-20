import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;

import '../core/bridge.dart';
import '../theme/tokens.dart';
import 'pane.dart';
import 'release_pane.dart';

/// Releases and people connected by the library's local credits.
class PersonPane extends StatefulWidget {
  const PersonPane({super.key, required this.core, required this.id, required this.onFollow});

  final CoreBridge core;
  final PlatformInt64 id;
  final Future<void> Function(TargetDto, ThreadKind) onFollow;

  @override
  State<PersonPane> createState() => _PersonPaneState();
}

class _PersonPaneState extends State<PersonPane> {
  PersonDto? _person;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PersonPane old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id || old.core != widget.core) _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _person = null;
    try {
      final person = await widget.core.person(widget.id);
      if (!mounted || generation != _generation) return;
      setState(() {
        _person = person;
        _error = null;
      });
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error.toString());
    }
  }

  Future<void> _follow(ThreadDto thread) async {
    try {
      await widget.onFollow(thread.to, thread.kind);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  List<Widget> _section(String title, List<ThreadDto> threads) => threads.isEmpty ? [] : [
    SliverToBoxAdapter(child: Container(
      margin: const EdgeInsets.only(top: 18, bottom: 6),
      padding: const EdgeInsets.only(bottom: 6),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.rule))),
      child: Text(title, style: Tok.label),
    )),
    SliverList(delegate: SliverChildBuilderDelegate(
      (_, i) => ThreadLine(thread: threads[i], onFollow: () => _follow(threads[i])),
      childCount: threads.length,
    )),
  ];

  @override
  Widget build(BuildContext context) {
    final person = _person;
    if (person == null) return Text(_error ?? 'Reading person…', style: Tok.label.copyWith(color: _error == null ? Tok.faint : Tok.warn));
    return CustomScrollView(slivers: [
      SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${person.tracks} ${person.tracks == 1 ? 'track' : 'tracks'} · ${person.releases.length} ${person.releases.length == 1 ? 'release' : 'releases'} · ${playsFact(person.plays, person.lastPlayedMs)}', style: Tok.label),
        if (_error != null) Text(_error!, style: Tok.label.copyWith(color: Tok.warn)),
      ])),
      ..._section('Releases', person.releases),
      ..._section('Appears on', person.appearsOn),
      ..._section('Worked with', person.workedWith),
      const SliverToBoxAdapter(child: SizedBox(height: 20)),
    ]);
  }
}
