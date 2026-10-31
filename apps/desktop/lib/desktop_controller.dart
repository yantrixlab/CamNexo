import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'camera_source.dart';
import 'effects_model.dart';
import 'layout_model.dart';

export 'camera_source.dart';

enum PhoneState { waiting, connected, streaming }

enum CameraState { stopped, starting, ready, setupRequired, failed }

/// How the single-camera frame is shaped (used when the layout is one cell). Auto fits the whole
/// picture, so the frame follows how the phone is held. Landscape and Portrait are fixed frames
/// that stay the same however the phone is turned; the picture is cropped to fill them.
enum OrientationMode { auto, landscape, portrait }

/// How the layout was chosen.
enum LayoutMode {
  /// Picked from the number of cameras shown.
  auto,

  /// A ready-made template.
  template,

  /// Edited by hand.
  custom,
}

/// A cell of the layout together with the camera shown in it (null: nothing, the cell is black).
class ResolvedCell {
  const ResolvedCell(this.leaf, this.rect, this.camera);

  final Leaf leaf;
  final Rect rect;
  final CameraSource? camera;
}

const _clsid = '{5E6B7C2A-3F0D-4B7A-9C41-2D8E6A1F0B53}';
const _receiverExe = 'camnexo_receiver.exe';
const _cameraExe = 'camnexo_vcam.exe';
const _prefsKey = 'camnexo.desktop.v2';

