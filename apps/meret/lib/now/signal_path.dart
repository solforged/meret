import '../core/bridge.dart';

/// The verdict under the signal path: the fidelity, then what altered the
/// sound. An altering stage is named by its detail ("levelled -3.0 dB",
/// "RME ADI-2 · 48" when the file was 44.1); the Out stage in shared mode
/// says so in the zone's words. A caller that can't say whether the output
/// is exclusive ([exclusive] null) leaves the Out stage to its own line.
String? signalVerdict(NowDto now, {bool? exclusive}) {
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
      if (stage.alters && (stage.name != 'Out' || exclusive != null))
        stage.name == 'Out' && exclusive == false ? 'shared with macOS' : stage.detail,
  ].join(' · ');
}
