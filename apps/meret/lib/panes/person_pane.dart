import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;

import '../core/bridge.dart';
import '../theme/tokens.dart';
import 'pane.dart';
import 'release_pane.dart';

/// Releases, works and people connected by sourced credits.
class PersonPane extends StatefulWidget {
  const PersonPane({super.key, required this.core, required this.id, required this.onFollow, this.libraryVersion, this.lookupsVersion});

  final CoreBridge core;
  final PlatformInt64 id;
  final Future<void> Function(TargetDto, ThreadKind, String) onFollow;
  final BigInt? libraryVersion;
  final BigInt? lookupsVersion;

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
    if (old.id != widget.id || old.core != widget.core || old.libraryVersion != widget.libraryVersion || old.lookupsVersion != widget.lookupsVersion) _load();
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
      await widget.onFollow(thread.to, thread.kind, thread.provider);
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
        Text([
          '${person.tracks} ${person.tracks == 1 ? 'track' : 'tracks'}',
          if (person.releases.isNotEmpty) '${person.releases.length} ${person.releases.length == 1 ? 'release' : 'releases'}',
          if (person.works.isNotEmpty) '${person.works.length} ${person.works.length == 1 ? 'work' : 'works'}',
          playsFact(person.plays, person.lastPlayedMs),
        ].join(' · '), style: Tok.label),
        if (_error != null) Text(_error!, style: Tok.label.copyWith(color: Tok.warn)),
      ])),
      const ForksHere(),
      ..._section('Releases', person.releases),
      ..._section('Appears on', person.appearsOn),
      for (final role in person.roles) ..._section(role.title, role.threads),
      ..._section('Works', person.works),
      ..._section('Games', person.games),
      for (final group in person.groups) ..._section(group.title, group.threads),
      ..._section('Worked with', person.workedWith),
      const SliverToBoxAdapter(child: SizedBox(height: 20)),
    ]);
  }
}
