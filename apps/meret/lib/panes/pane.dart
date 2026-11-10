import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;

import '../core/bridge.dart';
import '../core/when.dart';
import '../theme/action_target.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';
import 'threads.dart';

/// "212 plays · last Tuesday", "1 play · today", "no plays yet".
String playsFact(BigInt plays, PlatformInt64? lastPlayedMs) {
  if (plays == BigInt.zero) return 'no plays yet';
  final count = '${plays.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},')} ${plays == BigInt.one ? 'play' : 'plays'}';
  return lastPlayedMs == null ? count : '$count · last ${dayWord(lastPlayedMs.toInt())}';
}

/// One primary action, with an optional second choice.
class PaneActions extends StatelessWidget {
  const PaneActions({super.key, required this.primary, required this.onPrimary, this.primaryKey, this.secondary, this.onSecondary, this.secondaryKey});
  final String primary;
  final VoidCallback? onPrimary;
  final Key? primaryKey;
  final String? secondary;
  final VoidCallback? onSecondary;
  final Key? secondaryKey;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 8, children: [
    PaneActionButton(key: primaryKey, label: primary, primary: true, onTap: onPrimary),
    if (secondary case final label?)
      PaneActionButton(key: secondaryKey, label: label, onTap: onSecondary),
  ]);
}

/// What a pane body shows before its DTO arrives: the stop's title, so the pane
/// never slides in bare, and one state line beneath.
Widget paneReading(String? title, String line, {bool error = false}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
  if (title != null) ...[
    Text(title, style: Tok.title, maxLines: 2, overflow: TextOverflow.ellipsis),
    const SizedBox(height: 8),
  ],
  Text(line, style: Tok.label.copyWith(color: error ? Tok.warn : Tok.faint)),
]);

/// A row or button that is a door: the pointer tints it `Tok.panel2`, as
/// TodayDoor and NowDoor do, so every door in the app answers a hover alike.
class Door extends StatefulWidget {
  const Door({super.key, required this.builder, this.enabled = true});

  /// Builds the door; `hover` is true only while the pointer is over an enabled door.
  final Widget Function(BuildContext context, bool hover) builder;
  final bool enabled;

  @override
  State<Door> createState() => _DoorState();
}

class _DoorState extends State<Door> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: widget.builder(context, _hover && widget.enabled),
  );
}

class PaneActionButton extends StatelessWidget {
  const PaneActionButton({super.key, required this.label, this.hint = '', this.primary = false, this.onTap, this.later = false});
  final String label;
  final String hint;
  final bool primary;
  final VoidCallback? onTap;

  /// Not built yet: greyed, and says so on hover, so the row reads as plate 01 draws it.
  final bool later;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final button = Door(
      enabled: enabled,
      builder: (context, hover) => ActionTarget(
        onTap: onTap,
        semanticLabel: label,
        excludeChildSemantics: true,
        focusColor: primary ? Tok.sky : Tok.gold,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: primary && enabled ? Tok.gold : hover ? Tok.panel2 : Colors.transparent,
            border: Border.all(color: primary && enabled ? Tok.gold : Tok.rule),
          ),
          child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(label, style: Tok.body.copyWith(
              fontSize: 12.5,
              fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
              color: primary && enabled ? Tok.sky : enabled ? Tok.ink : Tok.faint,
            )),
            if (hint.isNotEmpty) ...[
              Text(hint, style: Tok.label.copyWith(fontSize: 11.5, color: primary && enabled ? Tok.sky.withValues(alpha: 0.8) : Tok.faint)),
            ],
          ]),
        ),
      ),
    );
    return later ? Tooltip(message: 'Coming later', child: button) : button;
  }
}

/// What every pane shows at the top: a header that is its star on the
/// trail (plate 02), with the kind of thing, the thread that brought you
/// and who said so, then its name. Folds to a vertical spine when narrow.
class Pane extends StatefulWidget {
  const Pane({
    super.key, required this.kind, required this.title, this.via, this.source, this.body,
    this.showTitle = true, this.compact = false, this.onSpineTap, this.ahead = false,
    this.current = false, this.fork, this.anchors, this.stop,
  });

