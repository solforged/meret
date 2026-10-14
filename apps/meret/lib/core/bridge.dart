import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64, PlatformInt64Util;

import '../src/rust/api/core.dart' as rust;
import '../src/rust/api/types.dart';

export '../src/rust/api/types.dart';

/// Everything the UI asks of the core. The Rust implementation is the real
/// one; the fake one lets widget tests and design work run without the
/// native library.
///
/// Nothing here is called per frame. Now and the status line are streams;
/// the playhead is an anchor that `PlayheadClock` extrapolates.
abstract interface class CoreBridge {
  Stream<NowDto> now();
  Stream<StatusDto> status();
  Future<TrailDto?> trail();
  Future<FrontDto> front();
  Future<SearchDto> search(String input);
  Future<ReleaseDto> release(PlatformInt64 id);
  Future<PersonDto> person(PlatformInt64 id);
  Future<void> playRelease({required PlatformInt64 id, required int index, int? fromStop});
  Future<TrailDto> startTrail(TargetDto to);
  Future<TrailDto> follow(int fromStop, TargetDto to, ThreadKind via);
  Future<TrailDto?> trailBack();
  Future<TrailDto?> trailForward();
  Future<TrailDto> trailGo(int stop);
  Future<void> runCommand(String input);
  QueryDto parse(String input);
  Future<HistogramDto> histogram(ColumnDto column, String query, double lo, double hi, int bins);
  Future<void> transport(TransportDto cmd);
  Future<int> addRoot(String path);
  Future<RowsDto> rows(String query, int offset, int limit);
  Future<void> playResults(String query, int index);
}

class RustCore implements CoreBridge {
  @override
  Stream<NowDto> now() => rust.watchNow();
  @override
  Stream<StatusDto> status() => rust.watchStatus();
  @override
  Future<TrailDto?> trail() => rust.trail();
  @override
  Future<FrontDto> front() => rust.front();
  @override
  Future<SearchDto> search(String input) => rust.search(input: input);
  @override
  Future<ReleaseDto> release(PlatformInt64 id) => rust.release(id: id);
  @override
  Future<PersonDto> person(PlatformInt64 id) => rust.person(id: id);
  @override
  Future<void> playRelease({required PlatformInt64 id, required int index, int? fromStop}) =>
      rust.playRelease(id: id, index: index, fromStop: fromStop);
  @override
  Future<TrailDto> startTrail(TargetDto to) => rust.startTrail(to: to);
  @override
  Future<TrailDto> follow(int fromStop, TargetDto to, ThreadKind via) => rust.follow(fromStop: fromStop, to: to, via: via);
  @override
  Future<TrailDto?> trailBack() => rust.trailBack();
  @override
  Future<TrailDto?> trailForward() => rust.trailForward();
  @override
  Future<TrailDto> trailGo(int stop) => rust.trailGo(stop: stop);
  @override
  Future<void> runCommand(String input) => rust.runCommand(input: input);
  @override
  QueryDto parse(String input) => rust.parseQuery(input: input);
  @override
  Future<HistogramDto> histogram(ColumnDto column, String query, double lo, double hi, int bins) =>
      rust.histogram(column: column, query: query, lo: lo, hi: hi, bins: bins);
  @override
  Future<void> transport(TransportDto cmd) => rust.transport(cmd: cmd);
  @override
  Future<int> addRoot(String path) async => (await rust.addRoot(path: path)).toInt();
  @override
  Future<RowsDto> rows(String query, int offset, int limit) =>
      rust.rows(query: query, offset: BigInt.from(offset), limit: limit);
  @override
  Future<void> playResults(String query, int index) =>
      rust.playResults(query: query, index: BigInt.from(index));
}

/// The plates' Tuesday evening, as data.
class FakeCore implements CoreBridge {
  FakeCore();

  FakeCore.empty() : _empty = true {
    _state = const NowDto(title: '', subtitle: '', path: []);
  }

