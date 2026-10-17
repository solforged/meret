/// navigation.md's scaling table, by width rather than platform. `panes`
/// caps how many panes open at full width; [PaneRow] fits fewer when 440 px
/// each won't go.
enum WidthClass {
  /// One pane; swipe along the trail; query and player at the bottom.
  phone(panes: 1, nowWidth: null),

  /// Two panes: where you came from, where you are.
  foldable(panes: 2, nowWidth: null),

  /// Two or three panes; Now as a bar.
  laptop(panes: 3, nowWidth: null),

  /// Two or three panes and Now pinned at the right (decided 2026-10-17: pin from 1400).
  desk(panes: 3, nowWidth: 360),

  /// Four or five panes plus spines, and Now pinned at the right.
  large(panes: 5, nowWidth: 380);

  const WidthClass({required this.panes, required this.nowWidth});
  final int panes;

  /// The pinned Now pane's width; null when Now is a bar.
  final double? nowWidth;
  bool get pinnedNow => nowWidth != null;

  static WidthClass of(double width) => switch (width) {
        < 600 => phone,
        < 1000 => foldable,
        < 1400 => laptop,
        < 1800 => desk,
        _ => large,
      };
}
