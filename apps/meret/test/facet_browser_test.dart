import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/panes/facet_browser.dart';

void main() {
  for (final width in [800.0, 400.0]) {
    testWidgets('facet headings count what each column lists, without overflow at $width', (tester) async {
      final facets = await FakeCore().facets('');
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: FacetBrowser(facets: facets, onQuery: (_) {}))))));
      for (final (name, column, noun) in [('Idiom', facets.idioms, 'idiom'), ('People', facets.people, 'person'), ('Releases', facets.releases, 'release')]) {
        expect(find.text(name), findsOneWidget);
        final count = column.entries.length;
        expect(find.text('$count ${count == 1 ? noun : noun == 'person' ? 'people' : '${noun}s'}'), findsOneWidget);
        expect(find.text('${column.tracks} tracks'), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
