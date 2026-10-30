import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/main.dart';
import 'package:meret/now/now_pane.dart';

// Check the incremental tree sent to the engine, not only Flutter's in-memory
// semantics tree. A serialized orphan crashes the macOS accessibility bridge.
class _SemanticsBinding extends AutomatedTestWidgetsFlutterBinding {
  final children = <int, List<int>>{};
  final orphans = <int>{};
  final duplicateChildren = <int>{};
  final descriptions = <int, String>{};
  final duplicates = <String>{};
  final missingChildren = <String>{};
  String phase = 'initial';

  void resetTree() {
    children.clear();
    orphans.clear();
    duplicateChildren.clear();
    descriptions.clear();
    duplicates.clear();
    missingChildren.clear();
    phase = 'initial';
  }

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      _RecordingBuilder(this);
}

class _RecordingBuilder implements ui.SemanticsUpdateBuilder {
  _RecordingBuilder(this.binding);
  final _SemanticsBinding binding;
  final delegate = ui.SemanticsUpdateBuilder();
  final updated = <int>{};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateNode) {
      final args = invocation.namedArguments;
      final id = args[#id] as int;
      binding.children[id] = List<int>.of(
        args[#childrenInTraversalOrder] as List<int>,
      );
      binding.descriptions[id] =
          'label=${args[#label]} value=${args[#value]} parent=${args[#traversalParent]} children=${args[#childrenInTraversalOrder]}';
      updated.add(id);
      return Function.apply(
        delegate.updateNode,
        invocation.positionalArguments,
        args,
      );
    }
    if (invocation.memberName == #updateCustomAction) {
      return Function.apply(
        delegate.updateCustomAction,
        invocation.positionalArguments,
        invocation.namedArguments,
      );
    }
    return super.noSuchMethod(invocation);
  }

  @override
  ui.SemanticsUpdate build() {
    final reachable = <int>{};
    void visit(int id) {
      if (!reachable.add(id)) {
        binding.duplicateChildren.add(id);
        binding.duplicates.add(
          '$id: ${binding.descriptions[id]} parents=${binding.children.entries.where((entry) => entry.value.contains(id)).map((entry) => '${entry.key}: ${binding.descriptions[entry.key]}').join('; ')}',
        );
        return;
      }
      for (final child in binding.children[id] ?? <int>[]) {
        visit(child);
      }
    }

    visit(0);
    binding.orphans.addAll(updated.difference(reachable));
    for (final id in reachable.where((id) => !binding.children.containsKey(id))) {
      binding.missingChildren.add('${binding.phase}: missing $id; parents: ${binding.children.entries.where((entry) => entry.value.contains(id)).map((entry) => '${entry.key}: ${binding.descriptions[entry.key]}').join('; ')}');
    }
    // The engine deletes detached subtrees. Keeping every historical node here
    // would hide a later reference to a deleted node that was never resent.
    binding.children.removeWhere((id, _) => !reachable.contains(id));
    return delegate.build();
  }
}

