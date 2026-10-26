import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64, PlatformInt64Util;

import '../src/rust/api/core.dart' as rust;
import '../src/rust/api/types.dart';

export '../src/rust/api/types.dart';

/// The scan's phases, as `meret-core`'s `SCAN_VERBS` names them. Everything
/// else in the job list is a library job (lookups, analysis).
extension JobScan on JobDto {
  bool get isScan => verb == 'scanning' || verb == 'reading tags' || verb == 'reading covers';
}

/// Everything the UI asks of the core. The Rust implementation is the real
/// one; the fake one lets widget tests and design work run without the
/// native library.
///
/// Nothing here is called per frame. Now and the status are streams;
/// the playhead is an anchor that `PlayheadClock` extrapolates.
abstract interface class CoreBridge {
  Stream<NowDto> now();
  Stream<StatusDto> status();
  Future<TrailDto?> trail();
  Future<FrontDto> front();
  Future<SearchDto> search(String input);
  Future<ReleaseDto> release(PlatformInt64 id);
  Future<PersonDto> person(PlatformInt64 id);
  Future<WorkDto> work(PlatformInt64 id);
  Future<void> playWork(PlatformInt64 id, int index);
  Future<GameDto> game(PlatformInt64 id);
  Future<void> playGame(PlatformInt64 id, int index);
  Future<void> playRelease({required PlatformInt64 id, required int index, int? fromStop});
  Future<TrailDto> startTrail(TargetDto to);
  Future<TrailDto> follow(int fromStop, TargetDto to, ThreadKind via, String provider);
  Future<TrailDto?> trailBack();
  Future<TrailDto?> trailForward();
  Future<TrailDto> trailGo(int stop);
  Future<TrailDto?> trailSibling(int step);
  Future<TrailDto> pruneBranch(int leaf);
  Future<int> playTrail(bool whole);
  Future<List<TrailSummaryDto>> trailHistory(int limit);
  Future<TrailDto> keepTrail({String? name});
  /// A trail from Home's Trails becomes active at the stop it was left on.
  Future<TrailDto> openTrail(String uid);
  Future<void> runCommand(String input);
  QueryDto parse(String input);
  Future<HistogramDto> histogram(ColumnDto column, String query, double lo, double hi, int bins);
  Future<void> transport(TransportDto cmd);
  /// Writes the queue position and the open listen; called as the app quits.
  Future<void> flushMemory();
  /// The queue after the playing item; ask again when Now's item changes.
  Future<UpNextDto> upNext(int limit);
  Future<int> addRoot(String path);
  Future<void> removeRoot(int id);
  SettingsDto settings();
  Future<void> setSettings(SettingsDto s);
  Future<LookupStatusDto> lookups();
  Future<void> setLookups(LookupsDto lookups);
  Future<List<OutputDeviceDto>> outputDevices();
  Future<VolumeDto> volume();
  Future<VolumeDto> setVolume(double scalar);
  Future<List<FolderSuggestionDto>> suggestFolders();
  Future<RowsDto> rows(String query, ViewDto view, int offset, int limit);
  Future<void> playResults(String query, ViewDto view, int index);
  Future<FacetsDto> facets(String query);
  Future<List<ListenDto>> history(int limit);
  Future<List<PlayedDto>> mostPlayed(int days, int limit);
  Future<List<DormantDto>> dormant(int limit);
  Future<List<ResumeDto>> resumePoints(int limit);
  Future<void> pickUp(PlatformInt64 releaseId);
  /// Play something's picks, best first, each saying why.
  Future<List<PickDto>> picks(int limit);
  /// `⇧Space`: plays the first pick from the top; null when nothing is playable.
  Future<PickDto?> playSomething();
  /// A pick clicked in Now: plays that release from the top with its why.
  Future<PickDto> playPick(PlatformInt64 releaseId);
  /// Play on: every zone and what it does to the sound.
  Future<List<ZoneDto>> zones();
  /// Sends output to a zone; while playing it applies from the next track.
  Future<void> playOn(String zone);
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
  Future<WorkDto> work(PlatformInt64 id) => rust.work(id: id);
  @override
  Future<void> playWork(PlatformInt64 id, int index) => rust.playWork(id: id, index: index);
  @override
  Future<GameDto> game(PlatformInt64 id) => rust.game(id: id);
  @override
  Future<void> playGame(PlatformInt64 id, int index) => rust.playGame(id: id, index: index);
  @override
  Future<void> playRelease({required PlatformInt64 id, required int index, int? fromStop}) =>
      rust.playRelease(id: id, index: index, fromStop: fromStop);
  @override
  Future<TrailDto> startTrail(TargetDto to) => rust.startTrail(to: to);
  @override
  Future<TrailDto> follow(int fromStop, TargetDto to, ThreadKind via, String provider) => rust.follow(fromStop: fromStop, to: to, via: via, provider: provider);
  @override
  Future<TrailDto?> trailBack() => rust.trailBack();
  @override
  Future<TrailDto?> trailForward() => rust.trailForward();
  @override
  Future<TrailDto> trailGo(int stop) => rust.trailGo(stop: stop);
  @override
  Future<TrailDto?> trailSibling(int step) => rust.trailSibling(step: step);
  @override
  Future<TrailDto> pruneBranch(int leaf) => rust.pruneBranch(leaf: leaf);
  @override
  Future<int> playTrail(bool whole) => rust.playTrail(whole: whole);
  @override
  Future<List<TrailSummaryDto>> trailHistory(int limit) => rust.trailHistory(limit: limit);
  @override
  Future<TrailDto> keepTrail({String? name}) => rust.keepTrail(name: name);
  @override
  Future<TrailDto> openTrail(String uid) => rust.openTrail(uid: uid);
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
  Future<void> flushMemory() => rust.flushMemory();
  @override
  Future<UpNextDto> upNext(int limit) => rust.upNext(limit: limit);
  @override
  Future<int> addRoot(String path) async => (await rust.addRoot(path: path)).toInt();
  @override
  Future<void> removeRoot(int id) => rust.removeRoot(id: PlatformInt64Util.from(id));
  @override
  SettingsDto settings() => rust.settings();
  @override
  Future<void> setSettings(SettingsDto s) => rust.setSettings(s: s);
  @override
  Future<LookupStatusDto> lookups() => rust.lookups();
  @override
  Future<void> setLookups(LookupsDto lookups) => rust.setLookups(lookups: lookups);
  @override
  Future<List<OutputDeviceDto>> outputDevices() => rust.outputDevices();
  @override
  Future<VolumeDto> volume() => rust.volume();
  @override
  Future<VolumeDto> setVolume(double scalar) => rust.setVolume(scalar: scalar);
  @override
  Future<List<FolderSuggestionDto>> suggestFolders() => rust.suggestFolders();
  @override
  Future<RowsDto> rows(String query, ViewDto view, int offset, int limit) =>
      rust.rows(query: query, view: view, offset: BigInt.from(offset), limit: limit);
  @override
  Future<void> playResults(String query, ViewDto view, int index) =>
      rust.playResults(query: query, view: view, index: BigInt.from(index));
  @override
  Future<FacetsDto> facets(String query) => rust.facets(query: query);
  @override
  Future<List<ListenDto>> history(int limit) => rust.history(limit: limit);
  @override
  Future<List<PlayedDto>> mostPlayed(int days, int limit) => rust.mostPlayed(days: days, limit: limit);
  @override
  Future<List<DormantDto>> dormant(int limit) => rust.dormant(limit: limit);
  @override
  Future<List<ResumeDto>> resumePoints(int limit) => rust.resumePoints(limit: limit);
  @override
  Future<void> pickUp(PlatformInt64 releaseId) => rust.pickUp(releaseId: releaseId);
  @override
  Future<List<PickDto>> picks(int limit) => rust.picks(limit: limit);
  @override
  Future<PickDto?> playSomething() => rust.playSomething();
  @override
  Future<PickDto> playPick(PlatformInt64 releaseId) => rust.playPick(releaseId: releaseId);
  @override
  Future<List<ZoneDto>> zones() => rust.zones();
  @override
  Future<void> playOn(String zone) => rust.playOn(zone: zone);
}

