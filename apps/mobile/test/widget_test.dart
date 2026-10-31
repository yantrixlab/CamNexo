import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:camnexo_mobile/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Real font metrics: the default test font is much wider than Roboto and reports false overflows.
    // The fonts are kept in test/fonts so the result does not depend on the Flutter SDK's layout.
    final loader = FontLoader('Roboto');
    for (final name in ['roboto-regular.ttf', 'roboto-medium.ttf', 'roboto-bold.ttf']) {
      final file = File('test/fonts/$name');
      expect(file.existsSync(), isTrue, reason: 'missing test font $name');
      loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
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

  testWidgets('lists one computer once when old announcements of it linger', (tester) async {
    await tester.pumpWidget(const CamNexoApp());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['CamNexo-Satellite', 'CamNexo-Satellite (1)', 'CamNexo-Satellite(2)']) {
      await messenger.handlePlatformMessage(
        'camnexo/discovery/events',
        const StandardMethodCodec().encodeSuccessEnvelope(
            {'type': 'found', 'name': name, 'host': '192.168.31.224', 'port': 7878}),
        (_) {},
      );
    }
    await tester.pump();

    expect(find.text('Satellite'), findsOneWidget);
    expect(find.text('Satellite (1)'), findsNothing);
    expect(find.text('Satellite(2)'), findsNothing);
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
