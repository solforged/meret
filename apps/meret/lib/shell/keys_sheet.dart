import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Every key on one page (navigation.md, plate 04). The hints stay off the
/// screen; this, the Go and Controls menus and the tooltips carry them.
/// `?` or Esc closes it.
Future<void> showKeysSheet(BuildContext context) => showDialog<void>(
  context: context,
  barrierColor: Colors.black54,
  builder: (_) => const _KeysSheet(),
);

/// The groups in reading order: where to go, the trail, a pane, playback.
const keyGroups = <(String, List<(String, String)>)>[
  ('Go', [
    ('⌘1', 'Home over the trail; again, Today'),
    ('⌘2–⌘9', "Home's doors, in order"),
    ('⌘L', 'Library table'),
    ('/', 'Search, or a command'),
    ('Esc', 'Close Home, then the tree'),
  ]),
  ('Trail', [
    ('[', 'Back along the trail'),
    (']', 'Forward'),
    ('⌥[ ⌥]', 'Other branch'),
    ('T', 'The whole tree'),
    ('⌘S', 'Keep the trail'),
    ('⌘⌫', 'Prune the branch'),
  ]),
  ('In a pane', [
    ('↑ ↓', 'Move through the table'),
    ('↵', 'Play the chosen row'),
    ('⌘↵', 'Follow it'),
  ]),
  ('Play', [
    ('Space', 'Play or pause'),
    ('⇧Space', 'Play something'),
    ('⌥Space', 'From the start'),
    ('N', 'Now'),
    ('H', 'History'),
  ]),
  ('Meret', [
    ('?', 'These keys'),
    ('⌘,', 'Settings'),
  ]),
];

class _KeysSheet extends StatelessWidget {
  const _KeysSheet();

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {const CharacterActivator('?'): () => Navigator.of(context).pop()},
    child: Focus(autofocus: true, child: Dialog(
      key: const ValueKey('keys-sheet'),
      backgroundColor: Tok.panel,
      insetPadding: const EdgeInsets.all(20),
      shape: const RoundedRectangleBorder(side: BorderSide(color: Tok.rule)),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 12, 12, 8), child: Row(children: [
          const Expanded(child: Text('Keys', style: Tok.label)),
          IconButton(tooltip: 'Close  ?', onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close, size: 18, color: Tok.muted)),
        ])),
        const Divider(height: 1, color: Tok.rule),
        Flexible(child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          // Two columns where there's room, one on a narrow window.
          child: Wrap(spacing: 32, runSpacing: 18, children: [
            for (final (title, keys) in keyGroups) SizedBox(width: 276, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(title.toUpperCase(), style: Tok.label.copyWith(color: Tok.gold2))),
              for (final (key, does) in keys) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 72, child: Text(key, style: Tok.monoSmall.copyWith(color: Tok.ink))),
                Expanded(child: Text(does, style: Tok.body.copyWith(fontSize: 12.5, color: Tok.muted))),
              ])),
            ])),
          ]),
        )),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
          child: Text('The Go and Controls menus list these too.', style: Tok.label.copyWith(letterSpacing: 0)),
        ),
      ])),
    )),
  );
}