void main() {
  final binding = _SemanticsBinding();

  setUp(binding.resetTree);
  tearDown(() => expect(binding.missingChildren, isEmpty, reason: binding.missingChildren.join('\n')));

  for (final platform in [TargetPlatform.android, TargetPlatform.macOS]) {
  testWidgets(
    'slider semantics retain values and platform adjustments on ${platform.name}',
    (tester) async {
      final semantics = tester.ensureSemantics();
      var value = 0.4;
      final step = platform == TargetPlatform.macOS ? 0.1 : 0.05;
      var enabled = true;
      final committed = <double>[];
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return ThinSlider(
                  value: value,
                  semanticFormatterCallback: (value) =>
                      '${(value * 100).round()} seconds',
                  onChanged: enabled
                      ? (next) => setState(() => value = next)
                      : null,
                  onChangeEnd: committed.add,
                );
              },
            ),
          ),
        ),
      );
      final slider = find.byType(ThinSlider);
      expect(
        tester.getSemantics(slider),
        isSemantics(
          isSlider: true,
          hasEnabledState: true,
          isEnabled: true,
          value: '40 seconds',
          increasedValue: '${((0.4 + step) * 100).round()} seconds',
          decreasedValue: '${((0.4 - step) * 100).round()} seconds',
          hasIncreaseAction: true,
          hasDecreaseAction: true,
        ),
      );
      tester.getSemantics(slider).owner!.performAction(
        tester.getSemantics(slider).id,
        ui.SemanticsAction.increase,
      );
      await tester.pump();
      expect(value, closeTo(0.4 + step, 0.00001));
      expect(committed, [value]);
      tester.getSemantics(slider).owner!.performAction(
        tester.getSemantics(slider).id,
        ui.SemanticsAction.decrease,
      );
      await tester.pump();
      expect(value, closeTo(0.4, 0.00001));
      expect(committed.length, 2);
      update(() => value = 1);
      await tester.pump();
      expect(
        tester.getSemantics(slider),
        isSemantics(
          value: '100 seconds',
          hasIncreaseAction: false,
          hasDecreaseAction: true,
        ),
      );
      update(() => value = 0);
      await tester.pump();
      expect(
        tester.getSemantics(slider),
        isSemantics(
          value: '0 seconds',
          hasIncreaseAction: true,
          hasDecreaseAction: false,
        ),
      );
      update(() => enabled = false);
      await tester.pump();
      expect(
        tester.getSemantics(slider),
        isSemantics(
          isSlider: true,
          hasEnabledState: true,
          isEnabled: false,
          hasIncreaseAction: false,
          hasDecreaseAction: false,
        ),
      );
      semantics.dispose();
    },
  );
  }

  for (final rtl in [false, true]) {
    testWidgets('slider pointer and keyboard input commit once and respect ${rtl ? 'RTL' : 'LTR'} bounds', (tester) async {
      final semantics = tester.ensureSemantics();
      var value = 0.5;
      var enabled = true;
      final committed = <double>[];
      late StateSetter update;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: Scaffold(body: Directionality(
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          child: Center(child: SizedBox(width: 200, child: StatefulBuilder(builder: (context, setState) {
            update = setState;
            return ThinSlider(
              sliderKey: const ValueKey('input-slider'),
              value: value,
              onChanged: enabled ? (next) => setState(() => value = next) : null,
              onChangeEnd: committed.add,
            );
          }))),
        )),
      ));
      final slider = find.byKey(const ValueKey('input-slider'));
      await tester.tapAt(tester.getTopLeft(slider) + const Offset(56, 16));
      await tester.pump();
      expect(value, closeTo(rtl ? 0.75 : 0.25, 0.00001));
      expect(committed, hasLength(1));
      expect(tester.getSemantics(slider).flagsCollection.isFocused, ui.Tristate.isTrue);
      committed.clear();
      await tester.drag(slider, const Offset(500, 0));
      await tester.pump();
      expect(value, rtl ? 0 : 1);
      expect(committed, hasLength(1), reason: 'a drag commits only when it ends');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(value, closeTo(rtl ? 0.1 : 0.9, 0.00001));
      expect(committed, hasLength(2));
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(value, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(value, 1);
      update(() => enabled = false);
      await tester.pump();
      committed.clear();
      await tester.tap(slider);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(value, 1);
      expect(committed, isEmpty);
      semantics.dispose();
    });
  }

  testWidgets(
    'sliders keep engine semantics connected across dialog transitions',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  ThinSlider(value: 0.4, onChanged: (_) {}),
                  TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        content: SizedBox(
                          width: 300,
                          child: ThinSlider(
                            sliderKey: const ValueKey('dialog-slider'),
                            value: 0.5,
                            onChanged: (_) {},
                          ),
                        ),
                      ),
                    ),
                    child: const Text('Settings'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Settings'));
        await tester.pump();
        await tester.pumpAndSettle();
        final slider = find.byKey(const ValueKey('dialog-slider'));
        await tester.drag(slider, const Offset(40, 0));
        await tester.pumpAndSettle();
        Navigator.of(tester.element(slider)).pop();
        await tester.pumpAndSettle();
      }
      semantics.dispose();
      expect(
        binding.orphans,
        isEmpty,
        reason: 'every updated node must be reachable from the engine root',
      );
      expect(
        binding.duplicateChildren,
        isEmpty,
        reason: binding.duplicates.join('\n'),
      );
    },
  );

  testWidgets(
    'native shell semantics stay connected while searching and opening settings',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(MeretApp(core: FakeCore()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      for (var i = 0; i < 3; i++) {
        tester.view.physicalSize = Size(i == 1 ? 900 : 1440, 900);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.comma);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Playback'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.sendKeyEvent(LogicalKeyboardKey.slash);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.enterText(find.byType(TextField), 'Iona');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }
      semantics.dispose();
      expect(
        binding.orphans,
        isEmpty,
        reason: binding.orphans
            .map((id) => '$id: ${binding.descriptions[id]}')
            .join('\n'),
      );
      expect(
        binding.duplicateChildren,
        isEmpty,
        reason: binding.duplicates.join('\n'),
      );
    },
  );

  testWidgets('loaded queue semantics remain complete through every query and Now animation frame', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    final core = FakeCore();
    await core.playResults('', const ViewDto(sort: SortKeyDto.library_, descending: false, group: false), 0);
    await core.transport(const TransportDto.pause());
    await tester.pumpWidget(MeretApp(core: core));

    Future<void> frames(String phase, [int count = 20]) async {
      for (var frame = 0; frame < count; frame++) {
        binding.phase = '$phase frame $frame';
        await tester.pump(const Duration(milliseconds: 16));
        expect(binding.orphans, isEmpty, reason: '${binding.phase}: ${binding.orphans.map((id) => '$id: ${binding.descriptions[id]}').join('\n')}');
        expect(binding.missingChildren, isEmpty, reason: binding.missingChildren.join('\n'));
      }
    }

    await frames('loaded queue');
    await tester.tap(find.byKey(const ValueKey('lcd-title')));
    await frames('open Now');
    await core.transport(const TransportDto.resume());
    await frames('playing', 8);
    final selected = (await core.upNext(4)).items[2];
    await core.jumpToQueued(selected.token);
    await frames('queue jump', 8);
    await core.transport(const TransportDto.pause());
    await frames('pause', 4);

    await tester.tap(find.byKey(const ValueKey('lcd-seek')), kind: ui.PointerDeviceKind.mouse);
    await frames('seek click', 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await frames('seek keyboard', 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await frames('query focus after seeking');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames('query unfocus after seeking');

    for (final width in [1440.0, 720.0, 1440.0]) {
      tester.view.physicalSize = Size(width, 900);
      await frames('resize $width');
      await tester.tap(find.byType(TextField));
      await frames('query focus $width');
      await tester.enterText(find.byType(TextField), 'Iona');
      await frames('query text $width');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await frames('dismiss suggestions $width', 4);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await frames('query unfocus $width');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await frames('open settings $width');
      await tester.tap(find.byKey(const ValueKey('settings-nav-playback')));
      await frames('playback settings $width');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await frames('close settings $width');
    }
    semantics.dispose();
    expect(binding.orphans, isEmpty, reason: binding.orphans.map((id) => '$id: ${binding.descriptions[id]}').join('\n'));
    expect(binding.duplicateChildren, isEmpty, reason: binding.duplicates.join('\n'));
    debugDefaultTargetPlatformOverride = null;
  });
}