  bool _empty = false;
  String _root = '/Music';
  BigInt _libraryVersion = BigInt.one;
  TrailDto? _trail;
  final _forward = <int, int>{};
  final _results = <String, List<int>>{};
  late final _sampleRows = List.generate(_releases.length * 12 * 7, _row);
  final _statuses = StreamController<StatusDto>.broadcast();
  final _now = StreamController<NowDto>.broadcast();
  NowDto _state = NowDto(
    title: 'Small Two of Pieces ~Broken Pieces~',
    subtitle: 'Joanne Hogg · Xenogears, disc 2 · ending',
    anchor: AnchorDto(item: BigInt.one, positionMs: 226000, rate: 1),
    lengthMs: BigInt.from(391000),
    path: const [
      StageDto(name: 'File', detail: 'FLAC 16/44.1', alters: false),
      StageDto(name: 'Decode', detail: 'no DSP', alters: false),
      StageDto(name: 'Out', detail: 'RME ADI-2 · 44.1', alters: false),
    ],
    fidelity: FidelityDto.bitPerfect,
  );

  @override
  Stream<NowDto> now() async* {
    yield _state;
    yield* _now.stream;
  }

  @override
  Stream<StatusDto> status() async* {
    yield _status;
    yield* _statuses.stream;
  }

  StatusDto get _status => StatusDto(
        sources: _empty ? const [SourceDto(name: 'This Mac', detail: '0', ok: true)] : const [
          SourceDto(name: 'This Mac', detail: '48,210', ok: true),
          SourceDto(name: 'Music Assistant', detail: '6 providers', ok: true),
          SourceDto(name: 'Spotify', detail: 'Connect', ok: true),
          SourceDto(name: 'Roon', detail: '1 of 2 zones', ok: false),
        ],
        jobs: _empty ? [] : [JobDto(verb: 'analysing', done: BigInt.from(1204), total: BigInt.from(3880))],
        guessed: _empty ? BigInt.zero : BigInt.from(312),
        newLeads: _empty ? BigInt.zero : BigInt.from(14),
        tracks: BigInt.from(_total),
        libraryVersion: _libraryVersion,
      );

  int get _total => _empty ? 0 : 48210;

