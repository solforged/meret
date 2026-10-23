import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../core/when.dart';
import '../draw/constellation.dart';
import '../shell/width_class.dart';
import '../theme/tokens.dart';
import 'pane.dart';

class TreePane extends StatefulWidget {
  const TreePane({
    super.key, required this.trail, required this.onGo, required this.onPrune,
    required this.onKeep, required this.onPlay,
  });

  final TrailDto trail;
  final ValueChanged<int> onGo;
  final ValueChanged<int> onPrune;
  final VoidCallback onKeep;
  final ValueChanged<bool> onPlay;

  @override
  State<TreePane> createState() => _TreePaneState();
}

class _TreePaneState extends State<TreePane> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final TreePane(:trail, :onGo, :onPrune, :onKeep, :onPlay) = widget;
    final stops = {for (final stop in trail.stops) stop.index: stop};
    final root = trail.stops.firstWhere((stop) => stop.parent == null);
    final current = stops[trail.current]!;
    final opened = trail.stops.map((stop) => stop.openedMs.toInt());
    final start = opened.reduce(math.min);
    final end = opened.reduce(math.max);
    final title = trail.name ?? (root.title == current.title ? root.title : '${root.title} → ${current.title}');
    return LayoutBuilder(builder: (context, box) {
      final narrow = WidthClass.of(box.maxWidth) == WidthClass.phone;
      return ColoredBox(
        color: Tok.sky,
        child: Scrollbar(
          controller: _scroll,
          child: SingleChildScrollView(
            key: const ValueKey('tree-pane-scroll'),
            controller: _scroll,
            primary: false,
            scrollDirection: Axis.vertical,
            hitTestBehavior: HitTestBehavior.opaque,
            padding: EdgeInsets.all(narrow ? 12 : 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Trail · a tree · ${dayDate(start)}, ${clockTime(start)}–${clockTime(end)}', style: Tok.label),
              const SizedBox(height: 4),
              Text(title, style: Tok.title),
              const SizedBox(height: 12),
              TreePaneFacts(trail: trail),
              const SizedBox(height: 16),
              Wrap(spacing: 8, runSpacing: 8, children: [
                PaneActionButton(key: const ValueKey('tree-name'), label: 'Name it', onTap: onKeep),
                PaneActionButton(key: const ValueKey('tree-play-branch'), label: 'Play this branch', onTap: () => onPlay(false)),
                PaneActionButton(key: const ValueKey('tree-play-whole'), label: 'Play the whole tree', hint: 'depth first', onTap: () => onPlay(true)),
                PaneActionButton(key: const ValueKey('tree-keep'), label: trail.kept ? 'Kept' : 'Keep', hint: '⌘S', primary: true, onTap: onKeep),
              ]),
              const SizedBox(height: 20),
              TrailTree(trail: trail, onGo: onGo),
              const SizedBox(height: 10),
              Wrap(spacing: 20, runSpacing: 6, children: [
                for (final (mark, label, color) in [
                  ('━', 'this branch', Tok.gold),
                  ('━', 'earlier branches', Tok.muted),
                  ('┅', 'branches meet', Tok.gold),
                  ('◯', 'a fork', Tok.gold),
                  ('⋯', 'peek', Tok.faint),
                ])
                  Text.rich(TextSpan(children: [
                    TextSpan(text: '$mark ', style: TextStyle(color: color)),
                    TextSpan(text: label),
                  ]), style: Tok.label),
              ]),
              const SizedBox(height: 24),
              const Text('Branches', style: Tok.label),
              const SizedBox(height: 8),
              _Branches(trail: trail, stops: stops, root: root, onGo: onGo, onPrune: onPrune),
            ]),
          ),
        ),
      );
    });
  }
}

class TreePaneFacts extends StatelessWidget {
  const TreePaneFacts({super.key, required this.trail});
  final TrailDto trail;

  int get stops => trail.stops.length;
  int get branches => trail.branches.length;
  int get peeks => trail.stops.where((stop) => stop.isPeek).length;
  int _actions(String action) => trail.stops.fold(0, (count, stop) => count + stop.actions.where((item) => item == action).length);
  int get wants => _actions('wanted');
  int get played => _actions('played');

  @override
  Widget build(BuildContext context) => Wrap(spacing: 24, runSpacing: 6, children: [
    Text(_count(stops, 'stop'), style: Tok.monoSmall),
    Text([
      _count(branches, 'branch', 'branches'),
      if (peeks != 0) _count(peeks, 'peek'),
    ].join(' · '), style: Tok.monoSmall),
    if (wants != 0 || played != 0)
      Text([
        if (wants != 0) _count(wants, 'want'),
        if (played != 0) '$played played',
      ].join(' · '), style: Tok.monoSmall),
    if (trail.meetings.isNotEmpty) Text(_count(trail.meetings.length, 'meeting point'), style: Tok.monoSmall),
  ]);
}

String _count(int count, String singular, [String? plural]) => '$count ${count == 1 ? singular : plural ?? '${singular}s'}';

class _Branches extends StatelessWidget {
  const _Branches({required this.trail, required this.stops, required this.root, required this.onGo, required this.onPrune});
  final TrailDto trail;
  final Map<int, StopDto> stops;
  final StopDto root;
  final ValueChanged<int> onGo;
  final ValueChanged<int> onPrune;

  static const _headers = ['Branch', 'Leaves from', 'Stops', 'When', 'What happened', 'State'];
  static const _flex = [3, 2, 0, 0, 3, 3];
  static const _cellPadding = 6.0;

