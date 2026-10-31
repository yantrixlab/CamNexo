import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum PhoneState { waiting, connected, streaming }

enum CameraState { stopped, starting, ready, setupRequired, failed }

/// A picture size the phone can capture and encode.
class Resolution {
  const Resolution(this.width, this.height);

  final int width;
  final int height;

  /// Common name for the size, like "Full HD".
  String get name => switch (height) {
        2160 => '4K',
        1440 => '2K',
        1080 => 'Full HD',
        720 => 'HD',
        540 => 'qHD',
        360 => '360p',
        _ => '${height}p',
      };

  /// Short form for the top bar, like "1080p" or "4K".
  String get shortName => switch (height) {
        2160 => '4K',
        1440 => '1440p',
        _ => '${height}p',
      };

  String get dimensions => '$width × $height';

  @override
  bool operator ==(Object other) => other is Resolution && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);
}

/// The shape of the frame sent to apps. The picture itself is always upright (the phone works
/// that out from its sensor). Auto fits the whole picture, so the frame follows how the phone is
/// held. Landscape and Portrait are fixed frames: they stay the same however the phone is turned,
/// and the picture is cropped to fill them.
enum OrientationMode { auto, landscape, portrait }

const _clsid = '{5E6B7C2A-3F0D-4B7A-9C41-2D8E6A1F0B53}';
const _receiverExe = 'camnexo_receiver.exe';
const _cameraExe = 'camnexo_vcam.exe';

/// Runs the two helper programs (receiver and virtual camera), and turns their output
/// into state the UI can show.
class DesktopController extends ChangeNotifier {
  Process? _receiver;
  Process? _camera;
  String? helperDir;

  CameraState camera = CameraState.stopped;
  bool receiverListening = false;
  String? error;

  /// The name phones see when they search the network, once announced (null until then).
  String? discoveryName;
  bool discoveryFailed = false;

  /// Sizes the connected phone offers (empty until a phone has reported), the size in use, and
  /// whether the phone is choosing by itself (Auto).
  List<Resolution> resolutions = const [];
  Resolution? currentResolution;
  bool resolutionAuto = true;

  /// What was picked here: null means Auto. Sent to the phone, and again if it reconnects.
  Resolution? chosenResolution;

  void setResolution(Resolution? r) {
    chosenResolution = r;
    resolutionAuto = r == null;
    final stdin = _receiver?.stdin;
    try {
      stdin?.writeln(r == null ? 'resolution auto' : 'resolution ${r.width} ${r.height}');
    } catch (_) {}
    notifyListeners();
  }

  OrientationMode orientation = OrientationMode.auto;
  bool flip = false; // turn the picture 180 degrees (for a phone mounted upside down)

  void setOrientation(OrientationMode mode) {
    orientation = mode;
    _sendOrientation();
    notifyListeners();
  }

  void toggleFlip() {
    flip = !flip;
    _sendOrientation();
    notifyListeners();
  }

  /// The receiver passes this on to the phone, and re-sends it to a phone that connects later.
  void _sendOrientation() {
    final r = _receiver;
    if (r == null) return;
    try {
      r.stdin.writeln('orientation ${orientation.name} ${flip ? 1 : 0}');
    } catch (_) {}
  }

  /// Addresses the phone can use, as printed by the receiver (for example 192.168.1.20:7878).
  final List<String> addresses = [];

  PhoneState phone = PhoneState.waiting;
  String? phoneAddress;
  String? streamSize;
  int fpsIn = 0;
  int fpsDecoded = 0;
  int kbps = 0;
  int decodeErrors = 0;
  int rotation = 0;

  bool _disposed = false;

  String get registerCommand => '& "${helperDir ?? '<folder>'}\\$_cameraExe" register';

