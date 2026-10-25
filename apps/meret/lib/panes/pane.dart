import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;

import '../core/bridge.dart';
import '../core/when.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';
import 'threads.dart';

/// "212 plays · last Tuesday", "1 play · today", "no plays yet".
String playsFact(BigInt plays, PlatformInt64? lastPlayedMs) {
  if (plays == BigInt.zero) return 'no plays yet';
  final count = '${plays.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},')} ${plays == BigInt.one ? 'play' : 'plays'}';
  return lastPlayedMs == null ? count : '$count · last ${dayWord(lastPlayedMs.toInt())}';
}

/// One primary action, with a second choice or the planned Want and Crate actions.
class PaneActions extends StatelessWidget {
  const PaneActions({super.key, required this.primary, required this.onPrimary, this.primaryKey, this.secondary, this.onSecondary});
  final String primary;
  final VoidCallback? onPrimary;
  final Key? primaryKey;
  final String? secondary;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 8, children: [
    PaneActionButton(key: primaryKey, label: primary, hint: secondary == null ? 'Space' : '', primary: true, onTap: onPrimary),
    if (secondary case final label?)
      PaneActionButton(label: label, hint: '', onTap: onSecondary)
    else ...[
      const PaneActionButton(label: 'Want', hint: 'W', later: true),
      const PaneActionButton(label: 'Crate', hint: 'C', later: true),
    ],
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
      builder: (context, hover) => GestureDetector(
        onTap: onTap,
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
              Text(hint, style: Tok.label.copyWith(color: primary && enabled ? Tok.sky.withValues(alpha: 0.6) : Tok.faint, letterSpacing: 0)),
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
    this.current = false, this.forks = 0, this.anchors, this.stop,
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

  /// Branches leaving this stop, shown as `⑂ n` in the header.
  final int forks;

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
      if (anchors != null && stop != null) pane = ThreadAnchor(anchors: anchors, end: ThreadEnd.pane, stop: stop, on: !folded, child: pane);
      return AnimatedOpacity(
        opacity: ahead ? Pane.aheadOpacity : 1, duration: Pane.dimming,
        child: Stack(fit: StackFit.expand, children: [
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
      ]));
    });
  }

  /// Plate 02: the star, the kind, the thread that brought you in gold
  /// italic, and who said so or how many branches leave here.
  Widget _header(BuildContext context) {
    final Pane(:kind, :via, :source, :current, :forks, :anchors, :stop) = widget;
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
    if (anchors != null && stop != null) star = ThreadAnchor(anchors: anchors, end: ThreadEnd.star, stop: stop, child: star);
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
        Text(kind.toUpperCase(), style: Tok.label.copyWith(fontWeight: FontWeight.w500), maxLines: 1),
        if (via != null) ...[
          const SizedBox(width: 9),
          Flexible(child: Text(via, style: Tok.body.copyWith(fontSize: 12, fontStyle: FontStyle.italic, fontWeight: FontWeight.w500, color: Tok.gold2), maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
        const Spacer(),
        if (forks > 0)
          Tooltip(
            message: forks == 1 ? 'One branch leaves here' : '$forks branches leave here',
            child: Container(
              key: const ValueKey('pane-forks'),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(border: Border.all(color: Tok.gold3)),
              child: Text('⑂ $forks', style: Tok.label.copyWith(color: Tok.gold, letterSpacing: 0)),
            ),
          )
        else if (source != null)
          Flexible(child: Text(source, style: Tok.label.copyWith(fontSize: 10, color: Tok.dim, letterSpacing: 0), maxLines: 1, overflow: TextOverflow.ellipsis)),
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
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    label: title,
    child: MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
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
                Text(meta, style: Tok.body.copyWith(fontSize: 12.5, color: Tok.dim), maxLines: 1),
              ],
            ]),
          ),
        ),
      ),
    ),
  );
}

/// The tree around one pane, shared by its fork rows and thread marks.
class TrailPaneScope extends InheritedWidget {
  const TrailPaneScope({super.key, required this.trail, required this.stop, required this.onGo, required this.onPrune, this.ahead = const {}, this.anchors, required super.child});
  final TrailDto trail;
  final StopDto stop;

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
  ThreadWay way(TargetDto target) {
    if (next?.target == target) return ThreadWay.went;
    final parent = trail.stops.where((node) => node.index == stop.parent).firstOrNull;
    if (parent?.target == target) return ThreadWay.came;
    if (trail.stops.any((node) => (node.onPath || ahead.contains(node.index)) && node.target == target)) return ThreadWay.onTrail;
    return ThreadWay.open;
  }

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
/// you came from, elsewhere on the trail, or not taken.
enum ThreadWay { went, came, onTrail, open }

/// The end of a followable row (plate 02): `→` follows, `←` is where you
/// came from, `○` is already on this trail. The followed row's is gold.
class ThreadArrow extends StatelessWidget {
  const ThreadArrow({super.key, required this.target, this.hover = false});
  final TargetDto target;
  final bool hover;

