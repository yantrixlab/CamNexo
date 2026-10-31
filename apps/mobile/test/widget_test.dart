import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:camnexo_mobile/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Real font metrics: the default test font is much wider than Roboto and reports false overflows.
    // The fonts ship inside the Flutter SDK: find them from FLUTTER_ROOT, or by walking up from the
    // test runner's own location (FLUTTER_ROOT is not always set, for example on CI).
    String? dir;
    final root = Platform.environment['FLUTTER_ROOT'];
    if (root != null && Directory('$root/bin/cache/artifacts/material_fonts').existsSync()) {
      dir = '$root/bin/cache/artifacts/material_fonts';
    }
    for (var d = File(Platform.resolvedExecutable).parent; dir == null; d = d.parent) {
      if (Directory('${d.path}/artifacts/material_fonts').existsSync()) dir = '${d.path}/artifacts/material_fonts';
      if (d.parent.path == d.path) break;
    }
    if (dir != null) {
      final loader = FontLoader('Roboto');
      for (final name in ['roboto-regular.ttf', 'roboto-medium.ttf', 'roboto-bold.ttf']) {
        final file = File('$dir/$name');
        if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
      }
      await loader.load();
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // No native modules in unit tests: accept and ignore their channel calls.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'camnexo/stream',
      'camnexo/stream/events',
      'camnexo/discovery',
      'camnexo/discovery/events',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async => null);
    }
  });

  testWidgets('shows the header, nearby computers and a manual fallback',
      (tester) async {
    await tester.pumpWidget(const CamNexoApp());
    // Let the failed camera plugin call complete, then rebuild.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    expect(find.text('CamNexo'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Computers nearby'), findsOneWidget);
    expect(find.text('Searching your Wi-Fi…'), findsOneWidget);
    // No camera plugin in unit tests: the preview falls back to its retry state.
    expect(find.text('Retry'), findsOneWidget);

    // The manual address entry is still available.
    await tester.tap(find.text('Enter address manually'));
    await tester.pump();
    expect(find.text('Computer IP address'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });

  // Sends a status event from the (mocked) native module to the screen.
  Future<void> emitStatus(Map<String, Object?> event) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    await messenger.handlePlatformMessage(
      'camnexo/stream/events',
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
  }

  for (final layout in [
    ('portrait', const Size(411, 914)),
    ('landscape', const Size(914, 411)),
    ('small landscape', const Size(640, 360)),
  ]) {
    testWidgets('lays out without overflow, idle and streaming: ${layout.$1}', (tester) async {
      tester.view.physicalSize = layout.$2;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const CamNexoApp());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Computers nearby'), findsOneWidget);

      await emitStatus({'state': 'streaming', 'width': 1920, 'height': 1080});
      await emitStatus({'state': 'stats', 'width': 1920, 'height': 1080, 'fps': 30, 'kbps': 7700, 'dropped': 3});
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('Streaming live'), findsOneWidget);
      expect(find.text('Stop streaming'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
