import 'dart:async';
import 'dart:io';
import 'dart:math' show min;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;

import '../core/bridge.dart';
import '../core/playhead.dart';
import '../core/when.dart';
import '../draw/body_painter.dart';
import '../panes/release_mark.dart';
import '../panes/row_menu.dart';
import '../panes/track_row.dart';
import '../theme/action_target.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';
import 'zones.dart';
import 'folder_error.dart';
import 'picks.dart';
import 'signal_path.dart';

/// Now: what's playing, the transport, the signal path and the queue.
/// Pinned at the right from 1800 px, opened beside the panes below that; [NowBar] on a phone. [nothingToPlay]
/// is why play has nothing to play, when it hasn't: the title slot says so.
class NowPane extends StatelessWidget {
  const NowPane({
    super.key, required this.core, required this.now, required this.clock, required this.onToggle,
    this.onRelease, this.settingsChanges, this.nothingToPlay,
  });

  final CoreBridge core;
  final NowDto? now;
  final PlayheadClock clock;
  final VoidCallback onToggle;
  final Future<void> Function(PlatformInt64)? onRelease;
  final Listenable? settingsChanges;
  final NothingToPlayDto? nothingToPlay;

  @override
  Widget build(BuildContext context) {
    final n = now;
    final loaded = n?.anchor != null;
    final light = Light.of(context);
    return Container(
      color: Color.alphaBlend(light.wash, Tok.panel),
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Expanded(child: Text('NOW', style: Tok.caps)),
          ListenableBuilder(
            listenable: clock,
            builder: (_, _) => Text(!loaded ? '' : clock.playing ? 'playing' : 'paused', style: Tok.label),
          ),
        ]),
        const SizedBox(height: 8),
        Text(nowTitle(n, nothingToPlay: nothingToPlay), style: Tok.title.copyWith(fontSize: 17), maxLines: 2, overflow: TextOverflow.ellipsis),
        Text(n?.subtitle ?? '', style: Tok.body.copyWith(color: Tok.muted, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
        if (!loaded && nothingToPlay != null)
          NothingToPlayNote(reason: nothingToPlay!, core: core, label: false, padding: EdgeInsets.zero),
        if (n?.releaseId != null && onRelease != null)
          Align(alignment: Alignment.centerLeft, child: TextButton.icon(
            key: const ValueKey('now-open-release'),
            onPressed: () => onRelease!(n!.releaseId!),
            icon: const Icon(Icons.arrow_outward, size: 14),
            label: const Text('Go to release'),
          )),
        if (n != null) NowFacts(now: n),
        _WhySlot(n?.why),
        if (n?.error case final error?)
          FolderError(message: error, actionKey: const ValueKey('now-check-folders'), padding: const EdgeInsets.only(top: 4)),
        const SizedBox(height: 10),
        // The LCD above carries previous, play and next; the pane keeps a
        // seek bar wide enough to aim, which the LCD's hairline isn't.
        SeekBar(core: core, now: n, clock: clock),
        Expanded(flex: 4, child: NowDial(now: n, clock: clock, onToggle: loaded ? onToggle : null)),
        Expanded(flex: 5, child: SingleChildScrollView(
          key: const PageStorageKey('now-pane'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // The output's own block: the path to it, what the path does to
            // the sound, and its volume. Paused or stopped there is no path
            // to draw, so no heading either.
            if (n != null && (n.path.isNotEmpty || n.fidelity != null)) ...[
              const Text('SIGNAL PATH', style: Tok.caps),
              const SizedBox(height: 6),
              SignalStages(n.path),
              if (n.fidelity != null) Padding(
                padding: const EdgeInsets.only(top: 6),
                child: NowFidelity(now: n, exclusive: core.settings().exclusive),
              ),
              const SizedBox(height: 2),
            ],
            DeviceVolume(core: core, now: now),
            const SizedBox(height: 14),
            PlayOn(core: core, now: n, settingsChanges: settingsChanges),
            if (loaded) ...[
              UpNext(core: core, now: n, onRelease: onRelease),
              const SizedBox(height: 14),
            ],
            PlaySomething(core: core, now: n, onRelease: onRelease, actions: loaded || nothingToPlay == null),
            const SizedBox(height: 12),
            NowMemory(core: core, now: n, resumeLimit: 3, historyLimit: 3, onRelease: onRelease),
            const SizedBox(height: 12),
          ]),
        )),
      ]),
    );
  }
}

/// The bare dial shared by Today's Resume and the pinned pane.
class NowDial extends StatelessWidget {
  const NowDial({super.key, required this.now, required this.clock, this.onToggle});
  final NowDto? now;
  final PlayheadClock clock;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) => ActionTarget(
    onTap: onToggle,
    semanticLabel: clock.playing ? 'Pause' : 'Play',
    excludeChildSemantics: true,
    child: RepaintBoundary(child: Stack(alignment: Alignment.center, children: [
      CustomPaint(
        size: Size.infinite,
        painter: BodyPainter(
          clock: clock, lengthMs: (now?.body?.lengthMs ?? now?.lengthMs)?.toDouble() ?? 1,
          loudness: now?.body?.loudness ?? Uint8List(0),
          bands: now?.body == null ? const [] : [now!.body!.low, now!.body!.mid, now!.body!.high],
          light: Light.of(context).accent,
        ),
      ),
      if (now?.cover case final cover?)
        ClipOval(child: Image.file(File(cover), width: 96, height: 96, fit: BoxFit.cover, cacheWidth: 256)),
    ])),
  );
}

