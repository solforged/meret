/// navigation.md's scaling table, by width rather than platform. `panes`
/// caps how many panes open at full width; [PaneRow] fits fewer when 440 px
/// each won't go.
enum WidthClass {
  /// One pane; swipe along the trail; query and player at the bottom.
  phone(panes: 1, nowWidth: null),

  /// Two panes: where you came from, where you are.
  foldable(panes: 2, nowWidth: null),

  /// Two or three panes; Now opens on `N` or a click on the LCD.
  laptop(panes: 3, nowWidth: null),

  /// Three panes; Now opens beside them on `N` or a click on the LCD.
  desk(panes: 3, nowWidth: null),

  /// Four or five panes plus spines, and Now pinned at the right.
  large(panes: 5, nowWidth: 380);

  const WidthClass({required this.panes, required this.nowWidth});
  final int panes;

  /// The Now panel's width when it's pinned by default (decided
  /// 2026-10-23: from 1800 pt); null when it opens on `N`, at [panel].
  final double? nowWidth;
  bool get pinnedNow => nowWidth != null;
  static const panel = 360.0;

  static WidthClass of(double width) => switch (width) {
        < 600 => phone,
        < 1000 => foldable,
        < 1560 => laptop,
        < 1800 => desk,
        _ => large,
      };
}
