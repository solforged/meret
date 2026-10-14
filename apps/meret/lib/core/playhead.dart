import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'bridge.dart';

/// The playhead at display rate, from anchors the core sends only when
/// something changes. Ticks on vsync while playing and not at all while
/// paused, so a paused app draws nothing.
///
/// Painters take this as `repaint:`, so the body turns at 120 Hz without
/// rebuilding a single widget.
class PlayheadClock extends ChangeNotifier {
  PlayheadClock(TickerProvider vsync) {
    _ticker = vsync.createTicker((_) => notifyListeners());
  }

  late final Ticker _ticker;
  final Stopwatch _since = Stopwatch();
  double _baseMs = 0;
  double _rate = 0;

  double get positionMs => _baseMs + _rate * _since.elapsedMicroseconds / 1000.0;
  bool get playing => _rate > 0;

  void anchor(AnchorDto? a) {
    _baseMs = a?.positionMs ?? 0;
    _rate = a?.rate ?? 0;
    _since
      ..reset()
      ..start();
    if (_rate > 0) {
      if (!_ticker.isActive) _ticker.start();
    } else {
      _ticker.stop();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}