  @override
  Widget build(BuildContext context) {
    final way = TrailPaneScope.of(context)?.way(target) ?? ThreadWay.open;
    final (glyph, colour) = switch (way) {
      ThreadWay.went => ('→', Tok.gold),
      ThreadWay.came => ('←', Tok.faint),
      ThreadWay.onTrail => ('○', Tok.dim),
      ThreadWay.open => ('→', hover ? Tok.ink : Tok.dim),
    };
    return SizedBox(width: 14, child: Text(glyph, key: ValueKey('arrow-${way.name}'), style: Tok.body.copyWith(color: colour), textAlign: TextAlign.right));
  }
}

/// A followable row: lit gold when it's the thread that led to the next
/// pane, and the start of that thread's line.
class TrailRow extends StatelessWidget {
  const TrailRow({super.key, required this.target, required this.child});
  final TargetDto target;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = TrailPaneScope.of(context);
    if (scope == null || scope.way(target) != ThreadWay.went) return child;
    final lit = DecoratedBox(
      key: const ValueKey('thread-went'),
      decoration: const BoxDecoration(color: Color(0x1AD2A64E), border: Border(left: BorderSide(color: Tok.gold, width: 2))),
      child: Padding(padding: const EdgeInsets.only(left: 6), child: child),
    );
    final anchors = scope.anchors;
    return anchors == null ? lit : ThreadAnchor(anchors: anchors, end: ThreadEnd.went, stop: scope.stop.index, child: lit);
  }
}

/// Appended to a followed thread without changing its destination or action.
class TrailThreadMark extends StatelessWidget {
  const TrailThreadMark({super.key, required this.target});
  final TargetDto target;

  @override
  Widget build(BuildContext context) {
    final title = TrailPaneScope.of(context)?.followedLeaf(target);
    return title == null ? const SizedBox.shrink() : Text('⑂ → $title', style: Tok.label.copyWith(color: Tok.dim), maxLines: 1, overflow: TextOverflow.ellipsis);
  }
}

/// Shared fork rows, as a sliver for entity panes or a box for search.
class ForksHere extends StatelessWidget {
  const ForksHere({super.key, this.sliver = true});
  final bool sliver;

  @override
  Widget build(BuildContext context) {
    final scope = TrailPaneScope.of(context);
    final branches = scope?.trail.branches.where((branch) => branch.fork == scope.stop.index).toList() ?? const <BranchDto>[];
    if (scope == null || !scope.stop.isFork || branches.isEmpty) {
      return sliver ? const SliverToBoxAdapter(child: SizedBox.shrink()) : const SizedBox.shrink();
    }
    final stops = {for (final stop in scope.trail.stops) stop.index: stop};
    final content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        margin: EdgeInsets.only(top: sliver ? 18 : 8, bottom: 6),
        padding: const EdgeInsets.only(bottom: 6),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.rule))),
        child: const Text('Forks here', style: Tok.label),
      ),
      for (final branch in branches)
        Row(children: [
          Expanded(child: Semantics(
            selected: branch.current,
            button: true,
            child: InkWell(
              key: ValueKey('fork-${scope.stop.index}-${branch.leaf}'),
              onTap: () => scope.onGo(branch.leaf),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.line))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(stops[branch.leaf]!.title, style: Tok.body.copyWith(color: branch.current ? Tok.gold : Tok.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text([
                    ?stops[branch.first]?.via,
                    agoShort(branch.whenMs.toInt()),
                    ...branch.actions,
                  ].join(' · '), style: Tok.label),
                ]),
              ),
            ),
          )),
          if (branch.prunable) TextButton(
            key: ValueKey('prune-${scope.stop.index}-${branch.leaf}'),
            onPressed: () => scope.onPrune(branch.leaf),
            child: Text('prune', style: Tok.label.copyWith(color: Tok.dim)),
          ),
        ]),
    ]);
    return sliver ? SliverToBoxAdapter(child: content) : content;
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
