import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/panes/facet_browser.dart';

void main() {
  for (final width in [800.0, 400.0]) {
    testWidgets('facet headings label track totals without overflow at $width', (tester) async {
      final facets = await FakeCore().facets('');
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: FacetBrowser(facets: facets, onQuery: (_) {}))))));
      for (final (name, column) in [('Idiom', facets.idioms), ('People', facets.people), ('Releases', facets.releases)]) {
        expect(find.text(name), findsOneWidget);
        expect(find.text('${column.tracks} tracks'), findsWidgets);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
