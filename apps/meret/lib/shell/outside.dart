import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/bridge.dart';
import '../core/when.dart';
import '../now/signal_path.dart';

/// Playback outside the window (plate 10): the menu bar item, its panel and
/// the media keys live in Swift (`Outside.swift`); this feeds them Now and
/// carries their commands to the core. The engine lives as long as the
/// process, so the glue goes through Dart rather than a second FFI surface.
class Outside {
  Outside(this.core) {
    if (!Platform.isMacOS) return;
    _channel.setMethodCallHandler(_command);
  }

  final CoreBridge core;
  static const _channel = MethodChannel('meret/outside');
  static const pickUpLimit = 3;

  /// The device volume after each volume key, for Now's slider.
  final volume = ValueNotifier<VolumeDto?>(null);

  NowDto? _now;
  int _pickUpGeneration = 0;
  int _volumeGeneration = 0;
  Future<void> _keys = Future.value();

  /// Each Now goes out as the fields the menu bar, the Now Playing centre
  /// and the panel draw. Swift extrapolates the position from the anchor.
  /// The pick-up rows follow whenever the item or the rate changes (the
  /// same rule as Now's own list), so the panel never fetches while open;
  /// the device the volume keys would reach follows then and when the
  /// signal path changes.
  void now(NowDto now) {
    final before = _now;
    _now = now;
    if (!Platform.isMacOS) return;
    final anchor = now.anchor;
    _channel.invokeMethod<void>('now', {
      'loaded': anchor != null,
      'title': now.title,
      'subtitle': now.subtitle,
      'cover': now.cover,
      'why': now.why,
      'lengthMs': now.lengthMs?.toInt(),
      'positionMs': anchor?.positionMs,
      'rate': anchor?.rate,
      'verdict': verdict(now),
      'warn': now.fidelity != FidelityDto.bitPerfect,
      'error': now.error,
    }).catchError((_) {});
    final moved = before == null || before.anchor?.item != anchor?.item || before.anchor?.rate != anchor?.rate;
    if (moved) _sendPickUp();
    if (moved || !listEquals(before.path, now.path)) _sendVolumeTarget();
  }

  /// Swift takes the volume keys only while Meret plays on a device other
  /// than macOS's default output, and only for what that device can do.
  Future<void> _sendVolumeTarget() async {
    final generation = ++_volumeGeneration;
    final VolumeDto current;
    try {
      current = await core.volume();
    } catch (_) {
      return;
    }
    if (generation != _volumeGeneration) return;
    _channel.invokeMethod<void>('volumeTarget', {
      'device': current.settable ? current.device : null,
      'mute': current.muted != null,
    }).catchError((_) {});
  }

  /// Presses run one at a time, so a held key steps from where the last
  /// press landed.
  Future<void> _volumeKey(String key, bool fine) => _keys = _keys.then((_) async {
    final VolumeDto next;
    if (key == 'mute') {
      final muted = (await core.volume()).muted;
      if (muted == null) return;
      next = await core.setMute(!muted);
    } else {
      next = await core.stepVolume(up: key == 'up', fine: fine);
    }
    volume.value = next;
  }).catchError((_) {});

  Future<void> _sendPickUp() async {
    final generation = ++_pickUpGeneration;
    final List<ResumeDto> points;
    try {
      points = await core.resumePoints(pickUpLimit);
    } catch (_) {
      return;
    }
    if (generation != _pickUpGeneration) return;
    _channel.invokeMethod<void>('pickUp', pickUpRows(points)).catchError((_) {});
  }

  /// One line for the signal path: "● Bit-perfect · FLAC 16/44.1 → Studio
  /// Display XDR Speakers · 44.1". Nothing until the device has been opened.
  static String? verdict(NowDto now) {
    final fidelity = signalVerdict(now);
    if (fidelity == null) return null;
    if (now.path.isEmpty) return fidelity;
    final ends = now.path.length == 1 ? now.path.first.detail : '${now.path.first.detail} → ${now.path.last.detail}';
    return '$fidelity · $ends';
  }

  /// The panel's pick-up rows, worded for one line each: the release, then
  /// where it resumes (the track for idioms that restart one, otherwise the
  /// second).
  static List<Map<String, Object?>> pickUpRows(List<ResumeDto> points) => [
    for (final point in points)
      {
        'releaseId': point.releaseId,
        'title': [point.title, if (point.credit != null) point.credit!].join(' · '),
        'detail': switch (point.idiom) {
          'set' || 'spoken' || null => clockLength(point.positionMs.toInt()),
          _ => point.recordingTitle,
        },
        'cover': point.cover,
      },
  ];

  Future<Object?> _command(MethodCall call) async {
    final loaded = _now?.anchor != null;
    final playing = (_now?.anchor?.rate ?? 0) > 0;
    switch (call.method) {
      case 'toggle':
        if (!loaded) {
          await core.playSomething();
        } else {
          await core.transport(playing ? const TransportDto.pause() : const TransportDto.resume());
        }
      case 'play':
        if (!loaded) {
          await core.playSomething();
        } else if (!playing) {
          await core.transport(const TransportDto.resume());
        }
      case 'pause':
        if (playing) await core.transport(const TransportDto.pause());
      case 'next':
        await core.transport(const TransportDto.next());
      case 'previous':
        await core.transport(const TransportDto.previous());
      case 'seek':
        await core.transport(TransportDto.seek(ms: BigInt.from((call.arguments as num).round())));
      case 'playSomething':
        await core.playSomething();
      case 'pickUp':
        await core.pickUp(call.arguments as int);
      case 'volumeKey':
        final args = call.arguments as Map;
        await _volumeKey(args['key'] as String, args['fine'] as bool? ?? false);
      default:
        throw MissingPluginException(call.method);
    }
    return null;
  }

  void dispose() {
    if (Platform.isMacOS) _channel.setMethodCallHandler(null);
    volume.dispose();
  }
}
