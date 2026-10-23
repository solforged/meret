import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/main.dart';
import 'package:meret/panes/front_pane.dart';
import 'package:meret/panes/front_memory.dart';
import 'package:meret/panes/person_pane.dart';
import 'package:meret/settings/settings_window.dart';
import 'package:meret/shell/status_line.dart';
import 'package:meret/theme/tokens.dart';

void main() {
  testWidgets('Allow answers the Front question and membership follows its provider', (tester) async {
    final core = _LookupCore();
    _size(tester, const Size(1400, 1100));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: FrontPane(
      core: core, memoryVersion: 0, onQuery: (_) {},
    ))));
    await tester.pump();
    await tester.pump();
    expect(find.text('Lookups'), findsOneWidget);
    final frontCalls = core.frontCalls;
    await tester.ensureVisible(find.text('Allow'));
    await tester.tap(find.text('Allow'));
    await tester.pump();
    await tester.pump();
    expect(core.answers, [LookupsDto.allowed]);
    expect(core.frontCalls, greaterThan(frontCalls));
    expect(find.text('Lookups'), findsNothing);

    final person = (await core.search('Joanne Hogg')).people.single;
    final trail = await core.startTrail(TargetDto.person(id: person.id));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PersonPane(
      core: core, id: person.id,
      onFollow: (to, kind, provider) async { await core.follow(trail.current, to, kind, provider); },
    ))));
    await tester.pump();
    expect(find.text('Member of'), findsOneWidget);
    final member = (await core.person(person.id)).groups.single.threads.single;
    await tester.ensureVisible(find.text(member.title));
    await tester.tap(find.text(member.title));
    await tester.pump();
    await tester.pump();
    expect(core.providers, ['musicbrainz']);
    final followed = (await core.trail())!;
    expect(followed.stops[followed.current].target, member.to);
    expect(followed.stops[followed.current].viaSource, 'MB');
  });

  testWidgets('Not now defers the Lookups question for this run only', (tester) async {
    final core = _LookupCore();
    _size(tester, const Size(1400, 1100));
    Widget front() => MaterialApp(home: Scaffold(body: FrontPane(
      key: UniqueKey(), core: core, memoryVersion: 0, onQuery: (_) {},
    )));
    await tester.pumpWidget(front());
    await tester.pump();
    await tester.pump();
    expect(find.text('Lookups'), findsOneWidget);

    await tester.ensureVisible(find.text('Not now'));
    await tester.tap(find.text('Not now'));
    await tester.pump();
    await tester.pump();
    expect(core.answers, isEmpty);
    expect(find.text('Lookups'), findsNothing);
    expect(find.text('Albums with two editions'), findsOneWidget);

    await tester.pumpWidget(front());
    await tester.pump();
    await tester.pump();
    expect(find.text('Lookups'), findsOneWidget);
    expect((await core.lookups()).setting, LookupsDto.unasked);
  });

  testWidgets('format bars share the sum of the format counts', (tester) async {
    final core = _CopiesCore();
    _size(tester, const Size(1400, 1100));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: FrontPane(
      core: core, memoryVersion: 0, onQuery: (_) {},
    ))));
    await tester.pump();
    await tester.pump();

    for (final label in ['Lossless', 'Lossy']) {
      final bar = find.descendant(
        of: find.ancestor(of: find.text(label), matching: find.byType(FrontDoor)),
        matching: find.byType(FractionallySizedBox),
      );
      expect(tester.widget<FractionallySizedBox>(bar).widthFactor, 0.5, reason: label);
    }
  });

  testWidgets('an empty Front shows suggestions and adds the selected path', (tester) async {
    final core = _RecordingEmptyCore();
    final suggestions = await core.suggestFolders();
    await _surface(tester, core);

    final counted = suggestions.where((suggestion) => suggestion.audioFiles != null).length;
    expect(counted, lessThan(suggestions.length));
    expect(find.text('Meret found $counted places with music'), findsOneWidget);
    for (final suggestion in suggestions) {
      expect(find.text(suggestion.label), findsOneWidget);
      expect(find.text(suggestion.path), findsOneWidget);
      if (suggestion.note.isNotEmpty) expect(find.text(suggestion.note), findsOneWidget);
    }
    expect(find.text('macOS will ask for access'), findsWidgets);
    expect(find.text('Bring your history'), findsOneWidget);
    expect(find.text('Connect a service'), findsOneWidget);
    expect(find.ancestor(of: find.text('Connect a service'), matching: find.byType(FrontDoor)), findsNothing);

    await tester.tap(find.text(suggestions.first.label));
    await tester.pump();
    await tester.pump();

    expect(core.addedPaths, [suggestions.first.path]);
    expect((await core.front()).roots.single.path, suggestions.first.path);
    expect(find.text('Choose a folder…'), findsNothing);
    expect(find.text('+ Add folder'), findsOneWidget);
  });

  testWidgets('the welcome headline waits for the folder look', (tester) async {
    final core = _SlowSuggestionsCore();
    _size(tester, const Size(1400, 1100));
    await tester.pumpWidget(MaterialApp(home: SettingsScope(
      core: core,
      onChanged: (_) {},
      child: Scaffold(body: FrontPane(core: core, memoryVersion: 0, onQuery: (_) {})),
    )));
    await tester.pump();
    await tester.pump();
    expect(find.text('Looking for music folders…'), findsOneWidget);
    expect(find.textContaining('Start with'), findsNothing);
    expect(find.textContaining('Meret found'), findsNothing);

    core.found.complete(const [
      FolderSuggestionDto(path: '/Volumes/Data', label: 'Data', kind: FolderKindDto.volume, more: false, note: '', asksPermission: true),
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.text('Looking for music folders…'), findsNothing);
    expect(find.text('Start with a music folder'), findsOneWidget);
  });

  testWidgets('a Front door tints one step deeper while pressed', (tester) async {
    final core = FakeCore.empty();
    _size(tester, const Size(1400, 1100));
    await tester.pumpWidget(MaterialApp(home: SettingsScope(
      core: core,
      onChanged: (_) {},
      child: Scaffold(body: FrontPane(core: core, memoryVersion: 0, onQuery: (_) {})),
    )));
    await tester.pump();
    await tester.pump();

    final door = find.ancestor(of: find.text('Choose a folder…'), matching: find.byType(FrontDoor));
    Color fill() => (tester.widget<Container>(find.descendant(of: door, matching: find.byType(Container)).first).decoration! as BoxDecoration).color!;
    expect(fill(), Tok.sky);

    final gesture = await tester.startGesture(tester.getCenter(door));
    await tester.pump();
    expect(fill(), Tok.line);

    await gesture.up();
    await tester.pump();
    expect(fill(), Tok.sky);
  });

  testWidgets('the empty Front stacks its columns on a narrow window', (tester) async {
    final core = FakeCore.empty();
    _size(tester, const Size(400, 1000));
    await tester.pumpWidget(MaterialApp(home: SettingsScope(
      core: core,
      onChanged: (_) {},
      child: Scaffold(body: FrontPane(core: core, memoryVersion: 0, onQuery: (_) {})),
    )));
    await tester.pump();
    await tester.pump();

    expect(find.text('Collection'), findsOneWidget);
    expect(find.text('Leads'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Leads')).dy, greaterThan(tester.getTopLeft(find.text('Collection')).dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('This Mac popover shows folder state and opens Folders', (tester) async {
    await _statusLine(tester, _status(const [SourceDto(key: 'local', name: 'My collection', detail: '0', ok: true)]));
    await tester.tap(find.byKey(const ValueKey('status-source-local')));
    await _settleOverlay(tester);

    expect(find.text('0 tracks in 0 folders.'), findsOneWidget);
    await tester.tap(find.text('Open in Settings'));
    await _settleOverlay(tester);

    _expectSection(tester, 'Folders');
    expect(find.text('0 tracks in 0 folders.'), findsNothing);
  });

  testWidgets('MusicBrainz popover uses the source key and opens Lookups', (tester) async {
    await _statusLine(tester, _status(const [SourceDto(key: 'musicbrainz', name: 'Online catalog', detail: 'not used yet', ok: true)]));
    await tester.tap(find.byKey(const ValueKey('status-source-musicbrainz')));
    await _settleOverlay(tester);

    expect(find.text('not used yet'), findsNWidgets(2));
    await tester.tap(find.text('Open in Settings'));
    await _settleOverlay(tester);

    _expectSection(tester, 'Lookups');
  });

  testWidgets('a scan popover shows its phase and progress and opens Folders', (tester) async {
    final job = JobDto(verb: 'reading tags', done: BigInt.from(12), total: BigInt.from(30));
    await _statusLine(tester, _status(const [], jobs: [job]));
    await tester.tap(find.byKey(const ValueKey('status-job-0')));
    await _settleOverlay(tester);

    expect(find.text('Folder scan'), findsOneWidget);
    expect(find.text('Phase · reading tags'), findsOneWidget);
    expect(find.text('12 of 30'), findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.4);
    await tester.tap(find.text('Open in Settings'));
    await _settleOverlay(tester);

    _expectSection(tester, 'Folders');
  });

  testWidgets('Escape and clicking outside dismiss a status popover', (tester) async {
    await _statusLine(tester, _status(const [SourceDto(key: 'musicbrainz', name: 'MusicBrainz', detail: 'not used yet', ok: true)]));
    final source = find.byKey(const ValueKey('status-source-musicbrainz'));
    await tester.tap(source);
    await _settleOverlay(tester);
    expect(find.text('Open in Settings'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settleOverlay(tester);
    expect(find.text('Open in Settings'), findsNothing);

    await tester.tap(source);
    await _settleOverlay(tester);
    await tester.tapAt(const Offset(900, 200));
    await _settleOverlay(tester);
    expect(find.text('Open in Settings'), findsNothing);
  });
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _surface(WidgetTester tester, CoreBridge core) async {
  _size(tester, const Size(1920, 1100));
  await tester.pumpWidget(MeretApp(core: core));
  await tester.pump();
  await tester.pump();
}

Future<void> _statusLine(WidgetTester tester, StatusDto status) async {
  _size(tester, const Size(1200, 800));
  final core = FakeCore.empty();
  await tester.pumpWidget(MaterialApp(home: SettingsScope(
    core: core,
    onChanged: (_) {},
    child: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: StatusLine(core: core, status: status, keys: const []))),
  )));
  await tester.pump();
}

Future<void> _settleOverlay(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

void _expectSection(WidgetTester tester, String name) {
  expect(find.byKey(ValueKey('settings-section-${name.toLowerCase()}')), findsOneWidget);
}

StatusDto _status(List<SourceDto> sources, {List<JobDto> jobs = const []}) => StatusDto(
  sources: sources,
  jobs: jobs,
  guessed: BigInt.zero,
  newLeads: BigInt.zero,
  tracks: BigInt.zero,
  libraryVersion: BigInt.one,
  lookupsVersion: BigInt.zero,
);

class _RecordingEmptyCore extends FakeCore {
  _RecordingEmptyCore() : super.empty();

  final addedPaths = <String>[];

  @override
  Future<int> addRoot(String path) {
    addedPaths.add(path);
    return super.addRoot(path);
  }
}

class _SlowSuggestionsCore extends FakeCore {
  _SlowSuggestionsCore() : super.empty();

  final found = Completer<List<FolderSuggestionDto>>();

  @override
  Future<List<FolderSuggestionDto>> suggestFolders() => found.future;
}

/// One album kept as FLAC and MP3: 43 tracks, 43 of each format.
class _CopiesCore extends FakeCore {
  @override
  Future<FrontDto> front() async {
    final front = await super.front();
    return FrontDto(
      tracks: BigInt.from(43),
      releases: BigInt.one,
      lookups: front.lookups,
      idioms: front.idioms,
      formats: [
        for (final label in ['Lossless', 'Lossy'])
          FrontLineDto(label: label, count: BigInt.from(43), note: '', query: 'format:$label'),
      ],
      addedLately: front.addedLately,
      needsYou: front.needsYou,
      roots: front.roots,
    );
  }
}

class _LookupCore extends FakeCore {
  final answers = <LookupsDto>[];
  final providers = <String>[];
  int frontCalls = 0;

  @override
  Future<FrontDto> front() {
    frontCalls++;
    return super.front();
  }

  @override
  Future<void> setLookups(LookupsDto lookups) {
    answers.add(lookups);
    return super.setLookups(lookups);
  }

  @override
  Future<TrailDto> follow(int fromStop, TargetDto to, ThreadKind via, String provider) {
    providers.add(provider);
    return super.follow(fromStop, to, via, provider);
  }
}
