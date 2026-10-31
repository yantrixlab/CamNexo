import 'package:flutter/material.dart';

import 'camera_screen.dart';
import 'theme.dart';

void main() {
  runApp(const CamNexoApp());
}

class CamNexoApp extends StatelessWidget {
  const CamNexoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CamNexo',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const CameraScreen(),
    );
  }
}
