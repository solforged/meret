import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../core/when.dart';
import '../theme/tokens.dart';

String _n(BigInt number) => number.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

enum DoorKind { today, pickUp, playSomething, query, trail, later }

/// One entry in Home: a door opens a pane, plays, or shows Today. Plumbing
/// never gets one (navigation.md, "Home").
class HomeDoor {
  const HomeDoor({required this.id, required this.glyph, required this.label, required this.kind, this.count, this.query, this.uid, this.amber = false, this.keys});
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
}

/// What Home shows, read from the core; shared by the column, the rail
/// and the surface's `⌘1`–`⌘9`.
class HomeDoors extends ChangeNotifier {
  FrontDto? _front;
  List<TrailSummaryDto> _trails = const [];
  int _partway = 0;
  String? error;
  (BigInt?, int)? _loadedFor;
  int _generation = 0;

  /// Read again when the library or the memory has moved on.
  Future<void> load(CoreBridge core, {required BigInt? libraryVersion, required int memoryVersion}) async {
    final versions = (libraryVersion, memoryVersion);
    if (versions == _loadedFor) return;
    _loadedFor = versions;
    final generation = ++_generation;
    try {
      final read = await Future.wait<Object>([core.front(), core.trailHistory(5), core.resumePoints(99)]);
      if (generation != _generation) return;
      _front = read[0] as FrontDto;
      _trails = read[1] as List<TrailSummaryDto>;
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
    final idioms = [...?front?.idioms.where((idiom) => idiom.releases > BigInt.zero && idiom.query != null)]
      ..sort((a, b) => b.tracks.compareTo(a.tracks));
    final needs = [...?front?.needsYou.where((need) => need.count > BigInt.zero)];
    var number = 0;
    String? next() => ++number <= 9 ? '⌘$number' : null;
    final listen = [
      HomeDoor(id: 'today', glyph: '◐', label: 'Today', kind: DoorKind.today, keys: next()),
      if (_partway > 0) HomeDoor(id: 'pick-up', glyph: '↺', label: 'Pick up', kind: DoorKind.pickUp, count: '$_partway', keys: next()),
      const HomeDoor(id: 'play-something', glyph: '✦', label: 'Play something', kind: DoorKind.playSomething, keys: '⇧␣'),
    ];
    final library = [
      if (front != null && front.tracks > BigInt.zero)
        HomeDoor(id: 'all', glyph: '≡', label: 'All tracks', kind: DoorKind.query, query: '', count: _n(front.tracks), keys: next()),
      for (final idiom in idioms)
        HomeDoor(id: 'idiom-${idiom.query}', glyph: _idiomGlyph(idiom.query), label: idiom.label, kind: DoorKind.query,
          query: idiom.query, count: _n(idiom.releases), keys: next()),
    ];
    final now = DateTime.now();
    return [
      ('Listen', listen),
      ('Library', library),
      ('Crates', const [HomeDoor(id: 'crates', glyph: '▤', label: 'Crates', kind: DoorKind.later)]),
      ('Trails', [
        for (final trail in _trails)
          HomeDoor(id: 'trail-${trail.uid}', glyph: trail.kept ? '◆' : '⑂', label: trail.name ?? trail.title, kind: DoorKind.trail, uid: trail.uid,
            count: dayWord(trail.whenMs.toInt(), now: now) == 'today' ? clockTime(trail.whenMs.toInt()) : dayWord(trail.whenMs.toInt(), now: now)),
      ]),
      ('Out there', [
        const HomeDoor(id: 'leads', glyph: '☆', label: 'Leads', kind: DoorKind.later),
        const HomeDoor(id: 'wants', glyph: '♡', label: 'Wants', kind: DoorKind.later),
        for (final (i, need) in needs.indexed)
          HomeDoor(id: 'need-$i', glyph: '≈', label: need.label, kind: need.query == null ? DoorKind.later : DoorKind.query,
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
/// over a trail, or the 52 pt rail of their glyphs inside one, with the door
/// the trail started from lit.
class Home extends StatelessWidget {
  const Home({
    super.key, required this.doors, required this.open, required this.onDoor, this.onOpen,
    this.litQuery, this.todayLit = false,
  });

  final HomeDoors doors;

  /// The column; otherwise the rail.
  final bool open;
  final ValueChanged<HomeDoor> onDoor;

  /// The rail's ◐: lays the column over the trail.
  final VoidCallback? onOpen;

  /// The open trail's root query, whose door stays lit.
  final String? litQuery;
  final bool todayLit;

  static const column = 248.0;
  static const rail = 52.0;

  bool _lit(HomeDoor door) => door.kind == DoorKind.today ? todayLit : door.query != null && door.query == litQuery;

  Widget _column(List<(String, List<HomeDoor>)> sections) => SizedBox(
    width: column,
    child: ListView(
      key: const ValueKey('home-column'),
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 20),
      children: [
        for (final (title, entries) in sections) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
            child: Text(title.toUpperCase(), style: Tok.label.copyWith(fontSize: 9.5, color: Tok.dim)),
          ),
          for (final door in entries) _Row(door: door, lit: _lit(door), onTap: door.kind == DoorKind.later ? null : () => onDoor(door)),
          if (title == 'Trails' && entries.isEmpty)
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
    final needs = sections.last.$2.where((door) => door.amber);
    return SizedBox(
      width: rail,
      child: ListView(key: const ValueKey('home-rail'), padding: const EdgeInsets.symmetric(vertical: 10), children: [
        for (final door in listen)
          _Glyph(door: door, lit: _lit(door), onTap: door.kind == DoorKind.today ? onOpen : () => onDoor(door)),
        const Divider(height: 14, indent: 14, endIndent: 14, color: Tok.line),
        for (final door in library) _Glyph(door: door, lit: _lit(door), onTap: () => onDoor(door)),
        const Divider(height: 14, indent: 14, endIndent: 14, color: Tok.line),
        _Glyph(door: const HomeDoor(id: 'trails', glyph: '⑂', label: 'Trails', kind: DoorKind.trail), onTap: onOpen),
        if (needs.isNotEmpty)
          _Glyph(door: HomeDoor(id: 'needs', glyph: '≈', label: 'Needs you', kind: DoorKind.later, amber: true,
            count: _n(needs.fold(BigInt.zero, (sum, door) => sum + BigInt.parse(door.count!.replaceAll(',', ''))))), onTap: onOpen),
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

class _Row extends StatelessWidget {
  const _Row({required this.door, required this.lit, this.onTap});
  final HomeDoor door;
  final bool lit;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final later = door.kind == DoorKind.later && !door.amber;
    final colour = later ? Tok.dim : door.amber ? Tok.warn : lit ? Tok.ink : Tok.muted;
    final row = InkWell(
      key: ValueKey('home-${door.id}'),
      onTap: onTap,
      canRequestFocus: false,
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: lit ? Tok.panel2 : null,
          border: Border(left: BorderSide(color: lit ? Tok.gold : Colors.transparent, width: 2)),
        ),
        child: Row(children: [
          SizedBox(width: 18, child: Text(door.glyph, style: Tok.body.copyWith(fontSize: 12.5, color: lit ? Tok.gold : door.amber ? Tok.warn : Tok.faint))),
          const SizedBox(width: 6),
          Expanded(child: Text(door.label, style: Tok.body.copyWith(fontSize: 13, color: colour), maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (door.count != null || door.keys != null) const SizedBox(width: 8),
          if (door.count != null)
            Text(door.count!, style: Tok.label.copyWith(color: door.amber ? Tok.warn : Tok.faint))
          else if (door.keys != null)
            Text(door.keys!, style: Tok.label.copyWith(color: Tok.dim)),
        ]),
      ),
    );
    return later ? Tooltip(message: 'Coming later', child: row) : row;
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
    waitDuration: const Duration(milliseconds: 300),
    child: InkWell(
      key: ValueKey('rail-${door.id}'),
      onTap: onTap,
      canRequestFocus: false,
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