/// The plates' Tuesday evening, as data.
class FakeCore implements CoreBridge {
  FakeCore();

  FakeCore.empty() : _empty = true {
    _state = const NowDto(title: '', subtitle: '', path: []);
    _roots.clear();
  }

  bool _empty = false;
  final _roots = <int, String>{1: '/Music'};
  final _rootIds = <String, int>{'/Music': 1};
  SettingsDto _settings = const SettingsDto(light: LightLevelDto.accent, exclusive: false, lookups: LookupsDto.unasked, level: LevelDto.off);
  BigInt _libraryVersion = BigInt.one;
  TrailDto? _trail;
  final _forward = <int, int>{};
  final _trailHistory = <({TrailDto trail, Map<int, int> forward, int departure})>[];
  int? _historyIndex;
  final _trailUids = <String>[];
  final _trailCreated = <String, int>{};
  final _keptTrails = <String, String?>{};
  final _trailPlayed = <String, Set<int>>{};
  final _trailVisits = <String, Map<int, int>>{};
  int _visitClock = 0;
  int _nextTrail = 0;

  @override
  Future<List<TrailSummaryDto>> trailHistory(int limit) async {
    _saveTrail();
    return [
      for (var i = _trailHistory.length - 1; i >= 0 && _trailHistory.length - i <= limit; i--)
        _trailSummary(i),
    ];
  }

  TrailSummaryDto _trailSummary(int index) {
    final trail = _trailHistory[index].trail;
    final uid = _trailUids[index];
    final root = trail.stops.first.title;
    final leaf = trail.stops.firstWhere((stop) => stop.index == trail.current).title;
    final parents = trail.stops.map((stop) => stop.parent).toSet();
    return TrailSummaryDto(
      uid: uid, title: root == leaf ? root : '$root → $leaf',
      stops: trail.stops.length,
      branches: trail.stops.where((stop) => !parents.contains(stop.index)).length,
      whenMs: PlatformInt64Util.from(_trailCreated[uid]!),
      kept: _keptTrails.containsKey(uid), name: _keptTrails[uid],
      played: _trailPlayed[uid]?.length ?? 0, wanted: 0,
    );
  }

  @override
  Future<TrailDto> keepTrail({String? name}) async {
    final index = _historyIndex;
    final trail = _trail;
    if (index == null || trail == null) throw 'No trail is open';
    _keptTrails[_trailUids[index]] = name;
    _trail = _withKept(trail, index);
    _saveTrail();
    return _trail!;
  }

  @override
  Future<TrailDto> openTrail(String uid) async {
    final index = _trailUids.indexOf(uid);
    if (index < 0) throw 'that trail is no longer in the history';
    _saveTrail();
    _loadTrail(index);
    return trailGo(_trail!.current);
  }

  TrailDto _withKept(TrailDto trail, int index) {
    final uid = _trailUids[index];
    return TrailDto(rootQuery: trail.rootQuery, current: trail.current, stops: trail.stops, meetings: trail.meetings,
      branches: _branches(trail, uid), kept: _keptTrails.containsKey(uid), name: _keptTrails[uid]);
  }

  List<BranchDto> _branches(TrailDto trail, String uid) {
    final stops = {for (final stop in trail.stops) stop.index: stop};
    final parents = trail.stops.map((stop) => stop.parent).toSet();
    final visits = _trailVisits[uid] ?? const <int, int>{};
    final branches = <BranchDto>[];
    for (final leaf in trail.stops.where((stop) => !parents.contains(stop.index) && !stop.isPeek)) {
      final path = <StopDto>[leaf];
      var node = leaf;
      int? fork;
      while (node.parent != null) {
        final parent = stops[node.parent]!;
        if (parent.isFork) {
          fork = parent.index;
          break;
        }
        path.add(parent);
        node = parent;
      }
      final current = path.any((stop) => stop.index == trail.current);
      final actions = path.reversed.expand((stop) => stop.actions).toList();
      branches.add(BranchDto(
        fork: fork, first: path.last.index, leaf: leaf.index, stops: path.length,
        whenMs: PlatformInt64Util.from(visits[leaf.index] ?? _trailCreated[uid]!),
        actions: actions, current: current, prunable: !current && actions.isEmpty,
      ));
    }
    branches.sort((a, b) => a.current != b.current ? (a.current ? -1 : 1) : (visits[b.leaf] ?? 0).compareTo(visits[a.leaf] ?? 0));
    return branches;
  }

  void _saveTrail() {
    final index = _historyIndex;
    final trail = _trail;
    if (index != null && trail != null) {
      _trailHistory[index] = (trail: trail, forward: Map.of(_forward), departure: _trailHistory[index].departure);
    }
  }

