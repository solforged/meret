import 'package:flutter_test/flutter_test.dart';
import 'package:meret/core/bridge.dart';

void main() {
  test('fake pick-up points use release rows and obey their idiom', () async {
    final core = FakeCore();
    final points = await core.resumePoints(20);
    expect(points, hasLength(2));
    expect(await core.resumePoints(1), hasLength(1));
    for (final point in points) {
      final release = await core.release(point.releaseId);
      expect(release.rows.any((row) => row.trackId == point.recordingId), isTrue);
      await core.pickUp(point.releaseId);
      final now = await core.now().first;
      expect(now.releaseId, point.releaseId);
      expect(now.title, point.recordingTitle);
      expect(now.anchor!.positionMs, point.idiom == 'score' ? point.positionMs.toDouble() : 0);
      expect(now.anchor!.rate, 1);
      await core.transport(const TransportDto.fromStart());
      expect((await core.now().first).anchor!.positionMs, 0);
    }
  });

  test('an empty fake has nothing to pick up', () async {
    final core = FakeCore.empty();
    expect(await core.resumePoints(20), isEmpty);
  });
}
