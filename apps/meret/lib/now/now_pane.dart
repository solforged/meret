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
import '../theme/light.dart';
import '../theme/tokens.dart';
import 'zones.dart';
import 'picks.dart';
import 'signal_path.dart';

/// Now: what's playing, the transport, the signal path and the queue.
/// Pinned at the right from 1800 px, opened beside the panes below that; [NowBar] on a phone. [nothingToPlay]
/// is the reply when play found nothing: the title slot says so.
class NowPane extends StatelessWidget {
  const NowPane({
    super.key, required this.core, required this.now, required this.clock, required this.onToggle,
    this.onRelease, this.settingsChanges, this.nothingToPlay = false,
  });

  final CoreBridge core;
  final NowDto? now;
  final PlayheadClock clock;
  final VoidCallback onToggle;
  final Future<void> Function(PlatformInt64)? onRelease;
  final Listenable? settingsChanges;
  final bool nothingToPlay;

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
          const Expanded(child: Text('NOW', style: Tok.label)),
          ListenableBuilder(
            listenable: clock,
            builder: (_, _) => Text(!loaded ? '' : clock.playing ? 'playing' : 'paused', style: Tok.label),
          ),
        ]),
        const SizedBox(height: 8),
        Text(nowTitle(n, nothingToPlay: nothingToPlay), style: Tok.title.copyWith(fontSize: 17), maxLines: 2, overflow: TextOverflow.ellipsis),
        Text(n?.subtitle ?? '', style: Tok.body.copyWith(color: Tok.muted, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
        if (n != null) NowFacts(now: n),
        _WhySlot(n?.why),
        if (n?.error case final error?) Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(error, style: Tok.label.copyWith(color: Tok.warn)),
        ),
        const SizedBox(height: 10),
        Transport(core: core, now: n, clock: clock, onToggle: onToggle),
        SeekBar(core: core, now: n, clock: clock),
        Expanded(flex: 4, child: NowDial(now: n, clock: clock, onToggle: loaded ? onToggle : null)),
        Expanded(flex: 5, child: SingleChildScrollView(
          key: const PageStorageKey('now-pane'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('SIGNAL PATH', style: Tok.label),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final s in n?.path ?? const <StageDto>[]) _Stage(s),
            ]),
            const SizedBox(height: 8),
            if (n?.fidelity != null) NowFidelity(now: n!, exclusive: core.settings().exclusive),
            const SizedBox(height: 12),
            PlayOn(core: core, now: n, settingsChanges: settingsChanges),
            if (loaded) ...[
              const SizedBox(height: 12),
              UpNext(core: core, now: n),
            ],
            const SizedBox(height: 12),
            PlaySomething(core: core, now: n),
            const SizedBox(height: 12),
            NowMemory(core: core, now: n, resumeLimit: 3, historyLimit: 3, onRelease: onRelease),
            const SizedBox(height: 12),
            DeviceVolume(core: core, now: now),
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
  Widget build(BuildContext context) => GestureDetector(
    onTap: onToggle,
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

/// The title slot's words: the loaded title, "Nothing playing", or the
/// reply to a play that found nothing.
String nowTitle(NowDto? now, {required bool nothingToPlay}) {
  if (now?.anchor == null && nothingToPlay) return 'Nothing to play yet';
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
    style: Tok.monoSmall.copyWith(color: now.fidelity == FidelityDto.bitPerfect ? Tok.ok : Tok.warn),
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
  ].join(' · '), style: Tok.monoSmall.copyWith(color: Tok.muted));
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
      });
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error.toString());
    }
  }

  Future<void> _pickUp(ResumeDto point) async {
    try {
      await widget.core.pickUp(point.releaseId);
      if (mounted) await _load();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
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
    if (_pickUps.isNotEmpty) ...[
      const NowSection(title: 'Pick up'),
      for (final point in _pickUps)
        NowDoor(
          key: ValueKey('now-pick-up-${point.releaseId}'),
          onTap: () => _pickUp(point),
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
              Moment(ms: point.updatedAt.toInt(), builder: (_, when) => Text(when, style: Tok.label)),
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
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text(listen.title, style: Tok.body, maxLines: 2, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              Moment(ms: listen.startedAtMs.toInt(), builder: (_, when) => Text(when, style: Tok.monoSmall)),
            ]),
            Text([
              if (listen.credit != null) listen.credit!,
              if (listen.releaseTitle != null) listen.releaseTitle!,
              _listenOutcome(listen, identical(listen, _history.first) ? widget.now : null),
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

String _listenOutcome(ListenDto listen, NowDto? now) {
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
      Text(title, style: Tok.label),
      if (meta != null) Text(meta!, style: Tok.label.copyWith(letterSpacing: 0)),
    ]),
  );
}

class NowDoor extends StatefulWidget {
  const NowDoor({super.key, required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  State<NowDoor> createState() => _NowDoorState();
}

class _NowDoorState extends State<NowDoor> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: Semantics(button: widget.onTap != null, child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
        decoration: BoxDecoration(
          color: _hover && widget.onTap != null ? Tok.panel2 : Colors.transparent,
          border: const Border(bottom: BorderSide(color: Tok.line)),
        ),
        child: widget.child,
      ),
    )),
  );
}

