import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../settings/settings_window.dart';
import '../theme/tokens.dart';

String _n(BigInt number) => number.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

/// The top line's one word on the plumbing (navigation.md, "Activity"): a
/// dot while every source is fine, a ring while a job runs, amber when
/// something needs you. Its popover lists sources, folders, jobs and
/// guesses, and opens Settings.
class Activity extends StatefulWidget {
  const Activity({super.key, required this.core, required this.status});

  final CoreBridge core;
  final StatusDto? status;

  @override
  State<Activity> createState() => _ActivityState();
}

class _ActivityState extends State<Activity> {
  final _menu = MenuController();
  final _focus = FocusNode();
  List<RootDto>? _roots;
  Object? _rootsError;
  BigInt? _rootsVersion;

  @override
  void initState() {
    super.initState();
    _readRoots();
  }

  @override
  void didUpdateWidget(Activity old) {
    super.didUpdateWidget(old);
    if (widget.status?.libraryVersion != _rootsVersion) _readRoots();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// Folders come from the Front's summary; read again when the library changes.
  Future<void> _readRoots() async {
    final version = widget.status?.libraryVersion;
    _rootsVersion = version;
    try {
      final front = await widget.core.front();
      if (!mounted || version != _rootsVersion) return;
      setState(() {
        _roots = front.roots;
        _rootsError = null;
      });
    } catch (error) {
      if (mounted && version == _rootsVersion) setState(() => _rootsError = error);
    }
  }

  void _settings(SettingsSection section) {
    _menu.close();
    showSettings(context, section: section);
  }

  /// What needs you, in as few words as the line can hold.
  List<String> _needs(StatusDto status) {
    final offline = _roots?.where((root) => !root.online).length ?? 0;
    return [
      for (final source in status.sources) if (!source.ok) '${source.name} ${source.detail}',
      if (offline > 0) '$offline ${offline == 1 ? 'folder' : 'folders'} offline',
      if (status.guessed > BigInt.zero) '≈ ${_n(status.guessed)} to identify',
    ];
  }

  Widget _row({required Key key, required bool ok, required String name, required String detail, VoidCallback? onTap, Widget? below}) => InkWell(
    key: key,
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.line))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          _Dot(ok ? Tok.ok : Tok.warn),
          const SizedBox(width: 8),
          Expanded(child: Text(name, style: Tok.body.copyWith(fontSize: 12.5, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 12),
          Flexible(child: Text(detail, style: Tok.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ]),
        if (below != null) Padding(padding: const EdgeInsets.only(left: 14, top: 4), child: below),
      ]),
    ),
  );

  List<Widget> _popover(StatusDto? status) => [
    SizedBox(width: 340, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (status == null)
        const Padding(padding: EdgeInsets.all(12), child: Text('Starting…', style: Tok.label))
      else ...[
        for (final source in status.sources)
          _row(
            key: ValueKey('activity-source-${source.key}'),
            ok: source.ok, name: source.name, detail: source.detail,
            onTap: () => _settings(switch (source.key) {
              'local' => SettingsSection.folders,
              'musicbrainz' => SettingsSection.lookups,
              _ => SettingsSection.sources,
            }),
          ),
        if (_rootsError != null)
          Padding(padding: const EdgeInsets.all(12), child: Text('Could not read folders: $_rootsError', style: Tok.body.copyWith(color: Tok.warn)))
        else
          for (final root in _roots ?? const <RootDto>[])
            _row(
              key: ValueKey('activity-folder-${root.id}'),
              ok: root.online, name: root.label.isEmpty ? root.path : root.label,
              detail: root.online ? '${_n(root.tracks)} ${root.tracks == BigInt.one ? 'track' : 'tracks'}' : 'offline',
              onTap: () => _settings(SettingsSection.folders),
            ),
        for (final (index, job) in status.jobs.indexed)
          _row(
            key: ValueKey('activity-job-$index'),
            ok: true, name: job.verb, detail: '${_n(job.done)} of ${_n(job.total)}',
            onTap: () => _settings(SettingsSection.folders),
            below: LinearProgressIndicator(
              value: job.total > BigInt.zero ? (job.done.toDouble() / job.total.toDouble()).clamp(0, 1) : null,
              minHeight: 2, color: Tok.gold2, backgroundColor: Tok.rule,
            ),
          ),
        if (status.guessed > BigInt.zero)
          _row(key: const ValueKey('activity-guesses'), ok: false, name: '≈ ${_n(status.guessed)} guesses', detail: 'to identify'),
      ],
      InkWell(
        key: const ValueKey('activity-settings'),
        onTap: () => _settings(SettingsSection.folders),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Expanded(child: Text('Folders and sources in Settings…', style: Tok.body.copyWith(fontSize: 12, color: Tok.gold), maxLines: 1, overflow: TextOverflow.ellipsis)),
            const Text('⌘,', style: Tok.label),
          ]),
        ),
      ),
    ])),
  ];

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    final needs = status == null ? const <String>[] : _needs(status);
    final busy = status != null && status.jobs.isNotEmpty;
    final job = busy ? status.jobs.first : null;
    final words = [
      if (job != null) '${job.verb} ${_n(job.done)} / ${_n(job.total)}${status!.jobs.length > 1 ? ' · ${status.jobs.length - 1} more' : ''}',
      ...needs,
    ].join(' · ');
    final colour = needs.isNotEmpty ? Tok.warn : busy ? Tok.gold2 : Tok.faint;
    return MenuAnchor(
      controller: _menu,
      childFocusNode: _focus,
      onOpen: _readRoots,
      alignmentOffset: const Offset(0, 6),
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(Tok.panel),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        side: const WidgetStatePropertyAll(BorderSide(color: Tok.rule)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
      ),
      menuChildren: _popover(status),
      builder: (context, controller, _) => Semantics(
        label: words.isEmpty ? 'Every source is fine' : words,
        child: TextButton(
          key: const ValueKey('activity'),
          focusNode: _focus,
          onPressed: () => controller.isOpen ? controller.close() : controller.open(),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 9),
            minimumSize: const Size(26, 26),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(side: BorderSide(color: words.isEmpty ? Colors.transparent : colour.withValues(alpha: 0.35))),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (busy)
              SizedBox(width: 11, height: 11, child: CircularProgressIndicator(
                // Still, not spinning: the ring fills as the first job does.
                key: const ValueKey('activity-ring'), strokeWidth: 1.5, color: Tok.gold, backgroundColor: Tok.rule,
                value: job!.total > BigInt.zero ? (job.done.toDouble() / job.total.toDouble()).clamp(0.0, 1.0) : 0.25,
              ))
            else
              _Dot(needs.isEmpty ? Tok.ok : Tok.warn, key: const ValueKey('activity-dot')),
            if (words.isNotEmpty) ...[
              const SizedBox(width: 7),
              Flexible(child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(words, key: const ValueKey('activity-words'), style: Tok.label.copyWith(color: colour), maxLines: 1, overflow: TextOverflow.ellipsis),
              )),
            ],
          ]),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot(this.colour, {super.key});
  final Color colour;

  @override
  Widget build(BuildContext context) => Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: colour));
}
