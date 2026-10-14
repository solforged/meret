import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../theme/tokens.dart';

/// `/`: searches everything you own, can stream or have found, and takes
/// commands. Parsed as you type (a synchronous call; parsing is pure and
/// takes microseconds). Running a search starts a new trail.
class QueryLine extends StatefulWidget {
  const QueryLine({super.key, required this.core, required this.focus, this.onSubmit});

  final CoreBridge core;
  final FocusNode focus;
  final ValueChanged<QueryDto>? onSubmit;

  @override
  State<QueryLine> createState() => _QueryLineState();
}

class _QueryLineState extends State<QueryLine> {
  final _text = TextEditingController();
  QueryDto? _parsed;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _parsed;
    final hint = switch (p?.kind) {
      null => 'Search everything, or type a command',
      QueryKind.invalid => p!.error ?? '',
      QueryKind.command => '↵ to run',
      QueryKind.search => '↵ as a table · ⌘↵ as a sky',
    };
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(color: Tok.panel, border: Border(bottom: BorderSide(color: Tok.line))),
      child: Row(children: [
        Text('/', style: Tok.monoSmall.copyWith(color: Tok.gold)),
        const SizedBox(width: 10),
        Expanded(
          flex: 3,
          child: TextField(
            controller: _text,
            focusNode: widget.focus,
            style: Tok.monoSmall.copyWith(color: Tok.ink, fontSize: 12.5),
            cursorColor: Tok.gold,
            decoration: const InputDecoration.collapsed(hintText: ''),
            onChanged: (s) => setState(() => _parsed = s.isEmpty ? null : widget.core.parse(s)),
            onSubmitted: (_) {
              final p = _parsed;
              if (p != null && p.kind != QueryKind.invalid) widget.onSubmit?.call(p);
            },
          ),
        ),
        Flexible(
          child: Text(
            hint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Tok.label.copyWith(color: p?.kind == QueryKind.invalid ? Tok.ox : Tok.faint),
          ),
        ),
      ]),
    );
  }
}
