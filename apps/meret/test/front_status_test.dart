import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';
import 'package:meret/main.dart';
import 'package:meret/panes/front_pane.dart';
import 'package:meret/settings/settings_window.dart';
import 'package:meret/shell/status_line.dart';

void main() {
  testWidgets('an empty Front shows suggestions and adds the selected path', (tester) async {
    final core = _RecordingEmptyCore();
    final suggestions = await core.suggestFolders();
    await _surface(tester, core);

    expect(find.text('Meret found ${suggestions.length} places with music'), findsOneWidget);
    for (final suggestion in suggestions) {
      expect(find.text(suggestion.label), findsOneWidget);
      expect(find.text(suggestion.path), findsOneWidget);
      if (suggestion.note.isNotEmpty) expect(find.text(suggestion.note), findsOneWidget);
    }
    expect(find.text('macOS will ask to let Meret read this folder.'), findsWidgets);
    expect(find.text('Folder found · count after access'), findsWidgets);
    expect(find.text('Bring your history'), findsOneWidget);
    expect(find.text('History import is not available yet.'), findsOneWidget);

    await tester.tap(find.text(suggestions.first.label));
    await tester.pump();
    await tester.pump();

    expect(core.addedPaths, [suggestions.first.path]);
    expect((await core.front()).roots.single.path, suggestions.first.path);
    expect(find.text('Choose a folder…'), findsNothing);
    expect(find.text('+ Add folder'), findsOneWidget);
  });

  testWidgets('Connect a service opens Settings at Sources', (tester) async {
    await _surface(tester, FakeCore.empty());
    await tester.tap(find.text('Connect a service'));
    await _settleOverlay(tester);

    _expectSection(tester, 'Sources');
    expect(find.byType(FrontPane), findsOneWidget);
  });

  testWidgets('the empty Front stacks its columns on a narrow window', (tester) async {
    final core = FakeCore.empty();
    _size(tester, const Size(400, 1000));
    await tester.pumpWidget(MaterialApp(home: SettingsScope(
      core: core,
      onChanged: (_) {},
      child: Scaffold(body: FrontPane(core: core, onQuery: (_) {})),
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
    expect(find.text('No scan is running.'), findsOneWidget);
    await tester.tap(find.text('Open in Settings'));
    await _settleOverlay(tester);

    _expectSection(tester, 'Folders');
    expect(find.text('No scan is running.'), findsNothing);
  });

  testWidgets('MusicBrainz popover uses the source key and opens Lookups', (tester) async {
    await _statusLine(tester, _status(const [SourceDto(key: 'musicbrainz', name: 'Online catalog', detail: 'not used yet', ok: true)]));
    await tester.tap(find.byKey(const ValueKey('status-source-musicbrainz')));
    await _settleOverlay(tester);

    expect(find.text('MusicBrainz has never been contacted.'), findsOneWidget);
    expect(find.text('Matching is not built yet. When it is, Meret will ask in Needs you before sending tags.'), findsOneWidget);
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
