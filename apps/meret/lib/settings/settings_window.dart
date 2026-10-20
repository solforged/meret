import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bridge.dart';
import '../panes/add_folder.dart';
import '../shell/window_chrome.dart';
import '../theme/tokens.dart';

enum SettingsSection { folders, sources, playback, lookups, files, history, devices, light }

/// Keeps Settings over the surface, outside the music trail.
class SettingsScope extends StatefulWidget {
  const SettingsScope({super.key, required this.core, required this.onChanged, required this.child});

  final CoreBridge core;
  final ValueChanged<SettingsDto> onChanged;
  final Widget child;

  @override
  State<SettingsScope> createState() => _SettingsScopeState();
}

class _SettingsScopeState extends State<SettingsScope> {
  DialogRoute<void>? _route;

  void show(SettingsSection section) {
    if (_route != null) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: const Color(0xBD02040A),
      builder: (context) => _SettingsWindow(core: widget.core, onChanged: widget.onChanged, section: section),
    );
    _route = route;
    final chrome = WindowChrome.instance;
    chrome.onCloseSettings = () {
      if (route.isActive) navigator.removeRoute(route);
    };
    chrome.setSettingsVisible(true);
    navigator.push(route).whenComplete(() {
      _route = null;
      chrome.onCloseSettings = null;
      chrome.setSettingsVisible(false);
    });
  }

  @override
  void dispose() {
    if (_route != null) {
      WindowChrome.instance.onCloseSettings = null;
      WindowChrome.instance.setSettingsVisible(false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _SettingsAccess(state: this, child: widget.child);
}

class _SettingsAccess extends InheritedWidget {
  const _SettingsAccess({required this.state, required super.child});
  final _SettingsScopeState state;

  @override
  bool updateShouldNotify(_SettingsAccess oldWidget) => state != oldWidget.state;
}

void showSettings(BuildContext context, {SettingsSection section = SettingsSection.folders}) {
  context.getInheritedWidgetOfExactType<_SettingsAccess>()!.state.show(section);
}

class _SettingsWindow extends StatefulWidget {
  const _SettingsWindow({required this.core, required this.onChanged, required this.section});

  final CoreBridge core;
  final ValueChanged<SettingsDto> onChanged;
  final SettingsSection section;

  @override
  State<_SettingsWindow> createState() => _SettingsWindowState();
}

class _SettingsWindowState extends State<_SettingsWindow> {
  late SettingsSection _section = widget.section;
  SettingsDto? _settings;
  FrontDto? _front;
  StatusDto? _status;
  NowDto? _now;
  List<OutputDeviceDto>? _devices;
  StreamSubscription<StatusDto>? _statusSub;
  StreamSubscription<NowDto>? _nowSub;
  String _source = 'local';
  String? _error;
  String? _deviceError;
  RootDto? _confirmRemove;
  bool _saving = false;
  bool _changingFolders = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadFront();
    _loadDevices();
    _nowSub = widget.core.now().listen((now) {
      if (mounted) setState(() => _now = now);
    });
    _statusSub = widget.core.status().listen((status) {
      final changed = _status != null && _status!.libraryVersion != status.libraryVersion;
      if (mounted) setState(() => _status = status);
      if (changed) _loadFront();
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _nowSub?.cancel();
    super.dispose();
  }

  void _loadSettings() {
    try {
      final settings = widget.core.settings();
      if (mounted) setState(() => _settings = settings);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _loadFront() async {
    try {
      final front = await widget.core.front();
      if (mounted) setState(() => _front = front);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _loadDevices() async {
    try {
      final devices = await widget.core.outputDevices();
      if (mounted) setState(() => _devices = devices);
    } catch (error) {
      if (mounted) setState(() => _deviceError = error.toString());
    }
  }

  Future<void> _save({LightLevelDto? light, String? outputDevice, bool changeDevice = false, bool? exclusive}) async {
    final current = _settings!;
    final next = SettingsDto(
      light: light ?? current.light,
      outputDevice: changeDevice ? outputDevice : current.outputDevice,
      exclusive: exclusive ?? current.exclusive,
    );
    setState(() { _saving = true; _error = null; });
    try {
      await widget.core.setSettings(next);
      if (!mounted) return;
      setState(() => _settings = next);
      widget.onChanged(next);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addFolder() async {
    setState(() { _changingFolders = true; _error = null; });
    try {
      if (await addMusicFolder(widget.core, isMounted: () => mounted)) await _loadFront();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _changingFolders = false);
    }
  }

  Future<void> _removeFolder(RootDto root) async {
    setState(() { _changingFolders = true; _error = null; });
    try {
      await widget.core.removeRoot(root.id.toInt());
      if (!mounted) return;
      setState(() => _confirmRemove = null);
      await _loadFront();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _changingFolders = false);
    }
  }

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.escape): _CloseSettings(),
      SingleActivator(LogicalKeyboardKey.keyW, meta: true): _CloseSettings(),
    },
    child: Actions(
      actions: {_CloseSettings: CallbackAction<_CloseSettings>(onInvoke: (_) => Navigator.of(context).pop())},
      child: Focus(
        autofocus: true,
        child: Dialog(
          key: const ValueKey('settings-window'),
          backgroundColor: Tok.panel,
          surfaceTintColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11), side: const BorderSide(color: Color(0xFF344064))),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1160, maxHeight: 790),
            child: Column(children: [
              _titleBar(),
              Expanded(child: LayoutBuilder(builder: (context, constraints) => Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(width: constraints.maxWidth < 850 ? 164 : 204, child: _navigation()),
                const VerticalDivider(width: 1, color: Tok.rule),
                Expanded(child: SingleChildScrollView(
                  key: ValueKey(_section),
                  padding: EdgeInsets.all(constraints.maxWidth < 850 ? 22 : 34),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (_error != null) ...[_note(_error!, warning: true), const SizedBox(height: 20)],
                    KeyedSubtree(key: ValueKey('settings-section-${_section.name}'), child: _sectionBody()),
                  ]),
                )),
              ]))),
            ]),
          ),
        ),
      ),
    ),
  );

  Widget _titleBar() => Container(
    height: 52,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: const BoxDecoration(color: Color(0xFF0E1529), border: Border(bottom: BorderSide(color: Tok.line))),
    child: Row(children: [
      IconButton(
        onPressed: () => Navigator.of(context).pop(),
        tooltip: 'Close Settings',
        icon: Container(width: 11, height: 11, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFBC5B5A)), child: const Icon(Icons.close, size: 9, color: Color(0xFF5C2222))),
      ),
      const SizedBox(width: 42),
      Text('Meret settings', style: Tok.body.copyWith(fontWeight: FontWeight.w600, fontSize: 14)),
      const Spacer(),
      Text(_label(_section), style: Tok.label),
      const SizedBox(width: 6),
    ]),
  );

  Widget _navigation() => ColoredBox(
    color: const Color(0xFF080E20),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 20, 12, 16),
      child: ListView(children: [
        for (final section in SettingsSection.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Semantics(
              selected: section == _section,
              child: InkWell(
                key: ValueKey('settings-nav-${section.name}'),
                onTap: () => setState(() => _section = section),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  decoration: BoxDecoration(
                    color: section == _section ? const Color(0x1AD2A64E) : Colors.transparent,
                    border: Border.all(color: section == _section ? Tok.gold3 : Colors.transparent),
                  ),
                  child: Row(children: [
                    Icon(_icon(section), size: 17, color: section == _section ? Tok.ink : Tok.muted),
                    const SizedBox(width: 10),
                    Text(_label(section), style: Tok.body.copyWith(fontSize: 14, color: section == _section ? Tok.ink : Tok.muted)),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    ),
  );

  Widget _sectionBody() => switch (_section) {
    SettingsSection.folders => _folders(),
    SettingsSection.sources => _sources(),
    SettingsSection.playback => _playback(),
    SettingsSection.lookups => _lookups(),
    SettingsSection.files => _files(),
    SettingsSection.history => _history(),
    SettingsSection.devices => _pairedDevices(),
    SettingsSection.light => _light(),
  };

  Widget _folders() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _heading('Folders'),
    if (_front == null) const Text('Reading folders…', style: Tok.monoSmall)
    else if (_front!.roots.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('No folders yet', style: Tok.monoSmall))
    else for (final root in _front!.roots) _folder(root),
    const SizedBox(height: 22),
    Wrap(spacing: 16, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
      _button('Add a folder…', _changingFolders ? null : _addFolder, primary: true),
      if (_front != null) Text('${_count(_front!.tracks)} ${_front!.tracks == BigInt.one ? 'track' : 'tracks'} · ${_count(_front!.releases)} ${_front!.releases == BigInt.one ? 'release' : 'releases'}', style: Tok.monoSmall),
    ]),
  ]);

  Widget _folder(RootDto root) => Container(
    key: ValueKey('settings-root-${root.id}'),
    padding: const EdgeInsets.symmetric(vertical: 18),
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.rule))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 5, right: 10), child: _dot(root.online ? Tok.ok : Tok.warn)),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(root.label, style: Tok.body.copyWith(fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text(root.path, style: Tok.monoSmall.copyWith(color: Tok.ink)),
          const SizedBox(height: 6),
          Text(root.online ? 'Online' : 'Offline', style: Tok.body.copyWith(fontSize: 12, color: root.online ? Tok.ok : Tok.warn)),
        ])),
        const SizedBox(width: 12),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${_count(root.tracks)} tracks', style: Tok.monoSmall),
          const SizedBox(height: 8),
          _button('Remove…', _changingFolders ? null : () => setState(() => _confirmRemove = root)),
        ]),
      ]),
      if (_confirmRemove?.id == root.id) ...[
        const SizedBox(height: 14),
        const Text('Files stay on disk; re-adding this folder restores it.', style: Tok.body),
        const SizedBox(height: 10),
        Wrap(spacing: 8, children: [
          _button('Remove folder', _changingFolders ? null : () => _removeFolder(root), primary: true),
          _button('Cancel', _changingFolders ? null : () => setState(() => _confirmRemove = null)),
        ]),
      ],
    ]),
  );

  Widget _sources() {
    final local = _status?.sources.where((source) => source.key == 'local').firstOrNull;
    final entries = <(String, String, String, String)>[
      ('local', 'This Mac', _status == null ? 'Reading library…' : '${_count(_status!.tracks)} tracks', 'Your music folders'),
      ('musicbrainz', 'MusicBrainz', 'Not used yet', 'Recordings and credits'),
      ..._futureSources.map((source) => (source.$1, source.$2, 'Coming later', source.$3)),
    ];
    final selected = entries.firstWhere((entry) => entry.$1 == _source);
    final list = Column(children: [
      for (final entry in entries)
        InkWell(
          onTap: () => setState(() => _source = entry.$1),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: entry.$1 == _source ? const Color(0x1AD2A64E) : Colors.transparent,
              border: Border.all(color: entry.$1 == _source ? Tok.gold3 : Tok.line),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 5, right: 10), child: _dot(entry.$1 == 'local' ? (local?.ok == false ? Tok.warn : Tok.ok) : Tok.faint, hollow: entry.$1 != 'local')),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(entry.$2, style: Tok.body.copyWith(fontSize: 14)),
                const SizedBox(height: 3),
                Text(entry.$3, style: Tok.label.copyWith(letterSpacing: 0)),
              ])),
            ]),
          ),
        ),
    ]);
    final detail = Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: const Color(0xFF080E20), border: Border.all(color: Tok.rule)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(selected.$2, style: Tok.title.copyWith(fontSize: 21)),
        const SizedBox(height: 10),
        Text(selected.$3, style: Tok.monoSmall),
        const SizedBox(height: 22),
        Text(selected.$4, style: Tok.body.copyWith(color: Tok.muted)),
        if (selected.$1 == 'local') ...[
          const SizedBox(height: 22),
          _button('Manage folders', () => setState(() => _section = SettingsSection.folders)),
        ],
      ]),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _heading('Sources'),
      LayoutBuilder(builder: (context, constraints) => constraints.maxWidth >= 650
        ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 260, child: list), const SizedBox(width: 24), Expanded(child: detail)])
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [list, const SizedBox(height: 22), detail])),
    ]);
  }

  Widget _playback() {
    final settings = _settings;
    final deviceId = settings?.outputDevice;
    final devices = _devices ?? const <OutputDeviceDto>[];
    final knownDevice = devices.any((device) => device.id == deviceId);
    final selected = devices.where((device) => deviceId == null ? device.isDefault : device.id == deviceId).firstOrNull;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _heading('Playback'),
      if (settings == null) const Text('Reading playback settings…', style: Tok.monoSmall)
      else ...[
        _settingRow('Output device',
          _devices == null
            ? Text(_deviceError ?? 'Reading outputs…', style: Tok.monoSmall)
            : SizedBox(width: 240, child: DropdownButton<String>(
                key: const ValueKey('settings-output'),
                value: deviceId ?? '',
                isExpanded: true,
                dropdownColor: Tok.panel,
                style: Tok.body,
                items: [
                  const DropdownMenuItem(value: '', child: Text('System default')),
                  for (final device in devices) DropdownMenuItem(value: device.id, child: Text(device.name, overflow: TextOverflow.ellipsis)),
                  if (deviceId != null && !knownDevice) DropdownMenuItem(value: deviceId, child: const Text('Chosen output (away)')),
                ],
                onChanged: _saving ? null : (value) => _save(outputDevice: value == '' ? null : value, changeDevice: true),
              )),
          note: _devices != null && deviceId != null && !knownDevice ? 'Using the system default' : null),
        if (selected != null) Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text('${selected.maxBits} bit · ${selected.sampleRates.map((rate) => '${rate / 1000} kHz').join(', ')}', style: Tok.monoSmall),
        ),
        _settingRow('Exclusive mode',
          Switch(value: settings.exclusive && selected?.canBeExclusive != false, onChanged: _saving || selected?.canBeExclusive == false ? null : (value) => _save(exclusive: value)),
          note: selected?.canBeExclusive == false ? 'Not offered by this output' : null),
      ],
      const SizedBox(height: 12),
      _settingRow('Device volume', const Text('On the device', style: Tok.monoSmall)),
      _settingRow('Software volume', const Text('Not offered', style: Tok.label)),
      _settingRow('Gapless playback', const Text('Always on', style: Tok.monoSmall)),
      const SizedBox(height: 22),
      if (_now != null && _now!.path.isNotEmpty) ...[
        const Text('Signal path', style: Tok.label),
        const SizedBox(height: 12),
        for (final stage in _now!.path) Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('${stage.name} · ${stage.detail}', style: Tok.monoSmall),
        ),
      ],
    ]);
  }

  Widget _lookups() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _heading('Lookups'),
    _futureRow('MusicBrainz', 'Recordings and credits from your tags'),
    _futureRow('AcoustID', 'Fingerprints made on this Mac'),
  ]);

  Widget _files() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _heading('Files'),
    _futureRow('Write tags on save'),
    _futureRow('Undo every batch'),
    _futureRow('See moves first'),
  ]);

  Widget _history() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _heading('History'),
    _futureRow('Apple Music', 'Plays, ratings, playlists'),
    _futureRow('Last.fm', 'Every listen'),
    _futureRow('ListenBrainz', 'Every listen'),
  ]);

  Widget _pairedDevices() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _heading('Devices'),
    _futureRow('Pair a phone'),
  ]);

  Widget _light() {
    final accent = _now?.light == null ? Tok.gold : Color(_now!.light!.light);
    final wash = _now?.light == null ? const Color(0x14D2A64E) : Color(_now!.light!.wash);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _heading('Light'),
      if (_settings == null) const Text('Reading light settings…', style: Tok.monoSmall)
      else LayoutBuilder(builder: (context, constraints) => Wrap(spacing: 12, runSpacing: 12, children: [
        for (final (level, title, description) in const [
          (LightLevelDto.off, 'Off', 'Gold accent, no cover colour'),
          (LightLevelDto.accent, 'Accent', 'Cover colour on the body and transport'),
          (LightLevelDto.accentAndWash, 'Accent and wash', 'Plus a faint wash behind the music'),
        ]) SizedBox(
          width: constraints.maxWidth >= 550 ? (constraints.maxWidth - 24) / 3 : constraints.maxWidth,
          child: Semantics(
            selected: _settings!.light == level,
            button: true,
            child: InkWell(
              key: ValueKey('settings-light-${level.name}'),
              onTap: _saving ? null : () => _save(light: level),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Tok.sky, border: Border.all(color: _settings!.light == level ? Tok.gold2 : Tok.rule)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Container(
                    height: 146,
                    padding: const EdgeInsets.all(17),
                    decoration: BoxDecoration(color: level == LightLevelDto.accentAndWash ? Color.alphaBlend(wash, Tok.panel) : Tok.panel, border: Border.all(color: Tok.line)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      const Text('Now', style: Tok.label),
                      Center(child: Container(width: 54, height: 54, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: level == LightLevelDto.off ? Tok.gold : accent)))),
                      FractionallySizedBox(widthFactor: .74, child: Container(height: 3, color: level == LightLevelDto.off ? Tok.gold : accent)),
                    ]),
                  ),
                  const SizedBox(height: 14),
                  Text(title, style: Tok.body.copyWith(fontSize: 15, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 5),
                  Text(description, style: Tok.body.copyWith(fontSize: 12.5, color: Tok.muted)),
                  const SizedBox(height: 10),
                  Text(_settings!.light == level ? 'Selected' : ' ', style: Tok.label.copyWith(color: Tok.gold)),
                ]),
              ),
            ),
          ),
        ),
      ])),
      if (_now?.trackId != null) ...[
        const SizedBox(height: 22),
        const Text('Previewing', style: Tok.label),
        const SizedBox(height: 12),
        Text(_now!.title, style: Tok.body),
      ],
    ]);
  }
}

