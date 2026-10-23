import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/core/playhead.dart';
import 'package:meret/draw/body_painter.dart';
import 'package:meret/draw/histogram_header.dart';
import 'package:meret/now/now_pane.dart';
import 'package:meret/panes/table_pane.dart';
import 'package:meret/shell/outside.dart';

const _view = ViewDto(sort: SortKeyDto.library_, descending: false, group: false);

void main() {
  testWidgets('Now paints the loaded summary and clears it for an unanalysed item', (tester) async {
    final now = await FakeCore().now().first;
    final clock = PlayheadClock(tester);
    addTearDown(clock.dispose);
    Future<void> dial(NowDto value) => tester.pumpWidget(MaterialApp(home: Center(
      child: SizedBox(width: 240, height: 240, child: NowDial(now: value, clock: clock)),
    )));
    BodyPainter painter() => tester.widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((paint) => paint.painter).whereType<BodyPainter>().single;

    await dial(now);
    expect(painter().loudness, same(now.body!.loudness));
    expect(painter().loudness, isNotEmpty);
    expect(painter().bands, [now.body!.low, now.body!.mid, now.body!.high]);
    expect(painter().bands.every((band) => band.isNotEmpty), isTrue);
    expect(painter().lengthMs, now.body!.lengthMs.toDouble());

    await dial(const NowDto(title: 'Unanalysed', subtitle: '', path: []));
    expect(painter().loudness, isEmpty);
    expect(painter().bands, isEmpty);
  });

  testWidgets('a different summary with the same first bin invalidates the body drawing', (tester) async {
    final clock = PlayheadClock(tester);
    addTearDown(clock.dispose);
    BodyPainter painter(List<int> bins, List<int> band) => BodyPainter(
      clock: clock, lengthMs: 1000, loudness: Uint8List.fromList(bins),
      bands: [Uint8List.fromList(band)], light: Colors.amber,
    );
    final old = painter([10, 20], [30, 40]);
    expect(painter([10, 200], [30, 40]).shouldRepaint(old), isTrue);
    final changedBand = BodyPainter(clock: clock, lengthMs: old.lengthMs,
      loudness: old.loudness, bands: [Uint8List.fromList([30, 200])], light: old.light);
    expect(changedBand.shouldRepaint(old), isTrue);
  });

  for (final fidelity in [FidelityDto.altered, FidelityDto.lossy]) {
    testWidgets('Now and the native verdict preserve active levelling with $fidelity', (tester) async {
      const level = StageDto(name: 'Level', detail: 'levelled -3.2 dB', alters: true);
      final now = NowDto(title: '', subtitle: '', fidelity: fidelity, path: const [
        StageDto(name: 'File', detail: 'AAC', alters: false), level,
        StageDto(name: 'Out', detail: 'Speakers · 44.1', alters: true),
      ]);
      await tester.pumpWidget(MaterialApp(home: NowFidelity(now: now)));
      final text = tester.widget<Text>(find.byType(Text)).data!;
      expect(text, contains(level.detail));
      expect(Outside.verdict(now), contains(level.detail));
      if (fidelity == FidelityDto.lossy) expect(text, contains('Lossy'));
    });
  }

  testWidgets('brushing LUFS writes a negative range that filters the table', (tester) async {
    final core = FakeCore();
    String? query;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TablePane(
      core: core, query: '', onQuery: (value) => query = value,
    ))));
    await tester.pump();
    await tester.pump();
    final header = find.byKey(const ValueKey('table-lufs-histogram'));
    expect(tester.widget<HistogramHeader>(header).bins.any((bin) => bin > 0), isTrue);
    final rect = tester.getRect(header);
    final gesture = await tester.startGesture(Offset(rect.left + rect.width / 2, rect.center.dy));
    await gesture.moveTo(Offset(rect.left + rect.width * 0.65, rect.center.dy));
    await gesture.moveTo(Offset(rect.left + rect.width * 0.7, rect.center.dy));
    await gesture.moveTo(Offset(rect.left + rect.width * 5 / 6, rect.center.dy));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(query, matches(r'^lufs:-\d+\.\.-\d+$'));
    expect(core.parse(query!).kind, QueryKind.search);
    final result = await core.rows(query!, _view, 0, 100);
    expect(result.items, isNotEmpty);
    final range = query!.substring(5).split('..').map(double.parse).toList();
    for (final item in result.items.cast<ItemDto_Track>()) {
      expect(item.row.loudness, inInclusiveRange(range[0], range[1]));
    }
    final unfiltered = await core.rows('', _view, 0, 1);
    expect(result.tracks, lessThan(unfiltered.tracks));
  });

  test('fake analysis filters omit unknowns and honour signed LUFS comparisons', () async {
    final core = FakeCore();
    for (final query in ['lufs:-20..-10', 'lufs:<-18', 'lufs:>-14.2', 'dr:10..12']) {
      expect(core.parse(query).kind, QueryKind.search);
      final rows = await core.rows(query, _view, 0, 100);
      expect(rows.items, isNotEmpty);
      for (final item in rows.items.cast<ItemDto_Track>()) {
        if (query.startsWith('dr:')) {
          expect(item.row.dr, inInclusiveRange(10, 12));
        } else {
          expect(item.row.loudness, isNotNull);
          if (query == 'lufs:<-18') expect(item.row.loudness, lessThan(-18));
          if (query == 'lufs:>-14.2') expect(item.row.loudness, greaterThan(-14.2));
        }
      }
    }
    expect(core.parse('lufs:-20..oops').kind, QueryKind.invalid);
  });
}
