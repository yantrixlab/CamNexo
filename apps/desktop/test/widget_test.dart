import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camnexo_desktop/desktop_controller.dart';
import 'package:camnexo_desktop/layout_model.dart';
import 'package:camnexo_desktop/main.dart';

/// Feeds the lines a receiver prints when a phone connects and starts streaming.
void connectPhone(DesktopController c, int id, String ip, {String name = 'OnePlus AC2001'}) {
  c.debugHandleReceiverLine('[src $id] connected from $ip');
  c.debugHandleReceiverLine('[src $id] name $name');
  c.debugHandleReceiverLine('[src $id] stream 1920x1080');
  c.debugHandleReceiverLine('[src $id] cap sizes=640x360,1280x720,1920x1080,3840x2160 current=1920x1080 auto=1');
  c.debugHandleReceiverLine('[src $id] rx 30 fps in, 30 fps decoded, 4200 kbps, decode errors 0');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Real font metrics: the default test font is much wider than Roboto and reports false overflows.
    final loader = FontLoader('Roboto');
    for (final name in ['roboto-regular.ttf', 'roboto-medium.ttf', 'roboto-bold.ttf']) {
      final file = File('test/fonts/$name');
      expect(file.existsSync(), isTrue, reason: 'missing test font $name');
      loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  });

  testWidgets('shows the waiting screen with the layout, cameras and frame controls', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = DesktopController(); // not started: no helper programs in tests
    await tester.pumpWidget(CamNexoDesktopApp(controller: controller));

    expect(find.text('CamNexo'), findsOneWidget);
    expect(find.text('Waiting for phone'), findsOneWidget);
    expect(find.text('Waiting for your phone'), findsOneWidget);
    expect(find.text('Layout'), findsOneWidget);
    expect(find.text('Cameras'), findsOneWidget);
    // Single-camera frame control (labels show on a wide window).
    expect(find.text('Landscape'), findsOneWidget);
    expect(find.text('Portrait'), findsOneWidget);

    await tester.tap(find.text('Portrait'));
    await tester.pump();
    expect(controller.orientation, OrientationMode.portrait);
    expect(controller.layoutName, 'Auto'); // the shape is separate from the layout
    await tester.tap(find.text('Auto').first);
    await tester.pump();
    expect(controller.orientation, OrientationMode.auto);
  });

  testWidgets('connecting phones fills the Cameras panel and the layout follows the count', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = DesktopController();
    await tester.pumpWidget(CamNexoDesktopApp(controller: controller));

    connectPhone(controller, 1, '192.168.1.20');
    connectPhone(controller, 2, '192.168.1.21', name: 'Pixel 8');
    await tester.pump();
    expect(controller.sources.length, 2);
    expect(controller.layoutMode, LayoutMode.auto);
    expect(placedLeaves(controller.layout).length, 2); // Auto picks side by side for two

    await tester.tap(find.text('Cameras'));
    await tester.pump();
    expect(find.text('2 connected, 2 shown'), findsOneWidget);
    expect(find.text('OnePlus AC2001'), findsOneWidget);
    expect(find.text('Pixel 8'), findsOneWidget);

    // Hiding a camera leaves one cell.
    controller.setVisible(controller.sources.first, false);
    await tester.pump();
    expect(placedLeaves(controller.layout).length, 1);
    expect(controller.visibleSources.single.name, 'Pixel 8');
  });

  testWidgets('the Layout menu applies a template', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = DesktopController();
    await tester.pumpWidget(CamNexoDesktopApp(controller: controller));
    connectPhone(controller, 1, '192.168.1.20');
    connectPhone(controller, 2, '192.168.1.21');
    await tester.pump();

    await tester.tap(find.text('Layout'));
    await tester.pump();
    await tester.tap(find.text('Stacked'));
    await tester.pump();
    expect(controller.layoutMode, LayoutMode.template);
    expect(controller.templateId, 'stack');
    final cells = controller.resolvedCells();
    expect(cells.length, 2);
    expect(cells[0].rect.height, closeTo(0.5, 1e-9));
    expect(cells.map((c) => c.camera?.id), [1, 2]);
  });

  test('Resolution names', () {
    expect(const Resolution(3840, 2160).name, '4K');
    expect(const Resolution(1920, 1080).shortName, '1080p');
    expect(const Resolution(1280, 720).dimensions, '1280 × 720');
    expect(const Resolution(1920, 1080), const Resolution(1920, 1080));
  });

  test('parses a phone connecting, its sizes, its speed and leaving', () {
    final c = DesktopController();
    connectPhone(c, 3, '192.168.1.20');
    final s = c.sourceById(3)!;
    expect(s.label, 'OnePlus AC2001');
    expect(s.key, '192.168.1.20');
    expect(s.resolutions.map((r) => r.shortName), ['4K', '1080p', '720p', '360p']);
    expect(s.currentResolution, const Resolution(1920, 1080));
    expect(s.resolutionAuto, isTrue);
    expect(s.fps, 30);
    expect(s.kbps, 4200);
    expect(c.phone, PhoneState.streaming);

    c.debugHandleReceiverLine('[src 3] cap sizes=640x360,1280x720 current=1280x720 auto=0');
    expect(s.resolutionAuto, isFalse);

    c.debugHandleReceiverLine('[src 3] disconnected');
    expect(c.sources, isEmpty);
    expect(c.phone, PhoneState.waiting);
  });

  test('test cameras get their own key; the same phone reconnecting keeps its key', () {
    final c = DesktopController();
    c.debugHandleReceiverLine('[src 1] connected from simulated');
    expect(c.sourceById(1)!.key, 'simulated-1');
    expect(c.sourceById(1)!.isSimulated, isTrue);

    connectPhone(c, 4, '10.0.0.7');
    c.debugHandleReceiverLine('[src 4] disconnected');
    connectPhone(c, 5, '10.0.0.7');
    expect(c.sourceById(5)!.key, '10.0.0.7');
    expect(c.sources.where((s) => s.key == '10.0.0.7').length, 1);
  });

  group('layout model', () {
    test('Auto picks a template for the number of cameras', () {
      expect(placedLeaves(autoTemplateFor(0).build()).length, 1);
      expect(autoTemplateFor(2).id, 'side');
      expect(autoTemplateFor(3).id, 'main-right');
      expect(autoTemplateFor(4).id, 'grid4');
      expect(autoTemplateFor(5).id, 'grid6');
      expect(autoTemplateFor(8).id, 'grid8');
    });

    test('every template fills the frame exactly, with the number of cells it promises', () {
      for (final t in layoutTemplates) {
        final cells = placedLeaves(t.build());
        final area = cells.fold<double>(0, (a, p) => a + p.rect.width * p.rect.height);
        expect(area, closeTo(1.0, 1e-9), reason: t.id);
        expect(cells.where((p) => !p.leaf.empty).length, t.slots, reason: t.id);
      }
    });

    test('splitting and removing cells', () {
      var root = layoutTemplates.firstWhere((t) => t.id == 'single').build();
      final first = placedLeaves(root).single.leaf;
      root = splitLeaf(root, first.id, SplitAxis.horizontal);
      expect(placedLeaves(root).length, 2);
      final second = placedLeaves(root).last.leaf;
      root = splitLeaf(root, second.id, SplitAxis.vertical);
      expect(placedLeaves(root).length, 3);
      root = removeLeaf(root, second.id);
      expect(placedLeaves(root).length, 2);
      // The last remaining cell cannot be removed.
      root = removeLeaf(root, placedLeaves(root).last.leaf.id);
      expect(placedLeaves(root).length, 1);
      root = removeLeaf(root, placedLeaves(root).single.leaf.id);
      expect(placedLeaves(root).length, 1);
    });

    test('moving a divider changes both neighbours and stays inside limits', () {
      var root = layoutTemplates.firstWhere((t) => t.id == 'side').build();
      final split = splitDividers(root).single.split;
      root = setRatio(root, split.id, 0.7);
      expect(placedLeaves(root).first.rect.width, closeTo(0.7, 1e-9));
      root = setRatio(root, split.id, 5);
      expect(placedLeaves(root).first.rect.width, closeTo(0.9, 1e-9));
    });

    test('a layout survives saving and loading', () {
      var root = layoutTemplates.firstWhere((t) => t.id == 'main-right').build();
      root = updateLeaf(root, placedLeaves(root).first.leaf.id, (l) => l.copyWith(cameraKey: '10.0.0.7', cover: false));
      final back = LayoutNode.fromJson((jsonDecode(jsonEncode(root.toJson())) as Map).cast<String, Object?>());
      final a = placedLeaves(root), b = placedLeaves(back);
      expect(b.length, a.length);
      expect(b.first.leaf.cameraKey, '10.0.0.7');
      expect(b.first.leaf.cover, isFalse);
      expect(b.first.rect, a.first.rect);
    });

    test('cameras are handed out in order, and a cell can keep its own camera', () {
      final c = DesktopController();
      connectPhone(c, 1, '10.0.0.1');
      connectPhone(c, 2, '10.0.0.2');
      connectPhone(c, 3, '10.0.0.3');
      c.applyTemplate(layoutTemplates.firstWhere((t) => t.id == 'columns'));
      expect(c.resolvedCells().map((r) => r.camera?.id), [1, 2, 3]);

      // Put camera 3 in the first cell: the others shift to the free cells.
      final firstLeaf = placedLeaves(c.layout).first.leaf;
      c.editLayout((r) => updateLeaf(r, firstLeaf.id, (l) => l.copyWith(cameraKey: '10.0.0.3')));
      expect(c.layoutMode, LayoutMode.custom);
      expect(c.resolvedCells().map((r) => r.camera?.id), [3, 1, 2]);

      // Hidden cameras leave their cell empty rather than reappearing.
      c.setVisible(c.sourceById(3)!, false);
      expect(c.resolvedCells().map((r) => r.camera?.id), [null, 1, 2]);
    });

    test('a fixed shape is the largest 16:9 or 9:16 frame centred in the cell', () {
      // Whole frame: landscape fills it, portrait is a narrow band in the middle.
      expect(fixedShape(const Rect.fromLTWH(0, 0, 1, 1), landscape: true), const Rect.fromLTWH(0, 0, 1, 1));
      final band = fixedShape(const Rect.fromLTWH(0, 0, 1, 1), landscape: false);
      expect(band.height, closeTo(1, 1e-9));
      expect(band.width, closeTo(0.31640625, 1e-9));
      expect(band.center.dx, closeTo(0.5, 1e-9));
      // Left half (a tall cell): a landscape frame is half the height, centred vertically.
      final land = fixedShape(const Rect.fromLTWH(0, 0, 0.5, 1), landscape: true);
      expect(land.width, closeTo(0.5, 1e-9));
      expect(land.height, closeTo(0.5, 1e-9));
      expect(land.top, closeTo(0.25, 1e-9));
      // Whatever the cell, the result keeps its shape in real pixels.
      for (final cell in [const Rect.fromLTWH(0.1, 0.2, 0.3, 0.6), const Rect.fromLTWH(0, 0, 1, 0.2)]) {
        final r = fixedShape(cell, landscape: true);
        expect((r.width * 16) / (r.height * 9), closeTo(16 / 9, 1e-9));
        expect(cell.contains(r.topLeft) && cell.inflate(1e-9).contains(r.bottomRight), isTrue);
      }
    });

    test('the gap between cells keeps each cell inside the frame', () {
      final r = insetCell(const Rect.fromLTWH(0, 0, 0.5, 1), gap: true);
      expect(r.left, greaterThan(0));
      expect(r.right, lessThan(0.5));
      expect(insetCell(const Rect.fromLTWH(0, 0, 1, 1), gap: false), const Rect.fromLTWH(0, 0, 1, 1));
    });
  });
}
