import 'dart:math' as math;
import 'dart:ui' show Rect;

/// How a [Split] divides its area. Horizontal puts the two parts side by side, vertical stacks them.
enum SplitAxis { horizontal, vertical }

int _idCounter = 0;
String _nextId(String prefix) => '$prefix${++_idCounter}';

/// The output frame is cut up like a window manager does it: a tree whose leaves are cells and
/// whose branches are splits. Every cell shows one camera, so cells never overlap and the whole
/// frame is always covered.
sealed class LayoutNode {
  const LayoutNode(this.id);

  final String id;

  Map<String, Object?> toJson();

  static LayoutNode fromJson(Map<String, Object?> j) {
    if (j['t'] == 'split') {
      return Split(
        id: _nextId('s'),
        axis: j['axis'] == 'v' ? SplitAxis.vertical : SplitAxis.horizontal,
        ratio: ((j['ratio'] as num?) ?? 0.5).toDouble().clamp(0.1, 0.9),
        a: fromJson((j['a'] as Map).cast<String, Object?>()),
        b: fromJson((j['b'] as Map).cast<String, Object?>()),
      );
    }
    return Leaf(
      id: _nextId('c'),
      cameraKey: j['cam'] as String?,
      empty: (j['empty'] as bool?) ?? false,
      cover: (j['cover'] as bool?) ?? true,
    );
  }
}

/// One cell. [cameraKey] names the camera that was put here on purpose; with none, the cell takes
/// the next free camera. [empty] leaves the cell black on purpose. [cover] fills the cell and
/// crops the overflow; otherwise the whole picture fits inside it.
class Leaf extends LayoutNode {
  Leaf({String? id, this.cameraKey, this.empty = false, this.cover = true}) : super(id ?? _nextId('c'));

  final String? cameraKey;
  final bool empty;
  final bool cover;

  Leaf copyWith({String? cameraKey, bool clearCamera = false, bool? empty, bool? cover}) => Leaf(
        id: id,
        cameraKey: clearCamera ? null : (cameraKey ?? this.cameraKey),
        empty: empty ?? this.empty,
        cover: cover ?? this.cover,
      );

  @override
  Map<String, Object?> toJson() => {
        't': 'leaf',
        if (cameraKey != null) 'cam': cameraKey,
        if (empty) 'empty': true,
        'cover': cover,
      };
}

class Split extends LayoutNode {
  Split({String? id, required this.axis, required this.ratio, required this.a, required this.b})
      : super(id ?? _nextId('s'));

  final SplitAxis axis;

  /// Share of the area taken by [a] (the left or top part).
  final double ratio;
  final LayoutNode a;
  final LayoutNode b;

  Split copyWith({double? ratio, LayoutNode? a, LayoutNode? b}) =>
      Split(id: id, axis: axis, ratio: ratio ?? this.ratio, a: a ?? this.a, b: b ?? this.b);

  @override
  Map<String, Object?> toJson() => {
        't': 'split',
        'axis': axis == SplitAxis.vertical ? 'v' : 'h',
        'ratio': double.parse(ratio.toStringAsFixed(4)),
        'a': a.toJson(),
        'b': b.toJson(),
      };
}

/// A cell with the rectangle it occupies (fractions of the frame).
class PlacedLeaf {
  const PlacedLeaf(this.leaf, this.rect);

  final Leaf leaf;
  final Rect rect;
}

/// A draggable boundary between the two halves of a split.
class SplitDivider {
  const SplitDivider(this.split, this.area);

  final Split split;

  /// The whole area the split divides (fractions of the frame).
  final Rect area;

  /// The line itself, as a thin rectangle.
  Rect get line {
    if (split.axis == SplitAxis.horizontal) {
      final x = area.left + area.width * split.ratio;
      return Rect.fromLTWH(x, area.top, 0, area.height);
    }
    final y = area.top + area.height * split.ratio;
    return Rect.fromLTWH(area.left, y, area.width, 0);
  }
}

