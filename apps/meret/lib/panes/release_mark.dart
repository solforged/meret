import 'package:flutter/foundation.dart';

/// A track someone asked to see in its release (an Up next row): the release
/// pane that opens for it, or is already open, marks that row once it has
/// the tracklist.
class ReleaseMark extends ChangeNotifier {
  ReleaseMark._();
  static final instance = ReleaseMark._();

  final _tracks = <int, int>{};

  void mark(int releaseId, int trackId) {
    _tracks[releaseId] = trackId;
    notifyListeners();
  }

  /// The track marked in [releaseId], once.
  int? take(int releaseId) => _tracks.remove(releaseId);
}
