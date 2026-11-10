import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

/// One line of a row's menu. A null [onPressed] shows it greyed.
class RowAction {
  const RowAction(this.label, this.onPressed, {this.shortcut});

  final String label;
  final VoidCallback? onPressed;

  /// Shown beside the label; the pane handles the key itself.
  final SingleActivator? shortcut;
}

/// The keys every track and release row shares.
abstract final class RowKeys {
  static const play = SingleActivator(LogicalKeyboardKey.enter);
  static const playNext = SingleActivator(LogicalKeyboardKey.enter, shift: true);
  static const addToQueue = SingleActivator(LogicalKeyboardKey.enter, alt: true);
  static const open = SingleActivator(LogicalKeyboardKey.enter, meta: true);
  static const reveal = SingleActivator(LogicalKeyboardKey.keyR, shift: true, meta: true);

  /// Runs the action whose key this is: ↵ plays, ⇧↵ plays next, ⌥↵ adds to
  /// the queue, ⌘↵ opens, ⇧⌘R shows the file in Finder.
  static KeyEventResult handle(KeyEvent event, {VoidCallback? play, VoidCallback? playNext, VoidCallback? addToQueue, VoidCallback? open, VoidCallback? reveal}) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    for (final (activator, action) in [(RowKeys.play, play), (RowKeys.playNext, playNext), (RowKeys.addToQueue, addToQueue), (RowKeys.open, open), (RowKeys.reveal, reveal)]) {
      if (action != null && activator.accepts(event, keys)) {
        action();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }
}

/// Moves a tracklist's selection on ↑ and ↓ and scrolls the row it lands
/// on into view. Each row carries [key] for its index; [clear] when the list
/// is rebuilt for other contents.
class RowCursor {
  final _keys = <int, GlobalKey>{};

  GlobalKey key(int index) => _keys.putIfAbsent(index, GlobalKey.new);

  void clear() => _keys.clear();

  /// The index ↑ or ↓ moves [selected] to among [count] rows, or null when
  /// [event] is another key. With nothing selected, either arrow starts at the top.
  int? move(KeyEvent event, int? selected, int count) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
    final delta = event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : event.logicalKey == LogicalKeyboardKey.arrowUp ? -1 : 0;
    if (delta == 0 || count == 0) return null;
    final index = selected == null ? 0 : (selected + delta).clamp(0, count - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final row = _keys[index]?.currentContext;
      if (row == null || !row.mounted) return;
      Scrollable.ensureVisible(row, alignmentPolicy: delta > 0 ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd : ScrollPositionAlignmentPolicy.keepVisibleAtStart);
    });
    return index;
  }
}

/// The menu of a track or release: play verbs first, then where to go, then the file.
/// A null entry is a divider.
List<RowAction?> musicActions({
  required VoidCallback? play,
  required VoidCallback? playNext,
  required VoidCallback? addToQueue,
  List<RowAction> goTo = const [],
  VoidCallback? reveal,
}) => [
  RowAction('Play now', play, shortcut: RowKeys.play),
  RowAction('Play next', playNext, shortcut: RowKeys.playNext),
  RowAction('Add to queue', addToQueue, shortcut: RowKeys.addToQueue),
  if (goTo.isNotEmpty) null,
  ...goTo,
  if (reveal != null) ...[null, RowAction('Show in Finder', reveal, shortcut: RowKeys.reveal)],
];

/// Selects `path` in a Finder window.
Future<void> revealInFinder(String path) async {
  await Process.run('open', ['-R', path]);
}

/// "Queued 12 tracks next", "Added 1 track to the queue".
String queuedLine(int count, {required bool next}) {
  final tracks = '$count ${count == 1 ? 'track' : 'tracks'}';
  return next ? 'Playing $tracks next' : 'Added $tracks to the queue';
}

/// A short line saying what a menu did, for actions whose result is out of view.
void announce(BuildContext context, String text) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(text, style: Tok.body, maxLines: 1, overflow: TextOverflow.ellipsis),
      behavior: SnackBarBehavior.floating,
      width: 420,
      duration: const Duration(seconds: 2),
      backgroundColor: Tok.panel2,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4), side: const BorderSide(color: Tok.rule)),
    ));
}

/// A right-click, a two-finger click on a trackpad, or a ⌃-click.
bool isMenuClick(PointerDownEvent event) =>
  event.buttons & kSecondaryButton != 0 || (event.buttons == kPrimaryButton && HardwareKeyboard.instance.isControlPressed);

/// Opens [actions] at the pointer on a menu click, in the [RowMenuHost] above.
///
/// The menu opens on the pointer down itself, outside the gesture arena: a
/// secondary tap recognizer waits out its rivals before it fires and gives up
/// when two fingers drift on a trackpad. The innermost menu under the pointer
/// wins, so a row inside a row opens only its own.
class RowMenu extends StatelessWidget {
  const RowMenu({super.key, required this.actions, required this.child, this.onOpen});

