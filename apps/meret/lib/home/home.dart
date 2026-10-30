import 'dart:async';

import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../core/when.dart';
import '../theme/action_target.dart';
import '../theme/tokens.dart';
import 'trail_browser.dart';

String _n(BigInt number) => number.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

String _count(BigInt number, String noun) => '${_n(number)} ${number == BigInt.one ? noun : '${noun}s'}';

enum DoorKind { today, pickUp, history, playSomething, query, trail, allTrails, keptTrails, missing, later }

/// One entry in Home: a door opens a pane, plays, or shows Today. Plumbing
/// never gets one (navigation.md, "Home").
class HomeDoor {
  const HomeDoor({required this.id, required this.glyph, required this.label, required this.kind, this.count, this.query, this.uid, this.amber = false, this.keys, this.detail, this.subtitle, this.when, this.unavailable});
  final String id;
  final String glyph;
  final String label;
  final DoorKind kind;
  final String? count;

  /// The search the door roots a trail at; '' is the whole table.
  final String? query;

  /// The trail a Trails door reopens.
  final String? uid;
  final bool amber;

  /// The key beside the label: `⌘3`, `⇧␣`.
  final String? keys;
  final String? detail;
  final String? subtitle;

  /// When a trail was last visited, at the end of its second line.
  final String? when;

  /// Why the door can't be used now; it dims and does nothing, and says so on hover.
  final String? unavailable;
}

/// What Home shows, read from the core; shared by the column, the rail
/// and the surface's `⌘1`–`⌘9`.
class HomeDoors extends ChangeNotifier {
  FrontDto? _front;
  List<TrailSummaryDto> _trails = const [];
  int _kept = 0;
  int _partway = 0;

  String? error;
  (BigInt?, int)? _loadedFor;
  int _generation = 0;
  NothingToPlayDto? _nothingToPlay;

  /// Play something found nothing; the door says why instead of doing nothing.
  NothingToPlayDto? get nothingToPlay => _nothingToPlay;
  set nothingToPlay(NothingToPlayDto? value) {
    if (value == _nothingToPlay) return;
    _nothingToPlay = value;
    // Set from a build, so listeners hear after it.
    scheduleMicrotask(notifyListeners);
  }

  /// The trails the sidebar lists.
  static const recentTrails = 5;

  /// Read again when the library or the memory has moved on.
  Future<void> load(CoreBridge core, {required BigInt? libraryVersion, required int memoryVersion}) async {
    final versions = (libraryVersion, memoryVersion);
    if (versions == _loadedFor) return;
    _loadedFor = versions;
    final generation = ++_generation;
    try {
      final read = await Future.wait<Object>([core.front(), core.trailHistory(0xffffffff), core.resumePoints(99)]);
      if (generation != _generation) return;
      _front = read[0] as FrontDto;
      final trails = read[1] as List<TrailSummaryDto>;
      _trails = trails.take(recentTrails).toList();
      _kept = trails.where((trail) => trail.kept).length;
      _partway = (read[2] as List<ResumeDto>).length;
      error = null;
    } catch (e) {
      if (generation != _generation) return;
      error = e.toString();
    }
    notifyListeners();
  }

  static String _idiomGlyph(String? query) => switch (query) {
    'idiom:album' => '◉',
    'idiom:score' => '◈',
    'idiom:session' => '◎',
    'idiom:song' => '♪',
    'idiom:work' => '❦',
    'idiom:set' => '⁂',
    'idiom:spoken' => '❝',
    _ => '◇',
  };

