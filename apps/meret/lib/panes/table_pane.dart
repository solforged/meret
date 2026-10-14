import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../draw/histogram_header.dart';
import '../theme/tokens.dart';

/// iTunes' one big table as a pane (plate 04). Numeric headers are
/// histograms you brush; rows are virtual with a fixed extent, fetched from
/// the core in pages as they scroll into view.
class TablePane extends StatefulWidget {
  const TablePane({super.key, required this.core, required this.query, required this.onQuery});

  final CoreBridge core;
  final String query;
  final ValueChanged<String> onQuery;

  @override
  State<TablePane> createState() => _TablePaneState();
}

class _TablePaneState extends State<TablePane> {
  static const _row = 26.0;
  HistogramDto? _last;
  HistogramDto? _year;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(TablePane old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) _load();
  }

  Future<void> _load() async {
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    final results = await Future.wait([
      widget.core.histogram(ColumnDto.lastPlayed, widget.query, now - 365 * 86400, now, 52),
      widget.core.histogram(ColumnDto.year, widget.query, 1950, 2026, 76),
    ]);
    if (!mounted) return;
    setState(() {
      _last = results[0];
      _year = results[1];
    });
  }

  @override
  Widget build(BuildContext context) {
    final rows = _last?.matched.toInt() ?? 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: HistogramHeader(
            label: 'Year',
            bins: _year?.bins ?? Uint32List(0),
            onBrush: (r) => _brush('year', r, 1950, 2026),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: HistogramHeader(
            label: 'Last played',
            bins: _last?.bins ?? Uint32List(0),
            onBrush: (r) => _brushRecent(r),
          ),
        ),
      ]),
      const Divider(color: Tok.line, height: 16),
      Text('$rows rows', style: Tok.label),
      Expanded(
        child: ListView.builder(
          itemExtent: _row,
          itemCount: rows,
          // TODO(table): fetch rows i..j from the core's list handle, in pages,
          // through a small cache; never synchronously in build.
          itemBuilder: (_, i) => Align(
            alignment: Alignment.centerLeft,
            child: Text('row $i', style: Tok.monoSmall),
          ),
        ),
      ),
    ]);
  }

  /// Writes the brushed range back as a clause, so the query line shows it.
  void _brush(String key, (double, double)? r, double lo, double hi) {
    if (r == null) return widget.onQuery('');
    final a = (lo + r.$1 * (hi - lo)).round(), b = (lo + r.$2 * (hi - lo)).round();
    widget.onQuery('$key:$a..$b');
  }

  void _brushRecent((double, double)? r) {
    if (r == null) return widget.onQuery('');
    final days = ((1 - r.$1) * 365).ceil();
    widget.onQuery('last:${days}d');
  }
}