/// The title slot's words: the loaded title, "Nothing playing", or why
/// play has nothing to play.
String nowTitle(NowDto? now, {NothingToPlayDto? nothingToPlay}) {
  if (now?.anchor == null && nothingToPlay != null) return nothingToPlay.label;
  return now?.title.isNotEmpty == true ? now!.title : 'Nothing playing';
}

/// A pick's why in gold, in a slot of two lines that is there whether or
/// not there is a why, so the transport never moves when a pick starts.
class _WhySlot extends StatelessWidget {
  const _WhySlot(this.why);
  final String? why;

  static const _lines = 2;
  static const _lineHeight = 1.3;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: SizedBox(
      height: Tok.label.fontSize! * _lineHeight * _lines,
      child: Text(
        why ?? '', key: const ValueKey('now-why'),
        style: Tok.label.copyWith(color: Tok.gold, height: _lineHeight),
        maxLines: _lines, overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}

/// A moment in the when voice. "just now" turns into the clock time a
/// minute after the moment, the one rebuild a paused Now ever asks for.
class Moment extends StatefulWidget {
  const Moment({super.key, required this.ms, required this.builder});
  final int ms;
  final Widget Function(BuildContext context, String when) builder;

  @override
  State<Moment> createState() => _MomentState();
}

class _MomentState extends State<Moment> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(Moment old) {
    super.didUpdateWidget(old);
    if (old.ms != widget.ms) _arm();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _arm() {
    _timer?.cancel();
    final left = justNow - DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(widget.ms));
    if (left > Duration.zero) _timer = Timer(left + const Duration(seconds: 1), () => setState(() {}));
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, dayAndTime(widget.ms));
}

class NowFidelity extends StatelessWidget {
  const NowFidelity({super.key, required this.now, this.exclusive});
  final NowDto now;
  final bool? exclusive;

  @override
  Widget build(BuildContext context) => Text(
    signalVerdict(now, exclusive: exclusive) ?? '',
    style: Tok.label.copyWith(color: now.fidelity == FidelityDto.bitPerfect ? Tok.ok : Tok.warn),
  );
}

class NowFacts extends StatelessWidget {
  const NowFacts({super.key, required this.now});
  final NowDto now;

  @override
  Widget build(BuildContext context) => Text([
    if (now.path.firstOrNull?.name == 'File') now.path.first.detail,
    if (now.dr != null) 'DR ${now.dr}',
    if (now.loudnessLufs != null) '${now.loudnessLufs!.toStringAsFixed(1)} LUFS',
  ].join(' · '), style: Tok.monoSmall);
}

/// Recent listening belongs to Now, on Today and in the pinned pane.
class NowMemory extends StatefulWidget {
  const NowMemory({
    super.key, required this.core, required this.now, required this.resumeLimit,
    required this.historyLimit, this.onRelease, this.header, this.expanded = false,
  });
  final CoreBridge core;
  final NowDto? now;
  final int resumeLimit;
  final int historyLimit;
  final Future<void> Function(PlatformInt64)? onRelease;
  final Widget Function(List<ResumeDto>)? header;
  final bool expanded;

  @override
  State<NowMemory> createState() => _NowMemoryState();
}

class _NowMemoryState extends State<NowMemory> {
  List<ResumeDto> _resumes = const [];
  List<ListenDto> _history = const [];
  String? _error;

  /// A pick up that failed: it names the file, and Settings ▸ Folders is the answer.
  String? _pickUpError;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(NowMemory old) {
    super.didUpdateWidget(old);
    if (old.core != widget.core || old.now?.anchor?.item != widget.now?.anchor?.item ||
        old.now?.anchor?.rate != widget.now?.anchor?.rate) {
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final results = await Future.wait<Object>([
        widget.core.resumePoints(widget.resumeLimit), widget.core.history(widget.historyLimit),
      ]);
      if (!mounted || generation != _generation) return;
      setState(() {
        _resumes = results[0] as List<ResumeDto>;
        _history = results[1] as List<ListenDto>;
        _error = null;
        _pickUpError = null;
      });
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error.toString());
    }
  }

  Future<void> _pickUp(ResumeDto point) async {
    setState(() => _pickUpError = null);
    try {
      await widget.core.pickUp(point.releaseId);
      if (mounted) await _load();
    } catch (error) {
      if (mounted) setState(() => _pickUpError = error.toString());
    }
  }