  /// Built when the menu opens, so rows that are never right-clicked build none.
  final List<RowAction?> Function() actions;
  final Widget child;

  /// Runs before the menu opens; rows select themselves here.
  final VoidCallback? onOpen;

  /// The pointer down an inner menu already answered.
  static int? _claimed;

  void _down(BuildContext context, PointerDownEvent event) {
    if (!isMenuClick(event) || _claimed == event.pointer) return;
    final actions = this.actions();
    if (actions.isEmpty) return;
    _claimed = event.pointer;
    onOpen?.call();
    RowMenuHost.maybeOf(context)?.show(event.position, actions);
  }

  @override
  Widget build(BuildContext context) => Listener(onPointerDown: (event) => _down(context, event), child: child);
}

/// Whether [event] is a plain click that a row should act on: the primary
/// button, not a ⌃-click, which is the menu's.
bool isPlainClick(PointerDownEvent event) => event.buttons == kPrimaryButton && !isMenuClick(event);

/// Swallows the second click of a double click, so a row that plays on one
/// click doesn't start its track twice for a habit of two. [dispose] it with
/// the row.
class ClickOnce {
  Timer? _held;

  /// True when this click should act.
  bool take() {
    final fresh = _held == null;
    _held?.cancel();
    _held = Timer(kDoubleTapTimeout, () => _held = null);
    return fresh;
  }

  void dispose() => _held?.cancel();
}

/// Holds the one menu every row opens, drawn as the instrument: one panel,
/// gold on the line under the pointer.
///
/// It sits above the panes' scrollables. A menu anchored inside one closes
/// whenever it starts or stops scrolling, which a two-finger click on a
/// trackpad does without moving anything; here only real movement closes it.
class RowMenuHost extends StatefulWidget {
  const RowMenuHost({super.key, required this.child});

  final Widget child;

  static RowMenuHostState? maybeOf(BuildContext context) => context.findAncestorStateOfType<RowMenuHostState>();

  @override
  State<RowMenuHost> createState() => RowMenuHostState();
}

class RowMenuHostState extends State<RowMenuHost> {
  final _controller = MenuController();
  List<RowAction?> _actions = const [];

  /// Opens [actions] at [position], in global coordinates.
  void show(Offset position, List<RowAction?> actions) {
    final at = (context.findRenderObject()! as RenderBox).globalToLocal(position);
    // After this pointer down and the microtasks it queues: an open menu takes
    // it as a tap outside, and the close it starts would land on the new menu.
    Timer.run(() {
      if (!mounted) return;
      setState(() => _actions = actions);
      _controller.open(position: at);
    });
  }

  bool _scrolled(ScrollUpdateNotification notification) {
    if (_controller.isOpen && (notification.scrollDelta ?? 0) != 0) _controller.close();
    return false;
  }

  /// Keys a menu spells out by name on macOS, drawn as the Mac draws them.
  static final _glyphs = {LogicalKeyboardKey.backspace: '⌫'};

  static final _style = MenuStyle(
    backgroundColor: const WidgetStatePropertyAll(Tok.panel2),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    shadowColor: const WidgetStatePropertyAll(Colors.black),
    elevation: const WidgetStatePropertyAll(10),
    side: const WidgetStatePropertyAll(BorderSide(color: Tok.rule)),
    shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(5))),
    padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
  );

  static final _item = ButtonStyle(
    textStyle: const WidgetStatePropertyAll(Tok.body),
    foregroundColor: WidgetStateProperty.resolveWith((states) =>
      states.contains(WidgetState.disabled) ? Tok.dim
        : states.contains(WidgetState.hovered) || states.contains(WidgetState.focused) ? Tok.void_ : Tok.ink),
    backgroundColor: WidgetStateProperty.resolveWith((states) =>
      !states.contains(WidgetState.disabled) && (states.contains(WidgetState.hovered) || states.contains(WidgetState.focused)) ? Tok.gold : Colors.transparent),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    minimumSize: const WidgetStatePropertyAll(Size(220, 28)),
    maximumSize: const WidgetStatePropertyAll(Size(380, 28)),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
    shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(3))),
    visualDensity: VisualDensity.compact,
  );

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollUpdateNotification>(
    onNotification: _scrolled,
    child: Stack(fit: StackFit.passthrough, children: [
      widget.child,
      Positioned(left: 0, top: 0, child: MenuAnchor(
        controller: _controller,
        style: _style,
        menuChildren: [
          for (final action in _actions)
            if (action == null)
              const Divider(height: 9, thickness: 1, color: Tok.rule, indent: 2, endIndent: 2)
            else
              MenuItemButton(
                style: _item,
                shortcut: _glyphs.containsKey(action.shortcut?.trigger) ? null : action.shortcut,
                trailingIcon: switch (_glyphs[action.shortcut?.trigger]) {
                  final glyph? => Text(glyph),
                  null => null,
                },
                onPressed: action.onPressed,
                child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 250), child: Text(action.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ),
        ],
        child: const SizedBox.shrink(),
      )),
    ]),
  );
}
