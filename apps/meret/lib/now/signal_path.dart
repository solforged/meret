import '../core/bridge.dart';

String? signalVerdict(NowDto now) {
  final fidelity = switch (now.fidelity) {
    FidelityDto.bitPerfect => '● Bit-perfect',
    FidelityDto.altered => '◐ Altered',
    FidelityDto.lossy => '○ Lossy source',
    null => null,
  };
  if (fidelity == null) return null;
  return [
    fidelity,
    for (final stage in now.path)
      if (stage.name == 'Level' && stage.alters) stage.detail,
  ].join(' · ');
}