  @override
  Future<FrontDto> front() async {
    if (_empty) {
      return FrontDto(tracks: BigInt.zero, releases: BigInt.zero, idioms: const [], formats: const [], addedLately: const [], needsYou: const [], roots: const []);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    return FrontDto(
      tracks: BigInt.from(48210),
      releases: BigInt.from(8142),
      idioms: [
        for (final (label, releases, tracks, idiom) in const [
          ('Albums', 2104, 25210, 'album'),
          ('Songs', 3880, 3880, 'song'),
          ('Works', 1204, 9310, 'work'),
          ('Sessions', 412, 4110, 'session'),
          ('Scores', 212, 1840, 'score'),
          ('Sets', 318, 2420, 'set'),
          ('Spoken', 12, 1440, 'spoken'),
        ])
          IdiomLineDto(label: label, releases: BigInt.from(releases), tracks: BigInt.from(tracks), query: 'idiom:$idiom'),
      ],
      formats: [
        for (final (label, count, note, query) in const [
          ('FLAC 16/44.1', 31020, '', 'format:flac -format:hires'),
          ('Lossy', 8128, 'MP3, AAC, Ogg', 'format:lossy'),
          ('Hi-res, 24 bit', 6812, '', 'format:hires'),
          ('Native chiptune', 1840, 'SPC, NSF, VGM', 'format:chiptune'),
          ('DSD', 410, '', 'format:dsd'),
        ])
          FrontLineDto(label: label, count: BigInt.from(count), note: note, query: query),
      ],
      addedLately: [
        for (final id in [6, 4, 3])
          RecentDto(releaseId: PlatformInt64Util.from(id), title: _releases[id - 1].$1,
            artist: _releases[id - 1].$2, year: _releases[id - 1].$3,
            tracks: _releaseIndices(PlatformInt64Util.from(id)).length,
            addedMs: PlatformInt64Util.from(now - id * 86400000), query: 'release:${_quote(_releases[id - 1].$1)}'),
      ],
      needsYou: [
        FrontLineDto(label: 'Tracks with a guessed identity', count: BigInt.from(312), note: 'Mostly game rips; 41 could go to MusicBrainz with your tags and VGMdb’s list'),
        FrontLineDto(label: 'Albums with two editions', count: BigInt.from(18), note: 'Pick which one plays by default'),
      ],
      roots: [RootDto(id: PlatformInt64Util.from(1), path: _root, online: true)],
    );
  }

  @override
  Future<void> runCommand(String input) async {
    final command = input.trim();
    final verb = command.split(RegExp(r'\s+')).first.toLowerCase();
    if (verb == 'play') {
      await playResults(command.substring(4).trim(), 0);
      return;
    }
    throw "$verb isn't built yet";
  }

  @override
  Future<TrailDto?> trail() async => _trail;

  @override
  QueryDto parse(String input) {
    try {
      final tokens = _tokens(input);
      final canonical = tokens.join(' ');
      final verb = tokens.isEmpty ? '' : tokens.first.toLowerCase();
      final command = const ['play', 'queue', 'want', 'crate'].contains(verb);
      _clauses(command ? tokens.skip(1).join(' ') : canonical);
      return QueryDto(kind: command ? QueryKind.command : QueryKind.search, canonical: canonical);
    } catch (error) {
      return QueryDto(kind: QueryKind.invalid, canonical: input.trim(), error: error.toString());
    }
  }

  @override
  Future<SearchDto> search(String input) async {
    final parsed = parse(input);
    if (parsed.kind != QueryKind.search) throw parsed.error ?? 'Type a search, not a command';
    final clauses = _clauses(parsed.canonical);
    final indices = _matching(parsed.canonical);
    final words = clauses.where((c) => c.$1.isEmpty && !c.$3).map((c) => _fold(c.$2)).toList();
    final personWords = [...words, ...clauses.where((c) => c.$1 == 'by' && !c.$3).map((c) => _fold(c.$2))];
    final releaseWords = [...words, ...clauses.where((c) => c.$1 == 'release' && !c.$3).map((c) => _fold(c.$2))];
    final people = <String, (int, int)>{};
    final releases = <String, (int, int, TrackRowDto)>{};
    final tracks = <HitDto>[];
    final counts = List.filled(_sampleRows.length, 0);
    for (final index in indices) {
      counts[index % counts.length]++;
    }
    for (var index = 0; index < counts.length; index++) {
      final count = counts[index];
      if (count == 0) continue;
      final row = _sampleRows[index];
      for (final name in {row.artist, row.albumArtist}.whereType<String>()) {
        final old = people[name];
        final id = name == row.artist ? row.artistId! : row.albumArtistId!;
        people[name] = (id.toInt(), (old?.$2 ?? 0) + count);
      }
      final old = releases[row.album];
      releases[row.album] = (row.releaseId.toInt(), (old?.$2 ?? 0) + count, row);
    }
    final titles = [for (final row in _sampleRows) words.every((word) => _contains(row.title, word))];
    final trackTotal = [for (var i = 0; i < titles.length; i++) if (titles[i]) counts[i]].fold(0, (a, b) => a + b);
    for (var i = 0; i < indices.length && tracks.length < 8; i++) {
      final index = indices[i];
      final row = _sampleRows[index % _sampleRows.length];
      if (titles[index % titles.length]) {
        tracks.add(HitDto(kind: HitKind.track, id: PlatformInt64Util.from(index + 1), title: row.title,
          detail: '${row.artist} · ${row.album}', query: parsed.canonical, index: BigInt.from(i)));
      }
    }
    final personNames = people.keys.where((name) => personWords.isNotEmpty && personWords.every((word) => _contains(name, word))).toList()
      ..sort((a, b) => _rank(a, personWords).compareTo(_rank(b, personWords)));
    final releaseNames = releases.keys.where((name) => releaseWords.isNotEmpty && releaseWords.every((word) => _contains(name, word))).toList()
      ..sort((a, b) => _rank(a, releaseWords).compareTo(_rank(b, releaseWords)));
    return SearchDto(
      query: parsed.canonical,
      tracks: BigInt.from(indices.length),
      people: [for (final name in personNames.take(5))
        HitDto(kind: HitKind.person, id: PlatformInt64Util.from(people[name]!.$1), title: name,
          detail: '${people[name]!.$2} tracks', query: 'by:${_quote(name)}')],
      peopleTotal: BigInt.from(personNames.length),
      releases: [for (final name in releaseNames.take(5))
        HitDto(kind: HitKind.release, id: PlatformInt64Util.from(releases[name]!.$1), title: name,
          detail: '${releases[name]!.$3.albumArtist} · ${releases[name]!.$3.year} · ${releases[name]!.$2} tracks', query: 'release:${_quote(name)}')],
      releasesTotal: BigInt.from(releaseNames.length),
      trackHits: tracks,
      trackHitsTotal: BigInt.from(trackTotal),
    );
  }

  @override
  Future<TrailDto> startTrail(TargetDto to) async {
    final target = switch (to) {
      TargetDto_Search(:final query) => TargetDto.search(query: _searchQuery(query)),
      _ => to,
    };
    final title = await _title(target);
    _forward.clear();
    return _trail = TrailDto(
      rootQuery: target is TargetDto_Search ? target.query : null,
      current: 0,
      stops: [StopDto(index: 0, target: target, title: title, onPath: true, isFork: false, isPeek: false)],
      meetings: const [],
    );
  }

  String _searchQuery(String query) {
    final parsed = parse(query);
    if (parsed.kind != QueryKind.search) throw parsed.error ?? 'Type a search, not a command';
    return parsed.canonical;
  }

  Future<String> _title(TargetDto target) async => switch (target) {
    TargetDto_Search(:final query) => query.isEmpty ? 'Everything' : query,
    TargetDto_Release(:final id) => (await release(id)).title,
    TargetDto_Person(:final id) => (await person(id)).name,
  };

  @override
  Future<TrailDto> follow(int fromStop, TargetDto to, ThreadKind via) async {
    final trail = _trail;
    if (trail == null) throw 'No trail is open';
    if (to is TargetDto_Search) throw 'A search starts a new trail';
    if (!const [ThreadKind.by, ThreadKind.albumArtist, ThreadKind.appearsOn, ThreadKind.workedWith, ThreadKind.matched].contains(via)) {
      throw 'This thread is not followable yet';
    }
    if (!trail.stops.any((stop) => stop.index == fromStop)) throw 'Unknown trail stop';
    final title = await _title(to);
    final existing = trail.stops.where((stop) => stop.parent == fromStop && stop.target == to);
    if (existing.isNotEmpty) {
      _forward[fromStop] = existing.first.index;
      return trailGo(existing.first.index);
    }
    final index = trail.stops.length;
    _forward[fromStop] = index;
    _trail = TrailDto(rootQuery: trail.rootQuery, current: index, stops: [
      ...trail.stops,
      StopDto(index: index, parent: fromStop, target: to, title: title, via: _threadLabel(via),
        viaSource: via == ThreadKind.matched ? 'your library' : 'tags',
        onPath: false, isFork: false, isPeek: false),
    ], meetings: trail.meetings);
    return trailGo(index);
  }

  static String _threadLabel(ThreadKind kind) => switch (kind) {
    ThreadKind.by => 'by',
    ThreadKind.albumArtist => 'album artist',
    ThreadKind.appearsOn => 'on',
    ThreadKind.workedWith => 'worked with',
    ThreadKind.matched => 'matched',
    _ => throw 'This thread is not followable yet',
  };

  @override
  Future<TrailDto> trailGo(int stop) async {
    final trail = _trail;
    if (trail == null) throw 'No trail is open';
    final byIndex = {for (final node in trail.stops) node.index: node};
    if (!byIndex.containsKey(stop)) throw 'Unknown trail stop';
    final path = <int>{};
    int? cursor = stop;
    while (cursor != null) {
      path.add(cursor);
      final parent = byIndex[cursor]!.parent;
      if (parent != null) _forward[parent] = cursor;
      cursor = parent;
    }
    final children = <int, int>{};
    for (final node in trail.stops) {
      if (node.parent != null) children.update(node.parent!, (count) => count + 1, ifAbsent: () => 1);
    }
    return _trail = TrailDto(rootQuery: trail.rootQuery, current: stop, stops: [
      for (final node in trail.stops)
        StopDto(index: node.index, parent: node.parent, target: node.target, title: node.title,
          via: node.via, viaSource: node.viaSource, onPath: path.contains(node.index),
          isFork: (children[node.index] ?? 0) > 1, isPeek: node.isPeek),
    ], meetings: trail.meetings);
  }

  @override
  Future<TrailDto?> trailBack() async {
    final trail = _trail;
    if (trail == null) return null;
    final parent = trail.stops.firstWhere((stop) => stop.index == trail.current).parent;
    return parent == null ? null : trailGo(parent);
  }

  @override
  Future<TrailDto?> trailForward() async {
    final current = _trail?.current;
    final child = current == null ? null : _forward[current];
    return child == null ? null : trailGo(child);
  }

  static int _rank(String name, List<String> words) {
    final folded = _fold(name), text = words.join(' ');
    return folded == text ? 0 : folded.startsWith(text) ? 1 : 2;
  }

  static String _quote(String name) => '"${name.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  static String _fold(String text) {
    const accents = 'àáâãäåāèéêëēìíîïīòóôõöøōùúûüūýÿçñ';
    const plain = 'aaaaaaaeeeeeiiiiiooooooouuuuuyycn';
    return text.toLowerCase().split('').map((letter) {
      final i = accents.indexOf(letter);
      return i < 0 ? letter : plain[i];
    }).join('');
  }

