import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../core/when.dart';
import '../theme/tokens.dart';

String trailSummaryContext(TrailSummaryDto trail) {
  final ms = trail.whenMs.toInt();
  final year = DateTime.fromMillisecondsSinceEpoch(ms).year;
  return '${trail.stops} ${trail.stops == 1 ? 'stop' : 'stops'} · '
      '${trail.branches} ${trail.branches == 1 ? 'branch' : 'branches'} · '
      'Started ${dayDate(ms)} $year at ${clockTime(ms)}';
}

Future<String?> showTrailBrowser(BuildContext context, CoreBridge core) => showDialog<String>(
  context: context,
  barrierColor: Colors.black54,
  builder: (_) => _TrailBrowser(core: core),
);

class _TrailBrowser extends StatefulWidget {
  const _TrailBrowser({required this.core});
  final CoreBridge core;

  @override
  State<_TrailBrowser> createState() => _TrailBrowserState();
}

class _TrailBrowserState extends State<_TrailBrowser> {
  // The API accepts a limit rather than a cursor. Fetch the complete archive
  // so a title or kept filter cannot silently miss an older saved trail.
  late Future<List<TrailSummaryDto>> _trails = widget.core.trailHistory(0xffffffff);
  final _search = TextEditingController();
  bool _kept = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Widget _results(AsyncSnapshot<List<TrailSummaryDto>> snapshot) {
    if (snapshot.hasError) {
      return Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(snapshot.error.toString(), style: Tok.body.copyWith(color: Tok.warn)),
        TextButton(onPressed: () => setState(() {
          _trails = widget.core.trailHistory(0xffffffff);
        }), child: const Text('Retry')),
      ]));
    }
    final all = snapshot.data;
    if (all == null) return const Padding(padding: EdgeInsets.all(20), child: Text('Loading trails…', style: Tok.label));
    final query = _search.text.trim().toLowerCase();
    final trails = all.where((trail) => (!_kept || trail.kept) &&
      '${trail.name ?? ''} ${trail.title}'.toLowerCase().contains(query)).toList();
    if (trails.isEmpty) {
      return Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(all.isEmpty ? 'No trails yet' : _kept && query.isEmpty ? 'No kept trails yet' : 'No matching trails', style: Tok.body),
        const SizedBox(height: 8),
        Text(all.isEmpty ? 'Search or open a release to start a trail.' : _kept && query.isEmpty
            ? 'Keep a trail from its star or with ⌘S.' : 'Try a different name or show all recent trails.', style: Tok.label),
        if (query.isNotEmpty || _kept) TextButton(onPressed: () => setState(() {
          _search.clear();
          _kept = false;
        }), child: const Text('Reset filters')),
      ]));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4), child: Text(
        '${trails.length} ${trails.length == 1 ? 'trail' : 'trails'} · most recent first', style: Tok.label)),
      Expanded(child: ListView.separated(
        key: const ValueKey('trail-browser-results'),
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        itemCount: trails.length,
        separatorBuilder: (_, _) => const Divider(height: 1, color: Tok.line),
        itemBuilder: (_, index) {
          final trail = trails[index];
          return TextButton(
            key: ValueKey('trail-browser-${trail.uid}'),
            onPressed: () => Navigator.pop(context, trail.uid),
            style: TextButton.styleFrom(alignment: Alignment.centerLeft, padding: const EdgeInsets.all(12)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(trail.kept ? '◆' : '⑂', style: Tok.body.copyWith(color: Tok.gold)),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(trail.name ?? trail.title, style: Tok.body.copyWith(color: Tok.ink)),
                if (trail.name != null && trail.name != trail.title) Text(trail.title, style: Tok.body.copyWith(color: Tok.muted)),
                const SizedBox(height: 4),
                Text(trailSummaryContext(trail), style: Tok.label),
              ])),
            ]),
          );
        },
      )),
    ]);
  }

  @override
  Widget build(BuildContext context) => Dialog(
    key: const ValueKey('trail-browser'),
    backgroundColor: Tok.panel,
    insetPadding: const EdgeInsets.all(20),
    shape: const RoundedRectangleBorder(side: BorderSide(color: Tok.rule)),
    child: SizedBox(width: 680, height: 640, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 12, 12, 8), child: Row(children: [
        const Expanded(child: Text('All trails', style: Tok.body)),
        IconButton(tooltip: 'Close trails', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, size: 18, color: Tok.muted)),
      ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: TextField(
        key: const ValueKey('trail-browser-search'),
        controller: _search,
        autofocus: true,
        style: Tok.body,
        decoration: InputDecoration(labelText: 'Search trails', hintText: 'Name or route', suffixIcon: _search.text.isEmpty ? null : IconButton(
          tooltip: 'Clear trail search', onPressed: () => setState(_search.clear), icon: const Icon(Icons.close, size: 18),
        )),
        onChanged: (_) => setState(() {}),
      )),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8), child: Wrap(spacing: 8, children: [
        ChoiceChip(label: const Text('Recent'), selected: !_kept, onSelected: (_) => setState(() => _kept = false)),
        ChoiceChip(label: const Text('Kept'), selected: _kept, onSelected: (_) => setState(() => _kept = true)),
      ])),
      const Divider(height: 1, color: Tok.rule),
      Expanded(child: FutureBuilder<List<TrailSummaryDto>>(future: _trails, builder: (_, snapshot) => _results(snapshot))),
    ])),
  );
}
