import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;

import '../core/bridge.dart';
import '../core/when.dart';
import '../theme/tokens.dart';
import 'now_pane.dart';

Future<void> showHistorySheet(
  BuildContext context, CoreBridge core, Future<void> Function(PlatformInt64) onRelease,
) => showDialog<void>(
  context: context,
  barrierColor: Colors.black54,
  builder: (_) => _HistorySheet(core: core, onRelease: onRelease),
);

class _HistorySheet extends StatefulWidget {
  const _HistorySheet({required this.core, required this.onRelease});
  final CoreBridge core;
  final Future<void> Function(PlatformInt64) onRelease;

  @override
  State<_HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends State<_HistorySheet> {
  late final Future<List<ListenDto>> _history = widget.core.history(200);

  @override
  Widget build(BuildContext context) => Dialog(
    key: const ValueKey('history-sheet'),
    backgroundColor: Tok.panel,
    insetPadding: const EdgeInsets.all(20),
    shape: const RoundedRectangleBorder(side: BorderSide(color: Tok.rule)),
    child: SizedBox(width: 520, height: 640, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 12, 12, 8), child: Row(children: [
        const Expanded(child: Text('History · newest first', style: Tok.label)),
        IconButton(tooltip: 'Close history', onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close, size: 18, color: Tok.muted)),
      ])),
      const Divider(height: 1, color: Tok.rule),
      Expanded(child: FutureBuilder<List<ListenDto>>(
        future: _history,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Padding(padding: const EdgeInsets.all(20), child: Text(snapshot.error.toString(), style: Tok.label.copyWith(color: Tok.warn)));
          final listens = snapshot.data;
          if (listens == null) return const Padding(padding: EdgeInsets.all(20), child: Text('Reading your history…', style: Tok.label));
          if (listens.isEmpty) return const Padding(padding: EdgeInsets.all(20), child: Text('What you play will be here.', style: Tok.label));
          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            itemCount: listens.length,
            itemBuilder: (context, index) {
              final listen = listens[index];
              return NowDoor(
                key: ValueKey('history-listen-${listen.uid}'),
                onTap: listen.releaseId == null ? null : () {
                  Navigator.of(context).pop();
                  widget.onRelease(listen.releaseId!);
                },
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Expanded(child: Text(dayAndTime(listen.startedAtMs.toInt()), style: Tok.label)),
                    if (listen.counted) const Text('✓', style: TextStyle(color: Tok.ok)),
                  ]),
                  const SizedBox(height: 4),
                  Text(listen.title, style: Tok.body),
                  Text([if (listen.credit != null) listen.credit!, if (listen.releaseTitle != null) listen.releaseTitle!].join(' · '), style: Tok.label),
                  const SizedBox(height: 4),
                  Text('${clockLength(listen.playedMs.toInt())}${listen.lengthMs == null ? '' : ' of ${clockLength(listen.lengthMs!.toInt())}'}', style: Tok.monoSmall),
                ]),
              );
            },
          );
        },
      )),
      const Padding(padding: EdgeInsets.fromLTRB(20, 8, 20, 16), child: Text('Escape closes · a play opens its release', style: Tok.label)),
    ])),
  );
}
