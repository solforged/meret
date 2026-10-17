import 'package:flutter_test/flutter_test.dart';
import 'package:meret/shell/pane_row.dart';

void main() {
  List<double> widths(int count, double width, {int maxVisible = 5, Set<int> wide = const {}}) =>
      PaneRow.widths(count: count, width: width, maxVisible: maxVisible, minPane: 440, maxPane: 560, wide: wide, spine: 46);

  test('panes fold to spines once 440 px each will not fit, oldest first', () {
    expect(widths(3, 1000), [46, 477, 477]);
    expect(widths(3, 1400), [466.6666666666667, 466.6666666666667, 466.6666666666667]);
    expect(widths(1, 300), [300], reason: 'one pane always shows, however narrow');
    expect(widths(4, 2080, maxVisible: 3), [46, 678, 678, 678], reason: 'the width class caps full panes');
  });

  test('a table takes what the other panes do not need past 560 px', () {
    expect(widths(2, 1400, wide: {0}), [840, 560]);
    expect(widths(2, 1000, wide: {0}), [500, 500], reason: 'under 560 each there is nothing spare');
    expect(widths(3, 1800, wide: {1}), [560, 680, 560]);
    expect(widths(2, 1400, wide: {0, 1}), [700, 700], reason: 'two tables share equally');
  });

  test('a folded table does not absorb width', () {
    expect(widths(3, 1000, wide: {0}), [46, 477, 477]);
  });
}
