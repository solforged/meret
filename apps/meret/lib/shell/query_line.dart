import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../theme/tokens.dart';
import 'window_chrome.dart';

/// `/`: searches everything you own, can stream or have found, and takes
/// commands. Parsed as you type (a synchronous call; parsing is pure and
/// takes microseconds). Running a search starts a new trail.
///
/// On macOS it is also the window's title bar: the window buttons sit at
/// its left, and the space around the field moves the window.
class QueryLine extends StatefulWidget {
  const QueryLine({super.key, required this.core, required this.focus, this.onSubmit});

  final CoreBridge core;
  final FocusNode focus;
  final Future<void> Function(QueryDto)? onSubmit;

  @override
  State<QueryLine> createState() => _QueryLineState();
}

class _QueryLineState extends State<QueryLine> {
  final _text = TextEditingController();
  QueryDto? _parsed;
  String? _submitError;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _parsed;
    final hint = _submitError ?? switch (p?.kind) {
      null => 'Search everything, or type a command',
      QueryKind.invalid => p!.error ?? '',
      QueryKind.command => '↵ to run',
      QueryKind.search => '↵ as a table',
    };
    return ValueListenableBuilder(
      valueListenable: WindowChrome.instance.fullScreen,
      builder: (context, _, _) => Container(
        height: 38,
        decoration: const BoxDecoration(color: Tok.panel, border: Border(bottom: BorderSide(color: Tok.line))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          WindowDragArea(
            child: Container(
              alignment: Alignment.centerLeft,
              padding: EdgeInsets.only(left: 12 + WindowChrome.instance.buttonsInset, right: 10),
              child: Text('/', style: Tok.monoSmall.copyWith(color: Tok.gold)),
            ),
          ),
          Expanded(
            flex: 3,
            child: Center(
              child: TextField(
                controller: _text,
                focusNode: widget.focus,
                style: Tok.monoSmall.copyWith(color: Tok.ink, fontSize: 12.5),
                cursorColor: Tok.gold,
                decoration: const InputDecoration.collapsed(hintText: ''),
                onChanged: (s) => setState(() {
                  _parsed = s.isEmpty ? null : widget.core.parse(s);
                  _submitError = null;
                }),
                onSubmitted: (_) async {
                  final input = _text.text;
                  final parsed = _parsed ?? widget.core.parse(input);
                  if (parsed.kind == QueryKind.invalid) return;
                  try {
                    await widget.onSubmit?.call(parsed);
                  } catch (error) {
                    if (mounted && _text.text == input) setState(() => _submitError = error.toString());
                  }
                },
              ),
            ),
          ),
          Expanded(
            child: WindowDragArea(
              child: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Tok.label.copyWith(color: _submitError != null || p?.kind == QueryKind.invalid ? Tok.ox : Tok.faint),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
