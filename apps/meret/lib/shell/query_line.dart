import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bridge.dart';
import '../panes/add_folder.dart';
import '../theme/tokens.dart';

/// `/`: searches everything you own, can stream or have found, and takes
/// commands. Running a search starts a new trail. It sits in the top line,
/// whose empty space moves the window.
class QueryLine extends StatefulWidget {
  const QueryLine({super.key, required this.core, required this.focus, this.onSubmit, this.onSearch, this.clearOn});

  final CoreBridge core;
  final FocusNode focus;
  final Future<void> Function(QueryDto)? onSubmit;
  final Future<void> Function(SearchDto, HitDto?)? onSearch;

  /// The app left the search for a page the draft isn't about: it empties
  /// the line each time this notifies.
  final Listenable? clearOn;

  @override
  State<QueryLine> createState() => _QueryLineState();
}

class _QueryLineState extends State<QueryLine> {
  final _text = TextEditingController();
  final _overlay = OverlayPortalController();
  final _link = LayerLink();
  final _list = ScrollController();
  final _keys = <int, GlobalKey>{};
  QueryDto? _parsed;
  SearchDto? _hits;
  String? _submitError;
  int? _highlight;
  int _generation = 0;
  bool _dismissed = false;
  bool _submitting = false;
  bool _emptyLibrary = false;
  StreamSubscription<StatusDto>? _status;
  // The line's own width, so the popup under it is exactly as wide.
  final _fieldWidth = ValueNotifier<double>(0);

  List<HitDto> get _items => [...?_hits?.people, ...?_hits?.releases, ...?_hits?.trackHits];
  bool get _showHits => widget.focus.hasFocus && !_dismissed && _hits != null && _parsed?.kind == QueryKind.search;
  // Match a bare leading verb; quoted titles and negative search terms stay searches.
  String? get _unavailableCommand => RegExp(r'^\s*(queue|want|crate)(?:\s|$)', caseSensitive: false).firstMatch(_text.text)?.group(1)?.toLowerCase();
  String? get _error {
    final command = _unavailableCommand;
    return _submitError ?? (command != null ? 'The $command command is not available yet.'
        : _parsed?.kind == QueryKind.invalid ? _parsed?.error : null);
  }
  bool get _showError => widget.focus.hasFocus && !_dismissed && _error != null;

  /// `help` is no command; when it matches nothing, the panel lists the ones there are.
  bool get _asksForHelp => _text.text.trim().toLowerCase() == 'help';

