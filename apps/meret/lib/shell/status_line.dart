import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../theme/tokens.dart';

/// Always visible on desktop: every source's state, every running job, and
/// how many identities are guesses.
class StatusLine extends StatelessWidget {
  const StatusLine({super.key, required this.status, required this.keys});

  final StatusDto? status;

  /// Key hints for the current context: ('/', 'search'), ('[ ]', 'along the trail').
  final List<(String, String)> keys;

  @override
  Widget build(BuildContext context) {
    final s = status;
    String n(BigInt v) => v.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(color: Tok.void_, border: Border(top: BorderSide(color: Tok.line))),
      child: Row(children: [
        if (s != null) ...[
          for (final src in s.sources) ...[
            Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: src.ok ? Tok.ok : Tok.warn)),
            const SizedBox(width: 6),
            Text(src.name, style: Tok.monoSmall.copyWith(fontSize: 10.5, color: Tok.ink)),
            const SizedBox(width: 6),
            Text(src.detail, style: Tok.label),
            const SizedBox(width: 16),
          ],
          for (final j in s.jobs) ...[
            Text('↻ ${j.verb} ${n(j.done)} of ${n(j.total)}', style: Tok.label.copyWith(color: Tok.gold2)),
            const SizedBox(width: 16),
          ],
          if (s.guessed > BigInt.zero) Text('≈ ${n(s.guessed)} to identify', style: Tok.label.copyWith(color: Tok.warn)),
        ],
        const Spacer(),
        for (final (k, what) in keys) ...[
          Text(k, style: Tok.label.copyWith(color: Tok.gold)),
          const SizedBox(width: 5),
          Text(what, style: Tok.label),
          const SizedBox(width: 14),
        ],
      ]),
    );
  }
}
