import 'package:flutter/material.dart';

/// Facts joined by ` · `, broken between facts rather than inside one, so no
/// line ends on a dot and no fact splits across lines.
class Facts extends StatelessWidget {
  const Facts(this.facts, {super.key, required this.style});

  final List<String> facts;
  final TextStyle style;

  static const _dot = ' · ';

  @override
  Widget build(BuildContext context) {
    final shown = facts.where((fact) => fact.isNotEmpty).toList();
    return LayoutBuilder(builder: (context, box) {
      final scaler = MediaQuery.textScalerOf(context);
      final direction = Directionality.of(context);
      double width(String text) {
        final painter = TextPainter(text: TextSpan(text: text, style: style), textDirection: direction, textScaler: scaler, maxLines: 1)..layout();
        final w = painter.width;
        painter.dispose();
        return w;
      }

      final lines = <String>[];
      var line = '';
      for (final fact in shown) {
        final joined = line.isEmpty ? fact : '$line$_dot$fact';
        if (line.isNotEmpty && width(joined) > box.maxWidth) {
          lines.add(line);
          line = fact;
        } else {
          line = joined;
        }
      }
      if (line.isNotEmpty) lines.add(line);
      return Text(lines.join('\n'), style: style);
    });
  }
}
