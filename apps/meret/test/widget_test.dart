import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/core/playhead.dart';
import 'package:meret/main.dart';
import 'package:meret/shell/width_class.dart';

void main() {
  testWidgets('the surface comes up on fake data at desktop width', (tester) async {
    tester.view.physicalSize = const Size(2560, 1440);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MeretApp(core: FakeCore()));
    await tester.pump();

    expect(find.text('Iona'), findsWidgets);
    expect(find.text('NOW'), findsOneWidget);
    expect(find.text('● Bit-perfect'), findsOneWidget);
    expect(find.textContaining('≈ 312 to identify'), findsOneWidget);
  });

  testWidgets('on a phone, one pane and Now as a bar', (tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MeretApp(core: FakeCore()));
    await tester.pump();

    expect(WidthClass.of(400), WidthClass.phone);
    expect(find.text('NOW'), findsNothing);
    expect(find.text('Small Two of Pieces ~Broken Pieces~'), findsOneWidget);
  });

  testWidgets('the playhead extrapolates while playing and holds when paused', (tester) async {
    late PlayheadClock clock;
    await tester.pumpWidget(_Host(onClock: (c) => clock = c));

    clock.anchor(AnchorDto(item: BigInt.one, positionMs: 1000, rate: 1));
    expect(clock.playing, isTrue);
    expect(clock.positionMs, closeTo(1000, 50));

    clock.anchor(AnchorDto(item: BigInt.one, positionMs: 5000, rate: 0));
    final held = clock.positionMs;
    await tester.pump(const Duration(milliseconds: 200));
    expect(clock.positionMs, held);
  });
}

class _Host extends StatefulWidget {
  const _Host({required this.onClock});
  final ValueChanged<PlayheadClock> onClock;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SingleTickerProviderStateMixin {
  late final clock = PlayheadClock(this);

  @override
  void initState() {
    super.initState();
    widget.onClock(clock);
  }

  @override
  void dispose() {
    clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