  /// Pick up never offers what is loaded; the header above describes it.
  Iterable<ResumeDto> get _pickUps => _resumes.where((point) => point.releaseId != widget.now?.releaseId);

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    if (widget.header != null) widget.header!(_resumes),
    if (_error != null) Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(_error!, style: Tok.label.copyWith(color: Tok.warn)),
    ),
    if (_pickUpError != null)
      FolderError(message: _pickUpError!, actionKey: const ValueKey('now-pick-up-check-folders')),
    if (_pickUps.isNotEmpty) ...[
      const NowSection(title: 'Pick up'),
      for (final point in _pickUps)
        NowDoor(
          key: ValueKey('now-pick-up-${point.releaseId}'),
          onTap: () => _pickUp(point),
          actions: () => [
            RowAction('Pick up', () => _pickUp(point)),
            RowAction('From the start', () => widget.core.playRelease(id: point.releaseId, index: 0).catchError((Object error) {
              if (mounted) setState(() => _pickUpError = error.toString());
            })),
            if (widget.onRelease != null) ...[null, RowAction('Go to release', () => widget.onRelease!(point.releaseId))],
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(point.recordingTitle, style: Tok.body, maxLines: 2, overflow: TextOverflow.ellipsis),
            Text([point.title, if (point.credit != null) point.credit!].join(' · '), style: Tok.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 5),
            Text(resumeRule(point.idiom), style: Tok.label),
            const SizedBox(height: 7),
            LinearProgressIndicator(
              value: point.lengthMs == null || point.lengthMs! <= BigInt.zero ? 0 :
                (point.positionMs.toDouble() / point.lengthMs!.toDouble()).clamp(0.0, 1.0),
              minHeight: 2, color: Light.of(context).accent, backgroundColor: Tok.line,
            ),
            const SizedBox(height: 5),
            Row(children: [
              Expanded(child: Text(positionOf(point.positionMs.toInt(), point.lengthMs?.toInt()), style: Tok.monoSmall)),
              Moment(ms: point.updatedAt.toInt(), builder: (_, when) => Text(when, style: Tok.data)),
            ]),
          ]),
        ),
      const SizedBox(height: 22),
    ],
    if (_history.isNotEmpty) ...[
      NowSection(title: 'What was that?', meta: widget.expanded ? 'H for all history' : null),
      for (final listen in _history)
        NowDoor(
          key: ValueKey('now-listen-${listen.uid}'),
          onTap: widget.onRelease == null || listen.releaseId == null ? null : () => widget.onRelease!(listen.releaseId!),
          actions: () => trackActions(context, widget.core, listen.trackId,
            onOpen: widget.onRelease == null || listen.releaseId == null ? null : () => widget.onRelease!(listen.releaseId!)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text(listen.title, style: Tok.body, maxLines: 2, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              Moment(ms: listen.startedAtMs.toInt(), builder: (_, when) => Text(when, style: Tok.monoSmall)),
            ]),
            Text([
              if (listen.credit != null) listen.credit!,
              if (listen.releaseTitle != null) listen.releaseTitle!,
              listenOutcome(listen, identical(listen, _history.first) ? widget.now : null),
            ].join(' · '), style: Tok.label),
          ]),
        ),
    ],
  ]);
}

/// "m:ss of m:ss"; an unknown length reads "–:––".
String positionOf(int positionMs, int? lengthMs) =>
  '${clockLength(positionMs)} of ${lengthMs == null ? '–:––' : clockLength(lengthMs)}';

/// The idiom's resume rule as the Pick up rows and Today's Resume say it:
/// "Album · from the top of the track", "Score · the cue where it stopped".
String resumeRule(String? idiom) {
  final rule = switch (idiom) {
    'album' => 'from the top of the track',
    'song' => 'from the top of the song',
    'work' => 'from the start of the movement',
    'session' => 'from the top of the take',
    'score' => 'the cue where it stopped',
    'set' => 'the exact second',
    'spoken' => 'five seconds back',
    _ => 'where it stopped',
  };
  return idiom == null || !const ['album', 'song', 'work', 'session', 'score', 'set', 'spoken'].contains(idiom)
    ? rule : '${idiom[0].toUpperCase()}${idiom.substring(1)} · $rule';
}

/// How a listen ended, as Now and History say it: "played through",
/// "skipped at 0:01", "paused at 2:14".
String listenOutcome(ListenDto listen, NowDto? now) {
  final anchor = now?.anchor;
  if (listen.trackId != null && listen.trackId == now?.trackId && anchor != null) {
    return '${anchor.rate == 0 ? 'paused' : 'playing'} at ${clockLength(anchor.positionMs.round())}';
  }
  final length = listen.lengthMs;
  if (length != null && length > BigInt.zero && listen.playedMs >= length) return 'played through';
  return '${listen.counted ? 'played for' : 'skipped at'} ${clockLength(listen.playedMs.toInt())}';
}