Widget _heading(String title) => Padding(
  padding: const EdgeInsets.only(bottom: 22),
  child: Text(title, style: Tok.title.copyWith(fontSize: 25)),
);

Widget _note(String text, {bool warning = false}) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
  decoration: BoxDecoration(color: const Color(0xFF070C1B), border: Border.all(color: warning ? Tok.warn : Tok.rule)),
  child: Text(text, style: Tok.body.copyWith(color: warning ? Tok.warn : Tok.muted)),
);

Widget _settingRow(String title, Widget control, {String? note}) => Container(
  padding: const EdgeInsets.symmetric(vertical: 14),
  decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tok.line))),
  child: LayoutBuilder(builder: (context, constraints) {
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: Tok.body.copyWith(fontSize: 15, fontWeight: FontWeight.w500)),
      if (note != null) ...[
        const SizedBox(height: 4),
        Text(note, style: Tok.body.copyWith(color: Tok.muted)),
      ],
    ]);
    return constraints.maxWidth < 550
      ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [text, const SizedBox(height: 10), control])
      : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: text), const SizedBox(width: 24), control]);
  }),
);

Widget _futureRow(String title, [String? note]) => _settingRow(title, const Text('Coming later', style: Tok.label), note: note);

Widget _button(String title, VoidCallback? onPressed, {bool primary = false}) => TextButton(
  onPressed: onPressed,
  style: TextButton.styleFrom(
    foregroundColor: primary ? Tok.sky : Tok.muted,
    disabledForegroundColor: Tok.faint,
    backgroundColor: primary ? Tok.gold : Colors.transparent,
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
    shape: const RoundedRectangleBorder(side: BorderSide(color: Tok.rule)),
    textStyle: Tok.body.copyWith(fontWeight: primary ? FontWeight.w600 : FontWeight.w400),
  ),
  child: Text(title),
);

