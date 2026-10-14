import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../theme/tokens.dart';
import 'table_pane.dart';

/// A search keeps its people and releases close to the table of results.
class SearchPane extends StatelessWidget {
  const SearchPane({super.key, required this.core, required this.search, required this.query,
    required this.onHit, required this.onQuery, this.libraryVersion, this.tracks, this.scanning = false});

  final CoreBridge core;
  final SearchDto search;
  final String query;
  final ValueChanged<HitDto> onHit;
  final ValueChanged<String> onQuery;
  final BigInt? libraryVersion;
  final BigInt? tracks;
  final bool scanning;

  Widget _group(String name, BigInt total, List<HitDto> hits) => Row(mainAxisSize: MainAxisSize.min, children: [
    Text('$name · $total', style: Tok.label),
    const SizedBox(width: 8),
    for (final hit in hits) Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Tooltip(
        message: hit.detail,
        child: TextButton(
          key: ValueKey('search-hit-${hit.kind.name}-${hit.id}'),
          onPressed: () => onHit(hit),
          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 28)),
          child: Text(hit.title, style: Tok.body.copyWith(color: Tok.gold)),
        ),
      ),
    ),
  ]);

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    if (search.people.isNotEmpty || search.releases.isNotEmpty) ...[
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
      core: core,
      query: query,
      onQuery: onQuery,
      libraryVersion: libraryVersion,
      tracks: tracks,
      scanning: scanning,
    )),
  ]);
}
