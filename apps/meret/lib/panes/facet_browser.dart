import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../theme/tokens.dart';

/// The core supplies both the cascade counts and every click's query.
class FacetBrowser extends StatelessWidget {
  const FacetBrowser({super.key, required this.facets, required this.onQuery});

  final FacetsDto? facets;
  final ValueChanged<String> onQuery;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 172,
    child: DecoratedBox(
      decoration: BoxDecoration(border: Border.all(color: Tok.line)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: _column('Idiom', facets?.idioms)),
        const VerticalDivider(width: 1, color: Tok.line),
        Expanded(child: _column('People', facets?.people)),
        const VerticalDivider(width: 1, color: Tok.line),
        Expanded(child: _column('Releases', facets?.releases)),
      ]),
    ),
  );

  Widget _column(String name, FacetColumnDto? column) => ColoredBox(
    color: Tok.sky,
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
        child: Row(children: [
          Expanded(child: Text(name, style: Tok.label)),
          Text('${column?.tracks ?? 0}', style: Tok.label.copyWith(color: Tok.dim)),
        ]),
      ),
      Expanded(child: ListView.builder(
        key: ValueKey('facet-$name'),
        primary: false,
        itemExtent: 20,
        itemCount: column == null ? 0 : column.entries.length + 1,
        itemBuilder: (_, index) {
          final entry = index == 0 ? null : column!.entries[index - 1];
          final selected = entry?.selected ?? !column!.entries.any((entry) => entry.selected);
          return Semantics(
            key: ValueKey('facet-$name-${entry?.id ?? 'all'}'),
            button: true, selected: selected,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onQuery(entry?.query ?? column!.allQuery),
                child: Container(
                  decoration: BoxDecoration(
                    color: selected ? const Color(0x14D2A64E) : Colors.transparent,
                    border: Border(left: BorderSide(color: selected ? Tok.gold : Colors.transparent, width: 2)),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(children: [
                    Expanded(child: Text(entry?.name ?? 'All', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: Tok.body.copyWith(color: selected ? Tok.ink : Tok.muted))),
                    const SizedBox(width: 8),
                    Text('${entry?.tracks ?? column!.tracks}', style: Tok.label.copyWith(color: Tok.dim)),
                  ]),
                ),
              ),
            ),
          );
        },
      )),
    ]),
  );
}
