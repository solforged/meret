import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;

import '../core/bridge.dart';
import '../theme/action_target.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';
import 'pane.dart';
import 'row_menu.dart';

/// A track in a release, game or work tracklist.
///
/// One grammar for every tracklist: a click anywhere on the row plays from
/// it, the arrow at its end follows the thread named under the title (its
/// work, or the release it is on), and a right-click opens [actions]. Nothing
/// inside the row takes a click for itself except that arrow.
class TrackRow extends StatefulWidget {
  const TrackRow({
    super.key, required this.title, required this.onPlay, required this.actions,
    this.position, this.wide = false, this.under = const [], this.thread, this.threadLine = true, this.onFollow, this.followKey,
    this.arrowSlot = false, this.aside, this.length = '', this.playing = false, this.selected = false,
  });

  final String title;
  final VoidCallback onPlay;

  /// The row's menu, built when it opens.
  final List<RowAction?> Function() actions;

  /// `07` or `2-07`; empty for an unnumbered track, null in a list without numbers.
  final String? position;

  /// The list numbers its discs, so the numbers need the room.
  final bool wide;

  /// Plain lines under the title: who plays this recording.
  final List<String> under;

  /// The thread this row can follow, named on the last line under the title.
  final ThreadDto? thread;

  /// False when [under] already says where the arrow goes, as a queue row's does.
  final bool threadLine;
  final VoidCallback? onFollow;
  final Key? followKey;

  /// Keeps the arrow's room on a row without a thread, so a list where only
  /// some rows have one keeps its lengths in a column.
  final bool arrowSlot;

  /// Who, at the right, when it isn't the release's own artist.
  final String? aside;
  final String length;
  final bool playing;
  final bool selected;

  static const _arrow = 26.0;

  @override
  State<TrackRow> createState() => _TrackRowState();
}

class _TrackRowState extends State<TrackRow> {
  final _click = ClickOnce();
  bool _hover = false;

  @override
  void dispose() {
    _click.dispose();
    super.dispose();
  }

  void _tap() {
    if (_click.take()) widget.onPlay();
  }

  @override
  Widget build(BuildContext context) {
    final TrackRow(:title, :position, :under, :thread, :aside, :length, :playing, :selected) = widget;
    final light = Light.of(context);
    final scope = thread == null ? null : TrailPaneScope.of(context);
    final went = thread != null && scope?.way(thread.to, via: thread.label) == ThreadWay.went;
    // The lead slot answers the pointer: the number gives way to what a click does.
    final lead = _hover || playing
        ? Icon(Icons.play_arrow, size: 14, color: playing ? light.accent : Tok.ink)
        : Text(position ?? '', style: Tok.monoSmall, maxLines: 1, softWrap: false, overflow: TextOverflow.clip);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: RowMenu(
        actions: widget.actions,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _tap,
          child: ThreadRowBox(
            target: thread?.to, via: thread?.label, hover: _hover, vertical: 5,
            edge: playing ? light.accent : null,
            fill: playing ? light.wash : selected ? Tok.pick : null,
            child: Row(children: [
              SizedBox(width: position == null ? 20 : widget.wide ? 40 : 28, child: Align(alignment: Alignment.centerLeft, child: lead)),
              Expanded(child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Tok.body.copyWith(color: playing ? light.accent : Tok.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
                  for (final line in under) Text(line, style: Tok.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (thread != null && widget.threadLine)
                    Text(thread.title, style: Tok.labelMuted.copyWith(color: went ? Tok.gold : Tok.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              )),
              // The title keeps the room: who is a short word at its side.
              if (aside != null)
                Container(
                  constraints: const BoxConstraints(maxWidth: 112),
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(aside, style: Tok.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              const SizedBox(width: 8),
              Text(length, style: Tok.monoSmall),
              if (thread != null)
                _Follow(key: widget.followKey, thread: thread, onFollow: widget.onFollow, rowHover: _hover)
              else if (widget.arrowSlot)
                const SizedBox(width: TrackRow._arrow),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The arrow at a track row's end: the one part of the row that goes
/// somewhere instead of playing.
class _Follow extends StatefulWidget {
  const _Follow({super.key, required this.thread, required this.onFollow, required this.rowHover});
  final ThreadDto thread;
  final VoidCallback? onFollow;
  final bool rowHover;

  @override
  State<_Follow> createState() => _FollowState();
}

class _FollowState extends State<_Follow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Go to ${widget.thread.title}',
    waitDuration: const Duration(milliseconds: 500),
    excludeFromSemantics: true,
    child: MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: ActionTarget(
        onTap: widget.onFollow,
        semanticLabel: 'Go to ${widget.thread.title}',
        excludeChildSemantics: true,
        child: Container(
          width: 22, height: 22,
          margin: const EdgeInsets.only(left: TrackRow._arrow - 22),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: _hover ? Tok.rule : Colors.transparent, borderRadius: BorderRadius.circular(3)),
          child: ThreadArrow(target: widget.thread.to, via: widget.thread.label, hover: _hover || widget.rowHover),
        ),
      ),
    ),
  );
}

/// Queues through [queue] and says what went in, or why it didn't.
Future<void> queueAndSay(BuildContext context, Future<int> Function() queue, {required bool next}) async {
  try {
    final count = await queue();
    if (context.mounted) announce(context, count == 0 ? 'Nothing to queue' : queuedLine(count, next: next));
  } catch (error) {
    if (context.mounted) announce(context, error.toString());
  }
}

/// "Go to" for a track's own artist, as the thread a tag credit is.
ThreadDto artistThread(TrackRowDto row) => ThreadDto(
  kind: ThreadKind.by, label: 'by', source: 'tags', provider: 'local_tags',
  to: TargetDto.person(id: row.artistId!), title: row.artist ?? '', detail: '',
);

/// A release's menu wherever one is listed outside a tracklist: the play
/// verbs, then the way to its pane.
List<RowAction?> releaseActions(BuildContext context, CoreBridge core, PlatformInt64 id, {VoidCallback? onOpen}) => musicActions(
  play: () => core.playRelease(id: id, index: 0).catchError((Object error) {
    if (context.mounted) announce(context, error.toString());
  }),
  playNext: () => queueAndSay(context, () => core.queueRelease(id, next: true), next: true),
  addToQueue: () => queueAndSay(context, () => core.queueRelease(id, next: false), next: false),
  goTo: [if (onOpen != null) RowAction('Go to release', onOpen)],
);

/// A lone track's menu, where it is listed away from its tracklist: it can
/// join the queue, and its release can open. Empty when there is neither.
List<RowAction?> trackActions(BuildContext context, CoreBridge core, PlatformInt64? track, {VoidCallback? onOpen}) => [
  if (track != null) ...[
    RowAction('Play next', () => queueAndSay(context, () => core.queueTracks([track], next: true), next: true), shortcut: RowKeys.playNext),
    RowAction('Add to queue', () => queueAndSay(context, () => core.queueTracks([track], next: false), next: false), shortcut: RowKeys.addToQueue),
  ],
  if (track != null && onOpen != null) null,
  if (onOpen != null) RowAction('Go to release', onOpen),
];
