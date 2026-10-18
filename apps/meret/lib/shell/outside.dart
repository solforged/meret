import 'dart:io';

import 'package:flutter/services.dart';

import '../core/bridge.dart';
import '../core/when.dart';
import '../src/rust/api/types.dart';

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

  NowDto? _now;
  int _pickUpGeneration = 0;

  /// Each Now goes out as the fields the menu bar, the Now Playing centre
  /// and the panel draw. Swift extrapolates the position from the anchor.
  /// The pick-up rows follow whenever the item or the rate changes (the
  /// same rule as Now's own list), so the panel never fetches while open.
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
    if (before == null || before.anchor?.item != anchor?.item || before.anchor?.rate != anchor?.rate) {
      _sendPickUp();
    }
  }

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
    final fidelity = switch (now.fidelity) {
      FidelityDto.bitPerfect => '● Bit-perfect',
      FidelityDto.altered => '◐ Altered',
      FidelityDto.lossy => '○ Lossy source',
      null => null,
    };
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
      default:
        throw MissingPluginException(call.method);
    }
    return null;
  }

  void dispose() {
    if (Platform.isMacOS) _channel.setMethodCallHandler(null);
  }
}