  /// "PERSON · COMPOSER", "SCORE · 1998", "GROUP · NOT OWNED".
  final String kind;
  final String title;

  /// The thread followed into this pane: "composed by".
  final String? via;

  /// Who said so: "MusicBrainz · VGMdb".
  final String? source;
  final Widget? body;
  final bool showTitle;

  /// One header line, `kind · title`, for a search whose table needs the room.
  final bool compact;

  /// A folded pane, or a dimmed one, clicked: go to its stop.
  final VoidCallback? onSpineTap;

  /// A stop ahead of the current one, which `]` walks back into: dimmed. A
  /// click anywhere on it goes there; nothing inside takes the click.
  final bool ahead;

  /// The stop you're at: its star is lit and its header carries a gold edge.
  final bool current;

  /// The header's branch control, when branches or folded peeks leave this
  /// stop. It sits where the source is named, so it moves nothing.
  final Widget? fork;

  /// Where this pane's thread ends register, so the row can draw them.
  final ThreadAnchors? anchors;
  final int? stop;

  static const header = 34.0;
  static const aheadOpacity = 0.42;
  static const dimming = Duration(milliseconds: 120);

  @override
  State<Pane> createState() => _PaneState();
}

class _PaneState extends State<Pane> {
  final _focus = FocusNode();
  FocusNode? _foldedFocus;
  bool _folded = false;
  double _fullWidth = 440;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final folded = box.maxWidth < 60;
      if (folded != _folded) {
        if (folded) {
          _foldedFocus = _focus.hasFocus ? FocusManager.instance.primaryFocus : null;
        } else {
          final focus = _foldedFocus;
          _foldedFocus = null;
          if (focus != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && !_folded && focus.context != null) focus.requestFocus();
            });
          }
        }
        _folded = folded;
      }
      if (!folded) _fullWidth = box.maxWidth;
      final Pane(:kind, :title, :via, :source, :body, :compact, :showTitle, :onSpineTap, :ahead, :current, :anchors, :stop) = widget;
      Widget pane = Focus(
        focusNode: _focus, canRequestFocus: false, descendantsAreFocusable: !folded && !ahead,
        child: AnimatedContainer(
          duration: Pane.dimming,
          decoration: BoxDecoration(color: current ? Tok.panel : Tok.sky, border: const Border(right: BorderSide(color: Tok.line))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _header(context),
            Expanded(child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(height: compact ? 8 : 12),
                if (compact)
                  Text(title, style: Tok.body.copyWith(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)
                else if (showTitle)
                  Text(title, style: Tok.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                SizedBox(height: compact ? 8 : showTitle ? 12 : 0),
                Expanded(child: body ?? const SizedBox()),
              ]),
            )),
          ]),
        ),
      );
      final slot = Stack(fit: StackFit.expand, children: [
        Visibility(
          visible: !folded, maintainState: true,
          // Keep a hidden body at its last full width, not the spine's 46 px.
          child: OverflowBox(
            alignment: Alignment.topLeft, minWidth: _fullWidth, maxWidth: _fullWidth,
            child: pane,
          ),
        ),
        if (folded) PaneSpine(title: title, meta: via ?? kind, onTap: onSpineTap)
        else if (ahead && onSpineTap != null)
          Semantics(
            button: true, label: title,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(key: const ValueKey('pane-ahead'), behavior: HitTestBehavior.opaque, onTap: onSpineTap),
            ),
          ),
      ]);
      // The slot's own box, the spine's width when folded, is what threads join.
      return AnimatedOpacity(
        opacity: ahead ? Pane.aheadOpacity : 1, duration: Pane.dimming,
        child: anchors != null && stop != null ? ThreadAnchor(anchors: anchors, end: ThreadEnd.pane, stop: stop, child: slot) : slot,
      );
    });
  }

  /// Plate 02: the star, the kind, the thread that brought you in gold
  /// italic, and who said so or how many branches leave here.
  Widget _header(BuildContext context) {
    final Pane(:kind, :via, :source, :current, :fork, :anchors, :stop) = widget;
    final light = Light.of(context).accent;
    Widget star = AnimatedContainer(
      key: const ValueKey('pane-star'),
      duration: Pane.dimming,
      width: current ? 10 : 8, height: current ? 10 : 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: current ? light : Tok.muted,
        boxShadow: current ? [BoxShadow(color: light.withValues(alpha: 0.09), spreadRadius: 4), BoxShadow(color: light, blurRadius: 10)] : const [],
      ),
    );
    if (anchors != null && stop != null) star = ThreadAnchor(anchors: anchors, end: ThreadEnd.star, stop: stop, color: light, child: star);
    return AnimatedContainer(
      key: const ValueKey('pane-header'),
      duration: Pane.dimming,
      height: Pane.header,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(border: Border(
        top: BorderSide(color: current ? Tok.gold : Colors.transparent, width: 2),
        bottom: const BorderSide(color: Tok.line),
      )),
      child: Row(children: [
        SizedBox(width: 10, height: 10, child: Center(child: star)),
        const SizedBox(width: 9),
        Text(kind.toUpperCase(), style: Tok.caps, maxLines: 1),
        if (via != null) ...[
          const SizedBox(width: 9),
          Flexible(child: Text(via, style: Tok.body.copyWith(fontSize: 12, fontStyle: FontStyle.italic, fontWeight: FontWeight.w500, color: Tok.gold2), maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
        const Spacer(),
        if (fork case final fork?)
          fork
        else if (source != null)
          Flexible(child: Text(source, style: Tok.label.copyWith(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis)),
      ]),
    );
  }
}

/// A folded pane (plate 01): the stop's name written upwards, its thread
/// or kind beneath, in a 46 px column. Clicking it returns to that stop.
class PaneSpine extends StatelessWidget {
  const PaneSpine({super.key, required this.title, this.meta, this.onTap});
  final String title;
  final String? meta;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ActionTarget(
    semanticLabel: 'Go to $title',
    excludeChildSemantics: true,
    onTap: onTap,
    child: Container(
      decoration: const BoxDecoration(color: Tok.void_, border: Border(right: BorderSide(color: Tok.line))),
      alignment: Alignment.topCenter,
      padding: const EdgeInsets.only(top: 14),
      child: RotatedBox(
        quarterTurns: 3,
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Flexible(child: Text(title, style: Tok.body.copyWith(fontSize: 12.5, fontWeight: FontWeight.w500, color: Tok.muted), maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (meta case final meta?) ...[
            const SizedBox(width: 8),
            Text(meta, style: Tok.body.copyWith(fontSize: 12.5, color: Tok.faint), maxLines: 1),
          ],
        ]),
      ),
    ),
  );
}

/// The tree around one pane, shared by its fork rows and thread marks.
class TrailPaneScope extends InheritedWidget {
  const TrailPaneScope({super.key, required this.trail, required this.stop, required this.onGo, required this.onPrune, this.ahead = const {}, this.anchors, this.core, required super.child});
  final TrailDto trail;
  final StopDto stop;

  /// What a row's menu plays and queues through.
  final CoreBridge? core;

  /// Where the row you followed registers, so its thread can be drawn.
  final ThreadAnchors? anchors;

  /// The stops ahead on the row; they show as dimmed panes, not as marks.
  final Set<int> ahead;
  final ValueChanged<int> onGo;
  final ValueChanged<int> onPrune;

  static TrailPaneScope? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<TrailPaneScope>();

  /// The next pane on the row, when this stop's thread led there.
  StopDto? get next => trail.stops.where((node) => node.parent == stop.index && !node.isPeek && (node.onPath || ahead.contains(node.index))).firstOrNull;

  /// How [target] stands on this trail, for the arrow at the end of its row.
  /// [via] is the row's thread ("album artist"): one person can be credited
  /// in several ways, and only the thread that was followed is lit.
  ThreadWay way(TargetDto target, {String? via}) {
    final next = this.next;
    if (next?.target == target && (via == null || next!.via == via)) return ThreadWay.went;
    final parent = trail.stops.where((node) => node.index == stop.parent).firstOrNull;
    if (parent?.target == target) return ThreadWay.came;
    if (trail.stops.any((node) => (node.onPath || ahead.contains(node.index)) && node.target == target)) return ThreadWay.onTrail;
    if (followedLeaf(target) != null) return ThreadWay.forked;
    return ThreadWay.open;
  }

  /// Where the thread to [target] led on a branch that isn't on the row.
  String? followedLeaf(TargetDto target) {
    final stops = {for (final node in trail.stops) node.index: node};
    final children = trail.stops.where((node) => node.parent == stop.index && !node.isPeek && !node.onPath && !ahead.contains(node.index) && node.target == target)
        .map((node) => node.index).toSet();
    if (children.isEmpty) return null;
    for (final branch in trail.branches) {
      StopDto? node = stops[branch.leaf];
      while (node != null && node.index != stop.index) {
        if (children.contains(node.index)) return stops[branch.leaf]?.title;
        node = stops[node.parent];
      }
    }
    return null;
  }

  @override
  bool updateShouldNotify(TrailPaneScope oldWidget) =>
      trail != oldWidget.trail || stop != oldWidget.stop || anchors != oldWidget.anchors || !setEquals(ahead, oldWidget.ahead);
}

/// Where a thread stands on the trail: followed to the next pane, the one
/// you came from, elsewhere on the trail, followed on a branch that isn't
/// on the row, or not taken.
enum ThreadWay { went, came, onTrail, forked, open }

/// The end of a followable row (plate 02): `→` follows, `←` is where you
/// came from, `○` is already on this trail, `⑂` was followed on another
/// branch (its tooltip says where it led). The followed row's is gold.
class ThreadArrow extends StatelessWidget {
  const ThreadArrow({super.key, required this.target, this.via, this.hover = false});
  final TargetDto target;

  /// The row's thread, so only the one that was followed is gold.
  final String? via;
  final bool hover;

  @override
  Widget build(BuildContext context) {
    final scope = TrailPaneScope.of(context);
    final way = scope?.way(target, via: via) ?? ThreadWay.open;
    final (glyph, colour) = switch (way) {
      ThreadWay.went => ('→', Tok.gold),
      ThreadWay.came => ('←', Tok.faint),
      ThreadWay.onTrail => ('○', Tok.faint),
      ThreadWay.forked => ('⑂', Tok.gold2),
      ThreadWay.open => ('→', hover ? Tok.ink : Tok.faint),
    };
    final arrow = SizedBox(width: 14, child: Text(glyph, key: ValueKey('arrow-${way.name}'), style: Tok.body.copyWith(color: colour), textAlign: TextAlign.right));
    final leaf = way == ThreadWay.forked ? scope?.followedLeaf(target) : null;
    return leaf == null ? arrow : Tooltip(message: '⑂ → $leaf', child: arrow);
  }
}

/// Every list row's box: a 2 px edge that lights for the playing track or the
/// followed thread, then the same inset whether it is lit or not. Text never
/// touches the edge, and nothing shifts when a row lights.
class RowBox extends StatelessWidget {
  const RowBox({super.key, required this.child, this.edge, this.fill, this.vertical = 6});

  final Widget child;

  /// The edge's colour while the row is lit.
  final Color? edge;
  final Color? fill;
  final double vertical;

  static const edgeWidth = 2.0;
  static const inset = 6.0;

  /// The followed thread's tint.
  static const went = Color(0x1AD2A64E);

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.fromLTRB(inset, vertical, inset, vertical),
    decoration: BoxDecoration(
      color: fill ?? Colors.transparent,
      border: Border(
        bottom: const BorderSide(color: Tok.line),
        left: BorderSide(color: edge ?? Colors.transparent, width: edgeWidth),
      ),
    ),
    child: child,
  );
}

/// A [RowBox] for a row that follows a thread: lit gold when it's the thread
/// that led to the next pane, and the start of that thread's line. [edge] and
/// [fill] win over the thread's own, for a row that is also playing or selected.
class ThreadRowBox extends StatelessWidget {
  const ThreadRowBox({super.key, required this.target, this.via, this.hover = false, this.edge, this.fill, this.vertical = 6, required this.child});

  /// Null for a row with no thread: a plain [RowBox].
  final TargetDto? target;
  final String? via;
  final bool hover;
  final Color? edge;
  final Color? fill;
  final double vertical;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final target = this.target;
    final scope = target == null ? null : TrailPaneScope.of(context);
    final went = scope != null && scope.way(target!, via: via) == ThreadWay.went;
    final box = RowBox(
      edge: edge ?? (went ? Tok.gold : null),
      fill: fill ?? (went ? RowBox.went : hover ? Tok.panel2 : null),
      vertical: vertical,
      child: child,
    );
    if (!went) return box;
    final lit = KeyedSubtree(key: const ValueKey('thread-went'), child: box);
    final anchors = scope.anchors;
    return anchors == null ? lit : ThreadAnchor(anchors: anchors, end: ThreadEnd.went, stop: scope.stop.index, child: lit);
  }
}