  static List<String> _tokens(String input) {
    final tokens = <String>[];
    var start = -1, quoted = false, escaped = false;
    for (var i = 0; i < input.length; i++) {
      final char = input[i];
      if (!quoted && char.trim().isEmpty) {
        if (start >= 0) tokens.add(input.substring(start, i));
        start = -1;
        continue;
      }
      if (start < 0) start = i;
      if (char == '"' && !escaped) quoted = !quoted;
      escaped = quoted && char == r'\' && !escaped;
    }
    if (quoted) throw 'Unclosed quote';
    if (start >= 0) tokens.add(input.substring(start));
    return tokens;
  }

  static List<(String, String, bool)> _clauses(String input) {
    return [for (var token in _tokens(input)) (() {
      final negated = token.startsWith('-');
      if (negated) token = token.substring(1);
      final colon = token.startsWith('"') ? -1 : token.indexOf(':');
      final key = colon < 0 ? '' : token.substring(0, colon).toLowerCase();
      if (!const ['', 'by', 'sung', 'composer', 'composed', 'release', 'album', 'idiom', 'format',
        'year', 'length', 'plays', 'dr', 'last', 'added', 'not', 'is', 'game', 'film', 'label', 'crate', 'work'].contains(key)) {
        throw 'Unknown key `$key:`';
      }
      var value = colon < 0 ? token : token.substring(colon + 1);
      if (value.startsWith('"') && value.endsWith('"')) value = value.substring(1, value.length - 1).replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
      if (value.isEmpty) throw 'A search value is missing';
      final valid = switch (key) {
        'idiom' => const ['album', 'song', 'work', 'session', 'score', 'set', 'spoken'].contains(value.toLowerCase()),
        'format' => const ['flac', 'hires', 'hi-res', '24bit', 'dsd', 'chiptune', 'native', 'lossy'].contains(value.toLowerCase()),
        'is' || 'not' => const ['owned', 'own', 'lossless', 'streamable', 'stream', 'wanted', 'want', 'guessed', 'unmatched', 'dormant', 'lead'].contains(value.toLowerCase()),
        'year' || 'plays' || 'dr' || 'length' => RegExp(r'^[<>]?\d+(?:\.\d+)?(?:s|m|h|:\d+)?(?:\.\.\d+(?:\.\d+)?(?:s|m|h|:\d+)?)?$').hasMatch(value),
        'last' || 'added' => RegExp(r'^\d+[dwmy]$').hasMatch(value),
        _ => true,
      };
      if (!valid) throw 'Invalid $key value: $value';
      return (key == 'album' ? 'release' : key, value, negated);
    })()];
  }