List<PlacedLeaf> placedLeaves(LayoutNode node, [Rect area = const Rect.fromLTWH(0, 0, 1, 1)]) {
  switch (node) {
    case Leaf():
      return [PlacedLeaf(node, area)];
    case Split():
      final (ra, rb) = _halves(node, area);
      return [...placedLeaves(node.a, ra), ...placedLeaves(node.b, rb)];
  }
}

List<SplitDivider> splitDividers(LayoutNode node, [Rect area = const Rect.fromLTWH(0, 0, 1, 1)]) {
  switch (node) {
    case Leaf():
      return const [];
    case Split():
      final (ra, rb) = _halves(node, area);
      return [SplitDivider(node, area), ...splitDividers(node.a, ra), ...splitDividers(node.b, rb)];
  }
}

(Rect, Rect) _halves(Split s, Rect area) {
  if (s.axis == SplitAxis.horizontal) {
    final w = area.width * s.ratio;
    return (
      Rect.fromLTWH(area.left, area.top, w, area.height),
      Rect.fromLTWH(area.left + w, area.top, area.width - w, area.height),
    );
  }
  final h = area.height * s.ratio;
  return (
    Rect.fromLTWH(area.left, area.top, area.width, h),
    Rect.fromLTWH(area.left, area.top + h, area.width, area.height - h),
  );
}

// ------------------------------------------------------------------------- editing

/// Cuts a cell in two. The camera stays in the first half; the second half takes a free camera.
LayoutNode splitLeaf(LayoutNode root, String leafId, SplitAxis axis) {
  switch (root) {
    case Leaf():
      if (root.id != leafId) return root;
      return Split(axis: axis, ratio: 0.5, a: root, b: Leaf(cover: root.cover));
    case Split():
      return root.copyWith(a: splitLeaf(root.a, leafId, axis), b: splitLeaf(root.b, leafId, axis));
  }
}

/// Removes a cell; its neighbour takes over the space. The last cell cannot be removed.
LayoutNode removeLeaf(LayoutNode root, String leafId) {
  switch (root) {
    case Leaf():
      return root;
    case Split():
      if (root.a is Leaf && root.a.id == leafId) return root.b;
      if (root.b is Leaf && root.b.id == leafId) return root.a;
      return root.copyWith(a: removeLeaf(root.a, leafId), b: removeLeaf(root.b, leafId));
  }
}

LayoutNode updateLeaf(LayoutNode root, String leafId, Leaf Function(Leaf) change) {
  switch (root) {
    case Leaf():
      return root.id == leafId ? change(root) : root;
    case Split():
      return root.copyWith(a: updateLeaf(root.a, leafId, change), b: updateLeaf(root.b, leafId, change));
  }
}

LayoutNode setRatio(LayoutNode root, String splitId, double ratio) {
  switch (root) {
    case Leaf():
      return root;
    case Split():
      if (root.id == splitId) return root.copyWith(ratio: ratio.clamp(0.1, 0.9));
      return root.copyWith(a: setRatio(root.a, splitId, ratio), b: setRatio(root.b, splitId, ratio));
  }
}

/// Makes every cell give up its camera choice (cameras are handed out in order again).
LayoutNode clearAssignments(LayoutNode root) {
  switch (root) {
    case Leaf():
      return root.copyWith(clearCamera: true, empty: false);
    case Split():
      return root.copyWith(a: clearAssignments(root.a), b: clearAssignments(root.b));
  }
}

int leafCount(LayoutNode root) => placedLeaves(root).length;

// ------------------------------------------------------------------------ templates

/// A ready-made way to cut up the frame.
class LayoutTemplate {
  const LayoutTemplate(this.id, this.name, this.hint, this.slots, this._build);

  final String id;
  final String name;
  final String hint;
  final int slots;
  final LayoutNode Function() _build;

  LayoutNode build() => _build();
}

Leaf _l({bool cover = true}) => Leaf(cover: cover);
Split _h(double r, LayoutNode a, LayoutNode b) => Split(axis: SplitAxis.horizontal, ratio: r, a: a, b: b);
Split _v(double r, LayoutNode a, LayoutNode b) => Split(axis: SplitAxis.vertical, ratio: r, a: a, b: b);