/// A followable cell in a table row: lit gold when it's the thread that led
/// to the next pane, and the start of that thread's line. [via] names the
/// thread when the same target is reachable more than one way. Whole rows
/// use [ThreadRowBox].
class TrailRow extends StatelessWidget {
  const TrailRow({super.key, required this.target, this.via, required this.child});
  final TargetDto target;
  final String? via;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = TrailPaneScope.of(context);
    if (scope == null || scope.way(target, via: via) != ThreadWay.went) return child;
    final lit = DecoratedBox(
      key: const ValueKey('thread-went'),
      decoration: const BoxDecoration(color: RowBox.went, border: Border(left: BorderSide(color: Tok.gold, width: RowBox.edgeWidth))),
      child: Padding(padding: const EdgeInsets.only(left: 6), child: child),
    );
    final anchors = scope.anchors;
    return anchors == null ? lit : ThreadAnchor(anchors: anchors, end: ThreadEnd.went, stop: scope.stop.index, child: lit);
  }
}

/// The header's branch control: `⑂ n` opens the branches leaving this stop
/// and the stops that folded away as peeks. It is a popover over the pane,
/// so a fork never moves what you were reading.
class ForkControl extends StatefulWidget {
  const ForkControl({super.key, required this.trail, required this.stop, required this.onGo, required this.onPrune});
  final TrailDto trail;
  final StopDto stop;
  final ValueChanged<int> onGo;
  final ValueChanged<int> onPrune;