  static final _letter = RegExp(r'[a-z0-9]');

  static bool _contains(String text, String word) {
    final haystack = _fold(text), needle = _fold(word);
    var start = 0;
    while (start <= haystack.length) {
      final index = haystack.indexOf(needle, start);
      if (index < 0) return false;
      if (index == 0 || !_letter.hasMatch(haystack[index - 1])) return true;
      start = index + 1;
    }
    return false;
  }

  List<int> _matching(String query) {
    if (_empty) return const [];
    final cached = _results.remove(query);
    if (cached != null) {
      _results[query] = cached;
      return cached;
    }
    final clauses = _clauses(query);
    final matches = [
      for (var i = 0; i < _sampleRows.length; i++) clauses.every((c) => _matches(_sampleRows[i], c)),
    ];
    final indices = [for (var i = 0; i < _total; i++) if (matches[i % matches.length]) i];
    _results[query] = indices;
    if (_results.length > 8) _results.remove(_results.keys.first);
    return indices;
  }

  static bool _matches(TrackRowDto row, (String, String, bool) clause) {
    final (key, value, negated) = clause;
    final word = _fold(value);
    final matched = switch (key) {
      '' => [row.title, row.artist ?? '', row.album, row.albumArtist ?? ''].any((s) => _contains(s, word)),
      'by' || 'sung' || 'composer' || 'composed' => [row.artist ?? '', row.albumArtist ?? ''].any((s) => _contains(s, word)),
      'release' => _contains(row.album, word),
      'idiom' => word == (row.artist == 'Yasunori Mitsuda' || row.artist == 'Joanne Hogg' ? 'score' : row.artist == 'Bill Evans Trio' ? 'session' : 'album'),
      'format' => word == 'lossy' ? row.format == 'AAC' : word == 'flac' ? row.format.startsWith('FLAC') : false,
      'year' => _number(row.year?.toDouble() ?? 0, value),
      'plays' || 'dr' => _number(0, value),
      'length' => _number((row.lengthMs?.toDouble() ?? 0) / 1000, value),
      'is' => word == 'owned' || word == 'own' || (word == 'lossless' && row.format != 'AAC'),
      'not' => !(word == 'owned' || word == 'own' || (word == 'lossless' && row.format != 'AAC')),
      'last' || 'added' => true,
      _ => false,
    };
    return negated ? !matched : matched;
  }

