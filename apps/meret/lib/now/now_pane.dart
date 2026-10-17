import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../core/playhead.dart';
import '../draw/body_painter.dart';
import '../theme/light.dart';
import '../theme/tokens.dart';

/// Now: the playing body, the signal path and, later, the queue.
/// Pinned at the right on large screens; a bar on phones.
class NowPane extends StatelessWidget {
  const NowPane({super.key, required this.core, required this.now, required this.clock, required this.onToggle});

  final CoreBridge core;
  final NowDto? now;
  final PlayheadClock clock;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final n = now;
    final length = n?.lengthMs?.toDouble() ?? 1;
    return Container(
      color: Color.alphaBlend(Light.of(context).wash, Tok.panel),
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('NOW', style: Tok.label),
        const SizedBox(height: 8),
        Text(n?.title ?? 'Nothing playing', style: Tok.title.copyWith(fontSize: 17)),
        Text(n?.subtitle ?? '', style: Tok.body.copyWith(color: Tok.muted, fontSize: 12)),
        const SizedBox(height: 8),
        if (n?.cover case final cover?) ...[
          Image.file(File(cover), width: 128, height: 128, fit: BoxFit.contain, cacheWidth: 256),
          const SizedBox(height: 8),
        ],
        // Rebuilt per tick, but only this one Text.
        ListenableBuilder(
          listenable: clock,
          builder: (_, _) => Text('${_fmt(clock.positionMs)} / ${_fmt(length)}', style: Tok.monoSmall),
        ),
        Expanded(
          child: GestureDetector(
            onTap: onToggle,
            child: RepaintBoundary(
              child: CustomPaint(
                size: Size.infinite,
                painter: BodyPainter(clock: clock, lengthMs: length, loudness: _demoBody(0), bands: [_demoBody(1), _demoBody(2), _demoBody(3)], light: Light.of(context).accent),
              ),
            ),
          ),
        ),
        Text('SIGNAL PATH', style: Tok.label),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final s in n?.path ?? const <StageDto>[]) _Stage(s),
        ]),
        const SizedBox(height: 8),
        if (n?.fidelity case final f?)
          Text(
            switch (f) {
              FidelityDto.bitPerfect => '● Bit-perfect',
              FidelityDto.altered => '◐ Altered',
              FidelityDto.lossy => '○ Lossy source',
            },
            style: Tok.monoSmall.copyWith(color: f == FidelityDto.bitPerfect ? Tok.ok : Tok.warn),
          ),
        const SizedBox(height: 12),
        DeviceVolume(core: core, now: now),
      ]),
    );
  }

  static String _fmt(double ms) {
    final s = (ms / 1000).floor();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  // TODO(now): replace with the core's body summary for the playing recording.
  static final _bodies = <int, Uint8List>{};
  static Uint8List _demoBody(int seed) => _bodies.putIfAbsent(seed, () {
        final r = math.Random(seed + 7);
        var v = 120.0;
        return Uint8List.fromList(List.generate(180, (i) {
          v = (v + r.nextDouble() * 40 - 20).clamp(30, 250);
          return v.round();
        }));
      });
}

/// The output device's own volume; samples stay untouched. [compact] is
/// the slider alone, for Now as a bar, with the reason as a tooltip.
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
    _load();
  }

  @override
  void didUpdateWidget(DeviceVolume oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.core != widget.core || oldWidget.now != widget.now) _load();
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
    final reason = _error ?? volume?.reason ?? (volume == null ? 'Reading device volume…' : null);
    final accent = Light.of(context).accent;
    final slider = SliderTheme(
      data: SliderThemeData(
        trackHeight: 2,
        activeTrackColor: accent,
        inactiveTrackColor: Tok.line,
        thumbColor: accent,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      ),
      child: Slider(
        key: const ValueKey('now-volume'),
        value: scalar,
        semanticFormatterCallback: (value) => '${(value * 100).round()} percent device volume',
        onChanged: enabled ? (value) => setState(() => _dragging = value) : null,
        onChangeEnd: enabled ? _save : null,
      ),
    );
    if (widget.compact) {
      return Tooltip(
        message: reason ?? 'Device volume ${(scalar * 100).round()}%',
        child: SizedBox(width: 168, child: Row(children: [
          const Text('VOL', style: Tok.label),
          Expanded(child: slider),
        ])),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('DEVICE VOLUME', style: Tok.label)),
        Text(volume?.scalar == null ? '—' : '${(scalar * 100).round()}%', style: Tok.monoSmall),
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