  /// The fixed sections, in their fixed order; a door hides at zero.
  List<(String, List<HomeDoor>)> get sections {
    final front = _front;
    // An idiom's door counts its tracks, the same unit as All tracks and as
    // the page the door opens; it shows whenever the library has any.
    final idioms = [...?front?.idioms.where((idiom) => idiom.tracks > BigInt.zero && idiom.query != null)]
      ..sort((a, b) => b.tracks.compareTo(a.tracks));
    final needs = [...?front?.needsYou.where((need) => need.count > BigInt.zero)];
    var number = 0;
    String? next() => ++number <= 9 ? '⌘$number' : null;
    final listen = [
      HomeDoor(id: 'today', glyph: '◐', label: 'Today', kind: DoorKind.today, keys: next()),
      if (_partway > 0)
        HomeDoor(id: 'pick-up', glyph: '↺', label: 'Pick up', kind: DoorKind.pickUp, count: _count(BigInt.from(_partway), 'release'), keys: next()),
      const HomeDoor(id: 'history', glyph: '◷', label: 'History', kind: DoorKind.history, keys: 'H'),
      HomeDoor(id: 'play-something', glyph: '✦', label: 'Play something', kind: DoorKind.playSomething,
        keys: _nothingToPlay == null ? '⇧␣' : null, unavailable: _nothingToPlay?.label),
    ];
    final library = [
      if (front != null && front.tracks > BigInt.zero)
        HomeDoor(id: 'all', glyph: '≡', label: 'All tracks', kind: DoorKind.query, query: '', count: _count(front.tracks, 'track'), keys: next()),
      for (final idiom in idioms)
        HomeDoor(id: 'idiom-${idiom.query}', glyph: _idiomGlyph(idiom.query), label: idiom.label, kind: DoorKind.query,
          query: idiom.query, count: _count(idiom.tracks, 'track'), keys: next()),
    ];
    final now = DateTime.now();
    return [
      ('Listen', listen),
      ('Library', library),
      ('Trails', [
        for (final trail in _trails)
          HomeDoor(id: 'trail-${trail.uid}', glyph: trail.kept ? '◆' : '⑂', label: trail.name ?? trail.title, kind: DoorKind.trail, uid: trail.uid,
            detail: [if (trail.name != null) trail.title, trailSummaryContext(trail)].join('\n'),
            subtitle: trail.title.contains(' → ') ? '→ ${trail.title.split(' → ').last}' : _count(BigInt.from(trail.stops), 'stop'),
            when: dayAndTime(trail.whenMs.toInt(), now: now)),
        if (_kept > 0) HomeDoor(id: 'kept-trails', glyph: '◆', label: 'Kept trails', kind: DoorKind.keptTrails, count: '$_kept'),
        const HomeDoor(id: 'all-trails', glyph: '≡', label: 'All trails', kind: DoorKind.allTrails),
      ]),
      ('Out there', [
        for (final (i, need) in needs.indexed)
          HomeDoor(id: 'need-$i', glyph: '≈', label: need.label,
            kind: need.missingFiles ? DoorKind.missing : need.query == null ? DoorKind.later : DoorKind.query,
            query: need.query, count: _n(need.count), amber: true),
      ]),
    ];
  }

  /// `⌘1`–`⌘9`: Today, Pick up, then the Library rows.
  List<HomeDoor> get numbered => [
    for (final (_, doors) in sections)
      for (final door in doors)
        if (door.keys?.startsWith('⌘') ?? false) door,
  ];
}

/// Home (plates 01 and 06): the 248 pt column of doors beside Today or laid
/// over a trail, or the 52 pt rail of their glyphs inside one, with the open
/// trail's row lit, or failing that the door it started from.
class Home extends StatelessWidget {
  const Home({
    super.key, required this.doors, required this.open, required this.onDoor, this.onOpen,
    this.litQuery, this.currentTrail, this.todayLit = false,
  });

  final HomeDoors doors;

  /// The column; otherwise the rail.
  final bool open;
  final ValueChanged<HomeDoor> onDoor;

  /// The rail's ◐: lays the column over the trail.
  final VoidCallback? onOpen;

  /// The open trail's root query, whose door stays lit while its own row isn't listed.
  final String? litQuery;

  /// The open trail's uid, whose row is lit.
  final String? currentTrail;
  final bool todayLit;

  static const column = 248.0;
  static const rail = 52.0;

  /// Under this width the column gives way to the rail, so the page keeps its room.
  static const railBelow = 720.0;

