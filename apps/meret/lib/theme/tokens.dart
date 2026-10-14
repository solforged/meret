import 'package:flutter/painting.dart';

/// The instrument: fixed colours from the trails plates. Only `light` comes
/// from what's playing (clamped in OKLCH by the core); nothing else changes.
abstract final class Tok {
  static const void_ = Color(0xFF03050C);
  static const sky = Color(0xFF070B1A);
  static const panel = Color(0xFF0A1024);
  static const panel2 = Color(0xFF0D1430);
  static const line = Color(0xFF18203C);
  static const rule = Color(0xFF263056);

  static const ink = Color(0xFFEBE6DA);
  static const muted = Color(0xFFA6AAC0);
  static const faint = Color(0xFF6A7194);
  static const dim = Color(0xFF474E70);

  static const gold = Color(0xFFD2A64E);
  static const gold2 = Color(0x99D2A64E);
  static const gold3 = Color(0x40D2A64E);
  static const ox = Color(0xFFB0414F);
  static const ok = Color(0xFF8FC2A2);
  static const warn = Color(0xFFE3A066);

  /// Default light; replaced per release by the core's clamped cover colour.
  static const light = Color(0xFFDF9672);

  // TODO(theme): bundle Instrument Sans and Geist Mono as assets.
  static const sans = 'Instrument Sans';
  static const mono = 'Geist Mono';

  static const label = TextStyle(fontFamily: mono, fontSize: 10.5, letterSpacing: 0.6, color: faint);
  static const body = TextStyle(fontFamily: sans, fontSize: 13, color: ink, height: 1.35);
  static const title = TextStyle(fontFamily: sans, fontSize: 22, fontWeight: FontWeight.w600, color: ink);
  static const monoSmall = TextStyle(fontFamily: mono, fontSize: 11.5, color: muted);
}