/// Runs the two helper programs (receiver and virtual camera), and turns their output
/// into state the UI can show: the connected cameras and how they are laid out.
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

  /// Addresses the phone can use, as printed by the receiver (for example 192.168.1.20:7878).
  final List<String> addresses = [];

  bool _disposed = false;

  String get registerCommand => '& "${helperDir ?? '<folder>'}\\$_cameraExe" register';

  // ------------------------------------------------------------------ cameras

  final List<CameraSource> sources = [];

  /// Settings remembered by camera key, so a phone that reconnects (or the next session) gets them back.
  final Set<String> _hiddenKeys = {};
  final Set<String> _flipKeys = {};
  final Map<String, String> _resolutionByKey = {}; // "1920x1080"
  final Map<String, CameraEffects> _effectsByKey = {};

  /// Whether the receiver can do background effects (it needs onnxruntime.dll and its model).
  bool fxAvailable = false;
  String? fxMessage;

  bool get anyEffects => sources.any((s) => !s.effects.isOff);

  /// The folder with the ready-made background pictures, inside the app's own files.
  String get backgroundsDir {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return '$exeDir${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets'
        '${Platform.pathSeparator}assets${Platform.pathSeparator}backgrounds';
  }

  String? _backgroundFile(CameraEffects e) {
    if (e.background != BackgroundMode.image) return null;
    return e.customImage ?? '$backgroundsDir${Platform.pathSeparator}${e.builtIn}.jpg';
  }

  /// Changes the effects of one camera. They apply at once, in the picture every app receives.
  void setEffects(CameraSource s, CameraEffects e) {
    s.effects = e;
    if (e.isOff) {
      _effectsByKey.remove(s.key);
    } else {
      _effectsByKey[s.key] = e;
    }
    _sendEffects(s);
    _changed();
  }

  /// Gives every camera the same effects.
  void setEffectsForAll(CameraEffects e) {
    for (final s in sources) {
      setEffects(s, e);
    }
  }

  /// The command that tells the receiver what to do with camera [s].
  @visibleForTesting
  String effectLine(CameraSource s) {
    final e = s.effects;
    final mode = switch (e.background) {
      BackgroundMode.none => 0,
      BackgroundMode.blur => 1,
      BackgroundMode.image => 2,
    };
    return 'effect ${s.id} $mode ${e.blur} ${e.brightness} ${e.contrast} ${e.saturation} ${e.warmth} ${_backgroundFile(e) ?? '-'}';
  }

  void _sendEffects(CameraSource s) => _send(effectLine(s));

  CameraSource? sourceById(int id) {
    for (final s in sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  CameraSource? sourceByKey(String key) {
    for (final s in sources) {
      if (s.key == key) return s;
    }
    return null;
  }

  List<CameraSource> get visibleSources => sources.where((s) => s.visible).toList();

  /// The camera the quick controls in the top bar act on: the first one shown.
  CameraSource? get primary {
    final v = visibleSources;
    if (v.isNotEmpty) return v.first;
    return sources.isEmpty ? null : sources.first;
  }

  PhoneState get phone {
    if (sources.any((s) => s.streaming)) return PhoneState.streaming;
    if (sources.isNotEmpty) return PhoneState.connected;
    return PhoneState.waiting;
  }

  void setResolution(CameraSource s, Resolution? r) {
    s.resolutionAuto = r == null;
    if (r == null) {
      _resolutionByKey.remove(s.key);
    } else {
      _resolutionByKey[s.key] = '${r.width}x${r.height}';
    }
    _send(r == null ? 'resolution ${s.id} auto' : 'resolution ${s.id} ${r.width} ${r.height}');
    _changed();
  }

  void toggleFlip(CameraSource s) {
    s.flip = !s.flip;
    if (s.flip) {
      _flipKeys.add(s.key);
    } else {
      _flipKeys.remove(s.key);
    }
    _send('flip ${s.id} ${s.flip ? 1 : 0}');
    _changed();
  }

  /// Shows or hides a camera in the layout (it stays connected).
  void setVisible(CameraSource s, bool visible) {
    s.visible = visible;
    if (visible) {
      _hiddenKeys.remove(s.key);
    } else {
      _hiddenKeys.add(s.key);
    }
    _layoutChanged();
  }

  void disconnectCamera(CameraSource s) => _send('disconnect ${s.id}');

  /// Adds test cameras that draw a moving picture (for trying layouts without phones).
  void addSimulatedCameras(int count) => _send('simulate $count');

  // ------------------------------------------------------------------- layout

  LayoutMode layoutMode = LayoutMode.auto;
  String? templateId;
  LayoutNode layout = autoTemplateFor(0).build();
  int _autoCount = 0;

  /// The shape every camera's picture keeps inside its cell.
  ///   auto       each cell uses its own Fill or Fit setting, so the picture follows the cell.
  ///   landscape  fixed: every picture is a wide 16:9 frame, centred in its cell and cropped to fill it.
  ///   portrait   fixed: every picture is a tall 9:16 frame, centred in its cell and cropped to fill it.
  /// Turning a phone or changing the layout never changes a fixed shape.
  OrientationMode frameShape = OrientationMode.auto;

  OrientationMode get orientation => frameShape;

  void setOrientation(OrientationMode mode) {
    frameShape = mode;
    _layoutChanged();
  }

  /// Lets CamNexo choose the layout from the number of cameras.
  void useAutoLayout() {
    layoutMode = LayoutMode.auto;
    templateId = null;
    _rebuildAuto(force: true);
    _layoutChanged();
  }

  void applyTemplate(LayoutTemplate t) {
    layoutMode = LayoutMode.template;
    templateId = t.id;
    layout = t.build();
    _layoutChanged();
  }

  /// Applies a hand edit (split, remove, move a divider, pick a camera). The layout becomes Custom.
  void editLayout(LayoutNode Function(LayoutNode) change) {
    layout = change(layout);
    layoutMode = LayoutMode.custom;
    templateId = null;
    _layoutChanged();
  }

  /// Name of the layout for the top bar.
  String get layoutName {
    switch (layoutMode) {
      case LayoutMode.auto:
        return 'Auto';
      case LayoutMode.template:
        return templateById(templateId)?.name ?? 'Layout';
      case LayoutMode.custom:
        return 'Custom';
    }
  }

  void _rebuildAuto({bool force = false}) {
    if (layoutMode != LayoutMode.auto) return;
    final count = visibleSources.length;
    if (!force && count == _autoCount) return;
    _autoCount = count;
    layout = autoTemplateFor(count).build();
  }

  /// The cells with the camera each one shows. A cell takes the camera put there on purpose; the
  /// others take the remaining visible cameras in the order they connected.
  List<ResolvedCell> resolvedCells() {
    final placed = placedLeaves(layout);
    final visible = visibleSources;
    final used = <String>{};
    for (final p in placed) {
      final key = p.leaf.cameraKey;
      if (!p.leaf.empty && key != null && visible.any((s) => s.key == key)) used.add(key);
    }
    final free = visible.where((s) => !used.contains(s.key)).iterator;
    return [
      for (final p in placed)
        ResolvedCell(
          p.leaf,
          p.rect,
          p.leaf.empty
              ? null
              : p.leaf.cameraKey != null
                  ? visible.where((s) => s.key == p.leaf.cameraKey).firstOrNull
                  : (free.moveNext() ? free.current : null),
        ),
    ];
  }

  bool _pushQueued = false;

  void _layoutChanged() {
    _rebuildAuto();
    _changed();
    if (_pushQueued) return;
    _pushQueued = true;
    scheduleMicrotask(() {
      _pushQueued = false;
      _pushLayout();
    });
  }

  /// Sends the cells to the receiver, which composes the picture the virtual camera shows.
  void _pushLayout() {
    final cells = resolvedCells();
    final gap = cells.length > 1;
    final parts = <String>[];
    for (final c in cells) {
      var r = insetCell(c.rect, gap: gap);
      var cover = c.leaf.cover;
      if (frameShape != OrientationMode.auto) {
        r = fixedShape(r, landscape: frameShape == OrientationMode.landscape);
        cover = true; // a fixed frame is always filled
      }
      parts.add('${c.camera?.id ?? -1} ${r.left.toStringAsFixed(4)} ${r.top.toStringAsFixed(4)} '
          '${r.width.toStringAsFixed(4)} ${r.height.toStringAsFixed(4)} ${cover ? 1 : 0}');
    }
    _send('layout ${cells.length} ${parts.join(' ')}');
  }

  // ------------------------------------------------------------------- saving

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final text = prefs.getString(_prefsKey);
      if (text == null) return;
      final j = (jsonDecode(text) as Map).cast<String, Object?>();
      _hiddenKeys
        ..clear()
        ..addAll(((j['hidden'] as List?) ?? const []).cast<String>());
      _flipKeys
        ..clear()
        ..addAll(((j['flip'] as List?) ?? const []).cast<String>());
      _resolutionByKey
        ..clear()
        ..addAll(((j['res'] as Map?) ?? const {}).cast<String, String>());
      _effectsByKey.clear();
      ((j['fx'] as Map?) ?? const {}).forEach((k, v) {
        _effectsByKey[k as String] = CameraEffects.fromJson((v as Map).cast<String, Object?>());
      });
      layoutMode = LayoutMode.values.firstWhere((m) => m.name == j['mode'], orElse: () => LayoutMode.auto);
      templateId = j['template'] as String?;
      frameShape = OrientationMode.values.firstWhere((m) => m.name == j['shape'], orElse: () => OrientationMode.auto);
      if (layoutMode == LayoutMode.template && templateById(templateId) == null) {
        layoutMode = LayoutMode.auto; // a template from an older version that no longer exists
        templateId = null;
      }
      final tree = j['layout'];
      if (layoutMode != LayoutMode.auto && tree is Map) {
        layout = LayoutNode.fromJson(tree.cast<String, Object?>());
      }
      _rebuildAuto(force: true);
      notifyListeners();
    } catch (_) {
      // Saved settings are a convenience; start fresh if they cannot be read.
    }
  }

  Timer? _saveTimer;
  bool _persist = false; // only the running app saves; tests and previews do not

  void _save() {
    if (!_persist) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _prefsKey,
          jsonEncode({
            'mode': layoutMode.name,
            'template': templateId,
            'layout': layout.toJson(),
            'shape': frameShape.name,
            'hidden': _hiddenKeys.toList(),
            'flip': _flipKeys.toList(),
            'res': _resolutionByKey,
            'fx': {for (final e in _effectsByKey.entries) e.key: e.value.toJson()},
          }),
        );
      } catch (_) {}
    });
  }

  void _changed() {
    notifyListeners();
    _save();
  }

  void _send(String line) {
    try {
      _receiver?.stdin.writeln(line);
    } catch (_) {}
  }

  // ------------------------------------------------------------------ helpers

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
    _persist = true;
    await _load();
    await _startReceiver();
    await _startCamera();
  }

  Future<void> _startReceiver() async {
    try {
      // CAMNEXO_SIMULATE=3 starts with three test cameras (development).
      final simulate = int.tryParse(Platform.environment['CAMNEXO_SIMULATE'] ?? '') ?? 0;
      final p = await Process.start(
        '$helperDir${Platform.pathSeparator}$_receiverExe',
        [if (simulate > 0) ...['--simulate', '$simulate']],
      );
      _receiver = p;
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onReceiverLine);
      p.stderr.drain<void>();
      unawaited(p.exitCode.then((code) {
        if (_disposed) return;
        receiverListening = false;
        sources.clear();
        error ??= 'The receiver stopped (code $code). Another copy may be using port 7878.';
        notifyListeners();
      }));
      _pushLayout();
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

  // ----------------------------------------------------------- receiver output

  @visibleForTesting
  void debugHandleReceiverLine(String line) => _onReceiverLine(line);

  void _onReceiverLine(String line) {
    var changed = true;
    var layoutNeedsPush = false;

    final src = RegExp(r'^\[src (\d+)\] (.*)$').firstMatch(line);
    if (src != null) {
      final id = int.parse(src.group(1)!);
      final rest = src.group(2)!;
      layoutNeedsPush = _onSourceLine(id, rest);
    } else {
      final addr = RegExp(r'phone address:\s+(\S+)').firstMatch(line);
      final mdns = RegExp(r'\[mdns\] registered as (\S+)').firstMatch(line);
      final fxLine = RegExp(r'^\[fx\] background effects (ready|unavailable)(?: \((.*)\))?').firstMatch(line);
      if (fxLine != null) {
        fxAvailable = fxLine.group(1) == 'ready';
        fxMessage = fxLine.group(2);
      } else if (line.contains('receiver listening')) {
        receiverListening = true;
      } else if (mdns != null) {
        discoveryName = mdns.group(1);
        discoveryFailed = false;
      } else if (line.contains('[mdns]') && line.contains('FAILED')) {
        discoveryFailed = true;
      } else if (addr != null) {
        final a = addr.group(1)!;
        if (!addresses.contains(a)) addresses.add(a);
      } else if (line.contains('Cannot listen')) {
        error = 'Port 7878 is busy. Close any other CamNexo receiver and restart.';
      } else {
        changed = false;
      }
    }
    if (layoutNeedsPush) {
      _layoutChanged();
    } else if (changed) {
      notifyListeners();
    }
  }

  /// Handles one "[src N] ..." line. Returns true when the set of cameras changed, so the layout
  /// has to be recomputed and sent again.
  bool _onSourceLine(int id, String rest) {
    final connected = RegExp(r'^connected from (\S+)').firstMatch(rest);
    if (connected != null) {
      final peer = connected.group(1)!;
      final key = peer == 'simulated' ? 'simulated-$id' : peer;
      sources.removeWhere((s) => s.key == key);  // a stale entry for the same phone
      final s = CameraSource(id: id, key: key, address: peer);
      s.flip = _flipKeys.contains(key);
      s.visible = !_hiddenKeys.contains(key);
      final saved = RegExp(r'^(\d+)x(\d+)$').firstMatch(_resolutionByKey[key] ?? '');
      if (saved != null) s.pendingResolution = Resolution(int.parse(saved.group(1)!), int.parse(saved.group(2)!));
      sources.add(s);
      sources.sort((a, b) => a.id.compareTo(b.id));
      if (s.flip) _send('flip $id 1');
      s.effects = _effectsByKey[key] ?? const CameraEffects();
      if (!s.effects.isOff) _sendEffects(s);
      return true;
    }
    final s = sourceById(id);
    if (s == null) return false;

    if (rest == 'disconnected') {
      sources.remove(s);
      return true;
    }
    final name = RegExp(r'^name (.+)$').firstMatch(rest);
    if (name != null) {
      s.name = name.group(1)!.trim();
      return false;
    }
    final size = RegExp(r'^stream (\d+x\d+)').firstMatch(rest);
    if (size != null) {
      s.streamSize = size.group(1);
      return false;
    }
    final rot = RegExp(r'^rotation \d+ -> (\d+)').firstMatch(rest);
    if (rot != null) {
      s.rotation = int.parse(rot.group(1)!);
      return false;
    }
    final cap = RegExp(r'^cap sizes=(\S*) current=(\d+)x(\d+) auto=(\d)').firstMatch(rest);
    if (cap != null) {
      final list = <Resolution>[];
      for (final part in cap.group(1)!.split(',')) {
        final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(part);
        if (m != null) list.add(Resolution(int.parse(m.group(1)!), int.parse(m.group(2)!)));
      }
      list.sort((a, b) => (b.width * b.height).compareTo(a.width * a.height)); // largest first
      s.resolutions = list;
      s.currentResolution = Resolution(int.parse(cap.group(2)!), int.parse(cap.group(3)!));
      s.resolutionAuto = cap.group(4) == '1';
      // A size chosen in an earlier session is applied once the phone can take it.
      final want = s.pendingResolution;
      if (want != null) {
        s.pendingResolution = null;
        if (list.contains(want) && s.currentResolution != want) {
          s.resolutionAuto = false;
          _send('resolution ${s.id} ${want.width} ${want.height}');
        }
      }
      return false;
    }
    final rx = RegExp(r'^rx (\d+) fps in, (\d+) fps decoded, (\d+) kbps, decode errors (\d+)').firstMatch(rest);
    if (rx != null) {
      s.streaming = true;
      s.fps = int.parse(rx.group(2)!);
      s.kbps = int.parse(rx.group(3)!);
      s.decodeErrors = int.parse(rx.group(4)!);
    }
    return false;
  }

  Future<void> shutdown() async {
    _disposed = true;
    _saveTimer?.cancel();
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
    _saveTimer?.cancel();
    _receiver?.kill();
    _camera?.kill();
    super.dispose();
  }
}