/// Even grid of [cols] x [rows] cells.
LayoutNode grid(int cols, int rows) => _chain(
      SplitAxis.vertical,
      List.generate(rows, (_) => _chain(SplitAxis.horizontal, List.generate(cols, (_) => _l()))),
    );

/// Splits an area into equal parts along [axis].
LayoutNode _chain(SplitAxis axis, List<LayoutNode> parts) {
  if (parts.length == 1) return parts.first;
  final rest = _chain(axis, parts.sublist(1));
  return Split(axis: axis, ratio: 1 / parts.length, a: parts.first, b: rest);
}

final List<LayoutTemplate> layoutTemplates = [
  LayoutTemplate('single', 'Single', 'One camera in the whole frame', 1, () => _l(cover: false)),
  LayoutTemplate('side', 'Side by side', 'Two cameras next to each other', 2, () => _h(0.5, _l(), _l())),
  LayoutTemplate('stack', 'Stacked', 'Two cameras, one above the other', 2, () => _v(0.5, _l(), _l())),
  LayoutTemplate('main-right', 'Main + 2', 'One large camera and two small ones', 3,
      () => _h(0.66, _l(), _v(0.5, _l(), _l()))),
  LayoutTemplate('main-bottom', 'Main + 2 below', 'A large camera with two below it', 3,
      () => _v(0.7, _l(), _h(0.5, _l(), _l()))),
  LayoutTemplate('columns', 'Three columns', 'Three cameras side by side', 3, () => grid(3, 1)),
  LayoutTemplate('grid4', 'Grid 2 × 2', 'Four cameras in a grid', 4, () => grid(2, 2)),
  LayoutTemplate('main-3', 'Main + 3', 'One large camera and three small ones', 4,
      () => _h(0.72, _l(), _chain(SplitAxis.vertical, [_l(), _l(), _l()]))),
  LayoutTemplate('grid6', 'Grid 3 × 2', 'Six cameras in a grid', 6, () => grid(3, 2)),
  LayoutTemplate('grid8', 'Grid 4 × 2', 'Eight cameras in a grid', 8, () => grid(4, 2)),
];

LayoutTemplate? templateById(String? id) {
  for (final t in layoutTemplates) {
    if (t.id == id) return t;
  }
  return null;
}

/// The template Auto picks for a number of visible cameras.
LayoutTemplate autoTemplateFor(int cameras) {
  final id = switch (cameras) {
    <= 1 => 'single',
    2 => 'side',
    3 => 'main-right',
    4 => 'grid4',
    <= 6 => 'grid6',
    _ => 'grid8',
  };
  return templateById(id)!;
}

/// Gap between cells, as a fraction of the frame height (about 6 px at Full HD).
const double cellGap = 0.0055;

/// Shrinks a cell a little so neighbouring pictures do not touch. A single cell keeps all its area.
Rect insetCell(Rect r, {required bool gap}) {
  if (!gap) return r;
  final g = math.min(cellGap, math.min(r.width, r.height) / 4);
  // The frame is 16:9, so the same fraction is wider in x; scale it so the gap looks even.
  final gx = g * 9 / 16;
  return Rect.fromLTRB(r.left + gx, r.top + g, r.right - gx, r.bottom - g);
}

/// The largest 16:9 (or 9:16) frame that fits in the middle of a cell. [cell] and the result are
/// fractions of the 16:9 output frame, so the shape is worked out in equal units first.
Rect fixedShape(Rect cell, {required bool landscape}) {
  final aspect = landscape ? 16 / 9 : 9 / 16;
  final w = cell.width * 16, h = cell.height * 9;
  var nw = w, nh = h;
  if (w / h > aspect) {
    nw = h * aspect;
  } else {
    nh = w / aspect;
  }
  final fw = nw / 16, fh = nh / 9;
  return Rect.fromLTWH(cell.left + (cell.width - fw) / 2, cell.top + (cell.height - fh) / 2, fw, fh);
}
