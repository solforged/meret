/// navigation.md's scaling table, by width rather than platform.
enum WidthClass {
  /// One pane; swipe along the trail; query and player at the bottom.
  phone(panes: 1, pinnedNow: false),

  /// Two panes: where you came from, where you are.
  foldable(panes: 2, pinnedNow: false),

  /// Two or three panes; Now as a bar.
  laptop(panes: 3, pinnedNow: false),

  /// Four or five panes plus spines, and Now pinned at the right.
  large(panes: 4, pinnedNow: true);

  const WidthClass({required this.panes, required this.pinnedNow});
  final int panes;
  final bool pinnedNow;

  static WidthClass of(double width) => switch (width) {
        < 600 => phone,
        < 1000 => foldable,
        < 1800 => laptop,
        _ => large,
      };
}
