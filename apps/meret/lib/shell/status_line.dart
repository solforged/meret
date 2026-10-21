import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../settings/settings_window.dart';
import '../theme/tokens.dart';

String _n(BigInt number) => number.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

bool _isScan(JobDto job) => job.verb == 'scanning' || job.verb == 'reading tags';

/// Always visible on desktop: every source's state, every running job, and
/// how many identities are guesses.
class StatusLine extends StatefulWidget {
  const StatusLine({super.key, required this.core, required this.status, required this.keys});

  final CoreBridge core;
  final StatusDto? status;

  /// Key hints for the current context: ('/', 'search'), ('[ ]', 'along the trail').
  final List<(String, String)> keys;

  @override
  State<StatusLine> createState() => _StatusLineState();
}

class _StatusLineState extends State<StatusLine> {
  Future<FrontDto>? _front;

  Widget _local(StatusDto status) => FutureBuilder<FrontDto>(
    future: _front,
    builder: (context, snapshot) {
      final front = snapshot.data;
      final scans = status.jobs.where(_isScan);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(
          front == null
            ? 'This Mac has ${_n(status.tracks)} ${status.tracks == BigInt.one ? 'track' : 'tracks'}.'
            : '${_n(status.tracks)} ${status.tracks == BigInt.one ? 'track' : 'tracks'} in ${front.roots.length} ${front.roots.length == 1 ? 'folder' : 'folders'}.',
          style: Tok.body,
        ),
        const SizedBox(height: 8),
        if (snapshot.hasError)
          Text('Could not read folders: ${snapshot.error}', style: Tok.body.copyWith(color: Tok.warn))
        else if (front == null)
          const Text('Reading folders…', style: Tok.label)
        else if (front.roots.any((root) => !root.online))
          Text('${front.roots.where((root) => !root.online).length} offline', style: Tok.body.copyWith(color: Tok.muted)),
        if (scans.isNotEmpty)
          Text('Meret is ${scans.map((job) => job.verb).toSet().join(' and ')}.', style: Tok.body.copyWith(color: Tok.muted)),
      ]);
    },
  );

  Widget _source(SourceDto source, StatusDto status) {
    final section = switch (source.key) {
      'local' => SettingsSection.folders,
      'musicbrainz' => SettingsSection.lookups,
      _ => SettingsSection.sources,
    };
    return _StatusButton(
      key: ValueKey('status-source-${source.key}'),
      title: source.name,
      section: section,
      onOpen: source.key == 'local' ? () => setState(() {
        _front = widget.core.front();
      }) : null,
      onSettings: () => showSettings(context, section: section),
      content: switch (source.key) {
        'local' => _local(status),
        _ => Text(source.detail, style: Tok.body),
      },
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: source.ok ? Tok.ok : Tok.warn)),
        const SizedBox(width: 6),
        Text(source.name, style: Tok.monoSmall.copyWith(fontSize: 10.5, color: Tok.ink)),
        const SizedBox(width: 6),
        Text(source.detail, style: Tok.label),
      ]),
    );
  }

  Widget _job(JobDto job, int index) => _StatusButton(
    key: ValueKey('status-job-$index'),
    title: _isScan(job) ? 'Folder scan' : 'Library job',
    section: SettingsSection.folders,
    onSettings: () => showSettings(context, section: SettingsSection.folders),
    content: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Phase · ${job.verb}', style: Tok.body),
      const SizedBox(height: 8),
      Text('${_n(job.done)} of ${_n(job.total)}', style: Tok.monoSmall),
      const SizedBox(height: 10),
      LinearProgressIndicator(
        value: job.total > BigInt.zero ? (job.done.toDouble() / job.total.toDouble()).clamp(0, 1) : null,
        minHeight: 2,
        color: Tok.gold2,
        backgroundColor: Tok.line,
      ),
    ]),
    child: Text('↻ ${job.verb} ${_n(job.done)} of ${_n(job.total)}', style: Tok.label.copyWith(color: Tok.gold2)),
  );

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(color: Tok.void_, border: Border(top: BorderSide(color: Tok.line))),
      child: Row(children: [
        Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
          if (status != null) ...[
            for (final source in status.sources) _source(source, status),
            for (var index = 0; index < status.jobs.length; index++) _job(status.jobs[index], index),
            if (status.guessed > BigInt.zero)
              Text('≈ ${_n(status.guessed)} to identify', style: Tok.label.copyWith(color: Tok.warn)),
          ],
        ]))),
        for (final (key, what) in widget.keys) ...[
          const SizedBox(width: 12),
          Text(key, style: Tok.label.copyWith(color: Tok.gold)),
          const SizedBox(width: 5),
          Text(what, style: Tok.label),
        ],
      ]),
    );
  }
}

class _StatusButton extends StatefulWidget {
  const _StatusButton({super.key, required this.title, required this.section, required this.content, required this.onSettings, required this.child, this.onOpen});

  final String title;
  final SettingsSection section;
  final Widget content;
  final VoidCallback onSettings;
  final VoidCallback? onOpen;
  final Widget child;

  @override
  State<_StatusButton> createState() => _StatusButtonState();
}

class _StatusButtonState extends State<_StatusButton> {
  final _menu = MenuController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MenuAnchor(
    controller: _menu,
    childFocusNode: _focus,
    onOpen: widget.onOpen,
    alignmentOffset: const Offset(0, -8),
    style: MenuStyle(
      backgroundColor: const WidgetStatePropertyAll(Tok.panel),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      side: const WidgetStatePropertyAll(BorderSide(color: Tok.rule)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
    ),
    menuChildren: [
      SizedBox(width: 340, child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(widget.title, style: Tok.body.copyWith(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          widget.content,
          const SizedBox(height: 16),
          Align(alignment: Alignment.centerLeft, child: TextButton(
            key: ValueKey('status-open-settings-${widget.section.name}'),
            onPressed: () {
              _menu.close();
              widget.onSettings();
            },
            style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft, minimumSize: const Size(0, 28)),
            child: Text('Open in Settings', style: Tok.body.copyWith(color: Tok.gold)),
          )),
        ]),
      )),
    ],
    builder: (context, controller, child) => TextButton(
      focusNode: _focus,
      onPressed: () => controller.isOpen ? controller.close() : controller.open(),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.only(right: 16),
        minimumSize: const Size(0, 24),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const RoundedRectangleBorder(),
      ),
      child: widget.child,
    ),
  );
}