Widget _dot(Color colour, {bool hollow = false}) => Container(
  width: 7,
  height: 7,
  decoration: BoxDecoration(shape: BoxShape.circle, color: hollow ? Colors.transparent : colour, border: hollow ? Border.all(color: colour) : null),
);

String _count(BigInt number) => number.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

String _label(SettingsSection section) => switch (section) {
  SettingsSection.folders => 'Folders',
  SettingsSection.sources => 'Sources',
  SettingsSection.playback => 'Playback',
  SettingsSection.lookups => 'Lookups',
  SettingsSection.files => 'Files',
  SettingsSection.history => 'History',
  SettingsSection.devices => 'Devices',
  SettingsSection.light => 'Light',
};

IconData _icon(SettingsSection section) => switch (section) {
  SettingsSection.folders => Icons.folder_outlined,
  SettingsSection.sources => Icons.hub_outlined,
  SettingsSection.playback => Icons.play_arrow_outlined,
  SettingsSection.lookups => Icons.manage_search_outlined,
  SettingsSection.files => Icons.description_outlined,
  SettingsSection.history => Icons.history,
  SettingsSection.devices => Icons.phone_iphone_outlined,
  SettingsSection.light => Icons.wb_sunny_outlined,
};

const _futureSources = [
  ('spotify', 'Spotify', 'Saved music, playlists and Connect'),
  ('music-assistant', 'Music Assistant', 'Players and providers on your server'),
  ('roon', 'Roon', 'Your Roon zones'),
  ('bandcamp', 'Bandcamp', 'Your Bandcamp collection'),
  ('youtube', 'YouTube', 'Music on YouTube'),
  ('qobuz', 'Qobuz', 'Your Qobuz collection'),
  ('listenbrainz', 'ListenBrainz', 'History and scrobbling'),
  ('last-fm', 'Last.fm', 'History and scrobbling'),
];

class _CloseSettings extends Intent {
  const _CloseSettings();
}