  static bool _number(double number, String input) {
    if (input.endsWith('s')) {
      final start = double.tryParse(input.substring(0, input.length - 1));
      return start != null && number >= start && number < start + 10;
    }
    final range = input.split('..');
    if (range.length == 2) {
      final lo = double.tryParse(range.first), hi = double.tryParse(range.last);
      return lo != null && hi != null && number >= lo && number <= hi;
    }
    final bound = double.tryParse(input.startsWith('<') || input.startsWith('>') ? input.substring(1) : input);
    return bound != null && (input.startsWith('<') ? number < bound : input.startsWith('>') ? number > bound : number == bound);
  }

  @override
  Future<HistogramDto> histogram(ColumnDto column, String query, double lo, double hi, int bins) async {
    // A plausible shape: most listening recent, a long tail back.
    final b = Uint32List.fromList(List.generate(bins, (i) => (40 + 400 * (i / bins) * (i / bins) + (i * 37 % 23) * 4).round()));
    return HistogramDto(lo: lo, hi: hi, bins: b, matched: BigInt.from(214));
  }

  @override
  Future<int> addRoot(String path) async {
    _empty = false;
    _root = path;
    _libraryVersion += BigInt.one;
    _statuses.add(_status);
    return 1;
  }

  @override
  Future<RowsDto> rows(String query, int offset, int limit) async {
    final indices = _matching(query);
    final start = offset.clamp(0, indices.length);
    final count = limit.clamp(0, indices.length - start);
    return RowsDto(
      total: BigInt.from(indices.length),
      offset: BigInt.from(start),
      rows: List.generate(count, (i) => _row(indices[start + i])),
    );
  }

