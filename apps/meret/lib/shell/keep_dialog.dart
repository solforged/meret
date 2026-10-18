import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

Future<({String? name})?> askTrailName(BuildContext context, {required String suggested}) => showDialog<({String? name})>(
  context: context,
  barrierColor: const Color(0xBD02040A),
  builder: (context) => _KeepDialog(suggested: suggested),
);

class _KeepDialog extends StatefulWidget {
  const _KeepDialog({required this.suggested});
  final String suggested;

  @override
  State<_KeepDialog> createState() => _KeepDialogState();
}

class _KeepDialogState extends State<_KeepDialog> {
  late final _name = TextEditingController(text: widget.suggested)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.suggested.length);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _keep() => Navigator.of(context).pop((name: _name.text.trim().isEmpty ? null : _name.text));

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.escape): _CancelKeep(),
      SingleActivator(LogicalKeyboardKey.enter): _ConfirmKeep(),
      SingleActivator(LogicalKeyboardKey.numpadEnter): _ConfirmKeep(),
    },
    child: Actions(
      actions: {
        _CancelKeep: CallbackAction<_CancelKeep>(onInvoke: (_) => Navigator.of(context).pop()),
        _ConfirmKeep: CallbackAction<_ConfirmKeep>(onInvoke: (_) => _keep()),
      },
      child: Dialog(
        key: const ValueKey('keep-trail-dialog'),
        backgroundColor: Tok.panel,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11), side: const BorderSide(color: Color(0xFF344064))),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Keep this trail', style: Tok.title),
              const SizedBox(height: 18),
              TextField(
                key: const ValueKey('trail-name'),
                controller: _name,
                autofocus: true,
                style: Tok.body,
                cursorColor: Tok.gold,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  labelStyle: Tok.label,
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Tok.rule)),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Tok.gold)),
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _keep(),
              ),
              const SizedBox(height: 14),
              Text('Keeping keeps the whole tree. A branch you played or wanted is kept with it.', style: Tok.body.copyWith(color: Tok.muted)),
              const SizedBox(height: 22),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(foregroundColor: Tok.muted, textStyle: Tok.body),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 10),
                TextButton(
                  onPressed: _keep,
                  style: TextButton.styleFrom(
                    foregroundColor: Tok.sky,
                    backgroundColor: Tok.gold,
                    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
                    shape: const RoundedRectangleBorder(side: BorderSide(color: Tok.rule)),
                    textStyle: Tok.body.copyWith(fontWeight: FontWeight.w600),
                  ),
                  child: const Text('Keep'),
                ),
              ]),
            ]),
          ),
        ),
      ),
    ),
  );
}

class _CancelKeep extends Intent {
  const _CancelKeep();
}

class _ConfirmKeep extends Intent {
  const _ConfirmKeep();
}
