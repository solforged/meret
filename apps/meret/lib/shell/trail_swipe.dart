import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Two fingers sideways on a trackpad step along the trail, as `[` and `]`
/// do: fingers moving right go back, fingers moving left go forward, the way
/// a browser's history swipe runs. A sideways wheel (a Magic Mouse) does the
/// same.
///
/// The swipe is a drag recognizer in the gesture arena, so whatever is under
/// the pointer and scrolls or drags sideways itself (a histogram brush, a
/// strip of hits) keeps the gesture, and a swipe that wins doesn't also
/// scroll the list under it.
class TrailSwipe extends StatefulWidget {
  const TrailSwipe({super.key, required this.onStep, required this.child});

  /// -1 for a step back, 1 for a step forward.
  final ValueChanged<int> onStep;
  final Widget child;

  /// How far two fingers travel before the first step, and between further
  /// steps of one long swipe.
  static const first = 56.0;
  static const further = 180.0;

  /// A wheel has no end to its gesture; this long without an event is one.
  static const wheelPause = Duration(milliseconds: 220);

  @override
  State<TrailSwipe> createState() => _TrailSwipeState();
}

class _TrailSwipeState extends State<TrailSwipe> {
  double _travel = 0;
  double _next = TrailSwipe.first;

  double _wheel = 0;
  bool _wheelStepped = false;
  Duration? _wheelAt;

  void _start(DragStartDetails details) {
    _travel = 0;
    _next = TrailSwipe.first;
  }

  void _update(DragUpdateDetails details) {
    final before = _travel;
    _travel += details.primaryDelta ?? 0;
    // A swipe that turns round starts over from where it turned.
    if (before != 0 && _travel.sign != before.sign) _next = TrailSwipe.first;
    if (_travel.abs() < _next) return;
    final back = _travel > 0;
    _travel = 0;
    _next = TrailSwipe.further;
    widget.onStep(back ? -1 : 1);
  }

  void _signal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final delta = event.scrollDelta;
    if (delta.dx.abs() <= delta.dy.abs() * 1.5) return;
    // Something under the pointer that scrolls sideways registered first and keeps it.
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final at = event.timeStamp;
      if (_wheelAt == null || at - _wheelAt! > TrailSwipe.wheelPause) {
        _wheel = 0;
        _wheelStepped = false;
      }
      _wheelAt = at;
      if (_wheelStepped) return;
      _wheel += (event as PointerScrollEvent).scrollDelta.dx;
      if (_wheel.abs() < TrailSwipe.first) return;
      _wheelStepped = true;
      // The wheel reports where the view goes; fingers went the other way.
      widget.onStep(_wheel > 0 ? 1 : -1);
    });
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerSignal: _signal,
    child: RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      excludeFromSemantics: true,
      gestures: {
        HorizontalDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
          () => HorizontalDragGestureRecognizer(debugOwner: this, supportedDevices: const {PointerDeviceKind.trackpad}),
          (recognizer) => recognizer
            ..onStart = _start
            ..onUpdate = _update,
        ),
      },
      child: widget.child,
    ),
  );
}