  static const _releases = [
      ('Xenogears Original Soundtrack', 'Yasunori Mitsuda', 1998, ['The Beginning and the End', 'Stars of Tears', 'Small Two of Pieces ~Broken Pieces~']),
      ('Beyond These Shores', 'Iona', 1993, ['Prayer on the Mountain', 'Treasure', 'Beyond These Shores']),
      ('Waltz for Debby', 'Bill Evans Trio', 1961, ['My Foolish Heart', 'Waltz for Debby', 'Some Other Time']),
      ('Chrono Trigger', 'Yasunori Mitsuda', 1995, ['Corridors of Time', 'Wind Scene', 'To Far Away Times']),
      ('The Book of Kells', 'Iona', 1992, ['Kells', 'Revelation', 'Eternity']),
      ('Open Sky', 'Iona', 2000, ['Woven Cord', 'Wave After Wave', 'Woman Of Wisdom']),
      ('Journey into the Morn', 'Iona', 1995, ['Irish Day', 'Today', 'Inside My Heart']),
      ('Creid', 'Yasunori Mitsuda', 1998, ['Creid', 'Melkaba', 'Lahan']),
    ];
  static final _personNames = {..._releases.map((release) => release.$2), 'Joanne Hogg'}.toList();

  static PlatformInt64 _personId(String name) => PlatformInt64Util.from(_personNames.indexOf(name) + 1);

  List<int> _releaseIndices(PlatformInt64 id) {
    final release = id.toInt() - 1;
    if (_empty || release < 0 || release >= _releases.length) throw 'Release no longer exists';
    return [for (var i = 0; i < _total; i++) if ((i ~/ 12) % _releases.length == release) i];
  }

  List<TrackRowDto> _releaseRows(PlatformInt64 id) => _releaseIndices(id).map(_row).toList()
    ..sort((a, b) {
      final disc = a.disc.compareTo(b.disc);
      if (disc != 0) return disc;
      final track = a.number.compareTo(b.number);
      return track != 0 ? track : a.trackId.compareTo(b.trackId);
    });

  @override
  Future<ReleaseDto> release(PlatformInt64 id) async {
    final rows = _releaseRows(id);
    final first = rows.first;
    final artists = <PlatformInt64, List<TrackRowDto>>{};
    final formats = <String, int>{};
    var length = BigInt.zero;
    for (final row in rows) {
      if (row.artistId != null) artists.putIfAbsent(row.artistId!, () => []).add(row);
      formats.update(row.format, (count) => count + 1, ifAbsent: () => 1);
      length += row.lengthMs ?? BigInt.zero;
    }
    final sortedFormats = formats.keys.toList()..sort((a, b) => formats[b]!.compareTo(formats[a]!));
    return ReleaseDto(
      id: id, title: first.album, artist: first.albumArtist, year: first.year,
      idiom: first.albumArtist == 'Yasunori Mitsuda' ? 'Score' : first.albumArtist == 'Bill Evans Trio' ? 'Session' : 'Album',
      tracks: rows.length, discs: rows.map((row) => row.disc).toSet().length,
      lengthMs: length, formats: sortedFormats, rows: rows,
      credits: [
        if (first.albumArtistId != null)
          ThreadDto(kind: ThreadKind.albumArtist, label: 'album artist', source: 'tags',
            to: TargetDto.person(id: first.albumArtistId!), title: first.albumArtist!, detail: ''),
        for (final entry in artists.entries)
          if (entry.key != first.albumArtistId || entry.value.length != rows.length)
            ThreadDto(kind: ThreadKind.by, label: 'by', source: 'tags',
              to: TargetDto.person(id: entry.key), title: entry.value.first.artist!,
              detail: entry.value.map((row) => '${row.disc}-${row.number.toString().padLeft(2, '0')}').toSet().join(', ')),
      ],
    );
  }

