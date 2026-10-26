import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bridge.dart';
import '../core/when.dart';
import '../draw/histogram_header.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';
import 'add_folder.dart';
import 'facet_browser.dart';
import 'pane.dart';

/// iTunes' one big table as a pane (plate 04). The core orders and groups
/// rows; the fixed-extent list fetches pages as they scroll into view.
class TablePane extends StatefulWidget {
  const TablePane({super.key, required this.core, required this.query, required this.onQuery, this.onFollow, this.libraryVersion, this.tracks, this.scanning = false});

  final CoreBridge core;
  final String query;
  final ValueChanged<String> onQuery;
  /// Opens a row's release or artist: a hit of this search, so the thread
  /// is the search's own.
  final Future<void> Function(TargetDto)? onFollow;
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
  final _requests = <int, Future<RowsDto?>>{};
  final _focus = FocusNode();
  final _scroll = ScrollController();
  ViewDto _view = const ViewDto(sort: SortKeyDto.library_, descending: false, group: true);
  FacetsDto? _facets;
  HistogramDto? _last;
  HistogramDto? _year;
  HistogramDto? _dr;
  HistogramDto? _loudness;
  int _generation = 0;
  int? _total;
  int _tracks = 0;
  int _releases = 0;
  int? _selected;
  String? _rowsError;
  String? _actionError;
  bool _adding = false;
  (int, Duration)? _lastDown;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(TablePane old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query || old.libraryVersion != widget.libraryVersion || old.core != widget.core) _reset();
  }

  void _reset() {
    _generation++;
    _pages.clear();
    _pending.clear();
    _requests.clear();
    _total = null;
    _tracks = 0;
    _releases = 0;
    _selected = null;
    _rowsError = null;
    _actionError = null;
    _facets = null;
    _last = null;
    _year = null;
    _dr = null;
    _loudness = null;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
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
    await Future.wait([
      () async {
        try {
          final facets = await widget.core.facets(widget.query);
          if (mounted && generation == _generation) setState(() => _facets = facets);
        } catch (_) {
          // Rows report query errors; a missing browser stays quiet.
        }
      }(),
      () async {
        try {
          final results = await Future.wait([
            widget.core.histogram(ColumnDto.lastPlayed, widget.query, now - 365 * 86400, now, 52),
            widget.core.histogram(ColumnDto.year, widget.query, 1950, 2026, 76),
            widget.core.histogram(ColumnDto.dr, widget.query, 0, 30, 30),
            widget.core.histogram(ColumnDto.loudness, widget.query, -60, 0, 60),
          ]);
          if (!mounted || generation != _generation) return;
          setState(() {
            _last = results[0];
            _year = results[1];
            _dr = results[2];
            _loudness = results[3];
          });
        } catch (_) {
          // A missing histogram leaves its header quiet.
        }
      }(),
    ]);
  }

  ItemDto? _cached(int index) {
    final page = _pages[index ~/ _pageSize];
    if (page == null) return null;
    final offset = index - page.offset.toInt();
    return offset >= 0 && offset < page.items.length ? page.items[offset] : null;
  }

  ItemDto? _lookup(int index) {
    final page = index ~/ _pageSize;
    final cached = _pages.remove(page);
    if (cached != null) {
      _pages[page] = cached;
      return _cached(index);
    }
    if (_pending.add(page)) {
      final generation = _generation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _generation) _fetch(page, generation);
      });
    }
    return null;
  }

  Future<RowsDto?> _fetch(int page, int generation) {
    return _requests[page] ??= () async {
      try {
        final result = await widget.core.rows(widget.query, _view, page * _pageSize, _pageSize);
        if (!mounted || generation != _generation) return null;
        setState(() {
          _pending.remove(page);
          _requests.remove(page);
          _total = result.total.toInt();
          _tracks = result.tracks.toInt();
          _releases = result.releases.toInt();
          _pages[page] = result;
          while (_pages.length > _cacheSize) {
            _pages.remove(_pages.keys.first);
          }
        });
        return result;
      } catch (error) {
        if (!mounted || generation != _generation) return null;
        setState(() {
          _pending.remove(page);
          _requests.remove(page);
          _rowsError = error.toString();
        });
        return null;
      }
    }();
  }

  Future<ItemDto?> _itemAt(int index, int generation) async {
    final cached = _cached(index);
    if (cached != null) return cached;
    await _fetch(index ~/ _pageSize, generation);
    return mounted && generation == _generation ? _cached(index) : null;
  }

  Future<void> _addFolder() async {
    setState(() {
      _adding = true;
      _actionError = null;
    });
    try {
      await addMusicFolder(widget.core, isMounted: () => mounted);
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
    final generation = _generation;
    final item = await _itemAt(index, generation);
    final track = item is ItemDto_Group ? await _itemAt(index + 1, generation) : item;
    if (!mounted || generation != _generation || track is! ItemDto_Track) return;
    try {
      await widget.core.playResults(widget.query, _view, track.ordinal);
    } catch (error) {
      if (mounted) setState(() => _actionError = error.toString());
    }
  }

  Future<void> _follow(ItemDto item, {bool artist = false}) async {
    final onFollow = widget.onFollow;
    if (onFollow == null) return;
    final (release, person) = switch (item) {
      ItemDto_Group(:final field0) => (field0.releaseId, field0.albumArtistId),
      ItemDto_Track(:final row) => (row.releaseId, row.artistId),
    };
    if (artist && person == null) return;
    try {
      await onFollow(artist ? TargetDto.person(id: person!) : TargetDto.release(id: release));
    } catch (error) {
      if (mounted) setState(() => _actionError = error.toString());
    }
  }

  Future<void> _open(int index) async {
    final generation = _generation;
    final item = await _itemAt(index, generation);
    if (mounted && generation == _generation && item != null) await _follow(item);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter && _selected != null) {
      if (HardwareKeyboard.instance.isMetaPressed) {
        _open(_selected!);
      } else {
        _play(_selected!);
      }
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

  void _sort(SortKeyDto sort) {
    setState(() {
      final same = _view.sort == sort;
      _view = ViewDto(
        sort: same && _view.descending ? SortKeyDto.library_ : sort,
        descending: sort != SortKeyDto.library_ && same && !_view.descending,
        group: _view.group,
      );
      _reset();
    });
  }

  void _group(bool group) {
    if (_view.group == group) return;
    setState(() {
      _view = ViewDto(sort: _view.sort, descending: _view.descending, group: group);
      _reset();
    });
  }

  String get _sortName => _view.sort == SortKeyDto.library_
      ? 'library order'
      : '${_view.sort.name}, ${_view.descending ? 'descending' : 'ascending'}';

  static String _count(int n, String noun) => '$n ${n == 1 ? noun : '${noun}s'}';

  @override
  Widget build(BuildContext context) {
    final emptyLibrary = widget.tracks == BigInt.zero && !widget.scanning;
    final light = Light.of(context);
    return Focus(
      focusNode: _focus,
      onKeyEvent: _key,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FacetBrowser(facets: _facets, onQuery: widget.onQuery),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: HistogramHeader(label: 'Year', range: '1950–2026', bins: _year?.bins ?? Uint32List(0), onBrush: (r) => _brush('year', r, 1950, 2026))),
          const SizedBox(width: 16),
          Expanded(child: HistogramHeader(label: 'Last played', range: 'year ago–now', bins: _last?.bins ?? Uint32List(0), onBrush: _brushRecent)),
          const SizedBox(width: 16),
          Expanded(child: HistogramHeader(key: const ValueKey('table-dr-histogram'), label: 'DR', range: '0–30', bins: _dr?.bins ?? Uint32List(0), onBrush: (r) => _brush('dr', r, 0, 30))),
          const SizedBox(width: 16),
          Expanded(child: HistogramHeader(key: const ValueKey('table-lufs-histogram'), label: 'LUFS', range: '−60–0', bins: _loudness?.bins ?? Uint32List(0), onBrush: (r) => _brush('lufs', r, -60, 0))),
        ]),
        const Divider(color: Tok.line, height: 16),
        Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('${_count(_releases, 'release')} · ${_count(_tracks, 'track')} · sorted by $_sortName', style: Tok.label),
          Row(mainAxisSize: MainAxisSize.min, children: [
            const Text('Group: ', style: Tok.label),
            DecoratedBox(decoration: BoxDecoration(border: Border.all(color: Tok.rule)), child: Row(mainAxisSize: MainAxisSize.min, children: [
              _segment('Release', true),
              _segment('None', false),
            ])),
          ]),
        ]),
        if (_actionError != null) Text(_actionError!, style: Tok.label.copyWith(color: Tok.warn)),
        Expanded(
          child: _rowsError != null
              ? Align(alignment: Alignment.topLeft, child: Text(_rowsError!, style: Tok.body.copyWith(color: Tok.warn)))
              : emptyLibrary
                  ? Center(child: TextButton(onPressed: _adding ? null : _addFolder, child: const Text('Add a music folder', style: Tok.body)))
                  : _total == 0
                      ? Center(child: Text(widget.scanning ? 'Scanning…' : 'No matching tracks', style: Tok.label))
                      : LayoutBuilder(builder: (context, box) {
                          final shown = _shownColumns(box.maxWidth);
                          return Column(children: [
                              SizedBox(height: _row, child: _headers(shown)),
                              Expanded(child: ListView.builder(
                                key: const ValueKey('table-rows'), controller: _scroll,
                                itemExtent: _row, itemCount: _total ?? 1,
                                itemBuilder: (_, i) {
                                  final item = _lookup(i);
                                  final playing = item is ItemDto_Track && item.row.trackId.toInt() == light.track;
                                  // A double click is counted here, not by a gesture
                                  // recognizer: one would hold every single click on a
                                  // title or artist for the double-tap timeout.
                                  return Listener(
                                    key: ValueKey('table-row-$i'), behavior: HitTestBehavior.opaque,
                                    onPointerDown: (event) => _down(i, event.timeStamp),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: playing ? light.wash : _selected == i ? Tok.panel2 : Colors.transparent,
                                        border: Border(left: BorderSide(color: playing ? light.accent : Colors.transparent, width: 2), bottom: const BorderSide(color: Tok.line)),
                                      ),
                                      child: item == null
                                          ? const Align(alignment: Alignment.centerLeft, child: Text('…', style: Tok.label))
                                          : _columns(item, shown, playing: playing, light: light),
                                    ),
                                  );
                                },
                              )),
                            ]);
                        }),
        ),
      ]),
    );
  }

  Widget _segment(String text, bool group) => Semantics(
    button: true, selected: _view.group == group,
    child: GestureDetector(
      key: ValueKey('table-group-$group'), behavior: HitTestBehavior.opaque,
      onTap: () => _group(group),
      child: Container(
        color: _view.group == group ? const Color(0x14D2A64E) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(text, style: Tok.label.copyWith(color: _view.group == group ? Tok.gold : Tok.faint)),
      ),
    ),
  );

  Widget _cell(String text, TextStyle style, {Key? key, VoidCallback? onTap}) {
    final label = Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Text(text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    if (onTap == null) return label;
    return Semantics(
      key: key, button: true,
      child: MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: label)),
    );
  }

  void _down(int index, Duration at) {
    final last = _lastDown;
    _lastDown = (index, at);
    _select(index);
    if (last != null && last.$1 == index && at - last.$2 <= kDoubleTapTimeout) {
      _lastDown = null;
      _play(index);
    }
  }

  /// The fixed columns that fit beside a readable title and artist, giving
  /// way from the right: LUFS first, then DR, Format and Year. # and
  /// Length always stay.
  Set<_Col> _shownColumns(double width) {
    final shown = {..._Col.values};
    final flex = _view.group ? 300.0 : 460.0;
    double fixed() => shown.fold(0.0, (sum, col) => sum + col.width);
    for (final col in const [_Col.lufs, _Col.dr, _Col.format, _Col.year]) {
      if (fixed() + flex <= width) break;
      shown.remove(col);
    }
    return shown;
  }

  Widget _headers(Set<_Col> shown) {
    Widget header(String name, SortKeyDto sort) => _cell(
      '$name${_view.sort == sort ? _view.descending ? ' ↓' : ' ↑' : ''}',
      Tok.label.copyWith(color: _view.sort == sort ? Tok.gold : Tok.faint),
      key: ValueKey('table-sort-${sort.name}'), onTap: () => _sort(sort),
    );
    return Row(children: [
      SizedBox(width: _Col.number.width, child: header('#', SortKeyDto.library_)),
      Expanded(flex: 4, child: header('Title', SortKeyDto.title)),
      Expanded(flex: 3, child: header('Artist', SortKeyDto.artist)),
      if (!_view.group) Expanded(flex: 4, child: header('Album', SortKeyDto.album)),
      if (shown.contains(_Col.year)) SizedBox(width: _Col.year.width, child: header('Year', SortKeyDto.year)),
      SizedBox(width: _Col.length.width, child: header('Length', SortKeyDto.length)),
      if (shown.contains(_Col.format)) SizedBox(width: _Col.format.width, child: header('Format', SortKeyDto.format)),
      if (shown.contains(_Col.dr)) SizedBox(width: _Col.dr.width, child: _cell('DR', Tok.label)),
      if (shown.contains(_Col.lufs)) SizedBox(width: _Col.lufs.width, child: _cell('LUFS', Tok.label)),
    ]);
  }

  String _length(BigInt? ms) => ms == null ? '' : clockLength(ms.toInt());

  Widget _columns(ItemDto item, Set<_Col> shown, {required bool playing, required Light light}) {
    final group = item is ItemDto_Group ? item.field0 : null;
    final row = item is ItemDto_Track ? item.row : null;
    final artist = group?.albumArtist ?? (_view.group && row?.artist == row?.albumArtist ? '' : row?.artist ?? '');
    final person = group?.albumArtistId ?? row?.artistId;
    final title = group == null
        ? _cell(row!.title, Tok.body.copyWith(color: playing ? light.accent : Tok.ink))
        : Row(children: [
            SizedBox(width: 18, height: 18, child: group.cover == null
                ? const ColoredBox(color: Tok.rule)
                : Image.file(File(group.cover!), cacheWidth: (18 * MediaQuery.devicePixelRatioOf(context)).ceil(), fit: BoxFit.cover)),
            const SizedBox(width: 10),
            Expanded(child: TrailRow(target: TargetDto.release(id: group.releaseId), child: _cell(group.title, Tok.body.copyWith(fontWeight: FontWeight.w600),
              key: ValueKey('table-release-${group.releaseId}'), onTap: widget.onFollow == null ? null : () => _follow(item)))),
            Flexible(child: _cell(_count(group.tracks, 'track'), Tok.label)),
          ]);
    return Row(children: [
      SizedBox(width: _Col.number.width, child: _cell(group != null || row!.number == 0 ? '' : row.disc > 1 ? '${row.disc}-${row.number}' : '${row.number}', Tok.monoSmall)),
      Expanded(flex: 4, child: title),
      Expanded(flex: 3, child: _went(person == null || artist.isEmpty ? null : TargetDto.person(id: person), _cell(artist, Tok.body.copyWith(color: Tok.muted),
        key: group != null ? ValueKey('table-group-artist-${group.releaseId}') : ValueKey('table-artist-${row!.trackId}'),
        onTap: widget.onFollow == null || person == null || artist.isEmpty ? null : () => _follow(item, artist: true)))),
      if (!_view.group) Expanded(flex: 4, child: TrailRow(target: TargetDto.release(id: row!.releaseId), child: _cell(row.album, Tok.body.copyWith(color: Tok.muted),
        key: ValueKey('table-album-${row.trackId}'), onTap: widget.onFollow == null ? null : () => _follow(item)))),
      if (shown.contains(_Col.year)) SizedBox(width: _Col.year.width, child: _cell(group != null ? '${group.year ?? ''}' : _view.group ? '' : '${row!.year ?? ''}', Tok.monoSmall)),
      SizedBox(width: _Col.length.width, child: _cell(_length(group?.lengthMs ?? row?.lengthMs), Tok.monoSmall)),
      if (shown.contains(_Col.format)) SizedBox(width: _Col.format.width, child: _cell(group?.format ?? row!.format, Tok.monoSmall)),
      if (shown.contains(_Col.dr)) SizedBox(width: _Col.dr.width, child: _cell('${row?.dr ?? ''}', Tok.monoSmall)),
      if (shown.contains(_Col.lufs)) SizedBox(width: _Col.lufs.width, child: _cell(row?.loudness?.toStringAsFixed(1) ?? '', Tok.monoSmall)),
    ]);
  }

  Widget _went(TargetDto? target, Widget cell) => target == null ? cell : TrailRow(target: target, child: cell);

  /// Keeps a brushed range in this pane's local query.
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

/// The table's fixed-width columns.
enum _Col {
  number(40), year(60), length(72), format(120), dr(48), lufs(64);

  const _Col(this.width);
  final double width;
}