/// Now as a bar, below the panes, when the window is too narrow to pin it.
/// The title opens the full pane as a sheet, where Space still toggles.
/// [nothingToPlay] is the reply when play found nothing: the title slot
/// says so until something loads.
class NowBar extends StatelessWidget {
  const NowBar({
    super.key, required this.core, required this.now, required this.clock, required this.onToggle,
    this.onRelease, this.settingsChanges, this.nothingToPlay = false,
  });
  final CoreBridge core;
  final NowDto? now;
  final PlayheadClock clock;
  final VoidCallback onToggle;
  final Future<void> Function(PlatformInt64)? onRelease;
  final Listenable? settingsChanges;
  final bool nothingToPlay;

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
          Transport(core: core, now: n, clock: clock, onToggle: onToggle, compact: true),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              key: const ValueKey('now-bar-title'),
              behavior: HitTestBehavior.opaque,
              onTap: loaded ? () => _open(context) : null,
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
  void _open(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (sheetContext) {
        final room = MediaQuery.sizeOf(sheetContext);
        return CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.space, includeRepeats: false): onToggle},
          child: Focus(
            autofocus: true,
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
/// until something has been queued; play always answers, and with nothing
/// loaded it plays something.
class Transport extends StatelessWidget {
  const Transport({super.key, required this.core, required this.now, required this.clock, required this.onToggle, this.compact = false, this.id = 'now'});
  final CoreBridge core;
  final NowDto? now;
  final PlayheadClock clock;
  final VoidCallback onToggle;
  final bool compact;

  /// Prefixes the buttons' keys: `now-toggle`, or `lcd-toggle` in the LCD.
  final String id;

  @override
  Widget build(BuildContext context) {
    final loaded = now?.anchor != null;
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
          tooltip: clock.playing ? 'Pause' : 'Play',
          size: compact ? 22 : 28,
          color: accent,
          onPressed: onToggle,
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
  Widget build(BuildContext context) => IconButton(
        icon: Icon(icon),
        iconSize: size,
        tooltip: tooltip,
        color: color ?? Tok.ink,
        disabledColor: Tok.dim,
        padding: const EdgeInsets.all(4),
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
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
  const UpNext({super.key, required this.core, required this.now, this.limit = 8});
  final CoreBridge core;
  final NowDto? now;
  final int limit;

  @override
  State<UpNext> createState() => _UpNextState();
}

class _UpNextState extends State<UpNext> {
  UpNextDto? _upNext;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(UpNext old) {
    super.didUpdateWidget(old);
    if (old.core != widget.core || old.now?.anchor?.item != widget.now?.anchor?.item) _load();
  }

  Future<void> _load() async {
    final request = ++_request;
    try {
      final upNext = await widget.core.upNext(widget.limit);
      if (mounted && request == _request) setState(() => _upNext = upNext);
    } catch (_) {
      if (mounted && request == _request) setState(() => _upNext = null);
    }
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
      for (final item in upNext?.items ?? const <UpNextItemDto>[])
        Container(
          key: ValueKey('up-next-${item.token}'),
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.line))),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.title, style: Tok.body.copyWith(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(item.why ?? item.subtitle, style: Tok.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ])),
            const SizedBox(width: 8),
            Text(item.lengthMs == null ? '' : clockLength(item.lengthMs!.toInt()), style: Tok.monoSmall),
          ]),
        ),
      if (more > 0) Padding(padding: const EdgeInsets.only(top: 4), child: Text('$more more', style: Tok.label)),
    ]);
  }
}


/// The instrument's slider: a 2 px track and a small thumb in the light.
/// [sliderKey] lands on the `Slider` itself, so tests can read its value.
class ThinSlider extends StatelessWidget {
  const ThinSlider({super.key, this.sliderKey, required this.value, required this.onChanged, this.onChangeEnd, this.semanticFormatterCallback, this.hairline = false});
  final Key? sliderKey;
  final bool hairline;
  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final SemanticFormatterCallback? semanticFormatterCallback;

  @override
  Widget build(BuildContext context) {
    final accent = Light.of(context).accent;
    return SliderTheme(
      data: SliderThemeData(
        trackHeight: 2,
        activeTrackColor: accent,
        inactiveTrackColor: Tok.line,
        thumbColor: accent,
        disabledActiveTrackColor: Tok.line,
        disabledInactiveTrackColor: Tok.line,
        disabledThumbColor: Tok.dim,
        thumbShape: hairline ? SliderComponentShape.noThumb : const RoundSliderThumbShape(enabledThumbRadius: 5, disabledThumbRadius: 3),
        overlayShape: hairline ? SliderComponentShape.noOverlay : const RoundSliderOverlayShape(overlayRadius: 12),
        trackShape: const RectangularSliderTrackShape(),
      ),
      child: Slider(
        key: sliderKey,
        value: value.clamp(0.0, 1.0),
        semanticFormatterCallback: semanticFormatterCallback,
        onChanged: onChanged,
        onChangeEnd: onChangeEnd,
      ),
    );
  }
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
          const Text('VOL', style: Tok.label),
          Expanded(child: slider),
        ])),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('DEVICE VOLUME', style: Tok.label)),
        Text(volume?.scalar == null ? '—' : level, style: Tok.monoSmall),
      ]),
      slider,
      if (reason != null) Text(reason, style: Tok.monoSmall.copyWith(color: Tok.muted)),
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
          Text(s.name, style: Tok.label.copyWith(fontSize: 9.5)),
          Text(s.detail, style: Tok.monoSmall.copyWith(color: Tok.ink)),
        ]),
      );
}
