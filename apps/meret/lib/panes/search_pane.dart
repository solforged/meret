import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../theme/tokens.dart';
import 'table_pane.dart';

/// A search keeps its people and releases close to the table of results.
class SearchPane extends StatefulWidget {
  const SearchPane({super.key, required this.core, required this.query,
    required this.onHit, this.search, this.onQuery, this.onFollow, this.libraryVersion, this.tracks, this.scanning = false});

  final CoreBridge core;
  final SearchDto? search;
  final String query;
  final ValueChanged<HitDto> onHit;
  final ValueChanged<String>? onQuery;
  final Future<void> Function(TargetDto, ThreadKind)? onFollow;
  final BigInt? libraryVersion;
  final BigInt? tracks;
  final bool scanning;

  @override
  State<SearchPane> createState() => _SearchPaneState();
}

class _SearchPaneState extends State<SearchPane> {
  late String _query = widget.query;
  SearchDto? _search;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _search = widget.search;
    if (_search == null) _load();
  }

  @override
  void didUpdateWidget(SearchPane old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query || old.core != widget.core) {
      _query = widget.query;
      _search = widget.search;
      _load();
    } else if (old.libraryVersion != widget.libraryVersion) {
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final search = await widget.core.search(widget.query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _search = search;
        _error = null;
      });
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error.toString());
    }
  }

  void _filter(String query) {
    setState(() => _query = query);
    widget.onQuery?.call(query);
  }

  Widget _group(String name, BigInt total, List<HitDto> hits) => Row(mainAxisSize: MainAxisSize.min, children: [
    Text('$name · $total', style: Tok.label),
    const SizedBox(width: 8),
    for (final hit in hits) Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Tooltip(
        message: hit.detail,
        child: TextButton(
          key: ValueKey('search-hit-${hit.kind.name}-${hit.id}'),
          onPressed: () => widget.onHit(hit),
          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 28)),
          child: Text(hit.title, style: Tok.body.copyWith(color: Tok.gold)),
        ),
      ),
    ),
  ]);

  @override
  Widget build(BuildContext context) {
    final search = _search;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_error != null) Text(_error!, style: Tok.label.copyWith(color: Tok.warn)),
      if (search != null && (search.people.isNotEmpty || search.releases.isNotEmpty)) ...[
        SingleChildScrollView(
          key: const ValueKey('search-hit-strip'),
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            if (search.people.isNotEmpty) _group('People', search.peopleTotal, search.people),
            if (search.people.isNotEmpty && search.releases.isNotEmpty) const SizedBox(width: 20),
            if (search.releases.isNotEmpty) _group('Releases', search.releasesTotal, search.releases),
          ]),
        ),
        const Divider(color: Tok.line, height: 12),
      ],
      Expanded(child: TablePane(
        core: widget.core,
        query: _query,
        onQuery: _filter,
        onFollow: widget.onFollow,
        libraryVersion: widget.libraryVersion,
        tracks: widget.tracks,
        scanning: widget.scanning,
      )),
    ]);
  }
}
