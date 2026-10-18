import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/shell/outside.dart';
import 'package:meret/src/rust/api/types.dart';

/// The menu bar item and the media keys (plate 10) speak to the core
/// through `Outside`. Swift is not under test here; the channel is driven
/// as Swift would drive it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('meret/outside');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _RecordingCore core;
  late Outside outside;
  late List<MethodCall> sent;

  Future<void> command(String method, [Object? args]) async {
    final reply = await messenger.handlePlatformMessage(
      channel.name, channel.codec.encodeMethodCall(MethodCall(method, args)), (_) {},
    );
    if (reply != null) channel.codec.decodeEnvelope(reply);
  }

  setUp(() {
    core = _RecordingCore();
    sent = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      sent.add(call);
      return null;
    });
    outside = Outside(core);
  });

  tearDown(() {
    outside.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  NowDto playing() => NowDto(
    title: 'Terratus', subtitle: 'Justin E. Bell', path: const [],
    anchor: AnchorDto(item: BigInt.one, positionMs: 55000, rate: 1), lengthMs: BigInt.from(149000),
  );
  NowDto paused() => NowDto(
    title: 'Terratus', subtitle: 'Justin E. Bell', path: const [],
    anchor: AnchorDto(item: BigInt.one, positionMs: 55000, rate: 0), lengthMs: BigInt.from(149000),
  );
  const nothing = NowDto(title: '', subtitle: '', path: []);

  test('the play key resumes when paused and does nothing when playing', () async {
    outside.now(paused());
    await command('play');
    expect(core.transports.single, isA<TransportDto_Resume>());
    outside.now(playing());
    await command('play');
    expect(core.transports, hasLength(1));
    await command('pause');
    expect(core.transports.last, isA<TransportDto_Pause>());
  });

  test('toggle and play start Play something when nothing is loaded', () async {
    outside.now(nothing);
    await command('toggle');
    await command('play');
    expect(core.playSomethingCalls, 2);
    expect(core.transports, isEmpty);
    outside.now(playing());
    await command('toggle');
    expect(core.transports.single, isA<TransportDto_Pause>());
  });

  test('a seek from the system is milliseconds, rounded', () async {
    outside.now(playing());
    await command('seek', 61500.4);
    final seek = core.transports.single as TransportDto_Seek;
    expect(seek.ms, BigInt.from(61500));
  });

  test('pick-up rows go out when the item or the rate changes, not every anchor', () async {
    outside.now(playing());
    await Future<void>.delayed(Duration.zero);
    expect(sent.where((c) => c.method == 'pickUp'), hasLength(1));
    outside.now(NowDto(
      title: 'Terratus', subtitle: 'Justin E. Bell', path: const [],
      anchor: AnchorDto(item: BigInt.one, positionMs: 58000, rate: 1), lengthMs: BigInt.from(149000),
    ));
    outside.now(paused());
    await Future<void>.delayed(Duration.zero);
    expect(sent.where((c) => c.method == 'pickUp'), hasLength(2));
    final rows = sent.last.arguments as List;
    expect(rows, hasLength(lessThanOrEqualTo(Outside.pickUpLimit)));
  });

  test('the verdict is one line from the fidelity and the path ends', () {
    expect(Outside.verdict(nothing), isNull);
    expect(
      Outside.verdict(const NowDto(
        title: '', subtitle: '', fidelity: FidelityDto.bitPerfect,
        path: [
          StageDto(name: 'File', detail: 'FLAC 16/44.1', alters: false),
          StageDto(name: 'Decode', detail: 'no DSP', alters: false),
          StageDto(name: 'Out', detail: 'RME ADI-2 · 44.1', alters: false),
        ],
      )),
      '● Bit-perfect · FLAC 16/44.1 → RME ADI-2 · 44.1',
    );
    expect(
      Outside.verdict(const NowDto(title: '', subtitle: '', fidelity: FidelityDto.lossy, path: [])),
      '○ Lossy source',
    );
  });

  test('a pick-up row names the track for idioms that restart one, the second otherwise', () {
    ResumeDto point(String? idiom) => ResumeDto(
      releaseId: PlatformInt64Util.from(1), title: 'Cornell 5/8/77', credit: 'Grateful Dead',
      recordingId: PlatformInt64Util.from(2), recordingTitle: 'Scarlet Begonias', disc: 1, number: 3,
      positionMs: BigInt.from(6850000), lengthMs: BigInt.from(10000000), idiom: idiom,
      updatedAt: PlatformInt64Util.from(0),
    );
    final rows = Outside.pickUpRows([point('set'), point('album'), point(null)]);
    expect(rows.map((r) => r['detail']), ['1:54:10', 'Scarlet Begonias', '1:54:10']);
    expect(rows.first['title'], 'Cornell 5/8/77 · Grateful Dead');
  });
}

class _RecordingCore extends FakeCore {
  final transports = <TransportDto>[];
  int playSomethingCalls = 0;

  @override
  Future<void> transport(TransportDto cmd) {
    transports.add(cmd);
    return super.transport(cmd);
  }

  @override
  Future<PickDto?> playSomething() {
    playSomethingCalls++;
    return super.playSomething();
  }
}
