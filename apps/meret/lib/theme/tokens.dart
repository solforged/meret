import 'package:flutter/painting.dart';

/// One length for every move: trail steps slide, pages fade.
const kMotion = Duration(milliseconds: 200);

/// The instrument: fixed colours from the trails plates.
abstract final class Tok {
  static const void_ = Color(0xFF03050C);
  static const sky = Color(0xFF070B1A);
  static const panel = Color(0xFF0A1024);
  static const panel2 = Color(0xFF0D1430);

  /// The selected row: a step past [panel2], which hover uses.
  static const pick = Color(0xFF18234F);
  static const line = Color(0xFF18203C);
  static const rule = Color(0xFF263056);

  static const ink = Color(0xFFEBE6DA);
  static const muted = Color(0xFFA6AAC0);
  static const faint = Color(0xFF858CAB);
  static const dim = Color(0xFF474E70);

  static const gold = Color(0xFFD2A64E);
  static const gold2 = Color(0x99D2A64E);
  static const gold3 = Color(0x40D2A64E);
  static const ox = Color(0xFFB0414F);
  static const ok = Color(0xFF8FC2A2);
  static const warn = Color(0xFFE3A066);

  // Bundled under assets/fonts with their SIL Open Font Licenses.
  static const sans = 'Instrument Sans';
  static const mono = 'Geist Mono';

  // Words are Instrument Sans; Geist Mono is for tabular and code-like data
  // only: times, dates, counts and numbers in columns, key caps, DR/LUFS/format
  // values, paths and query syntax. `Tok.dim` is decoration (rules, disabled
  // glyphs, ornaments); information is never lighter than `Tok.faint`.

  /// Captions, subtitles, empty states and metadata lines. Tabular figures keep
  /// counts and times in a mixed line aligned.
  static const label = TextStyle(fontFamily: sans, fontSize: 12.5, color: faint, fontFeatures: [FontFeature.tabularFigures()]);

  /// [label] one step up in contrast: the line under a title.
  static const labelMuted = TextStyle(fontFamily: sans, fontSize: 12.5, color: muted, fontFeatures: [FontFeature.tabularFigures()]);

  /// Section heads: "Today", "Credits", "Most played in the last 7 days".
  static const heading = TextStyle(fontFamily: sans, fontSize: 12.5, fontWeight: FontWeight.w600, color: muted);

  /// Small-capital heads: NOW, SIGNAL PATH, the sidebar groups. Set uppercase by the caller.
  static const caps = TextStyle(fontFamily: sans, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: faint);

  static const body = TextStyle(fontFamily: sans, fontSize: 13, color: ink, height: 1.35);
  static const title = TextStyle(fontFamily: sans, fontSize: 22, fontWeight: FontWeight.w600, color: ink);

  /// Tabular and code-like data: times, dates, counts, key caps, paths, readouts.
  static const data = TextStyle(fontFamily: mono, fontSize: 11.5, color: faint);

  /// [data] one step up in contrast: table cells, durations, track numbers.
  static const monoSmall = TextStyle(fontFamily: mono, fontSize: 11.5, color: muted);
}