  @override
  Future<PersonDto> person(PlatformInt64 id) async {
    final index = id.toInt() - 1;
    if (_empty || index < 0 || index >= _personNames.length) throw 'Person no longer exists';
    final name = _personNames[index];
    final releases = <ThreadDto>[], appearsOn = <ThreadDto>[];
    final shared = <PlatformInt64, int>{};
    var tracks = 0;
    final ids = List.generate(_releases.length, (i) => i + 1)
      ..sort((a, b) => _releases[a - 1].$3.compareTo(_releases[b - 1].$3));
    for (final releaseId in ids) {
      final rows = _releaseRows(PlatformInt64Util.from(releaseId));
      final credited = rows.where((row) => row.artistId == id || row.albumArtistId == id).length;
      if (credited == 0) continue;
      tracks += credited;
      final first = rows.first;
      final own = first.albumArtistId == id;
      final thread = ThreadDto(kind: ThreadKind.appearsOn, label: 'on', source: 'tags',
        to: TargetDto.release(id: first.releaseId), title: first.album,
        detail: '${first.year} · ${own ? '${rows.length} tracks' : '$credited of ${rows.length} tracks'}');
      (own ? releases : appearsOn).add(thread);
      final people = {for (final row in rows) ...[row.artistId, row.albumArtistId]}..remove(null)..remove(id);
      for (final person in people) {
        shared.update(person!, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    final coworkers = shared.keys.toList()..sort((a, b) => shared[b]!.compareTo(shared[a]!));
    return PersonDto(id: id, name: name, tracks: tracks, releases: releases, appearsOn: appearsOn, workedWith: [
      for (final person in coworkers.take(12))
        ThreadDto(kind: ThreadKind.workedWith, label: 'worked with', source: 'tags',
          to: TargetDto.person(id: person), title: _personNames[person.toInt() - 1],
          detail: '${shared[person]} ${shared[person] == 1 ? 'release' : 'releases'} together'),
    ]);
  }

  @override
  Future<void> playRelease({required PlatformInt64 id, required int index, int? fromStop}) async {
    final rows = _releaseRows(id);
    if (index < 0 || index >= rows.length) throw RangeError.index(index, rows);
    _playRow(rows[index]);
  }


  TrackRowDto _row(int index) {
    final releaseIndex = (index ~/ 12) % _releases.length;
    final release = _releases[releaseIndex];
    final artist = index % (_releases.length * 12) == 2 ? 'Joanne Hogg' : release.$2;
    final number = index % 12 + 1;
    return TrackRowDto(
      trackId: PlatformInt64Util.from(index + 1),
      releaseId: PlatformInt64Util.from(releaseIndex + 1),
      artistId: _personId(artist),
      albumArtistId: _personId(release.$2),
      title: release.$4[index % release.$4.length],
      artist: artist,
      album: release.$1,
      albumArtist: release.$2,
      disc: 1,
      number: number,
      year: release.$3,
      lengthMs: BigInt.from(180000 + index * 7919 % 240000),
      format: index % 7 == 0 ? 'AAC' : 'FLAC 16/44.1',
      path: '/Music/${release.$1}/$number.flac',
    );
  }

  @override
  Future<void> playResults(String query, int index) async {
    final indices = _matching(query);
    if (index < 0 || index >= indices.length) throw RangeError.index(index, null, 'index', null, indices.length);
    _playRow(_row(indices[index]));
  }

  void _playRow(TrackRowDto row) {
    _state = NowDto(
      title: row.title,
      subtitle: '${row.artist} · ${row.album}',
      anchor: AnchorDto(item: BigInt.from(row.trackId.toInt()), positionMs: 0, rate: 1),
      lengthMs: row.lengthMs,
      path: [
        StageDto(name: 'File', detail: row.format, alters: false),
        const StageDto(name: 'Decode', detail: 'no DSP', alters: false),
        const StageDto(name: 'Out', detail: 'RME ADI-2 · 44.1', alters: false),
      ],
      fidelity: row.format == 'AAC' ? FidelityDto.lossy : FidelityDto.bitPerfect,
    );
    _now.add(_state);
  }

  @override
  Future<void> transport(TransportDto cmd) async {
    final a = _state.anchor;
    if (a == null) return;
    final pos = a.positionMs;
    _state = switch (cmd) {
      TransportDto_Pause() => _with(AnchorDto(item: a.item, positionMs: pos, rate: 0)),
      TransportDto_Resume() => _with(AnchorDto(item: a.item, positionMs: pos, rate: 1)),
      TransportDto_Seek(:final ms) => _with(AnchorDto(item: a.item, positionMs: ms.toDouble(), rate: a.rate)),
      _ => _state,
    };
    _now.add(_state);
  }

  NowDto _with(AnchorDto a) => NowDto(
        title: _state.title,
        subtitle: _state.subtitle,
        anchor: a,
        lengthMs: _state.lengthMs,
        path: _state.path,
        fidelity: _state.fidelity,
      );
}