  ({double stops, double when}) _fixedColumns(BuildContext context) {
    final text = TextPainter(
      textDirection: Directionality.of(context), textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    );
    final inherited = DefaultTextStyle.of(context).style;
    double width(String value, TextStyle style) {
      text.text = TextSpan(text: value, style: inherited.merge(style));
      text.layout();
      return text.width;
    }
    final count = trail.branches.fold(1, (count, branch) => math.max(count, branch.stops));
    final stopWidth = math.max(width('Stops', Tok.label), width('$count', Tok.monoSmall)) + _cellPadding * 2;
    final whenWidth = math.max(width('When', Tok.label), width('88:88–88:88', Tok.monoSmall)) + _cellPadding * 2;
    text.dispose();
    return (stops: stopWidth, when: whenWidth);
  }

  List<StopDto> _path(BranchDto branch) {
    final path = <StopDto>[];
    StopDto? stop = stops[branch.leaf];
    while (stop != null) {
      path.add(stop);
      if (stop.index == branch.first) break;
      stop = stops[stop.parent];
    }
    return path.reversed.toList();
  }

  Widget _cells(List<Widget> cells, ({double stops, double when}) fixed) => LayoutBuilder(builder: (context, box) {
    if (box.maxWidth < 600) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: _cellPadding, vertical: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          cells.first,
          const SizedBox(height: 10),
          LayoutBuilder(builder: (context, inner) => Wrap(spacing: 12, runSpacing: 10, children: [
            for (var i = 1; i < cells.length; i++)
              SizedBox(
                width: i == 2 ? fixed.stops : i == 3 ? fixed.when : (inner.maxWidth - 12) / 2,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_headers[i], style: Tok.label, maxLines: i == 2 || i == 3 ? 1 : null),
                  const SizedBox(height: 4),
                  cells[i],
                ]),
              ),
          ])),
        ]),
      );
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var i = 0; i < cells.length; i++)
        if (i == 2 || i == 3)
          SizedBox(width: i == 2 ? fixed.stops : fixed.when, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: _cellPadding, vertical: 10),
            child: cells[i],
          ))
        else
          Expanded(flex: _flex[i], child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: _cellPadding, vertical: 10),
            child: cells[i],
          )),
    ]);
  });

  Widget _row({
    required Key key, required List<String> cells, required ({double stops, double when}) fixed,
    required VoidCallback onGo, bool current = false, VoidCallback? onPrune, Key? pruneKey,
  }) => Semantics(
    selected: current, button: true,
    child: InkWell(
      key: key,
      onTap: onGo,
      child: Container(
        decoration: BoxDecoration(
          color: current ? Tok.panel2 : Colors.transparent,
          border: const Border(bottom: BorderSide(color: Tok.line)),
        ),
        child: _cells([
          for (var i = 0; i < cells.length; i++)
            i == 5 && onPrune != null
              ? Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(cells[i], style: Tok.monoSmall),
                  TextButton(
                    key: pruneKey,
                    onPressed: onPrune,
                    style: TextButton.styleFrom(
                      foregroundColor: Tok.gold, textStyle: Tok.label,
                      minimumSize: const Size(0, 24), padding: const EdgeInsets.symmetric(horizontal: 4),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('prune'),
                  ),
                ])
              : Text(cells[i], style: i == 0 ? Tok.body.copyWith(color: current ? Tok.gold : Tok.ink) : Tok.monoSmall),
        ], fixed),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final fixed = _fixedColumns(context);
    return LayoutBuilder(
      key: const ValueKey('tree-branches'),
      builder: (context, box) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (box.maxWidth >= 600)
          Container(
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.rule))),
            child: _cells([
              for (var i = 0; i < _headers.length; i++)
                Text(
                  _headers[i], key: ValueKey('tree-branches-header-$i'), style: Tok.label,
                  maxLines: i == 2 || i == 3 ? 1 : null, softWrap: i != 2 && i != 3,
                ),
            ], fixed),
          ),
        for (final branch in trail.branches) _branch(branch, fixed),
        for (final peek in trail.stops.where((stop) => stop.isPeek && !stop.onPath))
          _row(
            key: ValueKey('tree-peek-${peek.index}'), fixed: fixed,
            cells: [
              'peek: ${peek.title}', stops[peek.parent]?.title ?? root.title,
              '1', clockTime(peek.openedMs.toInt()), 'open for ${peek.dwellMs.toInt() ~/ 1000}s', 'folded',
            ],
            onGo: () => onGo(peek.index),
          ),
      ]),
    );
  }

  Widget _branch(BranchDto branch, ({double stops, double when}) fixed) {
    final path = _path(branch);
    final times = path.map((stop) => stop.openedMs.toInt());
    final first = stops[branch.first]!;
    final fork = stops[branch.fork];
    final from = fork == null ? root.title : [fork.title, ?first.via].join(' · ');
    final state = branch.current ? 'current'
        : branch.actions.contains('wanted') ? 'kept: it has a want'
        : branch.actions.isNotEmpty ? 'kept' : 'prunable';
    return _row(
      key: ValueKey('tree-branch-${branch.leaf}'), fixed: fixed,
      cells: [
        path.map((stop) => '→ ${stop.title}').join(' '), from, '${branch.stops}',
        '${clockTime(times.reduce(math.min))}–${branch.current ? 'now' : clockTime(times.reduce(math.max))}',
        trailActions(branch.actions), state,
      ],
      current: branch.current,
      onGo: () => onGo(branch.leaf),
      onPrune: branch.prunable ? () => onPrune(branch.leaf) : null,
      pruneKey: ValueKey('tree-prune-${branch.leaf}'),
    );
  }
}