  /// The rail has no trail rows, so there the door a trail started from is the lit one.
  bool _lit(HomeDoor door, {bool rail = false}) {
    if (door.kind == DoorKind.today) return todayLit;
    if (door.kind == DoorKind.trail) return door.uid != null && door.uid == currentTrail;
    if (door.query == null || door.query != litQuery) return false;
    return rail || !doors.sections.any((section) => section.$2.any((entry) => entry.kind == DoorKind.trail && entry.uid == currentTrail));
  }

  Widget _column(List<(String, List<HomeDoor>)> sections) => SizedBox(
    width: column,
    child: ListView(
      key: const ValueKey('home-column'),
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 20),
      children: [
        // Crates, Leads and Wants get doors when they open onto something.
        for (final (title, entries) in sections) if (entries.isNotEmpty || title == 'Trails') ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
            child: Text(title.toUpperCase(), style: Tok.label.copyWith(fontSize: 9.5, color: Tok.dim)),
          ),
          for (final door in entries)
            _Row(door: door, lit: _lit(door), onTap: door.kind == DoorKind.later || door.unavailable != null ? null : () => onDoor(door)),
          if (title == 'Trails' && entries.every((door) => door.kind == DoorKind.allTrails))
            const Padding(padding: EdgeInsets.fromLTRB(10, 3, 10, 3), child: Text('No trails yet', style: Tok.label)),
        ],
      ],
    ),
  );

  /// One glyph per Listen and Library door, then one for Trails and, while
  /// it isn't zero, Needs you; both of those open the column.
  Widget _rail(List<(String, List<HomeDoor>)> sections) {
    final listen = sections.first.$2.where((door) => door.kind != DoorKind.playSomething);
    final library = sections[1].$2;
    final needs = sections.last.$2.where((door) => door.amber).toList();
    return SizedBox(
      width: rail,
      child: ListView(key: const ValueKey('home-rail'), padding: const EdgeInsets.symmetric(vertical: 10), children: [
        for (final door in listen)
          _Glyph(door: door, lit: _lit(door, rail: true), onTap: door.kind == DoorKind.today ? onOpen : () => onDoor(door)),
        const Divider(height: 14, indent: 14, endIndent: 14, color: Tok.line),
        for (final door in library) _Glyph(door: door, lit: _lit(door, rail: true), onTap: () => onDoor(door)),
        const Divider(height: 14, indent: 14, endIndent: 14, color: Tok.line),
        _Glyph(door: const HomeDoor(id: 'trails', glyph: '⑂', label: 'Trails', kind: DoorKind.trail), onTap: onOpen),
        if (needs.isNotEmpty)
          _Glyph(door: HomeDoor(id: 'needs', glyph: '≈', label: 'Needs you', kind: DoorKind.later, amber: true,
            count: _n(needs.fold(BigInt.zero, (sum, door) => sum + BigInt.parse(door.count!.replaceAll(',', ''))))),
            // One need is one door: go to it; several open the column to choose.
            onTap: needs.length == 1 && needs.single.kind != DoorKind.later ? () => onDoor(needs.single) : onOpen),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: doors,
    builder: (context, _) {
      final sections = doors.sections;
      return Container(
        decoration: const BoxDecoration(color: Color(0xFF050917), border: Border(right: BorderSide(color: Tok.line))),
        // The column is drawn at its own width and clipped, so it slides over the rail.
        child: ClipRect(child: OverflowBox(
          alignment: Alignment.topLeft, minWidth: 0, maxWidth: open ? column : rail,
          child: open ? _column(sections) : _rail(sections),
        )),
      );
    },
  );
}

class _Row extends StatefulWidget {
  const _Row({required this.door, required this.lit, this.onTap});
  final HomeDoor door;
  final bool lit;
  final VoidCallback? onTap;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  final _tooltip = GlobalKey<TooltipState>();
  bool _focused = false;
  Timer? _dismiss;
  HomeDoor get door => widget.door;
  bool get lit => widget.lit;

  /// How long a focus tooltip stays up with focus still on its row.
  static const _linger = Duration(seconds: 4);

  /// The widest a count may grow before the label has none left.
  static const _countWidth = 104.0;

  @override
  void dispose() {
    _dismiss?.cancel();
    super.dispose();
  }

  /// Keyboard focus shows the row's tooltip. The row focus leaves is told in
  /// the same pass as the one focus arrives at, and its dismissal would take
  /// the new tooltip with it, so the new one waits for the pass to end.
  void _focusChanged(bool focused) {
    _focused = focused;
    _dismiss?.cancel();
    if (!focused) {
      Tooltip.dismissAllToolTips();
      return;
    }
    if (FocusManager.instance.highlightMode != FocusHighlightMode.traditional) return;
    scheduleMicrotask(() {
      if (!mounted || !_focused) return;
      _tooltip.currentState?.ensureTooltipVisible();
      _dismiss = Timer(_linger, () {
        if (mounted && _focused) Tooltip.dismissAllToolTips();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final later = (door.kind == DoorKind.later && !door.amber) || door.unavailable != null;
    final colour = later ? Tok.dim : door.amber ? Tok.warn : lit ? Tok.ink : Tok.muted;
    final row = ActionTarget(
      key: ValueKey('home-${door.id}'),
      onTap: widget.onTap,
      semanticLabel: [door.label, ?door.detail, if (door.detail == null) ?door.count].join(' · '),
      selected: lit,
      excludeChildSemantics: true,
      child: Container(
        height: door.subtitle == null ? 26 : 42,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: lit ? Tok.panel2 : null,
          border: Border(left: BorderSide(color: lit ? Tok.gold : Colors.transparent, width: 2)),
        ),
        child: Row(children: [
          SizedBox(width: 18, child: Text(door.glyph, style: Tok.body.copyWith(fontSize: 12.5, color: lit ? Tok.gold : door.amber ? Tok.warn : Tok.faint))),
          const SizedBox(width: 6),
          Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(door.label, style: Tok.body.copyWith(fontSize: 13, color: colour), maxLines: 1, overflow: TextOverflow.ellipsis),
            if (door.subtitle != null) Row(children: [
              Expanded(child: Text(door.subtitle!, style: Tok.label.copyWith(fontSize: 10, color: Tok.faint), maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (door.when != null) ...[
                const SizedBox(width: 6),
                Text(door.when!, style: Tok.label.copyWith(fontSize: 10, color: Tok.faint), maxLines: 1),
              ],
            ]),
          ])),
          if (door.count != null) ...[
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _countWidth),
              child: Text(door.count!, style: Tok.label.copyWith(color: door.amber ? Tok.warn : Tok.faint), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
          if (door.keys != null) ...[
            const SizedBox(width: 8),
            Text(door.keys!, style: Tok.label.copyWith(color: Tok.dim)),
          ],
        ]),
      ),
    );
    return Focus(canRequestFocus: false, onFocusChange: _focusChanged, child: Tooltip(key: _tooltip,
      message: door.unavailable != null ? '${door.label} · ${door.unavailable}'
        : later ? '${door.label} · Coming later'
        : [door.label, ?door.detail, if (door.detail == null) ?door.count, ?door.keys].join('\n'),
      excludeFromSemantics: true, child: row));
  }
}

class _Glyph extends StatelessWidget {
  const _Glyph({required this.door, this.lit = false, this.onTap});
  final HomeDoor door;
  final bool lit;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: [door.label, ?door.count, ?door.keys].join(' · '),
    excludeFromSemantics: true,
    waitDuration: const Duration(milliseconds: 300),
    child: ActionTarget(
      key: ValueKey('rail-${door.id}'),
      onTap: onTap,
      semanticLabel: [door.label, ?door.count].join(' · '),
      selected: lit,
      excludeChildSemantics: true,
      child: Container(
        height: 34,
        decoration: BoxDecoration(
          color: lit ? Tok.panel2 : null,
          border: Border(left: BorderSide(color: lit ? Tok.gold : Colors.transparent, width: 2)),
        ),
        child: Center(child: Text(door.glyph, style: Tok.body.copyWith(fontSize: 15, height: 1, color: lit ? Tok.gold : door.amber ? Tok.warn : Tok.faint))),
      ),
    ),
  );
}
