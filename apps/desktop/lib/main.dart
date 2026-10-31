import 'dart:io' show Process, ProcessSignal, exit, pid;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_controller.dart';
import 'home_screen.dart';
import 'preview_reader.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Frameless dark window: the picture uses the whole window and the controls float on top.
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1100, 660),
      minimumSize: Size(820, 440),
      center: true,
      backgroundColor: Colors.black,
      titleBarStyle: TitleBarStyle.hidden,
      title: 'CamNexo',
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );

  final controller = DesktopController();
  final preview = PreviewReader();
  runApp(CamNexoDesktopApp(controller: controller, preview: preview));
  await controller.start();
  await preview.start();
}

class CamNexoDesktopApp extends StatefulWidget {
  const CamNexoDesktopApp({super.key, required this.controller, this.preview});

  final DesktopController controller;
  final PreviewReader? preview;

  @override
  State<CamNexoDesktopApp> createState() => _CamNexoDesktopAppState();
}

class _CamNexoDesktopAppState extends State<CamNexoDesktopApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Remove the virtual camera cleanly: killing its helper abruptly can take the Windows
    // Camera Frame Server down with it.
    _lifecycle = AppLifecycleListener(onExitRequested: () async {
      await widget.controller.shutdown();
      widget.preview?.dispose();
      // The preview reader can be parked in a blocking read on the pipe (no phone, no frames),
      // and Dart's own exit waits for it forever. Everything is cleaned up by now, so end the
      // process directly.
      try {
        Process.killPid(pid, ProcessSignal.sigkill);
      } catch (_) {}
      exit(0);
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final preview = widget.preview;
    return MaterialApp(
      title: 'CamNexo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: HomeScreen(controller: controller, preview: preview),
    );
  }
}