  /// The branches that leave [stop], peeks folded away.
  static List<BranchDto> branchesOf(TrailDto trail, StopDto stop) => trail.branches.where((branch) => branch.fork == stop.index).toList();

  /// The stops opened from [stop] and left within the peek window.
  static List<StopDto> peeksOf(TrailDto trail, StopDto stop) => trail.stops.where((node) => node.parent == stop.index && node.isPeek).toList();

  static bool has(TrailDto trail, StopDto stop) => branchesOf(trail, stop).isNotEmpty || peeksOf(trail, stop).isNotEmpty;

  @override
  State<ForkControl> createState() => _ForkControlState();
}

class _ForkControlState extends State<ForkControl> {
  final _menu = MenuController();

  void _pick(VoidCallback act) {
    _menu.close();
    act();
  }

  Widget _row({required Key key, required String title, required String detail, required VoidCallback onTap, bool current = false, bool dim = false, Widget? trailing}) =>
    Row(children: [
      Expanded(child: Semantics(
        selected: current,
        button: true,
        child: InkWell(
          key: key,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.line))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Tok.body.copyWith(color: current ? Tok.gold : dim ? Tok.faint : Tok.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(detail, style: Tok.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ),
      )),
      ?trailing,
    ]);

  @override
  Widget build(BuildContext context) {
    final ForkControl(:trail, :stop, :onGo, :onPrune) = widget;
    final branches = ForkControl.branchesOf(trail, stop);
    final peeks = ForkControl.peeksOf(trail, stop);
    final stops = {for (final node in trail.stops) node.index: node};
    final label = branches.isNotEmpty ? '⑂ ${branches.length}' : '⑂ ${peeks.length} ${peeks.length == 1 ? 'peek' : 'peeks'}';
    final words = branches.isEmpty
        ? '${peeks.length} ${peeks.length == 1 ? 'stop' : 'stops'} folded away from here'
        : branches.length == 1 ? 'One branch leaves here' : '${branches.length} branches leave here';
    return MenuAnchor(
      controller: _menu,
      alignmentOffset: const Offset(0, 6),
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Tok.panel),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
        side: WidgetStatePropertyAll(BorderSide(color: Tok.rule)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4)))),
      ),
      menuChildren: [
        SizedBox(width: 320, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 6), child: Text(branches.isEmpty ? 'Peeks here' : 'Forks here', style: Tok.heading)),
          for (final branch in branches)
            _row(
              key: ValueKey('fork-${stop.index}-${branch.leaf}'),
              title: stops[branch.leaf]!.title,
              detail: [?stops[branch.first]?.via, agoShort(branch.whenMs.toInt()), ...branch.actions].join(' · '),
              current: branch.current,
              onTap: () => _pick(() => onGo(branch.leaf)),
              trailing: branch.prunable ? TextButton(
                key: ValueKey('prune-${stop.index}-${branch.leaf}'),
                onPressed: () => _pick(() => onPrune(branch.leaf)),
                child: Text('prune', style: Tok.label),
              ) : null,
            ),
          for (final peek in peeks)
            _row(
              key: ValueKey('peek-${stop.index}-${peek.index}'),
              title: peek.title,
              detail: ['peeked', '${peek.dwellMs.toInt() ~/ 1000}s'].join(' · '),
              dim: true,
              onTap: () => _pick(() => onGo(peek.index)),
            ),
        ])),
      ],
      builder: (context, controller, _) => Tooltip(
        message: words,
        child: ActionTarget(
          key: const ValueKey('pane-forks'),
          onTap: () => controller.isOpen ? controller.close() : controller.open(),
          semanticLabel: words,
          excludeChildSemantics: true,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(border: Border.all(color: Tok.gold3)),
            child: Text(label, style: Tok.label.copyWith(color: Tok.gold)),
          ),
        ),
      ),
    );
  }
}