  void _loadTrail(int index) {
    _historyIndex = index;
    final entry = _trailHistory[index];
    _trail = entry.trail;
    _forward
      ..clear()
      ..addAll(entry.forward);
  }
  final _results = <String, List<int>>{};
  final _lists = <(String, ViewDto), (List<int>, List<ItemDto>, int)>{};
  late final _sampleRows = List.generate(_releases.length * 12 * 7, _row);
  final _statuses = StreamController<StatusDto>.broadcast();
  final _now = StreamController<NowDto>.broadcast();
  static const _sampleLight = LightDto(light: 0xFFDF9672, wash: 0x14DF9672, dim: 0x55DF9672);
  static BodyDto _body(BigInt lengthMs, int seed) => BodyDto(
    loudness: Uint8List.fromList(List.generate(240, (i) => 80 + (i * 17 + seed * 13) % 176)),
    low: Uint8List.fromList(List.generate(240, (i) => 40 + (i * 7 + seed * 3) % 180)),
    mid: Uint8List.fromList(List.generate(240, (i) => 30 + (i * 11 + seed * 5) % 200)),
    high: Uint8List.fromList(List.generate(240, (i) => 20 + (i * 19 + seed * 7) % 160)),
    lengthMs: lengthMs,
  );
  NowDto _state = NowDto(
    trackId: PlatformInt64Util.from(3),
    releaseId: PlatformInt64Util.from(1),
    light: _sampleLight,
    title: 'Small Two of Pieces ~Broken Pieces~',
    subtitle: 'Joanne Hogg · Xenogears, disc 2 · ending',
    anchor: AnchorDto(item: BigInt.one, positionMs: 226000, rate: 1),
    lengthMs: BigInt.from(391000),
    body: _body(BigInt.from(391000), 2),
    dr: 11,
    loudnessLufs: -15.2,
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
        sources: [
          SourceDto(key: 'local', name: 'This Mac', detail: _empty ? '0' : '48,210', ok: true),
          SourceDto(key: 'musicbrainz', name: 'MusicBrainz', detail: switch (_settings.lookups) {
            LookupsDto.unasked => 'asks first',
            LookupsDto.allowed => 'not used yet',
            LookupsDto.off => 'off',
          }, ok: true),
        ],
        jobs: _empty ? [] : [JobDto(verb: 'analysing', done: BigInt.from(1204), total: BigInt.from(3880))],
        guessed: _empty ? BigInt.zero : BigInt.from(312),
        newLeads: _empty ? BigInt.zero : BigInt.from(14),
        tracks: BigInt.from(_total),
        libraryVersion: _libraryVersion,
        lookupsVersion: BigInt.zero,
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
      lookups: _settings.lookups == LookupsDto.unasked ? await lookups() : null,
      idioms: [
        for (final (idiom, releases, tracks) in const [
          ('album', 2104, 25210),
          ('song', 3880, 3880),
          ('work', 1204, 9310),
          ('session', 412, 4110),
          ('score', 212, 1840),
          ('set', 318, 2420),
          ('spoken', 12, 1440),
        ])
          IdiomLineDto(label: _idioms[idiom]!, releases: BigInt.from(releases), tracks: BigInt.from(tracks), query: 'idiom:$idiom'),
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
        FrontLineDto(label: 'Tracks with a guessed identity', count: BigInt.from(312), note: ''),
        FrontLineDto(label: 'Albums with two editions', count: BigInt.from(18), note: ''),
      ],
      roots: [for (final root in _roots.entries) RootDto(
        id: PlatformInt64Util.from(root.key), path: root.value, online: true,
        tracks: BigInt.from(48210 ~/ _roots.length),
        label: root.value.split('/').where((part) => part.isNotEmpty).lastOrNull ?? root.value,
      )],
    );
  }

  @override
  Future<void> runCommand(String input) async {
    final command = input.trim();
    final verb = command.split(RegExp(r'\s+')).first.toLowerCase();
    if (verb == 'play') {
      await playResults(command.substring(4).trim(), const ViewDto(sort: SortKeyDto.library_, descending: false, group: false), 0);
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
    _saveTrail();
    if (_historyIndex case final index?) {
      final previous = _trailHistory.removeAt(index);
      _trailHistory.add((trail: previous.trail, forward: previous.forward, departure: previous.trail.current));
      _trailUids.add(_trailUids.removeAt(index));
    }
    _forward.clear();
    final trail = TrailDto(
      rootQuery: target is TargetDto_Search ? target.query : null,
      current: 0,
      stops: [StopDto(index: 0, target: target, title: title, onPath: true, isFork: false, isPeek: false,
        openedMs: PlatformInt64Util.from(DateTime.now().millisecondsSinceEpoch), dwellMs: PlatformInt64Util.from(0), actions: const [])],
      meetings: const [],
      branches: const [],
      kept: false,
    );
    _trailHistory.add((trail: trail, forward: {}, departure: 0));
    final uid = 'fake-trail-${_nextTrail++}';
    _trailUids.add(uid);
    _trailCreated[uid] = DateTime.now().millisecondsSinceEpoch;
    _historyIndex = _trailHistory.length - 1;
    (_trailVisits[uid] ??= {})[0] = DateTime.now().millisecondsSinceEpoch + _visitClock++;
    return _trail = _withKept(trail, _historyIndex!);
  }

  String _searchQuery(String query) {
    final parsed = parse(query);
    if (parsed.kind != QueryKind.search) throw parsed.error ?? 'Type a search, not a command';
    return parsed.canonical;
  }

  static const _idioms = {
    'album': 'Albums', 'song': 'Songs', 'work': 'Works', 'session': 'Sessions', 'score': 'Scores', 'set': 'Sets', 'spoken': 'Spoken',
  };

  /// The core's `search_title`: a door's root takes the door's name.
  static String _searchTitle(String query) {
    if (query.trim().isEmpty) return 'All tracks';
    final idiom = RegExp(r'^idiom:(\w+)$').firstMatch(query.trim())?[1];
    return _idioms[idiom] ?? query;
  }

  Future<String> _title(TargetDto target) async => switch (target) {
    TargetDto_Search(:final query) => _searchTitle(query),
    TargetDto_Release(:final id) => (await release(id)).title,
    TargetDto_Person(:final id) => (await person(id)).name,
    TargetDto_Work(:final id) => (await work(id)).title,
    TargetDto_Game(:final id) => (await game(id)).title,
  };

  @override
  Future<TrailDto> follow(int fromStop, TargetDto to, ThreadKind via, String provider) async {
    final trail = _trail;
    if (trail == null) throw 'No trail is open';
    if (to is TargetDto_Search) throw 'A search starts a new trail';
    if (!const [
      ThreadKind.by, ThreadKind.albumArtist, ThreadKind.appearsOn, ThreadKind.workedWith,
      ThreadKind.composedBy, ThreadKind.lyricsBy, ThreadKind.arrangedBy, ThreadKind.performedBy,
      ThreadKind.conductedBy, ThreadKind.producedBy, ThreadKind.engineeredBy, ThreadKind.recordingOf,
      ThreadKind.matched, ThreadKind.hasMember,
      ThreadKind.scored, ThreadKind.soundtrackOf, ThreadKind.soundtrack, ThreadKind.sameSeries,
    ].contains(via)) {
      throw 'This thread is not followable yet';
    }
    if (!trail.stops.any((stop) => stop.index == fromStop)) throw 'Unknown trail stop';
    final onPath = trail.stops.where((stop) => stop.onPath && stop.target == to);
    if (onPath.isNotEmpty) return trailGo(onPath.first.index);
    final title = await _title(to);
    final existing = trail.stops.where((stop) => stop.parent == fromStop && stop.target == to);
    if (existing.isNotEmpty) {
      _forward[fromStop] = existing.first.index;
      return trailGo(existing.first.index);
    }
    final index = trail.stops.map((stop) => stop.index).reduce((a, b) => a > b ? a : b) + 1;
    _forward[fromStop] = index;
    _trail = TrailDto(rootQuery: trail.rootQuery, current: index, branches: const [], kept: trail.kept, name: trail.name, stops: [
      ...trail.stops,
      StopDto(index: index, parent: fromStop, target: to, title: title, via: _threadLabel(via),
        viaSource: switch (provider) { 'musicbrainz' => 'MB', 'wikidata' => 'Wikidata', 'library' => 'your library', _ => 'tags' },
        onPath: false, isFork: false, isPeek: false,
        openedMs: PlatformInt64Util.from(DateTime.now().millisecondsSinceEpoch), dwellMs: PlatformInt64Util.from(0), actions: const []),
    ], meetings: [
      ...trail.meetings,
      for (final stop in trail.stops)
        if (stop.target == to) (stop.index, index),
    ]);
    return trailGo(index);
  }

  static String _threadLabel(ThreadKind kind) => switch (kind) {
    ThreadKind.by => 'by',
    ThreadKind.albumArtist => 'album artist',
    ThreadKind.appearsOn => 'appears on',
    ThreadKind.workedWith => 'worked with',
    ThreadKind.hasMember => 'has member',
    ThreadKind.composedBy => 'composed by',
    ThreadKind.lyricsBy => 'lyrics by',
    ThreadKind.arrangedBy => 'arranged by',
    ThreadKind.performedBy => 'performed by',
    ThreadKind.conductedBy => 'conducted by',
    ThreadKind.producedBy => 'produced by',
    ThreadKind.engineeredBy => 'engineered by',
    ThreadKind.recordingOf => 'recording of',
    ThreadKind.matched => 'found',
    ThreadKind.scored => 'scored',
    ThreadKind.soundtrackOf => 'soundtrack of',
    ThreadKind.soundtrack => 'soundtrack',
    ThreadKind.sameSeries => 'same series',
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
    final now = DateTime.now().millisecondsSinceEpoch;
    (_trailVisits[_trailUids[_historyIndex!]] ??= {})[stop] = now + _visitClock++;
    return _trail = _withKept(TrailDto(rootQuery: trail.rootQuery, current: stop, branches: const [], kept: false, stops: [
      for (final node in trail.stops)
        _copyTrailStop(node,
          onPath: path.contains(node.index), isFork: (children[node.index] ?? 0) > 1,
          openedMs: stop != trail.current && node.index == stop ? PlatformInt64Util.from(now) : null,
          dwellMs: stop != trail.current && node.index == trail.current
            ? PlatformInt64Util.from(node.dwellMs.toInt() + now - node.openedMs.toInt()) : null,
        ),
    ], meetings: trail.meetings), _historyIndex!);
  }

  static StopDto _copyTrailStop(StopDto stop, {bool? onPath, bool? isFork, PlatformInt64? openedMs, PlatformInt64? dwellMs, List<String>? actions}) => StopDto(
    index: stop.index, parent: stop.parent, target: stop.target, title: stop.title,
    via: stop.via, viaSource: stop.viaSource, onPath: onPath ?? stop.onPath,
    isFork: isFork ?? stop.isFork, isPeek: stop.isPeek,
    openedMs: openedMs ?? stop.openedMs, dwellMs: dwellMs ?? stop.dwellMs, actions: actions ?? stop.actions,
  );

  void _recordTrailPlayed(TrailDto trail, int historyIndex, Set<int> played) {
    (_trailPlayed[_trailUids[historyIndex]] ??= <int>{}).addAll(played);
    _trail = _withKept(TrailDto(
      rootQuery: trail.rootQuery, current: trail.current, kept: trail.kept, name: trail.name,
      branches: trail.branches, meetings: trail.meetings,
      stops: [for (final stop in trail.stops)
        played.contains(stop.index) ? _copyTrailStop(stop, actions: [...stop.actions, 'played']) : stop,
      ],
    ), historyIndex);
  }

  @override
  Future<TrailDto?> trailBack() async {
    final trail = _trail;
    if (trail == null) return null;
    final parent = trail.stops.firstWhere((stop) => stop.index == trail.current).parent;
    if (parent != null) return trailGo(parent);
    final index = _historyIndex;
    if (index == null || index == 0) return null;
    _saveTrail();
    _loadTrail(index - 1);
    return trailGo(_trailHistory[index - 1].departure);
  }

  @override
  Future<TrailDto?> trailForward() async {
    final trail = _trail;
    if (trail == null) return null;
    final index = _historyIndex;
    if (index != null && index + 1 < _trailHistory.length && trail.current == _trailHistory[index].departure) {
      _saveTrail();
      _loadTrail(index + 1);
      return trailGo(0);
    }
    final visible = trail.stops.where((stop) => stop.parent == trail.current && !stop.isPeek).toList();
    final preferred = _forward[trail.current];
    final child = visible.where((stop) => stop.index == preferred);
    return child.isNotEmpty ? trailGo(child.first.index) : visible.isEmpty ? null : trailGo(visible.last.index);
  }

  @override
  Future<TrailDto?> trailSibling(int step) async {
    final trail = _trail;
    if (trail == null) return null;
    final stops = {for (final stop in trail.stops) stop.index: stop};
    var child = stops[trail.current]!;
    while (child.parent != null) {
      final parent = stops[child.parent]!;
      final siblings = trail.stops.where((stop) => stop.parent == parent.index && !stop.isPeek).toList();
      if (siblings.length > 1) {
        final next = siblings[(siblings.indexOf(child) + step.sign) % siblings.length];
        bool below(StopDto node) {
          while (node.index != next.index && node.parent != null) {
            node = stops[node.parent]!;
          }
          return node.index == next.index;
        }
        final visits = _trailVisits[_trailUids[_historyIndex!]]!;
        final candidates = trail.stops.where((stop) => !stop.isPeek && below(stop)).toList()
          ..sort((a, b) => (visits[b.index] ?? 0).compareTo(visits[a.index] ?? 0));
        return trailGo(candidates.first.index);
      }
      child = parent;
    }
    return null;
  }

  @override
  Future<TrailDto> pruneBranch(int leaf) async {
    final trail = await this.trail();
    if (trail == null) throw "there's no trail to prune";
    final branch = trail.branches.where((branch) => branch.leaf == leaf).firstOrNull;
    if (branch == null) throw 'Unknown branch';
    if (branch.current) throw 'cannot prune the current branch';
    if (!branch.prunable) throw 'cannot prune a branch with actions';
    final stops = {for (final stop in trail.stops) stop.index: stop};
    final removed = <int>{};
    StopDto? node = stops[leaf];
    while (node != null && node.index != branch.fork) {
      removed.add(node.index);
      node = stops[node.parent];
    }
    _forward.removeWhere((parent, child) => removed.contains(parent) || removed.contains(child));
    _trail = TrailDto(
      rootQuery: trail.rootQuery, current: trail.current, kept: trail.kept, name: trail.name, branches: const [],
      stops: trail.stops.where((stop) => !removed.contains(stop.index)).toList(),
      meetings: trail.meetings.where((pair) => !removed.contains(pair.$1) && !removed.contains(pair.$2)).toList(),
    );
    return trailGo(trail.current);
  }

  @override
  Future<int> playTrail(bool whole) async {
    final trail = _trail;
    if (trail == null) throw 'nothing on this trail has tracks to play';
    final stops = {for (final stop in trail.stops) stop.index: stop};
    final selected = <StopDto>[];
    if (whole) {
      void visit(StopDto stop) {
        selected.add(stop);
        for (final child in trail.stops.where((node) => node.parent == stop.index && !node.isPeek)) {
          visit(child);
        }
      }
      visit(trail.stops.firstWhere((stop) => stop.parent == null));
    } else {
      StopDto? stop = stops[trail.current];
      while (stop != null) {
        selected.insert(0, stop);
        stop = stops[stop.parent];
      }
    }
    final rows = <TrackRowDto>[];
    final tracks = <PlatformInt64>{};
    final played = <int>{};
    for (final stop in selected) {
      final found = switch (stop.target) {
        TargetDto_Release(:final id) => (await release(id)).rows,
        TargetDto_Work(:final id) => (await work(id)).rows,
        TargetDto_Game(:final id) => (await game(id)).rows,
        _ => const <TrackRowDto>[],
      };
      if (found.isNotEmpty) played.add(stop.index);
      rows.addAll(found.where((row) => tracks.add(row.trackId)));
    }
    if (rows.isEmpty) throw 'nothing on this trail has tracks to play';
    _playQueue(rows);
    _recordTrailPlayed(trail, _historyIndex!, played);
    return rows.length;
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
        'year', 'length', 'plays', 'dr', 'lufs', 'last', 'added', 'not', 'is', 'game', 'film', 'label', 'crate', 'work'].contains(key)) {
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
        'lufs' => RegExp(r'^[<>]?-?\d+(?:\.\d+)?(?:\.\.-?\d+(?:\.\d+)?)?$').hasMatch(value),
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
      'idiom' => word == _idiom(row),
      'format' => word == 'lossy' ? row.format == 'AAC' : word == 'flac' ? row.format.startsWith('FLAC') : false,
      'year' => _number(row.year?.toDouble() ?? 0, value),
      'plays' => _number(0, value),
      'dr' => row.dr != null && _number(row.dr!.toDouble(), value),
      'lufs' => row.loudness != null && _number(row.loudness!, value),
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
    if (column == ColumnDto.dr || column == ColumnDto.loudness) {
      final b = Uint32List(bins);
      var matched = 0;
      for (final index in _matching(query)) {
        final row = _sampleRows[index % _sampleRows.length];
        final value = column == ColumnDto.dr ? row.dr?.toDouble() : row.loudness;
        if (value == null || value < lo || value > hi) continue;
        b[((value - lo) / (hi - lo) * bins).floor().clamp(0, bins - 1)]++;
        matched++;
      }
      return HistogramDto(lo: lo, hi: hi, bins: b, matched: BigInt.from(matched));
    }
    // A plausible shape: most listening recent, a long tail back.
    final b = Uint32List.fromList(List.generate(bins, (i) => (40 + 400 * (i / bins) * (i / bins) + (i * 37 % 23) * 4).round()));
    return HistogramDto(lo: lo, hi: hi, bins: b, matched: BigInt.from(214));
  }

  @override
  Future<int> addRoot(String path) async {
    final id = _rootIds.putIfAbsent(path, () => _rootIds.length + 1);
    _roots[id] = path;
    _empty = false;
    _libraryChanged();
    return id;
  }

  @override
  Future<void> removeRoot(int id) async {
    if (_roots.remove(id) == null) throw 'No folder with id $id';
    _empty = _roots.isEmpty;
    _libraryChanged();
  }

  void _libraryChanged() {
    _libraryVersion += BigInt.one;
    _results.clear();
    _lists.clear();
    _statuses.add(_status);
  }

  @override
  SettingsDto settings() => _settings;

  @override
  Future<void> setSettings(SettingsDto s) async {
    _settings = s;
  }

  @override
  Future<LookupStatusDto> lookups() async => LookupStatusDto(
    setting: _settings.lookups,
    releases: _empty ? BigInt.zero : BigInt.from(212),
    recordings: _empty ? BigInt.zero : BigInt.from(1840),
    people: _empty ? BigInt.zero : BigInt.from(28),
    unidentified: _empty ? BigInt.zero : BigInt.from(40),
    matched: BigInt.zero,
    lookedUp: BigInt.zero, waiting: BigInt.zero, failed: BigInt.zero,
  );

  @override
  Future<void> setLookups(LookupsDto lookups) async {
    _settings = SettingsDto(light: _settings.light, outputDevice: _settings.outputDevice,
      exclusive: _settings.exclusive, lookups: lookups, level: _settings.level);
    _statuses.add(_status);
  }

  @override
  Future<List<OutputDeviceDto>> outputDevices() async => [
    OutputDeviceDto(id: 'speakers', name: 'MacBook Pro Speakers', isDefault: true,
      canBeExclusive: true, sampleRates: Uint32List.fromList([44100, 48000, 96000]), maxBits: 24),
    OutputDeviceDto(id: 'dac', name: 'RME ADI-2 DAC', isDefault: false,
      canBeExclusive: true, sampleRates: Uint32List.fromList([44100, 48000, 88200, 96000, 192000]), maxBits: 32),
  ];

  double _volume = 0.5;
  @override
  Future<VolumeDto> volume() async => VolumeDto(scalar: _volume, settable: true, muted: false);
  @override
  Future<VolumeDto> setVolume(double scalar) async {
    if (!scalar.isFinite || scalar < 0 || scalar > 1) throw 'Volume must be between 0 and 1';
    _volume = scalar;
    return volume();
  }

  @override
  Future<List<FolderSuggestionDto>> suggestFolders() async {
    final suggestions = [
      FolderSuggestionDto(path: '~/Music', label: 'Music', kind: FolderKindDto.music,
        audioFiles: BigInt.from(1014), more: false, note: 'includes your Apple Music library', asksPermission: false),
      FolderSuggestionDto(path: '~/Library/Application Support/Steam/steamapps/music', label: 'Steam soundtracks', kind: FolderKindDto.steam,
        audioFiles: BigInt.from(206), more: false, note: '', asksPermission: false),
      const FolderSuggestionDto(path: '/Volumes/Music NAS', label: 'Music NAS', kind: FolderKindDto.volume,
        more: false, note: '', asksPermission: true),
    ];
    return suggestions.where((s) => !_roots.values.any((root) => s.path == root || s.path.startsWith('$root/'))).toList();
  }

  @override
  Future<RowsDto> rows(String query, ViewDto view, int offset, int limit) async {
    final (indices, items, releases) = _list(query, view);
    final start = offset.clamp(0, items.length);
    final count = limit.clamp(0, items.length - start);
    return RowsDto(
      total: BigInt.from(items.length),
      tracks: BigInt.from(indices.length),
      releases: BigInt.from(releases),
      offset: BigInt.from(start),
      items: items.sublist(start, start + count),
    );
  }

  (List<int>, List<ItemDto>, int) _list(String query, ViewDto view) {
    final key = (query, view);
    final cached = _lists.remove(key);
    if (cached != null) {
      _lists[key] = cached;
      return cached;
    }
    final indices = [..._matching(query)];
    final groups = <int, List<int>>{};
    for (final index in indices) {
      groups.putIfAbsent((index ~/ 12) % _releases.length + 1, () => []).add(index);
    }
    final items = <ItemDto>[];
    if (view.group) {
      final headers = <int, GroupDto>{};
      for (final entry in groups.entries) {
        entry.value.sort((a, b) {
          final number = (a % 12).compareTo(b % 12);
          return number != 0 ? number : a.compareTo(b);
        });
        final rows = entry.value.map(_row).toList();
        final first = rows.first;
        headers[entry.key] = GroupDto(
          releaseId: first.releaseId, title: first.album,
          albumArtist: first.albumArtist, albumArtistId: first.albumArtistId,
          year: first.year, idiom: _idiom(first), tracks: rows.length,
          lengthMs: rows.fold(BigInt.zero, (total, row) => total + (row.lengthMs ?? BigInt.zero)),
          format: [if (rows.any((row) => row.format != 'AAC')) 'Lossless, up to 16/48', if (rows.any((row) => row.format == 'AAC')) 'Lossy'].join(' · '),
        );
      }
      final releases = groups.keys.toList()..sort((a, b) {
        final left = headers[a]!, right = headers[b]!;
        final order = switch (view.sort) {
          SortKeyDto.library_ || SortKeyDto.artist => a.compareTo(b),
          SortKeyDto.title || SortKeyDto.album => _fold(left.title).compareTo(_fold(right.title)),
          SortKeyDto.year => (left.year ?? 0).compareTo(right.year ?? 0),
          SortKeyDto.length => left.lengthMs.compareTo(right.lengthMs),
          SortKeyDto.format => (left.format.startsWith('Lossless') ? 1 : 5).compareTo(right.format.startsWith('Lossless') ? 1 : 5),
        };
        return order == 0 ? a.compareTo(b) : view.descending ? -order : order;
      });
      indices.clear();
      for (final release in releases) {
        items.add(ItemDto.group(headers[release]!));
        for (final index in groups[release]!) {
          items.add(ItemDto.track(ordinal: indices.length, row: _row(index)));
          indices.add(index);
        }
      }
    } else {
      final text = switch (view.sort) {
        SortKeyDto.title => [for (final row in _sampleRows) _fold(row.title)],
        SortKeyDto.artist => [for (final row in _sampleRows) _fold(row.artist ?? row.albumArtist ?? '')],
        SortKeyDto.album => [for (final row in _sampleRows) _fold(row.album)],
        _ => const <String>[],
      };
      if (view.sort != SortKeyDto.library_ || view.descending) {
        indices.sort((a, b) {
          final left = _sampleRows[a % _sampleRows.length], right = _sampleRows[b % _sampleRows.length];
          final order = switch (view.sort) {
            SortKeyDto.library_ => a.compareTo(b),
            SortKeyDto.title || SortKeyDto.artist || SortKeyDto.album => text[a % text.length].compareTo(text[b % text.length]),
            SortKeyDto.year => (left.year ?? 0).compareTo(right.year ?? 0),
            SortKeyDto.length => (a * 7919 % 240000).compareTo(b * 7919 % 240000),
            SortKeyDto.format => (left.format == 'AAC' ? 5 : 1).compareTo(right.format == 'AAC' ? 5 : 1),
          };
          return order == 0 ? a.compareTo(b) : view.descending ? -order : order;
        });
      }
      for (var ordinal = 0; ordinal < indices.length; ordinal++) {
        items.add(ItemDto.track(ordinal: ordinal, row: _row(indices[ordinal])));
      }
    }
    final result = (indices, items, groups.length);
    _lists[key] = result;
    if (_lists.length > 8) _lists.remove(_lists.keys.first);
    return result;
  }

  static String _idiom(TrackRowDto row) => switch (row.albumArtist) {
    'Yasunori Mitsuda' => 'score',
    'Bill Evans Trio' => 'session',
    _ => 'album',
  };

  @override
  Future<FacetsDto> facets(String query) async {
    final clauses = _clauses(query), tokens = _tokens(query);
    int column((String, String, bool) clause) => clause.$3 ? -1 : switch (clause.$1) {
      'idiom' => 0, 'by' => 1, 'release' => 2, _ => -1,
    };
    String before(int at) => [
      for (var i = 0; i < tokens.length; i++)
        if (column(clauses[i]) < at) tokens[i],
    ].join(' ');
    FacetColumnDto facetColumn(int at) {
      final allQuery = before(at);
      final indices = _matching(allQuery);
      final entries = <String, (int, int)>{};
      for (final index in indices) {
        final row = _sampleRows[index % _sampleRows.length];
        final names = switch (at) {
          0 => {_idiom(row): const ['album', 'song', 'work', 'session', 'score', 'set', 'spoken'].indexOf(_idiom(row))},
          1 => {
            if (row.artist != null) row.artist!: row.artistId!.toInt(),
            if (row.albumArtist != null) row.albumArtist!: row.albumArtistId!.toInt(),
          },
          _ => {row.album: row.releaseId.toInt()},
        };
        for (final entry in names.entries) {
          entries[entry.key] = (entry.value, (entries[entry.key]?.$2 ?? 0) + 1);
        }
      }
      final names = entries.keys.toList()..sort((a, b) => at == 0
          ? entries[a]!.$1.compareTo(entries[b]!.$1) : _fold(a).compareTo(_fold(b)));
      return FacetColumnDto(allQuery: allQuery, tracks: indices.length, entries: [
        for (final name in names) (() {
          final selected = clauses.any((clause) => column(clause) == at && clause.$2.toLowerCase() == name.toLowerCase());
          final next = selected
              ? [for (var i = 0; i < tokens.length; i++)
                  if (!(column(clauses[i]) == at && clauses[i].$2.toLowerCase() == name.toLowerCase())) tokens[i]].join(' ')
              : '$allQuery ${['idiom', 'by', 'release'][at]}:${at == 0 ? name : _quote(name)}'.trim();
          return FacetDto(
            id: PlatformInt64Util.from(entries[name]!.$1),
            name: at == 0 ? const {'album': 'Albums', 'song': 'Songs', 'work': 'Works', 'session': 'Sessions', 'score': 'Scores', 'set': 'Sets', 'spoken': 'Spoken'}[name]! : name,
            tracks: entries[name]!.$2, selected: selected, query: next,
          );
        })(),
      ]);
    }
    return FacetsDto(idioms: facetColumn(0), people: facetColumn(1), releases: facetColumn(2));
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
      id: id, title: first.album, cover: null, artist: first.albumArtist, year: first.year,
      artistLinks: first.albumArtistId == null ? [] : [
        ThreadDto(kind: ThreadKind.albumArtist, label: 'album artist', source: 'tags', provider: 'local_tags',
          to: TargetDto.person(id: first.albumArtistId!), title: first.albumArtist!, detail: ''),
      ],
      idiom: first.albumArtist == 'Yasunori Mitsuda' ? 'Score' : first.albumArtist == 'Bill Evans Trio' ? 'Session' : 'Album',
      tracks: rows.length, discs: rows.map((row) => row.disc).toSet().length,
      lengthMs: length, formats: sortedFormats, rows: rows,
      dr: rows.where((row) => row.dr != null).map((row) => row.dr!).reduce((a, b) => a + b) ~/ rows.where((row) => row.dr != null).length,
      loudnessLufs: rows.where((row) => row.loudness != null).map((row) => row.loudness!).reduce((a, b) => a + b) / rows.where((row) => row.loudness != null).length,
      rowWorks: [for (final row in rows) row.trackId.toInt() == 1 ? _workThread(ThreadKind.recordingOf) : null],
      games: id.toInt() == 1 ? [_gameThread(ThreadKind.soundtrackOf)] : [],
      plays: BigInt.from(id.toInt() == 1 ? 212 : 0), lastPlayedMs: id.toInt() == 1 ? PlatformInt64Util.from(_memoryEvening.millisecondsSinceEpoch) : null,
      credits: [
        if (first.albumArtistId != null)
          ThreadDto(kind: ThreadKind.albumArtist, label: 'album artist', source: 'tags', provider: 'local_tags',
            to: TargetDto.person(id: first.albumArtistId!), title: first.albumArtist!, detail: ''),
        for (final entry in artists.entries)
          if (entry.key != first.albumArtistId || entry.value.length != rows.length)
            ThreadDto(kind: ThreadKind.by, label: 'by', source: 'tags', provider: 'local_tags',
              to: TargetDto.person(id: entry.key), title: entry.value.first.artist!,
              detail: entry.value.map((row) => '${row.disc}-${row.number.toString().padLeft(2, '0')}').toSet().join(', ')),
        if (id.toInt() == 1)
          ThreadDto(kind: ThreadKind.composedBy, label: 'composed by', source: 'tags', provider: 'local_tags',
            to: TargetDto.person(id: _personId('Yasunori Mitsuda')), title: 'Yasunori Mitsuda', detail: '1 track'),
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
      final thread = ThreadDto(kind: ThreadKind.appearsOn, label: 'appears on', source: 'tags', provider: 'local_tags',
        to: TargetDto.release(id: first.releaseId), title: first.album,
        detail: '${first.year} · ${own ? '${rows.length} tracks' : '$credited of ${rows.length} tracks'}');
      (own ? releases : appearsOn).add(thread);
      final people = {for (final row in rows) ...[row.artistId, row.albumArtistId]}..remove(null)..remove(id);
      for (final person in people) {
        shared.update(person!, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    final coworkers = shared.keys.toList()..sort((a, b) => shared[b]!.compareTo(shared[a]!));
    return PersonDto(id: id, name: name, tracks: tracks, releases: releases, appearsOn: appearsOn,
      roles: name == 'Yasunori Mitsuda' ? [
        CreditSectionDto(title: 'Composed', threads: [
          ThreadDto(kind: ThreadKind.composedBy, label: 'composed by', source: 'tags', provider: 'local_tags',
            to: TargetDto.release(id: PlatformInt64Util.from(1)), title: _releases.first.$1,
            detail: '1998 · 1 of ${_releaseRows(PlatformInt64Util.from(1)).length} tracks'),
        ]),
      ] : [],
      works: name == 'Yasunori Mitsuda' ? [_workThread(ThreadKind.composedBy, detail: '1 track')] : [],
      games: index == 0 ? [_gameThread(ThreadKind.scored)] : [],
      groups: name == 'Joanne Hogg' ? [
        CreditSectionDto(title: 'Member of', threads: [
          ThreadDto(kind: ThreadKind.hasMember, label: 'has member', source: 'MB', provider: 'musicbrainz',
            to: TargetDto.person(id: _personId('Iona')), title: 'Iona', detail: ''),
        ]),
      ] : [],
      plays: BigInt.from(index == 0 ? 1240 : 0), lastPlayedMs: index == 0 ? PlatformInt64Util.from(_memoryEvening.millisecondsSinceEpoch) : null, workedWith: [
      for (final person in coworkers.take(12))
        ThreadDto(kind: ThreadKind.workedWith, label: 'worked with', source: 'tags', provider: 'local_tags',
          to: TargetDto.person(id: person), title: _personNames[person.toInt() - 1],
          detail: '${shared[person]} ${shared[person] == 1 ? 'release' : 'releases'} together'),
    ]);
  }

  static ThreadDto _workThread(ThreadKind kind, {String detail = ''}) => ThreadDto(
    kind: kind, label: _threadLabel(kind), source: 'tags', provider: 'local_tags',
    to: TargetDto.work(id: PlatformInt64Util.from(1)), title: _releases.first.$4.first, detail: detail,
  );

  @override
  Future<WorkDto> work(PlatformInt64 id) async {
    if (_empty || id.toInt() != 1) throw 'Work no longer exists';
    final row = _row(0);
    return WorkDto(
      id: id, title: _releases.first.$4.first, composer: 'Yasunori Mitsuda',
      composerLinks: [
        ThreadDto(kind: ThreadKind.composedBy, label: 'composed by', source: 'tags', provider: 'local_tags',
          to: TargetDto.person(id: _personId('Yasunori Mitsuda')), title: 'Yasunori Mitsuda', detail: ''),
      ],
      parts: [], rows: [row], lengthMs: row.lengthMs ?? BigInt.zero, plays: BigInt.zero,
      recordingsKnown: BigInt.two,
      others: [
        ThreadDto(kind: ThreadKind.by, label: 'by', source: 'MB', provider: 'musicbrainz',
          to: TargetDto.person(id: _personId('Yasunori Mitsuda')), title: 'Chrono Cross — live', detail: 'Yasunori Mitsuda · 3:42'),
      ],
    );
  }

  @override
  Future<void> playWork(PlatformInt64 id, int index) async {
    final rows = (await work(id)).rows;
    if (index < 0 || index >= rows.length) throw RangeError.index(index, rows);
    _playQueue(rows.sublist(index));
  }

  static ThreadDto _gameThread(ThreadKind kind) => ThreadDto(
    kind: kind, label: _threadLabel(kind), source: 'Wikidata', provider: 'wikidata',
    to: TargetDto.game(id: PlatformInt64Util.from(1)), title: 'Lantern Vale', detail: '1998',
  );

  @override
  Future<GameDto> game(PlatformInt64 id) async {
    if (_empty || id.toInt() != 1) throw 'Game no longer exists';
    final release = await this.release(PlatformInt64Util.from(1));
    return GameDto(
      id: id, title: 'Lantern Vale', year: 1998, developers: 'Copper Finch',
      platforms: 'Pocket Station', series: 'Lantern Vale',
      composers: [
        ThreadDto(kind: ThreadKind.composedBy, label: 'composed by', source: 'Wikidata', provider: 'wikidata',
          to: TargetDto.person(id: _personId(_personNames.first)), title: _personNames.first, detail: ''),
      ],
      soundtracks: [
        ThreadDto(kind: ThreadKind.soundtrack, label: 'soundtrack', source: 'Wikidata', provider: 'wikidata',
          to: TargetDto.release(id: release.id), title: release.title, detail: '${release.year} · ${release.tracks} tracks'),
      ],
      sameSeries: [], rows: release.rows, lengthMs: release.lengthMs,
      plays: release.plays, lastPlayedMs: release.lastPlayedMs,
    );
  }

  @override
  Future<void> playGame(PlatformInt64 id, int index) async {
    final rows = (await game(id)).rows;
    if (index < 0 || index >= rows.length) throw RangeError.index(index, rows);
    _playQueue(rows.sublist(index));
  }

  @override
  Future<void> playRelease({required PlatformInt64 id, required int index, int? fromStop}) async {
    final rows = _releaseRows(id);
    if (index < 0 || index >= rows.length) throw RangeError.index(index, rows);
    _playQueue(rows.sublist(index));
    final historyIndex = _historyIndex;
    final trail = _trail;
    if (fromStop != null && historyIndex != null && trail != null &&
        trail.stops.any((stop) => stop.index == fromStop && stop.target == TargetDto.release(id: id))) {
      _recordTrailPlayed(trail, historyIndex, {fromStop});
    }
  }

  @override
  Future<List<ResumeDto>> resumePoints(int limit) async {
    if (_empty) return [];
    final now = DateTime.now().millisecondsSinceEpoch;
    return [
      for (final (index, position) in [(3, 126000), (14, 47000)])
        (() {
          final row = _row(index);
          return ResumeDto(releaseId: row.releaseId, title: row.album, credit: row.albumArtist,
            recordingId: row.trackId, recordingTitle: row.title, disc: row.disc, number: row.number,
            positionMs: BigInt.from(position), lengthMs: row.lengthMs, idiom: _idiom(row),
            updatedAt: PlatformInt64Util.from(now - index * 60000));
        })(),
    ].take(limit).toList();
  }

  @override
  Future<void> pickUp(PlatformInt64 releaseId) async {
    final points = await resumePoints(20);
    final saved = points.where((point) => point.releaseId == releaseId).firstOrNull;
    if (saved == null) throw 'That release has no resume point';
    final rows = _releaseRows(releaseId);
    final at = rows.indexWhere((row) => row.trackId == saved.recordingId);
    if (at < 0) throw 'The saved recording is unavailable';
    _playQueue(rows.sublist(at));
    final position = saved.idiom == 'score' || saved.idiom == 'set' ? saved.positionMs : BigInt.zero;
    final anchor = _state.anchor!;
    _state = _with(AnchorDto(item: anchor.item, positionMs: position.toDouble(), rate: 1));
    _now.add(_state);
  }

  /// Tokens count up across queues, as the engine's do; the opening Now is 1.
  final _queue = <(BigInt, TrackRowDto)>[];
  int _cursor = 0;
  BigInt _nextToken = BigInt.two;

  /// Why the queue is playing, when Play something chose it; other plays clear it.
  String? _why;

  void _playQueue(List<TrackRowDto> rows, {String? why}) {
    _why = why;
    _queue.clear();
    for (final row in rows) {
      _queue.add((_nextToken, row));
      _nextToken += BigInt.one;
    }
    _cursor = 0;
    _playRow(_queue.first);
  }

  /// The plates' picks over the fake releases: dormant Evans, Creid from the
  /// trail, Open Sky never played. Wording follows the core's PickDto.
  @override
  Future<List<PickDto>> picks(int limit) async {
    if (_empty) return [];
    PickDto pick(int id, String label, String reason, String plan) {
      final rows = _releaseRows(PlatformInt64Util.from(id));
      final minutes = rows.fold<int>(0, (sum, row) => sum + (row.lengthMs?.toInt() ?? 0)) ~/ 60000;
      final length = minutes >= 60 ? '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')}' : '$minutes min';
      return PickDto(releaseId: PlatformInt64Util.from(id), title: _releases[id - 1].$1, credit: _releases[id - 1].$2,
        label: label, reason: reason, plan: plan, meta: '${rows.length} tracks · $length · ${rows.first.format}');
    }
    return [
      pick(3, 'Dormant · 2 years', '96 plays, then nothing for 2 years.', 'The whole date, in order.'),
      pick(8, 'From your latest trail', "You reached it on Corridors of Time → Clannad and haven't played it through.", 'The whole album, in order.'),
      pick(6, 'Never played', 'In your library for 3 years, never played through.', 'The whole album, in order.'),
    ].take(limit).toList();
  }

  @override
  Future<PickDto?> playSomething() async {
    final pick = (await picks(1)).firstOrNull;
    if (pick == null) return null;
    _playQueue(_releaseRows(pick.releaseId), why: _pickWhy(pick));
    return pick;
  }

  @override
  Future<PickDto> playPick(PlatformInt64 releaseId) async {
    final pick = (await picks(3)).where((pick) => pick.releaseId == releaseId).firstOrNull;
    if (pick == null) throw 'that pick is gone';
    _playQueue(_releaseRows(pick.releaseId), why: _pickWhy(pick));
    return pick;
  }

  static String _pickWhy(PickDto pick) => '${pick.label} · ${pick.reason.replaceAll(RegExp(r'\.$'), '')}';

  @override
  Future<List<ZoneDto>> zones() async => [
    for (final device in await outputDevices())
      ZoneDto(
        id: 'local:${device.id}', name: device.name,
        detail: device.isDefault ? 'This Mac · default output' : 'This Mac',
        verdict: !_settings.exclusive ? '◐ shared with macOS'
          : device.sampleRates.last < 176400 ? '◐ refuses above ${device.sampleRates.last ~/ 1000} kHz' : '● bit-perfect',
        warn: !_settings.exclusive || device.sampleRates.last < 176400,
        current: _settings.outputDevice == null ? device.isDefault : _settings.outputDevice == device.id,
      ),
  ];

  @override
  Future<void> playOn(String zone) async {
    final id = zone.replaceFirst('local:', '');
    if (!(await outputDevices()).any((device) => device.id == id)) throw 'no zone $zone';
    _settings = SettingsDto(light: _settings.light, outputDevice: id, exclusive: _settings.exclusive, lookups: _settings.lookups, level: _settings.level);
  }

  @override
  Future<UpNextDto> upNext(int limit) async {
    final rest = _cursor + 1 < _queue.length ? _queue.sublist(_cursor + 1) : const <(BigInt, TrackRowDto)>[];
    return UpNextDto(
      items: [
        for (final (token, row) in rest.take(limit))
          UpNextItemDto(
            token: token,
            trackId: row.trackId,
            title: row.title,
            subtitle: '${row.artist} · ${row.album}',
            lengthMs: row.lengthMs,
          ),
      ],
      remaining: BigInt.from(rest.length),
    );
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
      dr: index % 11 == 0 ? null : 7 + index % 12,
      loudness: index % 11 == 0 ? null : -10.0 - index % 160 / 10,
      path: '/Music/${release.$1}/$number.flac',
    );
  }

  @override
  Future<void> playResults(String query, ViewDto view, int index) async {
    final indices = _list(query, view).$1;
    if (index < 0 || index >= indices.length) throw RangeError.index(index, null, 'index', null, indices.length);
    _playQueue([for (final i in indices.skip(index).take(50)) _row(i)]);
  }

  void _playRow((BigInt, TrackRowDto) item) {
    final (token, row) = item;
    _state = NowDto(
      trackId: row.trackId,
      releaseId: row.releaseId,
      light: _sampleLight,
      title: row.title,
      subtitle: '${row.artist} · ${row.album}',
      why: _why,
      anchor: AnchorDto(item: token, positionMs: 0, rate: 1),
      lengthMs: row.lengthMs,
      body: row.dr == null ? null : _body(row.lengthMs!, row.trackId.toInt()),
      dr: row.dr,
      loudnessLufs: row.loudness,
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
  Future<void> flushMemory() async {}

  @override
  Future<void> transport(TransportDto cmd) async {
    final a = _state.anchor;
    if (a == null) return;
    final pos = a.positionMs;
    switch (cmd) {
      case TransportDto_Next() || TransportDto_Previous() when _queue.isEmpty:
        return;
      case TransportDto_Next():
        if (_cursor + 1 < _queue.length) _playRow(_queue[++_cursor]);
        return;
      case TransportDto_Previous():
        if (pos <= 3000 && _cursor > 0) _cursor--;
        _playRow(_queue[_cursor]);
        return;
      default:
    }
    _state = switch (cmd) {
      TransportDto_Pause() => _with(AnchorDto(item: a.item, positionMs: pos, rate: 0)),
      TransportDto_Resume() => _with(AnchorDto(item: a.item, positionMs: pos, rate: 1)),
      TransportDto_FromStart() => _with(AnchorDto(item: a.item, positionMs: 0, rate: a.rate)),
      TransportDto_Seek(:final ms) => _with(AnchorDto(item: a.item, positionMs: ms.toDouble(), rate: a.rate)),
      _ => _state,
    };
    _now.add(_state);
  }

  NowDto _with(AnchorDto a) => NowDto(
        trackId: _state.trackId,
        releaseId: _state.releaseId,
        cover: _state.cover,
        light: _state.light,
        title: _state.title,
        subtitle: _state.subtitle,
        why: _state.why,
        anchor: a,
        lengthMs: _state.lengthMs,
        body: _state.body,
        loudnessLufs: _state.loudnessLufs,
        dr: _state.dr,
        path: _state.path,
        fidelity: _state.fidelity,
        error: _state.error,
      );

  DateTime get _memoryEvening {
    final now = DateTime.now();
    final evening = DateTime(now.year, now.month, now.day, 23, 14);
    return evening.isAfter(now) ? evening.subtract(const Duration(days: 1)) : evening;
  }

  @override
  Future<List<ListenDto>> history(int limit) async {
    if (_empty) return [];
    final evening = _memoryEvening;
    final entries = [
      (2, 23, 10, 226000, 391000, 'Small Two of Pieces'),
      (86, 22, 58, 180000, 180000, 'Creid, track 3'),
      (1, 22, 41, 313000, 313000, 'Stars of Tears'),
      (36, 21, 31, 366000, 183000, 'Corridors of Time'),
    ];
    return [
      for (final (index, hour, minute, played, length, title) in entries.take(limit))
        (() {
          final row = _row(index);
          return ListenDto(
            uid: 'fake-listen-$index', trackId: row.trackId, recordingId: row.trackId,
            releaseId: row.releaseId, title: title,
            credit: index == 1 ? _row(2).artist : row.artist, releaseTitle: row.album,
            startedAtMs: PlatformInt64Util.from(DateTime(evening.year, evening.month, evening.day, hour, minute).millisecondsSinceEpoch),
            playedMs: BigInt.from(played), lengthMs: BigInt.from(length), counted: true,
          );
        })(),
    ];
  }

  @override
  Future<List<PlayedDto>> mostPlayed(int days, int limit) async {
    if (_empty || days == 0) return [];
    final last = PlatformInt64Util.from(_memoryEvening.millisecondsSinceEpoch);
    return [
      for (final (index, plays, title) in [(2, 14, 'Small Two of Pieces'), (36, 11, 'Corridors of Time')])
        (() {
          final row = _row(index);
          return PlayedDto(trackId: row.trackId, recordingId: row.trackId, releaseId: row.releaseId,
            title: title, credit: row.artist, releaseTitle: row.album,
            plays: BigInt.from(plays), lastPlayedMs: last);
        })(),
      PlayedDto(trackId: PlatformInt64Util.from(48211), recordingId: PlatformInt64Util.from(48211),
        releaseId: PlatformInt64Util.from(9), title: 'Allegretto', credit: 'Kleiber', releaseTitle: 'Beethoven 7',
        plays: BigInt.from(6), lastPlayedMs: last),
    ].take(limit).toList();
  }

  @override
  Future<List<DormantDto>> dormant(int limit) async {
    if (_empty) return [];
    final now = DateTime.now().millisecondsSinceEpoch;
    return [
      for (final (id, title, credit, plays, days) in [
        (10, 'Sunday at the Village Vanguard', _releases[2].$2, 96, 730),
        (11, 'Outer Wilds', null, 18, 548),
        (12, 'Gould Goldberg 1955', 'Gould', 31, 1095),
      ])
        DormantDto(releaseId: PlatformInt64Util.from(id), title: title, credit: credit,
          plays: BigInt.from(plays), lastPlayedMs: PlatformInt64Util.from(now - days * 86400000)),
    ].take(limit).toList();
  }
}
