import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bridge.dart';
import '../core/query_filters.dart';
import '../core/when.dart';
import '../draw/histogram_header.dart';
import '../theme/action_target.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';
import 'add_folder.dart';
import 'facet_browser.dart';
import 'pane.dart';
import 'row_menu.dart';
import 'track_row.dart';

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

  /// The row the last click played, so a double click plays it once.
  int? _clicked;
  final _click = ClickOnce();
  late bool _filtersExpanded = !queryClauses(widget.query).any((clause) => clause.field == null);

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
    _click.dispose();
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

  /// A click on a row: a track plays from there in the order shown, and a
  /// release heading opens its release.
  void _tap(int index, ItemDto? item) {
    if (item == null) return;
    _select(index);
    if (item is ItemDto_Group) {
      _follow(item);
      return;
    }
    final again = _clicked == index;
    _clicked = index;
    if (_click.take() || !again) _play(index);
  }

  Future<void> _queueAt(int index, {required bool next}) async {
    final generation = _generation;
    final item = await _itemAt(index, generation);
    if (!mounted || generation != _generation || item == null) return;
    await queueAndSay(context, () => switch (item) {
      ItemDto_Group(:final field0) => widget.core.queueRelease(field0.releaseId, next: next),
      ItemDto_Track(:final row) => widget.core.queueTracks([row.trackId], next: next),
    }, next: next);
  }

  Future<void> _revealAt(int index) async {
    final item = await _itemAt(index, _generation);
    if (item case ItemDto_Track(:final row) when row.path != null) await revealInFinder(row.path!);
  }

  /// A row's menu: the play verbs, then its release and artist, then its file.
  List<RowAction?> _actions(int index, ItemDto? item) {
    if (item == null) return const [];
    final (release, person, name, path) = switch (item) {
      ItemDto_Group(:final field0) => (field0.title, field0.albumArtistId, field0.albumArtist, null),
      ItemDto_Track(:final row) => (row.album, row.artistId, row.artist, row.path),
    };
    return musicActions(
      play: () => _play(index),
      playNext: () => _queueAt(index, next: true),
      addToQueue: () => _queueAt(index, next: false),
      goTo: widget.onFollow == null ? const [] : [
        RowAction('Go to $release', () => _follow(item), shortcut: RowKeys.open),
        if (person != null && name != null && name.isNotEmpty) RowAction('Go to $name', () => _follow(item, artist: true)),
      ],
      reveal: path == null ? null : () => revealInFinder(path),
    );
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_selected case final selected?) {
      final handled = RowKeys.handle(event,
        play: () => _play(selected),
        playNext: () => _queueAt(selected, next: true),
        addToQueue: () => _queueAt(selected, next: false),
        open: () => _open(selected),
        reveal: () => _revealAt(selected),
      );
      if (handled == KeyEventResult.handled) return handled;
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

  /// The range a single filter on [field] applies, else the span the bins cover.
  String _span(String field, double lo, double hi) {
    final (from, to) = queryNumberBounds(widget.query, field, lo, hi) ?? (lo, hi);
    return '${_signed(from)}–${_signed(to)}';
  }

  static String _signed(double number) => _filterNumber(number).replaceFirst('-', '−');

  String _recentSpan() {
    final days = queryRecentDays(widget.query);
    return days == null || days == 365 ? '1 year ago–now' : '${_count(days, 'day')} ago–now';
  }

  @override
  Widget build(BuildContext context) {
    // A library with no music has no results to wait for: the one thing to do is add some.
    if (widget.tracks == BigInt.zero && !widget.scanning) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Library is empty', style: Tok.body),
        const SizedBox(height: 12),
        PaneActions(primary: 'Add folder', onPrimary: _adding ? null : _addFolder, primaryKey: const ValueKey('table-add-folder')),
        if (_actionError != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_actionError!, style: Tok.label.copyWith(color: Tok.warn))),
      ]));
    }
    final light = Light.of(context);
    final clauses = queryClauses(widget.query);
    final filters = clauses.indexed.where((entry) => entry.$2.field != null).toList();
    return Focus(
      focusNode: _focus,
      onKeyEvent: _key,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          TextButton.icon(
            key: const ValueKey('table-filters-toggle'),
            onPressed: () => setState(() => _filtersExpanded = !_filtersExpanded),
            icon: Icon(_filtersExpanded ? Icons.expand_less : Icons.expand_more, size: 16),
            label: Text(_filtersExpanded ? 'Hide filters' : 'Show filters'),
          ),
          for (final (index, clause) in filters) InputChip(
            key: ValueKey('table-filter-$index'),
            label: Text(clause.text, style: Tok.label),
            tooltip: clause.text,
            deleteButtonTooltipMessage: 'Remove ${clause.text}',
            onDeleted: () => widget.onQuery(removeQueryClause(widget.query, index)),
            visualDensity: VisualDensity.compact,
            backgroundColor: Tok.sky,
            side: const BorderSide(color: Tok.rule),
          ),
          if (filters.isNotEmpty) TextButton(
            key: const ValueKey('table-clear-filters'),
            onPressed: () => widget.onQuery(clearQueryFilters(widget.query)),
            child: const Text('Clear filters'),
          ),
        ]),
        if (_filtersExpanded) ...[
        FacetBrowser(facets: _facets, onQuery: widget.onQuery),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: HistogramHeader(label: 'Year', range: _span('year', 1950, 2026), selection: queryNumberRange(widget.query, 'year', 1950, 2026), bins: _year?.bins ?? Uint32List(0), onBrush: (r) => _brush('year', r, 1950, 2026), onSetRange: () => _editRange('year', 'Year', 1950, 2026))),
          const SizedBox(width: 16),
          Expanded(child: HistogramHeader(label: 'Last played', range: _recentSpan(), selection: queryRecentRange(widget.query), bins: _last?.bins ?? Uint32List(0), onBrush: _brushRecent, onSetRange: () => _editRange('last', 'Last played', 0, 365))),
          const SizedBox(width: 16),
          Expanded(child: HistogramHeader(key: const ValueKey('table-dr-histogram'), label: 'DR', range: _span('dr', 0, 30), selection: queryNumberRange(widget.query, 'dr', 0, 30), bins: _dr?.bins ?? Uint32List(0), onBrush: (r) => _brush('dr', r, 0, 30), onSetRange: () => _editRange('dr', 'DR', 0, 30))),
          const SizedBox(width: 16),
          Expanded(child: HistogramHeader(key: const ValueKey('table-lufs-histogram'), label: 'LUFS', range: _span('lufs', -60, 0), selection: queryNumberRange(widget.query, 'lufs', -60, 0), bins: _loudness?.bins ?? Uint32List(0), onBrush: (r) => _brush('lufs', r, -60, 0), onSetRange: () => _editRange('lufs', 'LUFS', -60, 0))),
        ]),
        ],
        const Divider(color: Tok.line, height: 16),
        Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(_total == null && _rowsError == null ? 'Loading results…' : '${_count(_releases, 'release')} · ${_count(_tracks, 'track')} · sorted by $_sortName', style: Tok.label),
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
              : _total == 0
                      ? Center(child: Text(widget.scanning ? 'Scanning…' : 'No matching tracks', style: Tok.label))
                      : LayoutBuilder(builder: (context, box) {
                          final shown = _shownColumns(box.maxWidth);
                          return Column(children: [
                              // The headers keep the rows' edge and inset, so the columns line up.
                              Padding(
                                padding: const EdgeInsets.only(left: RowBox.edgeWidth + RowBox.inset),
                                child: SizedBox(height: _row, child: _headers(shown)),
                              ),
                              Expanded(child: ListView.builder(
                                key: const ValueKey('table-rows'), controller: _scroll,
                                itemExtent: _row, itemCount: _total ?? 1,
                                itemBuilder: (_, i) {
                                  final item = _lookup(i);
                                  final playing = item is ItemDto_Track && item.row.trackId.toInt() == light.track;
                                  final selected = _selected == i;
                                  return Door(
                                    key: ValueKey('table-row-$i'),
                                    enabled: item != null,
                                    builder: (context, hover) => RowMenu(
                                      onOpen: () => _select(i),
                                      actions: () => _actions(i, item),
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () => _tap(i, item),
                                        child: Container(
                                          padding: const EdgeInsets.only(left: RowBox.inset),
                                          decoration: BoxDecoration(
                                            color: playing ? light.wash : selected ? Tok.pick : hover ? Tok.panel2 : Colors.transparent,
                                            border: Border(left: BorderSide(color: playing ? light.accent : Colors.transparent, width: RowBox.edgeWidth), bottom: const BorderSide(color: Tok.line)),
                                          ),
                                          child: item == null
                                              ? const Align(alignment: Alignment.centerLeft, child: Text('…', style: Tok.label))
                                              : _columns(item, shown, playing: playing, hover: hover, light: light),
                                        ),
                                      ),
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
      key: onTap == null ? key : null,
      padding: const EdgeInsets.only(right: 8),
      child: Text(text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    if (onTap == null) return label;
    return Semantics(
      key: key, button: true,
      child: MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: label)),
    );
  }

  /// The fixed columns that fit beside a readable title and artist, giving
  /// way from the right: LUFS first, then DR, Format and Year. # and
  /// Length always stay.
  Set<_Col> _shownColumns(double width) {
    final shown = {..._Col.values}..remove(_Col.go);
    final flex = _view.group ? 300.0 : 460.0;
    double fixed() => shown.fold(widget.onFollow == null ? 0.0 : _Col.go.width, (sum, col) => sum + col.width);
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
      if (widget.onFollow != null) SizedBox(width: _Col.go.width),
    ]);
  }

  String _length(BigInt? ms) => ms == null ? '' : clockLength(ms.toInt());

  /// As the release page numbers its tracks: `2-01` on a release with several discs, `01` on one.
  static String _trackNumber(TrackRowDto row, int discs) {
    final number = row.number.toString().padLeft(2, '0');
    return discs > 1 ? '${row.disc}-$number' : number;
  }

  /// One row's cells. Nothing in a row takes a click for itself but the
  /// arrow at its end, which opens the release: a track row plays, a release
  /// heading opens, and the artist is in the row's menu.
  Widget _columns(ItemDto item, Set<_Col> shown, {required bool playing, required bool hover, required Light light}) {
    final group = item is ItemDto_Group ? item.field0 : null;
    final row = item is ItemDto_Track ? item.row : null;
    final artist = group?.albumArtist ?? (_view.group && row?.artist == row?.albumArtist ? '' : row?.artist ?? '');
    final person = group?.albumArtistId ?? row?.artistId;
    final release = TargetDto.release(id: group?.releaseId ?? row!.releaseId);
    final title = group == null
        ? _cell(row!.title, Tok.body.copyWith(color: playing ? light.accent : Tok.ink))
        : Row(children: [
            SizedBox(width: 18, height: 18, child: group.cover == null
                ? const ColoredBox(color: Tok.rule)
                : Image.file(File(group.cover!), cacheWidth: (18 * MediaQuery.devicePixelRatioOf(context)).ceil(), fit: BoxFit.cover)),
            const SizedBox(width: 10),
            Expanded(child: TrailRow(target: release, child: _cell(group.title, Tok.body.copyWith(fontWeight: FontWeight.w600),
              key: ValueKey('table-release-${group.releaseId}')))),
            // The count takes what it needs, up to a cap, and the title the rest.
            ConstrainedBox(constraints: const BoxConstraints(maxWidth: 80), child: _cell(_count(group.tracks, 'track'), Tok.label)),
          ]);
    // The number gives way to what a click on a track does.
    final lead = row != null && (hover || playing)
        ? Align(alignment: Alignment.centerLeft, child: Icon(Icons.play_arrow, size: 14, color: playing ? light.accent : Tok.ink))
        : _cell(group != null || row!.number == 0 ? '' : _trackNumber(row, (item as ItemDto_Track).discs), Tok.monoSmall);
    return Row(children: [
      SizedBox(width: _Col.number.width, child: lead),
      Expanded(flex: 4, child: title),
      Expanded(flex: 3, child: _went(person == null || artist.isEmpty ? null : TargetDto.person(id: person), _cell(artist, Tok.body.copyWith(color: Tok.muted),
        key: group != null ? ValueKey('table-group-artist-${group.releaseId}') : ValueKey('table-artist-${row!.trackId}')))),
      if (!_view.group) Expanded(flex: 4, child: TrailRow(target: release, child: _cell(row!.album, Tok.body.copyWith(color: Tok.muted),
        key: ValueKey('table-album-${row.trackId}')))),
      if (shown.contains(_Col.year)) SizedBox(width: _Col.year.width, child: _cell(group != null ? '${group.year ?? ''}' : _view.group ? '' : '${row!.year ?? ''}', Tok.monoSmall)),
      SizedBox(width: _Col.length.width, child: _cell(_length(group?.lengthMs ?? row?.lengthMs), Tok.monoSmall)),
      if (shown.contains(_Col.format)) SizedBox(width: _Col.format.width, child: _cell(group?.format ?? row!.format, Tok.monoSmall)),
      if (shown.contains(_Col.dr)) SizedBox(width: _Col.dr.width, child: _cell('${row?.dr ?? ''}', Tok.monoSmall)),
      if (shown.contains(_Col.lufs)) SizedBox(width: _Col.lufs.width, child: _cell(row?.loudness?.toStringAsFixed(1) ?? '', Tok.monoSmall)),
      if (widget.onFollow != null) SizedBox(
        width: _Col.go.width,
        // A heading is a door and says so; a track's way to its release waits for the pointer.
        child: group != null || hover ? _GoTo(
          key: group != null ? ValueKey('table-go-release-${group.releaseId}') : ValueKey('table-go-track-${row!.trackId}'),
          target: release, label: group?.title ?? row!.album, hover: hover, onTap: () => _follow(item),
        ) : null,
      ),
    ]);
  }

  Widget _went(TargetDto? target, Widget cell) => target == null ? cell : TrailRow(target: target, child: cell);

  Future<void> _editRange(String field, String label, double minimum, double maximum) async {
    final bounds = queryNumberBounds(widget.query, field, minimum, maximum) ?? (minimum, maximum);
    final clause = await showDialog<String>(context: context, builder: (_) => _FilterRangeDialog(
      field: field, label: label,
      minimum: field == 'last' ? '${queryRecentDays(widget.query) ?? 30}' : _filterNumber(bounds.$1),
      maximum: _filterNumber(bounds.$2),
      hasFilter: queryClauses(widget.query).any((clause) => clause.field == field),
    ));
    if (!mounted || clause == null) return;
    widget.onQuery(replaceQueryField(widget.query, field, clause.isEmpty ? null : clause));
  }

  /// Keeps a brushed range in this pane's local query.
  void _brush(String key, (double, double)? r, double lo, double hi) {
    if (r == null) return widget.onQuery(replaceQueryField(widget.query, key, null));
    final a = (lo + r.$1 * (hi - lo)).round(), b = (lo + r.$2 * (hi - lo)).round();
    widget.onQuery(replaceQueryField(widget.query, key, '$key:$a..$b'));
  }

  void _brushRecent((double, double)? r) {
    if (r == null) return widget.onQuery(replaceQueryField(widget.query, 'last', null));
    final days = ((1 - r.$1) * 365).ceil().clamp(1, 365);
    widget.onQuery(replaceQueryField(widget.query, 'last', 'last:${days}d'));
  }
}

String _filterNumber(double number) => number == number.roundToDouble() ? number.toStringAsFixed(0) : number.toString();

class _FilterRangeDialog extends StatefulWidget {
  const _FilterRangeDialog({required this.field, required this.label, required this.minimum, required this.maximum, required this.hasFilter});
  final String field, label, minimum, maximum;
  final bool hasFilter;

  @override
  State<_FilterRangeDialog> createState() => _FilterRangeDialogState();
}

class _FilterRangeDialogState extends State<_FilterRangeDialog> {
  late final _minimum = TextEditingController(text: widget.minimum);
  late final _maximum = TextEditingController(text: widget.maximum);
  final _minimumFocus = FocusNode();
  final _maximumFocus = FocusNode();
  String? _error;

  @override
  void dispose() {
    _minimum.dispose();
    _maximum.dispose();
    _minimumFocus.dispose();
    _maximumFocus.dispose();
    super.dispose();
  }

  /// Shows what's wrong and keeps the cursor in the field to fix; Enter and the
  /// button both leave focus elsewhere first.
  void _fail(String message, FocusNode field) {
    setState(() => _error = message);
    field.requestFocus();
  }

  void _apply() {
    if (widget.field == 'last') {
      final days = int.tryParse(_minimum.text.trim());
      if (days == null || days < 1 || days > 4294967295) {
        _fail('Enter a whole number of days greater than zero.', _minimumFocus);
        return;
      }
      Navigator.pop(context, 'last:${days}d');
      return;
    }
    final minimum = double.tryParse(_minimum.text.trim());
    final maximum = double.tryParse(_maximum.text.trim());
    if (minimum == null || maximum == null || !minimum.isFinite || !maximum.isFinite) {
      _fail('Enter a number for both ends of the range.', minimum == null || !minimum.isFinite ? _minimumFocus : _maximumFocus);
      return;
    }
    if (minimum > maximum) {
      _fail('The minimum must be less than or equal to the maximum.', _minimumFocus);
      return;
    }
    Navigator.pop(context, '${widget.field}:${_filterNumber(minimum)}..${_filterNumber(maximum)}');
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('filter-range-dialog'),
    title: Text(widget.field == 'last' ? 'Last played' : '${widget.label} range'),
    content: SizedBox(width: 320, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        key: const ValueKey('filter-minimum'),
        controller: _minimum,
        focusNode: _minimumFocus,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
        decoration: InputDecoration(labelText: widget.field == 'last' ? 'Played within this many days' : 'Minimum'),
        onSubmitted: (_) => _apply(),
      ),
      if (widget.field != 'last') ...[
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('filter-maximum'),
          controller: _maximum,
          focusNode: _maximumFocus,
          keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
          decoration: const InputDecoration(labelText: 'Maximum'),
          onSubmitted: (_) => _apply(),
        ),
      ],
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: Tok.body.copyWith(color: Tok.warn))),
    ])),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      if (widget.hasFilter) TextButton(onPressed: () => Navigator.pop(context, ''), child: const Text('Clear')),
      TextButton(onPressed: _apply, child: const Text('Apply')),
    ],
  );
}

/// The table's fixed-width columns.
enum _Col {
  number(40), year(60), length(72), format(120), dr(48), lufs(64), go(28);

  const _Col(this.width);
  final double width;
}

/// The arrow at a table row's end: opens the row's release.
class _GoTo extends StatelessWidget {
  const _GoTo({super.key, required this.target, required this.label, required this.hover, required this.onTap});
  final TargetDto target;
  final String label;
  final bool hover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Go to $label',
    waitDuration: const Duration(milliseconds: 500),
    excludeFromSemantics: true,
    child: ActionTarget(
      onTap: onTap,
      semanticLabel: 'Go to $label',
      excludeChildSemantics: true,
      child: Center(child: ThreadArrow(target: target, hover: hover)),
    ),
  );
}
