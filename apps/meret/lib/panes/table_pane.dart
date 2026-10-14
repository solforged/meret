import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bridge.dart';
import '../draw/histogram_header.dart';
import '../theme/tokens.dart';

/// iTunes' one big table as a pane (plate 04). Numeric headers are
/// histograms you brush; rows are virtual with a fixed extent, fetched from
/// the core in pages as they scroll into view.
class TablePane extends StatefulWidget {
  const TablePane({super.key, required this.core, required this.query, required this.onQuery, this.libraryVersion, this.tracks, this.scanning = false});

  final CoreBridge core;
  final String query;
  final ValueChanged<String> onQuery;
  final BigInt? libraryVersion;
  final BigInt? tracks;
  final bool scanning;

  @override
  State<TablePane> createState() => _TablePaneState();
}

class _TablePaneState extends State<TablePane> {
  static const _row = 26.0;
  static const _pageSize = 100;
  static const _cacheSize = 20;
  final _pages = <int, RowsDto>{};
  final _pending = <int>{};
  final _focus = FocusNode();
  final _scroll = ScrollController();
  HistogramDto? _last;
  HistogramDto? _year;
  int _generation = 0;
  int? _total;
  int? _selected;
  String? _rowsError;
  String? _actionError;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(TablePane old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query || old.libraryVersion != widget.libraryVersion || old.core != widget.core) {
      _generation++;
      _pages.clear();
      _pending.clear();
      _total = null;
      _selected = null;
      _rowsError = null;
      _actionError = null;
      _last = null;
      _year = null;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _load();
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = _generation;
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    try {
      final results = await Future.wait([
        widget.core.histogram(ColumnDto.lastPlayed, widget.query, now - 365 * 86400, now, 52),
        widget.core.histogram(ColumnDto.year, widget.query, 1950, 2026, 76),
      ]);
      if (!mounted || generation != _generation) return;
      setState(() {
        _last = results[0];
        _year = results[1];
      });
    } catch (_) {
      // Rows report query errors. A missing histogram leaves its header quiet.
    }
  }

  TrackRowDto? _lookup(int index) {
    final page = index ~/ _pageSize;
    final cached = _pages.remove(page);
    if (cached != null) {
      _pages[page] = cached;
      final offset = index - cached.offset.toInt();
      return offset >= 0 && offset < cached.rows.length ? cached.rows[offset] : null;
    }
    if (_pending.add(page)) {
      final generation = _generation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _generation) _fetch(page, generation);
      });
    }
    return null;
  }

  Future<void> _fetch(int page, int generation) async {
    try {
      final result = await widget.core.rows(widget.query, page * _pageSize, _pageSize);
      if (!mounted || generation != _generation) return;
      setState(() {
        _pending.remove(page);
        _total = result.total.toInt();
        _pages[page] = result;
        while (_pages.length > _cacheSize) {
          _pages.remove(_pages.keys.first);
        }
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _pending.remove(page);
        _rowsError = error.toString();
      });
    }
  }

  Future<void> _addFolder() async {
    setState(() {
      _adding = true;
      _actionError = null;
    });
    try {
      final path = await getDirectoryPath();
      if (path != null && mounted) await widget.core.addRoot(path);
    } catch (error) {
      if (mounted) setState(() => _actionError = error.toString());
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  void _select(int index) {
    _focus.requestFocus();
    setState(() => _selected = index);
  }

  Future<void> _play(int index) async {
    _select(index);
    try {
      await widget.core.playResults(widget.query, index);
    } catch (error) {
      if (mounted) setState(() => _actionError = error.toString());
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter && _selected != null) {
      _play(_selected!);
      return KeyEventResult.handled;
    }
    final delta = event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : event.logicalKey == LogicalKeyboardKey.arrowUp ? -1 : 0;
    if (delta == 0 || (_total ?? 0) == 0) return KeyEventResult.ignored;
    final index = _selected == null ? 0 : (_selected! + delta).clamp(0, _total! - 1);
    _select(index);
    if (_scroll.hasClients) {
      final top = index * _row;
      final bottom = top + _row - _scroll.position.viewportDimension;
      final offset = top < _scroll.offset ? top : bottom > _scroll.offset ? bottom : _scroll.offset;
      _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final emptyLibrary = widget.tracks == BigInt.zero && !widget.scanning;
    return Focus(
      focusNode: _focus,
      onKeyEvent: _key,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
        Row(children: [
          Expanded(child: Text('${_total ?? 0} rows', style: Tok.label)),
          TextButton(onPressed: _adding ? null : _addFolder, child: const Text('+ Add folder', style: Tok.label)),
        ]),
        if (_actionError != null) Text(_actionError!, style: Tok.label.copyWith(color: Tok.warn)),
        Expanded(
          child: _rowsError != null
              ? Align(alignment: Alignment.topLeft, child: Text(_rowsError!, style: Tok.body.copyWith(color: Tok.warn)))
              : emptyLibrary
                  ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text('Add your music to the library.', style: Tok.body),
                      TextButton(onPressed: _adding ? null : _addFolder, child: const Text('Add a music folder', style: Tok.body)),
                    ]))
                  : _total == 0
                      ? Center(child: Text(widget.scanning ? 'Scanning music folders.' : 'No matching tracks.', style: Tok.label))
                      : LayoutBuilder(builder: (context, box) => SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: math.max(720, box.maxWidth),
                            height: box.maxHeight,
                            child: Column(children: [
                              SizedBox(height: _row, child: _columns(null, header: true)),
                              Expanded(child: ListView.builder(
                                key: const ValueKey('table-rows'),
                                controller: _scroll,
                                itemExtent: _row,
                                itemCount: _total ?? 1,
                                itemBuilder: (_, i) {
                                  final row = _lookup(i);
                                  return Listener(
                                    key: ValueKey('table-row-$i'),
                                    behavior: HitTestBehavior.opaque,
                                    onPointerDown: (_) => _select(i),
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onDoubleTap: () => _play(i),
                                      child: ColoredBox(
                                        color: _selected == i ? Tok.panel2 : Colors.transparent,
                                        child: row == null
                                            ? const Align(alignment: Alignment.centerLeft, child: Text('…', style: Tok.label))
                                            : _columns(row),
                                      ),
                                    ),
                                  );
                                },
                              )),
                            ]),
                          ),
                        )),
        ),
      ]),
    );
  }

  Widget _columns(TrackRowDto? row, {bool header = false}) {
    final seconds = row?.lengthMs?.toInt();
    final length = seconds == null ? '' : '${seconds ~/ 60000}:${(seconds ~/ 1000 % 60).toString().padLeft(2, '0')}';
    Widget cell(String text, TextStyle style) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Text(text, style: header ? Tok.label : style, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    return Row(children: [
      SizedBox(width: 36, child: cell(header ? '#' : (row!.number == 0 ? '' : '${row.number}'), Tok.monoSmall)),
      Expanded(flex: 4, child: cell(header ? 'Title' : row!.title, Tok.body)),
      Expanded(flex: 3, child: cell(header ? 'Artist' : row!.artist ?? '', Tok.body)),
      Expanded(flex: 4, child: cell(header ? 'Album' : row!.album, Tok.body)),
      SizedBox(width: 48, child: cell(header ? 'Year' : '${row!.year ?? ''}', Tok.monoSmall)),
      SizedBox(width: 56, child: cell(header ? 'Length' : length, Tok.monoSmall)),
      SizedBox(width: 100, child: cell(header ? 'Format' : row!.format, Tok.monoSmall)),
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
