import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:camnexo_desktop/desktop_controller.dart';
import 'package:camnexo_desktop/main.dart';

void main() {
  testWidgets('shows the waiting screen with status and orientation controls', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = DesktopController(); // not started: no helper programs in tests
    await tester.pumpWidget(CamNexoDesktopApp(controller: controller));

    expect(find.text('CamNexo'), findsOneWidget);
    expect(find.text('Waiting for phone'), findsOneWidget);
    expect(find.text('Waiting for your phone'), findsOneWidget);
    // Orientation control (labels show on a wide window).
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Landscape'), findsOneWidget);
    expect(find.text('Portrait'), findsOneWidget);

    // Choosing an orientation updates the controller.
    await tester.tap(find.text('Portrait'));
    await tester.pump();
    expect(controller.orientation, OrientationMode.portrait);
    await tester.tap(find.text('Auto'));
    await tester.pump();
    expect(controller.orientation, OrientationMode.auto);

    // The resolution menu is disabled until a phone reports its sizes.
    expect(find.text('Resolution'), findsOneWidget);
  });

  test('Resolution names and the phone capability line', () {
    expect(const Resolution(3840, 2160).name, '4K');
    expect(const Resolution(1920, 1080).shortName, '1080p');
    expect(const Resolution(1280, 720).dimensions, '1280 × 720');
    expect(const Resolution(1920, 1080), const Resolution(1920, 1080));
  });

  test('parses the resolution list a phone reports, largest first', () {
    final c = DesktopController();
    c.debugHandleReceiverLine(
        '[cap] sizes=640x360,1280x720,1920x1080,3840x2160 current=1920x1080 auto=1');
    expect(c.resolutions.map((r) => r.shortName), ['4K', '1080p', '720p', '360p']);
    expect(c.currentResolution, const Resolution(1920, 1080));
    expect(c.resolutionAuto, isTrue);

    c.debugHandleReceiverLine('[cap] sizes=640x360,1280x720 current=1280x720 auto=0');
    expect(c.resolutionAuto, isFalse);

    // Disconnecting clears the list so the menu is disabled again.
    c.debugHandleReceiverLine('[tcp] phone disconnected');
    expect(c.resolutions, isEmpty);
    expect(c.currentResolution, isNull);
  });
}
