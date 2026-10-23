import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bridge.dart';
import '../theme/tokens.dart';
import 'window_chrome.dart';

/// `/`: searches everything you own, can stream or have found, and takes
/// commands. Running a search starts a new trail.
///
/// On macOS it is also the window's title bar: the window buttons sit at
/// its left, and the space around the field moves the window.
class QueryLine extends StatefulWidget {
  const QueryLine({super.key, required this.core, required this.focus, this.onSubmit, this.onSearch});

  final CoreBridge core;
  final FocusNode focus;
  final Future<void> Function(QueryDto)? onSubmit;
  final Future<void> Function(SearchDto, HitDto?)? onSearch;

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

  List<HitDto> get _items => [...?_hits?.people, ...?_hits?.releases, ...?_hits?.trackHits];
  bool get _showHits => widget.focus.hasFocus && !_dismissed && _hits != null && _parsed?.kind == QueryKind.search;

  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(QueryLine old) {
    super.didUpdateWidget(old);
    if (old.focus != widget.focus) {
      old.focus.removeListener(_focusChanged);
      widget.focus.addListener(_focusChanged);
    }
    if (old.core != widget.core) _changed(_text.text);
  }

  @override
  void dispose() {
    widget.focus.removeListener(_focusChanged);
    _list.dispose();
    _text.dispose();
    super.dispose();
  }

  void _syncOverlay() {
    if (_showHits) {
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
    if (!_showHits) return;
    final last = _items.length;
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

  void _escape() {
    if (_showHits) {
      _dismiss();
    } else {
      widget.focus.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
    }
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
        final items = _items;
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
      if (mounted && generation == _generation) setState(() => _submitError = error.toString());
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
            if (hits.people.isNotEmpty) group('People', hits.peopleTotal, hits.people),
            if (hits.releases.isNotEmpty) group('Releases', hits.releasesTotal, hits.releases),
            if (hits.trackHits.isNotEmpty) group('Tracks', hits.trackHitsTotal, hits.trackHits),
            const Divider(height: 8, color: Tok.rule),
            _option(index, onTap: () => _submit(all: true), child: Text('All ${hits.tracks} tracks ↵', style: Tok.body.copyWith(color: Tok.gold))),
          ]),
        ),
      ),
    );
  }

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
    final hint = _submitError ?? switch (p?.kind) {
      null => 'Search or type a command',
      QueryKind.invalid => p!.error ?? '',
      QueryKind.command => '↵ to run',
      QueryKind.search => '↵ as a table',
    };
    return ValueListenableBuilder(
      valueListenable: WindowChrome.instance.fullScreen,
      builder: (context, _, _) => Container(
        height: 38,
        decoration: const BoxDecoration(color: Tok.panel, border: Border(bottom: BorderSide(color: Tok.line))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          WindowDragArea(
            child: Container(
              alignment: Alignment.centerLeft,
              padding: EdgeInsets.only(left: 12 + WindowChrome.instance.buttonsInset, right: 10),
              child: Text('/', style: Tok.monoSmall.copyWith(color: Tok.gold)),
            ),
          ),
          Expanded(
            flex: 3,
            child: LayoutBuilder(builder: (context, box) => OverlayPortal(
              controller: _overlay,
              overlayChildBuilder: (_) => Positioned(
                width: math.min(520, box.maxWidth),
                child: CompositedTransformFollower(
                  link: _link,
                  showWhenUnlinked: false,
                  targetAnchor: Alignment.bottomLeft,
                  followerAnchor: Alignment.topLeft,
                  child: _hits == null ? const SizedBox() : TextFieldTapRegion(child: _dropdown(_hits!)),
                ),
              ),
              child: CompositedTransformTarget(
                link: _link,
                child: Center(
                  child: CallbackShortcuts(
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
                        SingleActivator(LogicalKeyboardKey.space): DoNothingAndStopPropagationTextIntent(),
                        SingleActivator(LogicalKeyboardKey.space, shift: true): DoNothingAndStopPropagationTextIntent(),
                        SingleActivator(LogicalKeyboardKey.space, alt: true): DoNothingAndStopPropagationTextIntent(),
                      },
                      child: TextField(
                        controller: _text,
                        focusNode: widget.focus,
                        style: Tok.monoSmall.copyWith(color: Tok.ink, fontSize: 12.5),
                        cursorColor: Tok.gold,
                        decoration: const InputDecoration.collapsed(hintText: ''),
                        onChanged: _changed,
                        onEditingComplete: () {},
                        onSubmitted: (_) => _submit(),
                      ),
                    ),
                  ),
                ),
              ),
            )),
          ),
          Expanded(
            child: WindowDragArea(
              child: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Tok.label.copyWith(color: _submitError != null || p?.kind == QueryKind.invalid ? Tok.ox : Tok.faint),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