class NowSection extends StatelessWidget {
  const NowSection({super.key, required this.title, this.meta});
  final String title;
  final String? meta;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.only(bottom: 7),
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.rule))),
    child: Wrap(alignment: WrapAlignment.spaceBetween, spacing: 12, runSpacing: 4, children: [
      Text(title, style: Tok.heading),
      if (meta != null) Text(meta!, style: Tok.label),
    ]),
  );
}

class NowDoor extends StatefulWidget {
  const NowDoor({super.key, required this.child, this.onTap, this.semanticLabel, this.actions});
  final Widget child;
  final VoidCallback? onTap;
  final String? semanticLabel;

  /// The row's right-click menu, built when it opens.
  final List<RowAction?> Function()? actions;

  @override
  State<NowDoor> createState() => _NowDoorState();
}

class _NowDoorState extends State<NowDoor> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
      decoration: BoxDecoration(
        color: _hover && widget.onTap != null ? Tok.panel2 : Colors.transparent,
        border: const Border(bottom: BorderSide(color: Tok.line)),
      ),
      child: widget.child,
    );
    final content = widget.actions == null ? box : RowMenu(actions: widget.actions!, child: box);
    return MouseRegion(
    cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: widget.onTap == null ? content : ActionTarget(
      onTap: widget.onTap,
      semanticLabel: widget.semanticLabel,
      child: content,
    ),
  );
  }
}

/// Now as a bar, below the panes, when the window is too narrow to pin it.
/// The title opens the full pane as a sheet, where Space still toggles.
/// [nothingToPlay] is why play has nothing to play: the title slot says so
/// until something loads.
class NowBar extends StatelessWidget {
  const NowBar({
    super.key, required this.core, required this.now, required this.clock, required this.onToggle,
    this.onRelease, this.settingsChanges, this.nothingToPlay,
  });
  final CoreBridge core;
  final NowDto? now;
  final PlayheadClock clock;
  final VoidCallback onToggle;
  final Future<void> Function(PlatformInt64)? onRelease;
  final Listenable? settingsChanges;
  final NothingToPlayDto? nothingToPlay;