  Future<void> _addFolder() async {
    try {
      await addMusicFolder(widget.core, isMounted: () => mounted);
    } catch (error) {
      if (mounted) setState(() => _submitError = error.toString());
    }
  }

  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_focusChanged);
    widget.clearOn?.addListener(_clearDraft);
    _watchStatus();
  }

  @override
  void didUpdateWidget(QueryLine old) {
    super.didUpdateWidget(old);
    if (old.focus != widget.focus) {
      old.focus.removeListener(_focusChanged);
      widget.focus.addListener(_focusChanged);
    }
    if (old.clearOn != widget.clearOn) {
      old.clearOn?.removeListener(_clearDraft);
      widget.clearOn?.addListener(_clearDraft);
    }
    if (old.core != widget.core) {
      _watchStatus();
      _changed(_text.text);
    }
  }

  @override
  void dispose() {
    widget.focus.removeListener(_focusChanged);
    widget.clearOn?.removeListener(_clearDraft);
    _status?.cancel();
    _fieldWidth.dispose();
    _list.dispose();
    _text.dispose();
    super.dispose();
  }

  /// An empty library has nothing to match: the popup says so and offers a folder.
  void _watchStatus() {
    _status?.cancel();
    _status = widget.core.status().listen((status) {
      final empty = status.tracks == BigInt.zero && !status.jobs.any((job) => job.isScan);
      if (mounted && empty != _emptyLibrary) setState(() => _emptyLibrary = empty);
    });
  }

  void _clearDraft() {
    if (_text.text.isEmpty && _submitError == null) return;
    _text.clear();
    _changed('');
  }

  void _syncOverlay() {
    if (_showHits || _showError) {
      _overlay.show();
    } else {
      _overlay.hide();
    }
  }

  void _focusChanged() {
    if (!mounted) return;
    setState(() {
      _dismissed = !widget.focus.hasFocus;
      _highlight = null;
    });
    _syncOverlay();
  }

  void _changed(String input) {
    final generation = ++_generation;
    setState(() {
      _parsed = input.trim().isEmpty ? null : widget.core.parse(input);
      _submitError = null;
      _hits = null;
      _highlight = null;
      _dismissed = false;
    });
    _syncOverlay();
    if (_parsed?.kind != QueryKind.search) return;
    widget.core.search(input).then((hits) {
      if (!mounted || generation != _generation || _text.text != input) return;
      setState(() => _hits = hits);
      _syncOverlay();
    }).catchError((Object error) {
      if (!mounted || generation != _generation || _text.text != input) return;
      setState(() => _submitError = error.toString());
      _syncOverlay();
    });
  }

  void _move(int by) {
    if (!_showHits || (_items.isEmpty && _hits!.tracks == BigInt.zero)) return;
    final last = _items.length - (_hits!.tracks == BigInt.zero ? 1 : 0);
    setState(() => _highlight = _highlight == null ? (by > 0 ? 0 : last) : (_highlight! + by).clamp(0, last));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _highlight == null) return;
      final context = _keys[_highlight]?.currentContext;
      if (context != null) Scrollable.ensureVisible(context, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
    });
  }

  void _dismiss() {
    setState(() {
      _dismissed = true;
      _highlight = null;
    });
    _syncOverlay();
  }

  /// Escape dismisses help or suggestions, then hands focus back without
  /// discarding the draft. Clearing is an explicit action.
  void _escape() {
    if (_showHits || _showError) {
      _dismiss();
      return;
    }
    widget.focus.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
  }

  void _clear() {
    _text.clear();
    _changed('');
    widget.focus.requestFocus();
  }

  Future<void> _submit({HitDto? hit, bool all = false}) async {
    if (_submitting) return;
    final input = _text.text;
    final generation = _generation;
    final parsed = _parsed ?? widget.core.parse(input);
    if (parsed.kind == QueryKind.invalid) return;
    _submitting = true;
    try {
      if (parsed.kind == QueryKind.search && parsed.canonical.isNotEmpty) {
        final hits = _hits ?? await widget.core.search(input);
        if (!mounted || generation != _generation || _text.text != input) return;
        final items = [...hits.people, ...hits.releases, ...hits.trackHits];
        if (hits.tracks == BigInt.zero && hit == null && items.isEmpty) return;
        final selected = hit ?? (!all && _showHits && _highlight != null && _highlight! < items.length ? items[_highlight!] : null);
        await widget.onSearch?.call(hits, selected);
      } else {
        await widget.onSubmit?.call(parsed);
      }
      if (mounted && generation == _generation) {
        _dismiss();
        // Back to the surface's own focus, where `[` `]` and the other keys live.
        widget.focus.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _submitError = error.toString());
        _syncOverlay();
      }
    } finally {
      _submitting = false;
    }
  }

  Widget _dropdown(SearchDto hits) {
    var index = 0;
    Widget group(String name, BigInt total, List<HitDto> rows) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 4), child: Text('$name · $total', style: Tok.label)),
        for (final hit in rows) _hitRow(hit, index++),
      ],
    );
    return Material(
      key: const ValueKey('query-hits'),
      color: Tok.panel,
      elevation: 8,
      shape: const RoundedRectangleBorder(side: BorderSide(color: Tok.rule)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: math.min(520, math.max(100, MediaQuery.sizeOf(context).height - 100))),
        child: SingleChildScrollView(
          controller: _list,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            if (_items.isEmpty && hits.tracks == BigInt.zero)
              Padding(
                key: const ValueKey('query-no-results'),
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (_emptyLibrary) ...[
                    const Text('Library is empty', style: Tok.body),
                    TextButton(key: const ValueKey('query-add-folder'), onPressed: _addFolder, child: const Text('Add a music folder')),
                  ] else if (_asksForHelp) ...[
                    const Text('Commands', style: Tok.body),
                    const SizedBox(height: 4),
                    for (final (command, note) in const [
                      ('play <query>', 'Play matches'),
                      ('queue, want, crate', 'Coming later'),
                      ('?', 'All keys'),
                    ]) Padding(padding: const EdgeInsets.only(top: 2), child: Row(children: [
                      SizedBox(width: 140, child: Text(command, style: Tok.monoSmall)),
                      Text(note, style: Tok.label),
                    ])),
                  ] else ...[
                    const Text('No matches', style: Tok.body),
                    const SizedBox(height: 4),
                    const Text('Try fewer words or remove a filter.', style: Tok.label),
                  ],
                  TextButton(onPressed: _clear, child: const Text('Clear search')),
                ]),
              ),
            if (hits.people.isNotEmpty) group('People', hits.peopleTotal, hits.people),
            if (hits.releases.isNotEmpty) group('Releases', hits.releasesTotal, hits.releases),
            if (hits.trackHits.isNotEmpty) group('Tracks', hits.trackHitsTotal, hits.trackHits),
            if (hits.tracks > BigInt.zero) ...[
              const Divider(height: 8, color: Tok.rule),
              _option(index, onTap: () => _submit(all: true), child: Text('All ${hits.tracks} tracks ↵', style: Tok.body.copyWith(color: Tok.gold))),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _errorPanel() => Material(
    key: const ValueKey('query-error'),
    color: Tok.panel,
    elevation: 8,
    shape: const RoundedRectangleBorder(side: BorderSide(color: Tok.rule)),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Semantics(liveRegion: true, child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_error!, style: Tok.body.copyWith(color: Tok.warn)),
          const SizedBox(height: 6),
          Text(_unavailableCommand != null
              ? 'Use play <query> to play matching tracks, for example play by:Iona.'
              : RegExp(r'(^|\s)-?year:', caseSensitive: false).hasMatch(_text.text)
              ? 'For example, year:2017 or year:2000..2020.'
              : 'Edit the query or clear it to start again.', style: Tok.label),
        ],
      )),
    ),
  );

  Widget _hitRow(HitDto hit, int index) => _option(index,
    onTap: () => _submit(hit: hit),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(hit.title, style: Tok.body, maxLines: 1, overflow: TextOverflow.ellipsis),
      Text(hit.detail, style: Tok.label, maxLines: 1, overflow: TextOverflow.ellipsis),
    ]),
  );

  Widget _option(int index, {required VoidCallback onTap, required Widget child}) => Semantics(
    key: ValueKey('query-hit-$index'),
    selected: _highlight == index,
    button: true,
    child: InkWell(
      key: _keys.putIfAbsent(index, GlobalKey.new),
      onTap: onTap,
      canRequestFocus: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: _highlight == index ? const BoxDecoration(color: Tok.panel2, border: Border(left: BorderSide(color: Tok.gold, width: 2))) : null,
        child: child,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final p = _parsed;
    // Enter reaches the line only while it has focus; unfocused, it is a door.
    String hintFor({required bool docked}) => _submitError != null && widget.focus.hasFocus ? 'Could not complete'
      : widget.focus.hasFocus && _unavailableCommand != null ? 'Coming later' : switch (widget.focus.hasFocus ? p?.kind : null) {
      null => docked ? 'Search' : 'Search or type a command',
      QueryKind.invalid => 'Check query',
      QueryKind.command => '↵ to run',
      QueryKind.search => _hits?.tracks == BigInt.zero && _items.isEmpty
          ? _emptyLibrary ? 'Library is empty' : _asksForHelp ? 'Commands' : 'No matches'
          : '↵ as a table',
    };
    final warn = _submitError != null || (widget.focus.hasFocus && p?.kind == QueryKind.invalid);
    final empty = _text.text.isEmpty;
    return OverlayPortal(
      controller: _overlay,
      // Under the line, left edges together, as wide as the line (but wide enough to read).
      overlayChildBuilder: (context) => ValueListenableBuilder<double>(
        valueListenable: _fieldWidth,
        builder: (context, width, _) => Positioned(
          width: math.min(math.max(width, 320), MediaQuery.sizeOf(context).width - 32),
          child: CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.bottomLeft,
            followerAnchor: Alignment.topLeft,
            offset: const Offset(0, 4),
            child: TextFieldTapRegion(child: _showError ? _errorPanel() : _hits == null ? const SizedBox() : _dropdown(_hits!)),
          ),
        ),
      ),
      child: CompositedTransformTarget(
        link: _link,
        child: LayoutBuilder(builder: (context, box) {
          // Docked beside the LCD the line is short, and says so in a word.
          final hint = hintFor(docked: box.maxWidth < 260);
          if (box.maxWidth.isFinite && _fieldWidth.value != box.maxWidth) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _fieldWidth.value = box.maxWidth;
            });
          }
          return Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(color: const Color(0xFF040713), border: Border.all(color: widget.focus.hasFocus ? Tok.gold3 : Tok.rule)),
          child: Row(children: [
            Text('⌕', style: Tok.body.copyWith(color: Tok.faint, fontSize: 13)),
            const SizedBox(width: 8),
            Expanded(child: Stack(alignment: Alignment.centerLeft, children: [
              // The hint stands in for the words until there are some.
              if (empty)
                IgnorePointer(child: Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: Tok.body.copyWith(fontSize: 12.5, color: warn ? Tok.ox : Tok.faint))),
              CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
                  const SingleActivator(LogicalKeyboardKey.escape): _escape,
                  const SingleActivator(LogicalKeyboardKey.enter): _submit,
                },
                child: Shortcuts(
                  shortcuts: const {
                    SingleActivator(LogicalKeyboardKey.slash): DoNothingAndStopPropagationTextIntent(),
                    SingleActivator(LogicalKeyboardKey.bracketLeft): DoNothingAndStopPropagationTextIntent(),
                    SingleActivator(LogicalKeyboardKey.bracketRight): DoNothingAndStopPropagationTextIntent(),
                    SingleActivator(LogicalKeyboardKey.bracketLeft, alt: true): DoNothingAndStopPropagationTextIntent(),
                    SingleActivator(LogicalKeyboardKey.bracketRight, alt: true): DoNothingAndStopPropagationTextIntent(),
                    SingleActivator(LogicalKeyboardKey.backspace, meta: true): DoNothingAndStopPropagationTextIntent(),
                    SingleActivator(LogicalKeyboardKey.keyH): DoNothingAndStopPropagationTextIntent(),
                    SingleActivator(LogicalKeyboardKey.keyN): DoNothingAndStopPropagationTextIntent(),
                    SingleActivator(LogicalKeyboardKey.keyT): DoNothingAndStopPropagationTextIntent(),
                    CharacterActivator('?'): DoNothingAndStopPropagationTextIntent(),
                    SingleActivator(LogicalKeyboardKey.space): DoNothingAndStopPropagationTextIntent(),
                    SingleActivator(LogicalKeyboardKey.space, shift: true): DoNothingAndStopPropagationTextIntent(),
                    SingleActivator(LogicalKeyboardKey.space, alt: true): DoNothingAndStopPropagationTextIntent(),
                  },
                  child: Semantics(label: 'Search or command', child: TextField(
                    controller: _text,
                    focusNode: widget.focus,
                    style: Tok.monoSmall.copyWith(color: Tok.ink, fontSize: 12.5),
                    cursorColor: Tok.gold,
                    decoration: const InputDecoration.collapsed(hintText: ''),
                    onChanged: _changed,
                    onEditingComplete: () {},
                    onSubmitted: (_) => _submit(),
                  )),
                ),
              ),
            ])),
            if (!empty) ...[
              const SizedBox(width: 8),
              Flexible(child: Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: Tok.label.copyWith(color: warn ? Tok.ox : Tok.faint))),
              IconButton(
                key: const ValueKey('query-clear'),
                tooltip: 'Clear search',
                onPressed: _clear,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 24, height: 24),
                iconSize: 14,
                color: Tok.faint,
                icon: const Icon(Icons.close),
              ),
            ] else if (!widget.focus.hasFocus) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(border: Border.all(color: Tok.gold3)),
                child: Text('/', style: Tok.label.copyWith(color: Tok.gold, letterSpacing: 0)),
              ),
            ],
          ]),
          );
        }),
      ),
    );
  }
}
