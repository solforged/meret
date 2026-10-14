import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64Util;

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
  Stream<StatusDto> status() => Stream.value(StatusDto(
        sources: const [
          SourceDto(name: 'This Mac', detail: '48,210', ok: true),
          SourceDto(name: 'Music Assistant', detail: '6 providers', ok: true),
          SourceDto(name: 'Spotify', detail: 'Connect', ok: true),
          SourceDto(name: 'Roon', detail: '1 of 2 zones', ok: false),
        ],
        jobs: [JobDto(verb: 'analysing', done: BigInt.from(1204), total: BigInt.from(3880))],
        guessed: BigInt.from(312),
        newLeads: BigInt.from(14),
        tracks: BigInt.from(48210),
        libraryVersion: BigInt.one,
      ));

  @override
  Future<TrailDto?> trail() async => const TrailDto(
        current: 4,
        stops: [
          StopDto(index: 0, entity: 'recording:Corridors of Time', onPath: true, isFork: false, isPeek: false),
          StopDto(index: 1, parent: 0, entity: 'agent:Yasunori Mitsuda', via: 'composed by', onPath: true, isFork: true, isPeek: false),
          StopDto(index: 2, parent: 1, entity: 'release:Xenogears', via: 'scored', onPath: true, isFork: true, isPeek: false),
          StopDto(index: 3, parent: 2, entity: 'agent:Joanne Hogg', via: 'sung by', onPath: true, isFork: false, isPeek: false),
          StopDto(index: 4, parent: 3, entity: 'agent:Iona', via: 'member of', onPath: true, isFork: false, isPeek: false),
          StopDto(index: 5, parent: 2, entity: 'release:Creid', via: 'arranged as', onPath: false, isFork: false, isPeek: false),
          StopDto(index: 6, parent: 1, entity: 'agent:Nobuo Uematsu', via: 'worked with', onPath: false, isFork: false, isPeek: false),
        ],
        meetings: [],
      );

  @override
  QueryDto parse(String input) => QueryDto(kind: QueryKind.search, canonical: input.trim());

  @override
  Future<HistogramDto> histogram(ColumnDto column, String query, double lo, double hi, int bins) async {
    // A plausible shape: most listening recent, a long tail back.
    final b = Uint32List.fromList(List.generate(bins, (i) => (40 + 400 * (i / bins) * (i / bins) + (i * 37 % 23) * 4).round()));
    return HistogramDto(lo: lo, hi: hi, bins: b, matched: BigInt.from(214));
  }

  @override
  Future<int> addRoot(String path) async => 1;

  @override
  Future<RowsDto> rows(String query, int offset, int limit) async {
    final start = offset.clamp(0, 48210);
    final count = limit.clamp(0, 48210 - start);
    return RowsDto(
      total: BigInt.from(48210),
      offset: BigInt.from(start),
      rows: List.generate(count, (i) => _row(start + i)),
    );
  }

  TrackRowDto _row(int index) {
    const releases = [
      ('Xenogears Original Soundtrack', 'Yasunori Mitsuda', 1998, ['The Beginning and the End', 'Stars of Tears', 'Small Two of Pieces ~Broken Pieces~']),
      ('Beyond These Shores', 'Iona', 1993, ['Prayer on the Mountain', 'Treasure', 'Beyond These Shores']),
      ('Waltz for Debby', 'Bill Evans Trio', 1961, ['My Foolish Heart', 'Waltz for Debby', 'Some Other Time']),
      ('Chrono Trigger', 'Yasunori Mitsuda', 1995, ['Corridors of Time', 'Wind Scene', 'To Far Away Times']),
      ('The Book of Kells', 'Iona', 1992, ['Kells', 'Revelation', 'Eternity']),
    ];
    final release = releases[(index ~/ 12) % releases.length];
    final number = index % 12 + 1;
    return TrackRowDto(
      trackId: PlatformInt64Util.from(index + 1),
      title: release.$4[index % release.$4.length],
      artist: index % 60 == 2 ? 'Joanne Hogg' : release.$2,
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
    if (index < 0 || index >= 48210) throw RangeError.index(index, null, 'index', null, 48210);
    final row = _row(index);
    _state = NowDto(
      title: row.title,
      subtitle: '${row.artist} · ${row.album}',
      anchor: AnchorDto(item: BigInt.from(index + 1), positionMs: 0, rate: 1),
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
    final a = _state.anchor!;
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