  /// Looks for the helpers next to the app, then upward from it (development builds).
  String? _findHelpers() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final beside = Directory('${exeDir.path}${Platform.pathSeparator}helpers');
    if (File('${beside.path}${Platform.pathSeparator}$_receiverExe').existsSync()) {
      return beside.path;
    }
    Directory? dir = exeDir;
    for (var i = 0; i < 12 && dir != null; i++) {
      final candidate = Directory(
          '${dir.path}${Platform.pathSeparator}native${Platform.pathSeparator}windows'
          '${Platform.pathSeparator}vcam${Platform.pathSeparator}build${Platform.pathSeparator}Release');
      if (File('${candidate.path}${Platform.pathSeparator}$_receiverExe').existsSync()) {
        return candidate.path;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  Future<bool> _isCameraRegistered() async {
    try {
      final r = await Process.run(
          'reg', ['query', 'HKLM\\Software\\Classes\\CLSID\\$_clsid\\InprocServer32']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> start() async {
    helperDir = _findHelpers();
    if (helperDir == null) {
      error = 'Helper programs not found. Build native/windows/vcam first.';
      notifyListeners();
      return;
    }
    await _startReceiver();
    await _startCamera();
  }

  Future<void> _startReceiver() async {
    try {
      final p = await Process.start('$helperDir${Platform.pathSeparator}$_receiverExe', const []);
      _receiver = p;
      p.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onReceiverLine);
      p.stderr.drain<void>();
      unawaited(p.exitCode.then((code) {
        if (_disposed) return;
        receiverListening = false;
        phone = PhoneState.waiting;
        error ??= 'The receiver stopped (code $code). Another copy may be using port 7878.';
        notifyListeners();
      }));
    } catch (e) {
      error = 'Could not start the receiver: $e';
      notifyListeners();
    }
  }

  Future<void> _startCamera() async {
    if (!await _isCameraRegistered()) {
      camera = CameraState.setupRequired;
      notifyListeners();
      return;
    }
    camera = CameraState.starting;
    notifyListeners();
    // Windows stops the Frame Server after crashes and does not always restart it on demand.
    try {
      await Process.run('sc', ['start', 'FrameServer']);
    } catch (_) {}
    try {
      // `run` keeps the camera alive until a line arrives on its stdin (or the process ends).
      final p = await Process.start('$helperDir${Platform.pathSeparator}$_cameraExe', const ['run']);
      _camera = p;
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (line.contains('is live')) {
          camera = CameraState.ready;
          notifyListeners();
        }
      });
      p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        camera = CameraState.failed;
        error = 'Virtual camera: $line';
        notifyListeners();
      });
      unawaited(p.exitCode.then((_) {
        if (_disposed) return;
        if (camera != CameraState.failed) camera = CameraState.stopped;
        notifyListeners();
      }));
    } catch (e) {
      camera = CameraState.failed;
      error = 'Could not start the virtual camera: $e';
      notifyListeners();
    }
  }

  Future<void> restartCamera() async {
    await _stopCamera();
    error = null;
    await _startCamera();
  }

  Future<void> _stopCamera() async {
    final p = _camera;
    _camera = null;
    if (p == null) return;
    try {
      p.stdin.writeln();
      await p.stdin.flush();
      await p.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {
      p.kill();
    }
    camera = CameraState.stopped;
  }

  @visibleForTesting
  void debugHandleReceiverLine(String line) => _onReceiverLine(line);

  void _onReceiverLine(String line) {
    var changed = true;
    final addr = RegExp(r'phone address:\s+(\S+)').firstMatch(line);
    final from = RegExp(r'\[tcp\] phone connected from (\S+)').firstMatch(line);
    final size = RegExp(r'\[tcp\] stream (\d+x\d+)').firstMatch(line);
    final rx = RegExp(r'\[rx\] (\d+) fps in, (\d+) fps decoded, (\d+) kbps, decode errors (\d+)')
        .firstMatch(line);
    final rot = RegExp(r'\[tcp\] rotation \d+ -> (\d+)').firstMatch(line);

    final mdns = RegExp(r'\[mdns\] registered as (\S+)').firstMatch(line);
    final cap = RegExp(r'\[cap\] sizes=(\S*) current=(\d+)x(\d+) auto=(\d)').firstMatch(line);

    if (line.contains('receiver listening')) {
      receiverListening = true;
    } else if (cap != null) {
      final list = <Resolution>[];
      for (final part in cap.group(1)!.split(',')) {
        final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(part);
        if (m != null) list.add(Resolution(int.parse(m.group(1)!), int.parse(m.group(2)!)));
      }
      list.sort((a, b) => (b.width * b.height).compareTo(a.width * a.height)); // largest first
      resolutions = list;
      currentResolution = Resolution(int.parse(cap.group(2)!), int.parse(cap.group(3)!));
      resolutionAuto = cap.group(4) == '1';
    } else if (mdns != null) {
      discoveryName = mdns.group(1);
      discoveryFailed = false;
    } else if (line.contains('[mdns]') && line.contains('FAILED')) {
      discoveryFailed = true;
    } else if (addr != null) {
      final a = addr.group(1)!;
      if (!addresses.contains(a)) addresses.add(a);
    } else if (from != null) {
      phone = PhoneState.connected;
      phoneAddress = from.group(1);
    } else if (size != null) {
      streamSize = size.group(1);
    } else if (rot != null) {
      rotation = int.parse(rot.group(1)!);
    } else if (rx != null) {
      phone = PhoneState.streaming;
      fpsIn = int.parse(rx.group(1)!);
      fpsDecoded = int.parse(rx.group(2)!);
      kbps = int.parse(rx.group(3)!);
      decodeErrors = int.parse(rx.group(4)!);
    } else if (line.contains('phone disconnected')) {
      phone = PhoneState.waiting;
      phoneAddress = null;
      streamSize = null;
      fpsIn = fpsDecoded = kbps = 0;
      resolutions = const [];
      currentResolution = null;
    } else if (line.contains('Cannot listen')) {
      error = 'Port 7878 is busy. Close any other CamNexo receiver and restart.';
    } else {
      changed = false;
    }
    if (changed) notifyListeners();
  }

  Future<void> shutdown() async {
    _disposed = true;
    await _stopCamera();
    final r = _receiver;
    _receiver = null;
    if (r != null) {
      try {
        // Asks the receiver to withdraw its network announcement before it exits.
        r.stdin.writeln('quit');
        await r.stdin.flush();
        await r.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        r.kill();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _receiver?.kill();
    _camera?.kill();
    super.dispose();
  }
}
