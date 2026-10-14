import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// What every pane shows at the top: the thread that brought you, the kind
/// of thing, its name. Folds to a vertical spine when narrow.
class Pane extends StatelessWidget {
  const Pane({super.key, required this.kind, required this.title, this.via, this.source, this.body});

  /// "PERSON · COMPOSER", "SCORE · 1998", "GROUP · NOT OWNED".
  final String kind;
  final String title;

  /// The thread followed into this pane: "composed by".
  final String? via;

  /// Who said so: "MusicBrainz · VGMdb".
  final String? source;
  final Widget? body;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth < 60) return _Spine(title: title);
      return Container(
        decoration: const BoxDecoration(color: Tok.sky, border: Border(right: BorderSide(color: Tok.line))),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (via != null)
            Row(children: [
              Text(via!, style: Tok.label.copyWith(color: Tok.gold, fontStyle: FontStyle.italic, letterSpacing: 0)),
              const SizedBox(width: 12),
              if (source != null)
                Expanded(
                  child: Text(source!, style: Tok.label, textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
            ]),
          const SizedBox(height: 10),
          Text(kind, style: Tok.label, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text(title, style: Tok.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 12),
          Expanded(child: body ?? const SizedBox()),
        ]),
      );
    });
  }
}

class _Spine extends StatelessWidget {
  const _Spine({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(color: Tok.void_, border: Border(right: BorderSide(color: Tok.line))),
        alignment: Alignment.topCenter,
        padding: const EdgeInsets.only(top: 12),
        child: RotatedBox(quarterTurns: 1, child: Text(title, style: Tok.monoSmall, maxLines: 1)),
      );
}
