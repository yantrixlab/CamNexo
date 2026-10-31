import 'package:flutter/material.dart';

import 'camera_screen.dart';

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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const CameraScreen(),
    );
  }
}
