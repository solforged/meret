import 'package:flutter/widgets.dart';

import 'tokens.dart';

/// The one light the playing release lends the instrument (docs/direction.md:
/// the instrument and the light). The core clamps it from the cover in
/// OKLCH; a pale cover, or nothing playing, leaves the instrument's brass.
@immutable
class Light {
  const Light({this.accent = Tok.gold, this.wash = const Color(0x14D2A64E), this.dim = const Color(0x55D2A64E), this.track, this.release});

  /// Playing row, playhead, play ring.
  final Color accent;

  /// Selected-row tint, at most 8% over the sheet.
  final Color wash;

  /// Focused part in a strip, the transport's top edge.
  final Color dim;

  /// What's playing, so a row can say it's the one.
  final int? track;
  final int? release;

  static const brass = Light();

  static Light of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<LightScope>()?.light ?? brass;

  @override
  bool operator ==(Object other) =>
      other is Light && other.accent == accent && other.wash == wash && other.dim == dim && other.track == track && other.release == release;

  @override
  int get hashCode => Object.hash(accent, wash, dim, track, release);
}

class LightScope extends InheritedWidget {
  const LightScope({super.key, required this.light, required super.child});

  final Light light;

  @override
  bool updateShouldNotify(LightScope old) => old.light != light;
}
