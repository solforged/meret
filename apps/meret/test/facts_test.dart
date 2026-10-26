import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/draw/facts.dart';

void main() {
  testWidgets('facts break between facts, never after a dot', (tester) async {
    const facts = ['Album', '1994', '12 tracks', '1 disc', '45:12', 'DR 9', 'MP3'];
    await tester.pumpWidget(const MaterialApp(home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 160, child: Facts(facts, style: TextStyle(fontSize: 12))),
    )));
    final text = tester.widget<Text>(find.byType(Text)).data!;
    final lines = text.split('\n');
    expect(lines.length, greaterThan(1));
    for (final line in lines) {
      expect(line.endsWith('·'), isFalse, reason: line);
      expect(line.startsWith('·'), isFalse, reason: line);
    }
    expect(lines.join(' · '), facts.join(' · '));
  });
}