  @override
  Widget build(BuildContext context) {
    final n = now;
    final loaded = n?.anchor != null;
    return Container(
      height: 56,
      color: Color.alphaBlend(Light.of(context).wash, Tok.panel),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: LayoutBuilder(builder: (context, box) {
        // A phone keeps transport and title; seek arrives at 560, volume at 760.
        final seek = box.maxWidth >= 560;
        final volume = box.maxWidth >= 760;
        return Row(children: [
          Transport(core: core, now: n, clock: clock, onToggle: onToggle, compact: true, nothingToPlay: nothingToPlay),
          const SizedBox(width: 12),
          Expanded(
            child: ActionTarget(
              key: const ValueKey('now-bar-title'),
              onTap: loaded ? () => _open(context) : null,
              semanticLabel: 'Show Now: ${nowTitle(n, nothingToPlay: nothingToPlay)}',
              excludeChildSemantics: true,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(nowTitle(n, nothingToPlay: nothingToPlay), style: Tok.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(n?.subtitle ?? '', style: Tok.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
          ),
          if (seek) ...[
            const SizedBox(width: 12),
            SizedBox(width: 200, child: SeekBar(core: core, now: n, clock: clock, compact: true)),
          ],
          if (volume) ...[
            const SizedBox(width: 12),
            DeviceVolume(core: core, now: now, compact: true),
          ],
        ]);
      }),
    );
  }

  /// The sheet fits the window with 16 px to spare on every side.
  void _space() {
    final context = FocusManager.instance.primaryFocus?.context;
    const intent = ActivateIntent();
    final action = context == null ? null : Actions.maybeFind<ActivateIntent>(context);
    if (action != null && action.isEnabled(intent)) {
      Actions.invoke(context!, intent);
    } else {
      onToggle();
    }
  }

  void _open(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (sheetContext) {
        final room = MediaQuery.sizeOf(sheetContext);
        return CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.space, includeRepeats: false): _space},
          child: Focus(
            autofocus: true,
            skipTraversal: true,
            child: Dialog(
              alignment: Alignment.bottomRight,
              insetPadding: const EdgeInsets.fromLTRB(16, 16, 16, 72),
              backgroundColor: Colors.transparent,
              child: StreamBuilder<NowDto>(
                initialData: now,
                stream: core.now(),
                builder: (_, snapshot) => SizedBox(
                  width: min(380, room.width - 32), height: min(640, room.height - 32),
                  child: NowPane(
                    core: core, now: snapshot.data, clock: clock, onToggle: onToggle,
                    settingsChanges: settingsChanges,
                    onRelease: onRelease == null ? null : (id) async {
                      Navigator.of(sheetContext).pop();
                      await onRelease!(id);
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Previous, play or pause, next, and the time. Previous and next are off
/// until something has been queued; play answers, and with nothing loaded it
/// plays something, so it is off too when [nothingToPlay] says there is nothing.
class Transport extends StatelessWidget {
  const Transport({super.key, required this.core, required this.now, required this.clock, required this.onToggle, this.compact = false, this.id = 'now', this.nothingToPlay});
  final CoreBridge core;
  final NowDto? now;
  final PlayheadClock clock;
  final VoidCallback onToggle;
  final bool compact;
  final NothingToPlayDto? nothingToPlay;

  /// Prefixes the buttons' keys: `now-toggle`, or `lcd-toggle` in the LCD.
  final String id;

  @override
  Widget build(BuildContext context) {
    final loaded = now?.anchor != null;
    final stuck = !loaded && nothingToPlay != null;
    final length = now?.lengthMs?.toDouble();
    final accent = Light.of(context).accent;
    final buttons = Row(mainAxisSize: MainAxisSize.min, children: [
      _TransportButton(
        key: ValueKey('$id-previous'),
        icon: Icons.skip_previous,
        tooltip: 'Previous',
        onPressed: loaded ? () => core.transport(const TransportDto.previous()) : null,
      ),
      ListenableBuilder(
        listenable: clock,
        builder: (_, _) => _TransportButton(
          key: ValueKey('$id-toggle'),
          icon: clock.playing ? Icons.pause : Icons.play_arrow,
          tooltip: stuck ? nothingToPlay!.label : clock.playing ? 'Pause' : 'Play',
          size: compact ? 22 : 28,
          color: accent,
          onPressed: stuck ? null : onToggle,
        ),
      ),
      _TransportButton(
        key: ValueKey('$id-next'),
        icon: Icons.skip_next,
        tooltip: 'Next',
        onPressed: loaded ? () => core.transport(const TransportDto.next()) : null,
      ),
    ]);
    if (compact) return buttons;
    return Row(children: [
      buttons,
      const Spacer(),
      ListenableBuilder(
        listenable: clock,
        builder: (_, _) => Text(
          loaded ? positionOf(clock.positionMs.round(), (length ?? 0).round()) : '–:–– of –:––',
          style: Tok.monoSmall,
        ),
      ),
    ]);
  }
}

class _TransportButton extends StatelessWidget {
  const _TransportButton({super.key, required this.icon, required this.tooltip, required this.onPressed, this.size = 20, this.color});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: IconButton(
        icon: Icon(icon, semanticLabel: tooltip),
        iconSize: size,
        color: color ?? Tok.ink,
        disabledColor: Tok.dim,
        padding: const EdgeInsets.all(4),
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
      ),
  );
}

/// A thin slider over the playing item. Dragging seeks on release; the
/// clock is re-anchored at once so the hand doesn't jump back while the
/// engine's own anchor is on its way.
class SeekBar extends StatefulWidget {
  const SeekBar({super.key, required this.core, required this.now, required this.clock, this.compact = false, this.hairline = false, this.id = 'now'});
  final CoreBridge core;
  final NowDto? now;
  final PlayheadClock clock;
  final bool compact;

  /// The LCD's scrubber: the track alone, no thumb, no time.
  final bool hairline;

  /// Prefixes the slider's key: `now-seek`, or `lcd-seek` in the LCD.
  final String id;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final anchor = widget.now?.anchor;
    final length = widget.now?.lengthMs?.toDouble();
    final enabled = anchor != null && length != null && length > 0;
    return ListenableBuilder(
      listenable: widget.clock,
      builder: (_, _) {
        final position = (_dragging ?? (enabled ? widget.clock.positionMs : 0.0)).clamp(0.0, length ?? 1.0).toDouble();
        final slider = ThinSlider(
          sliderKey: ValueKey('${widget.id}-seek'),
          value: enabled ? position / length : 0,
          semanticFormatterCallback: (value) => 'Seek to ${clockLength((value * (length ?? 0)).round())}',
          onChanged: enabled ? (value) => setState(() => _dragging = value * length) : null,
          onChangeEnd: enabled ? (value) => _seek(anchor, value * length) : null,
          hairline: widget.hairline,
        );
        if (!widget.compact || widget.hairline) return slider;
        return Row(children: [
          Expanded(child: slider),
          const SizedBox(width: 6),
          Text(enabled ? positionOf(position.round(), length.round()) : '–:–– of –:––', style: Tok.monoSmall),
        ]);
      },
    );
  }

  Future<void> _seek(AnchorDto anchor, double ms) async {
    setState(() => _dragging = null);
    widget.clock.anchor(AnchorDto(item: anchor.item, positionMs: ms, rate: widget.clock.playing ? 1 : 0));
    await widget.core.transport(TransportDto.seek(ms: BigInt.from(ms.round())));
  }
}

/// The queue after the playing item, refetched when that item changes.
class UpNext extends StatefulWidget {
  const UpNext({super.key, required this.core, required this.now, this.limit = 8, this.onRelease});
  final CoreBridge core;
  final NowDto? now;
  final int limit;
  final Future<void> Function(PlatformInt64)? onRelease;

  @override
  State<UpNext> createState() => _UpNextState();
}

class _UpNextState extends State<UpNext> {
  UpNextDto? _upNext;
  int _request = 0;
  late int _limit = widget.limit;
  String? _error;
  bool _loading = false;
  BigInt? _playing;

  @override
  void initState() {
    super.initState();
    widget.core.queueChanged.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(UpNext old) {
    super.didUpdateWidget(old);
    if (old.core != widget.core) {
      old.core.queueChanged.removeListener(_load);
      widget.core.queueChanged.addListener(_load);
    }
    if (old.core != widget.core || old.limit != widget.limit) {
      _limit = widget.limit;
    }
    if (old.core != widget.core || old.now?.anchor?.item != widget.now?.anchor?.item || old.limit != widget.limit) _load();
  }

  @override
  void dispose() {
    widget.core.queueChanged.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() => _loading = true);
    try {
      final upNext = await widget.core.upNext(_limit);
      if (mounted && request == _request) {
        setState(() {
          _upNext = upNext;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted && request == _request) setState(() => _error = error.toString());
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<bool> _play(UpNextItemDto item) async {
    if (_playing != null) return false;
    setState(() => _playing = item.token);
    try {
      await widget.core.jumpToQueued(item.token);
      if (mounted) await _load();
      return true;
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
      return false;
    } finally {
      if (mounted) setState(() => _playing = null);
    }
  }

  /// The way from a queued track to its release, when it has one to open.
  ThreadDto? _release(UpNextItemDto item) => item.releaseId == null || widget.onRelease == null ? null : ThreadDto(
    kind: ThreadKind.appearsOn, label: 'appears on', source: 'queue', provider: 'local',
    to: TargetDto.release(id: item.releaseId!), title: 'the release of ${item.title}', detail: '',
  );

  Future<void> _inspect(UpNextItemDto item) async {
    if (item.releaseId != null && widget.onRelease != null) {
      try {
        await widget.onRelease!(item.releaseId!);
        // After the pane has opened, so the release marks this row, not a bare page.
        if (item.trackId != null) ReleaseMark.instance.mark(item.releaseId!.toInt(), item.trackId!.toInt());
      } catch (error) {
        if (mounted) setState(() => _error = error.toString());
      }
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item.title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(item.subtitle),
          if (item.lengthMs != null) Text(clockLength(item.lengthMs!.toInt())),
          if (item.why != null) Text(item.why!),
        ]),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final upNext = _upNext;
    final remaining = upNext?.remaining.toInt() ?? 0;
    final more = remaining - (upNext?.items.length ?? 0);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      NowSection(title: 'Up next', meta: switch (upNext) {
        null => null,
        _ when remaining == 0 => 'then stop',
        _ when more > 0 => '$remaining track${remaining == 1 ? '' : 's'}',
        _ => null,
      }),
      // A failed load has Try again; a play or open that failed names the file and points at the folders.
      if (_error != null)
        upNext == null
          ? Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(_error!, style: Tok.label.copyWith(color: Tok.warn)))
          : FolderError(message: _error!, actionKey: const ValueKey('up-next-check-folders'), padding: const EdgeInsets.symmetric(vertical: 6)),
      if (upNext == null && _loading) const Text('Reading the queue…', style: Tok.label),
      if (upNext == null && _error != null)
        TextButton(onPressed: _loading ? null : _load, child: const Text('Try again')),
      // A queued track is a track row: a click plays from it, the arrow goes to its release.
      for (final (index, item) in (upNext?.items ?? const <UpNextItemDto>[]).indexed)
        Semantics(
          key: ValueKey('up-next-${item.token}'),
          button: true,
          label: 'Play ${item.title}',
          child: TrackRow(
            title: item.title,
            // How many tracks away it is.
            position: '${index + 1}',
            under: [_playing == item.token ? 'Starting…' : item.why ?? item.subtitle],
            length: item.lengthMs == null ? '' : clockLength(item.lengthMs!.toInt()),
            thread: _release(item),
            threadLine: false,
            onFollow: () => _inspect(item),
            followKey: ValueKey('up-next-open-${item.token}'),
            arrowSlot: true,
            onPlay: () => _play(item),
            actions: () => [
              RowAction('Play now', _playing == null ? () => _play(item) : null, shortcut: RowKeys.play),
              if (_release(item) != null) ...[null, RowAction('Go to release', () => _inspect(item))],
            ],
          ),
        ),
      if (more > 0) Align(alignment: Alignment.centerLeft, child: TextButton(
        key: const ValueKey('up-next-more'),
        onPressed: _loading ? null : () {
          _limit += min(more, 50);
          _load();
        },
        child: Text(_loading ? 'Reading…' : 'Show ${min(more, 50)} more'),
      )),
    ]);
  }
}


/// The instrument's slider: a 2 px track and a small thumb in the light.
/// The track has no overlay portal; moving it cannot orphan native AX nodes.
class ThinSlider extends StatefulWidget {
  const ThinSlider({super.key, this.sliderKey, required this.value, required this.onChanged, this.onChangeEnd, this.semanticFormatterCallback, this.hairline = false});
  final Key? sliderKey;
  final bool hairline;
  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final SemanticFormatterCallback? semanticFormatterCallback;

  @override
  State<ThinSlider> createState() => _ThinSliderState();
}

class _ThinSliderState extends State<ThinSlider> {
  final _focus = FocusNode(debugLabel: 'slider');
  double? _dragging;
  bool _showFocus = false;
  bool _hover = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _adjust(double value) {
    if (widget.onChanged == null) return;
    final next = value.clamp(0.0, 1.0);
    widget.onChanged!(next);
    widget.onChangeEnd?.call(next);
  }

  void _move(double x, double width, double padding, bool rtl) {
    if (widget.onChanged == null || width <= padding * 2) return;
    final position = ((x - padding) / (width - padding * 2)).clamp(0.0, 1.0);
    final value = rtl ? 1 - position : position;
    setState(() => _dragging = value);
    widget.onChanged!(value);
  }

  void _finish() {
    final value = _dragging;
    if (value == null) return;
    setState(() => _dragging = null);
    if (widget.onChanged != null) widget.onChangeEnd?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    final position = (_dragging ?? widget.value).clamp(0.0, 1.0);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    String describe(double value) => widget.semanticFormatterCallback?.call(value) ?? '${(value * 100).round()}%';
    final step = switch (Theme.of(context).platform) {
      TargetPlatform.iOS || TargetPlatform.macOS => 0.1,
      _ => 0.05,
    };
    final increased = (position + step).clamp(0.0, 1.0);
    final decreased = (position - step).clamp(0.0, 1.0);
    return Semantics(
      key: widget.sliderKey,
      container: true,
      excludeSemantics: true,
      slider: true,
      enabled: enabled,
      focusable: enabled,
      focused: enabled && _focus.hasFocus,
      value: describe(position),
      increasedValue: enabled && position < 1 ? describe(increased) : null,
      decreasedValue: enabled && position > 0 ? describe(decreased) : null,
      onIncrease: enabled && position < 1 ? () => _adjust(increased) : null,
      onDecrease: enabled && position > 0 ? () => _adjust(decreased) : null,
      onDidGainAccessibilityFocus: enabled ? _focus.requestFocus : null,
      child: CallbackShortcuts(
        bindings: enabled ? {
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _adjust(position + (rtl ? -step : step)),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _adjust(position + (rtl ? step : -step)),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _adjust(increased),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _adjust(decreased),
          const SingleActivator(LogicalKeyboardKey.home, includeRepeats: false): () => _adjust(0),
          const SingleActivator(LogicalKeyboardKey.end, includeRepeats: false): () => _adjust(1),
        } : const {},
        child: FocusableActionDetector(
          focusNode: _focus,
          enabled: enabled,
          includeFocusSemantics: false,
          mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
          onFocusChange: (_) => setState(() {}),
          onShowFocusHighlight: (show) => setState(() => _showFocus = show),
          onShowHoverHighlight: (hover) => setState(() => _hover = hover),
          child: LayoutBuilder(builder: (context, box) {
            final width = box.hasBoundedWidth ? box.maxWidth : 144.0;
            final padding = widget.hairline ? 0.0 : min(12.0, width / 4);
            void move(Offset offset) => _move(offset.dx, width, padding, rtl);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTapDown: enabled ? (_) => _focus.requestFocus() : null,
              onTapUp: enabled ? (details) { move(details.localPosition); _finish(); } : null,
              onHorizontalDragStart: enabled ? (details) { _focus.requestFocus(); move(details.localPosition); } : null,
              onHorizontalDragUpdate: enabled ? (details) => move(details.localPosition) : null,
              onHorizontalDragEnd: enabled ? (_) => _finish() : null,
              onHorizontalDragCancel: enabled ? _finish : null,
              child: CustomPaint(
                painter: _ThinSliderPainter(position: position, padding: padding, rtl: rtl,
                  accent: Light.of(context).accent, enabled: enabled, hairline: widget.hairline,
                  showFocus: _showFocus, hover: _hover),
                child: SizedBox(width: width, height: widget.hairline ? 10 : 32),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _ThinSliderPainter extends CustomPainter {
  const _ThinSliderPainter({required this.position, required this.padding, required this.rtl,
    required this.accent, required this.enabled, required this.hairline, required this.showFocus, required this.hover});
  final double position;
  final double padding;
  final bool rtl;
  final Color accent;
  final bool enabled;
  final bool hairline;
  final bool showFocus;
  final bool hover;

  @override
  void paint(Canvas canvas, Size size) {
    final left = padding;
    final right = size.width - padding;
    final y = size.height / 2;
    final x = left + (right - left) * (rtl ? 1 - position : position);
    final paint = Paint()..strokeWidth = 2..color = Tok.line;
    canvas.drawLine(Offset(left, y), Offset(right, y), paint);
    paint.color = enabled ? accent : Tok.line;
    canvas.drawLine(Offset(rtl ? right : left, y), Offset(x, y), paint);
    if (enabled && hover && !hairline) {
      canvas.drawCircle(Offset(x, y), 9, Paint()..color = accent.withValues(alpha: 0.15));
    }
    if (!hairline) canvas.drawCircle(Offset(x, y), enabled ? 5 : 3, Paint()..color = enabled ? accent : Tok.dim);
    if (enabled && showFocus && size.width > 2 && size.height > 2) {
      canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(2)).deflate(1),
        Paint()..color = Tok.gold..style = PaintingStyle.stroke..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(_ThinSliderPainter old) => position != old.position || padding != old.padding || rtl != old.rtl ||
    accent != old.accent || enabled != old.enabled || hairline != old.hairline || showFocus != old.showFocus || hover != old.hover;
}


/// The output device's own volume; samples stay untouched. [compact] is
/// the slider alone, for Now as a bar, with the reason as a tooltip. Now
/// carries the volume while something plays, so the volume keys move the
/// slider too.
class DeviceVolume extends StatefulWidget {
  const DeviceVolume({super.key, required this.core, required this.now, this.compact = false});
  final CoreBridge core;
  final NowDto? now;
  final bool compact;

  @override
  State<DeviceVolume> createState() => _DeviceVolumeState();
}

class _DeviceVolumeState extends State<DeviceVolume> {
  VolumeDto? _volume;
  double? _dragging;
  String? _error;
  bool _saving = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _volume = widget.now?.volume;
    if (_volume == null) _load();
  }

  @override
  void didUpdateWidget(DeviceVolume oldWidget) {
    super.didUpdateWidget(oldWidget);
    final volume = widget.now?.volume;
    if (oldWidget.core != widget.core) {
      _load();
    } else if (volume != null) {
      if (volume != oldWidget.now?.volume && !_saving && _dragging == null) {
        ++_request;
        _volume = volume;
        _error = null;
      }
    } else if (oldWidget.now != widget.now) {
      _load();
    }
  }

  Future<void> _load() async {
    if (_saving || _dragging != null) return;
    final request = ++_request;
    try {
      final volume = await widget.core.volume();
      if (mounted && request == _request) setState(() { _volume = volume; _error = null; });
    } catch (error) {
      if (mounted && request == _request) setState(() => _error = error.toString());
    }
  }

  Future<void> _save(double scalar) async {
    ++_request;
    setState(() { _saving = true; _error = null; });
    try {
      final volume = await widget.core.setVolume(scalar);
      if (mounted) setState(() => _volume = volume);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() { _saving = false; _dragging = null; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final volume = _volume;
    final enabled = volume?.settable == true && volume?.scalar != null && !_saving && _error == null;
    final scalar = (_dragging ?? volume?.scalar ?? 0).clamp(0.0, 1.0);
    final level = volume?.muted == true && _dragging == null ? 'muted' : '${(scalar * 100).round()}%';
    final reason = _error ?? volume?.reason ?? (volume == null ? 'Reading device volume…' : null);
    final slider = ThinSlider(
      sliderKey: const ValueKey('now-volume'),
      value: scalar,
      semanticFormatterCallback: (value) => '${(value * 100).round()} percent device volume',
      onChanged: enabled ? (value) => setState(() => _dragging = value) : null,
      onChangeEnd: enabled ? _save : null,
    );
    if (widget.compact) {
      return Tooltip(
        message: reason ?? 'Device volume $level',
        child: SizedBox(width: 148, child: Row(children: [
          const Text('VOL', style: Tok.caps),
          Expanded(child: slider),
        ])),
      );
    }
    // One line under the signal path: the last stage's own control.
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Tooltip(message: 'Device volume', child: Text('VOLUME', style: Tok.caps)),
        Expanded(child: slider),
        SizedBox(width: 44, child: Text(volume?.scalar == null ? '—' : level, style: Tok.monoSmall, textAlign: TextAlign.right)),
      ]),
      if (reason != null) Text(reason, style: Tok.labelMuted),
    ]);
  }
}

/// The signal path's stages on one line: the last one, the output, gives
/// way when the pane is narrow. A long chain wraps instead.
class SignalStages extends StatelessWidget {
  const SignalStages(this.path, {super.key});
  final List<StageDto> path;

  @override
  Widget build(BuildContext context) {
    if (path.length > 3) return Wrap(spacing: 6, runSpacing: 6, children: [for (final s in path) _Stage(s)]);
    return Row(children: [
      for (final (i, s) in path.indexed) ...[
        if (i > 0) const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Text('→', style: Tok.label),
        ),
        if (i == path.length - 1) Flexible(child: _Stage(s)) else _Stage(s),
      ],
    ]);
  }
}

class _Stage extends StatelessWidget {
  const _Stage(this.s);
  final StageDto s;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(border: Border.all(color: s.alters ? Tok.warn : Tok.rule), borderRadius: BorderRadius.circular(3)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.name, style: Tok.label.copyWith(fontSize: 11), maxLines: 1),
          Text(s.detail, style: Tok.monoSmall.copyWith(color: Tok.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
      );
}