/// The slot after the last pane where the next one will open (plate 08).
class PaneGhost extends StatelessWidget {
  const PaneGhost({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(14),
    child: CustomPaint(
      painter: const _DashedBox(Tok.rule),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Next stop', style: Tok.body.copyWith(fontSize: 13.5, fontWeight: FontWeight.w600, color: Tok.muted), maxLines: 1),
          const SizedBox(height: 6),
          Text('Follow a thread and it opens here.', style: Tok.body.copyWith(fontSize: 13, color: Tok.faint), maxLines: 3, overflow: TextOverflow.ellipsis),
        ]),
      ),
    ),
  );
}

class _DashedBox extends CustomPainter {
  const _DashedBox(this.colour);
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = colour..strokeWidth = 1;
    const dash = 4.0, gap = 3.0;
    void line(Offset a, Offset b) {
      final length = (b - a).distance;
      final step = (b - a) / length;
      for (var d = 0.0; d < length; d += dash + gap) {
        canvas.drawLine(a + step * d, a + step * (d + dash).clamp(0, length), paint);
      }
    }
    final r = Offset.zero & size;
    final box = r.deflate(0.5);
    line(box.topLeft, box.topRight);
    line(box.topRight, box.bottomRight);
    line(box.bottomRight, box.bottomLeft);
    line(box.bottomLeft, box.topLeft);
  }

  @override
  bool shouldRepaint(_DashedBox old) => old.colour != colour;
}
