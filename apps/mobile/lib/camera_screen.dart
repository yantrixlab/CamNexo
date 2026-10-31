import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'discovery_bridge.dart';
import 'stream_bridge.dart';
import 'theme.dart';
import 'widgets.dart';

/// Live camera preview plus the connection to the desktop app. While streaming, the native
/// module owns the camera (CameraX -> H.264 -> TCP), so the in-app preview is replaced by a
/// status panel.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

const _defaultPort = 7878;
const _hostPref = 'last_host';
const _pcPref = 'last_pc';
const _maxAutoRetries = 5;
final _desktopDownloadUrl = Uri.parse('https://camnexo.yantrixlab.com/#download');

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  final _bridge = StreamBridge();
  final _discovery = DiscoveryBridge();
  final _host = TextEditingController();
  StreamSubscription<StreamStatus>? _sub;
  StreamSubscription<DiscoveryEvent>? _discSub;

  // Computers found on the network, and the one used last (connected to automatically).
  final Map<String, DiscoveredPc> _pcs = {};
  String? _rememberedPc;
  bool _autoPaused =
      false; // the user pressed Stop: do not reconnect on our own
  bool _showManual = false;
  int _autoRetries = 0;
  Timer? _retryTimer;

  List<CameraDescription> _cameras = const [];
  CameraController? _controller;
  CameraLensDirection _lens = CameraLensDirection.back;
  bool _torch = false;
  double _zoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  String? _error;
  bool _starting = true;

  bool _connecting = false;
  bool _streaming = false;
  StreamStatus? _stats;
  String _targetName = '';
  String _targetAddr = '';

  bool get _busy => _connecting || _streaming;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sub = _bridge.status.listen(_onStatus, onError: (_) {});
    _discSub = _discovery.events.listen(_onDiscovery, onError: (_) {});
    _init();
    _start();
  }

  Future<void> _init() async {
    // Load what was remembered first, so a computer found right away can be matched to it.
    await _loadPrefs();
    try {
      await _discovery.start();
    } catch (_) {
      // No discovery (for example in tests): the address field still works.
    }
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_hostPref);
      if (saved != null && _host.text.isEmpty && mounted) _host.text = saved;
      final savedPc = prefs.getString(_pcPref);
      _rememberedPc = savedPc == null ? null : DiscoveredPc.baseOf(savedPc);
    } catch (_) {
      // Remembering is a convenience; everything still works without it.
    }
  }

  Future<void> _rememberPc(String name) async {
    final base = DiscoveredPc.baseOf(name);
    _rememberedPc = base;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pcPref, base);
    } catch (_) {}
  }

  void _onDiscovery(DiscoveryEvent e) {
    if (!mounted) return;
    switch (e.type) {
      case 'found':
        final pc = e.pc!;
        setState(() => _pcs[pc.name] = pc);
        _maybeAutoConnect(pc);
      case 'lost':
        setState(() => _pcs.remove(e.name));
    }
  }

  /// Connects by itself to the computer used last time, as soon as it shows up.
  void _maybeAutoConnect(DiscoveredPc pc) {
    if (_busy || _autoPaused || pc.baseName != _rememberedPc) return;
    _connectTo(pc.host, pc.port, pcName: pc.name);
  }

  Future<void> _saveHost(String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_hostPref, value);
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _discSub?.cancel();
    _retryTimer?.cancel();
    _discovery.stop().then((_) {}, onError: (_) {});
    _bridge.stop().then((_) {}, onError: (_) {});
    _host.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_busy) return; // the native module manages the camera while streaming
    if (state == AppLifecycleState.inactive) {
      final old = _controller;
      _controller = null;
      old?.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      _start();
    }
  }

  void _onStatus(StreamStatus s) {
    if (!mounted) return;
    switch (s.state) {
      case 'connecting':
        setState(() => _connecting = true);
      case 'streaming':
        _autoRetries = 0;
        setState(() {
          _connecting = false;
          _streaming = true;
          _stats = s;
          _torch = false;
          _zoom = 1.0;
        });
      case 'stats':
        setState(() {
          _stats = s;
          if (s.minZoom != null && s.maxZoom != null) {
            _minZoom = s.minZoom!;
            _maxZoom = s.maxZoom!;
            _zoom = _zoom.clamp(_minZoom, _maxZoom);
          }
        });
      case 'error':
        setState(() {
          _connecting = false;
          _streaming = false;
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(s.message ?? 'Stream error')));
        _start();
        _scheduleReconnect();
      case 'idle':
        setState(() {
          _connecting = false;
          _streaming = false;
        });
        _start();
    }
  }

  /// The preview camera start in progress, if any. Connecting waits for it: disposing the preview
  /// camera releases every camera use case in the app, so doing that after the stream's camera is
  /// open would end the stream.
  Future<void>? _startRun;

  Future<void> _start() {
    final run = _startImpl();
    _startRun = run;
    return run;
  }

  Future<void> _startImpl() async {
    if (_busy) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    final old = _controller;
    _controller = null;
    await old?.dispose();

    try {
      if (_cameras.isEmpty) _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        throw CameraException('noCamera', 'No camera found on this device.');
      }
      final description = _cameras.firstWhere(
        (c) => c.lensDirection == _lens,
        orElse: () => _cameras.first,
      );
      final controller = CameraController(
        description,
        ResolutionPreset.high, // in-app preview only; the stream resolution is set on the computer
        enableAudio: false,
      );
      await controller.initialize();
      final min = await controller.getMinZoomLevel();
      final max = await controller.getMaxZoomLevel();
      if (!mounted || _busy) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _minZoom = min;
        _maxZoom = max;
        _zoom = min;
        _torch = false;
        _starting = false;
      });
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.code == 'CameraAccessDenied'
            ? 'Camera permission is needed. Allow it in Settings, then tap Retry.'
            : (e.description ?? e.code);
        _starting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Camera is unavailable: $e';
        _starting = false;
      });
    }
  }

  /// After a dropped connection, tries the remembered computer again if it is still on the
  /// network, a few times with a pause between attempts.
  void _scheduleReconnect() {
    final name = _rememberedPc;
    if (_autoPaused || name == null || _autoRetries >= _maxAutoRetries) return;
    _autoRetries++;
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 3), () {
      final pc = _pcs.values.where((p) => p.baseName == name).lastOrNull;
      if (!mounted || _busy || _autoPaused || pc == null) return;
      _connectTo(pc.host, pc.port, pcName: pc.name);
    });
  }

  /// Connect using the address typed in the field.
  Future<void> _connect() async {
    final raw = _host.text.trim();
    if (raw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Enter your computer's IP address.")),
      );
      return;
    }
    final parts = raw.split(':');
    final host = parts.first;
    final port = parts.length > 1
        ? int.tryParse(parts[1]) ?? _defaultPort
        : _defaultPort;
    _autoPaused = false;
    await _connectTo(host, port);
  }

  /// Connect to a computer picked from the nearby list.
  Future<void> _connectToPc(DiscoveredPc pc) async {
    _autoPaused = false;
    _autoRetries = 0;
    await _connectTo(pc.host, pc.port, pcName: pc.name);
  }

  Future<void> _connectTo(String host, int port, {String? pcName}) async {
    if (_busy) return;
    _retryTimer?.cancel();
    _host.text = host;
    _saveHost(host);
    if (pcName != null) _rememberPc(pcName);

    setState(() {
      _connecting = true;
      _targetName = pcName != null
          ? (_pcs[pcName]?.displayName ?? pcName)
          : host;
      _targetAddr = '$host:$port';
    });
    // Let a preview camera that is still starting finish (it closes itself, as we are busy now),
    // then release it so the native module can open the camera.
    try {
      await _startRun;
    } catch (_) {}
    final old = _controller;
    _controller = null;
    await old?.dispose();
    if (!mounted) return;
    setState(() {});

    await _bridge.start(
      host: host,
      port: port,
      front: _lens == CameraLensDirection.front,
    );
  }

  Future<void> _disconnect() {
    // The user stopped on purpose: do not reconnect until they connect again.
    _autoPaused = true;
    _retryTimer?.cancel();
    return _bridge.stop();
  }

  Future<void> _switchCamera() async {
    _lens = _lens == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    if (_streaming) {
      // The stream keeps running; the phone rebuilds its camera. Torch and zoom start over.
      setState(() {
        _torch = false;
        _zoom = _minZoom;
      });
      try {
        await _bridge.switchCamera(front: _lens == CameraLensDirection.front);
      } on Exception {
        // The phone keeps its current camera if the switch is refused.
      }
      return;
    }
    await _start();
  }

  Future<void> _toggleTorch() async {
    final next = !_torch;
    try {
      if (_streaming) {
        await _bridge.setTorch(next);
      } else {
        await _controller?.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      }
      setState(() => _torch = next);
    } on Exception {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This camera has no torch.')),
      );
    }
  }

  Future<void> _setZoom(double value) async {
    setState(() => _zoom = value);
    if (_streaming) {
      await _bridge.setZoom(value);
    } else {
      await _controller?.setZoomLevel(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final land = size.width > size.height;
    final main = AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween(begin: 0.96, end: 1.0).animate(anim),
          child: child,
        ),
      ),
      child: _busy
          ? KeyedSubtree(
              key: ValueKey('stream$land'),
              child: _streamPanel(context, land),
            )
          : KeyedSubtree(key: ValueKey('preview$land'), child: _preview(land)),
    );
    return Scaffold(
      body: DecoratedBox(
        // A faint glow behind the top of the screen that changes colour with the connection.
        decoration: const BoxDecoration(color: Palette.bg),
        child: Stack(
          children: [
            Positioned(
              top: -140,
              left: -60,
              right: -60,
              height: 360,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 800),
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      _accent.withValues(alpha: 0.20),
                      Colors.transparent,
                    ],
                    radius: 0.75,
                  ),
                ),
              ),
            ),
            SafeArea(
              child: land
                  // Wide screen: the picture or status on the left, controls and the connection
                  // panel in a column on the right.
                  ? Column(
                      children: [
                        _header(context, land),
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(child: main),
                              SizedBox(
                                width: (size.width * 0.4).clamp(300.0, 380.0),
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 16),
                                  child: Column(
                                    children: [
                                      _controls(context, land),
                                      Flexible(
                                        child: Align(
                                          alignment: Alignment.topCenter,
                                          child: _dock(context, land),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        _header(context, land),
                        Expanded(child: main),
                        _controls(context, land),
                        _dock(context, land),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Color get _accent => _streaming
      ? Palette.green
      : _connecting
      ? Palette.blue
      : Palette.violet;

  Widget _header(BuildContext context, bool land) {
    final color = _streaming
        ? Palette.green
        : _connecting
        ? Palette.blue
        : Palette.amber;
    final label = _streaming
        ? 'Streaming'
        : _connecting
        ? 'Connecting…'
        : 'Not connected';
    return Padding(
      padding: land
          ? const EdgeInsets.fromLTRB(20, 6, 20, 6)
          : const EdgeInsets.fromLTRB(20, 14, 20, 10),
      child: Row(
        children: [
          Image.asset(
            'assets/brand/logo.png',
            width: 40,
            height: 40,
            filterQuality: FilterQuality.medium,
            semanticLabel: 'CamNexo',
          ),
          const SizedBox(width: 12),
          const Text(
            'CamNexo',
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
          const Spacer(),
          AnimatedContainer(
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.fromLTRB(6, 4, 14, 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PulsingDot(color: color, active: _busy, size: 8),
                const SizedBox(width: 2),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(
                    label,
                    key: ValueKey(label),
                    style: TextStyle(
                      color: color,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The streaming status laid out side by side for a wide screen: rings on the left, details right.
  Widget _streamPanelWide(BuildContext context) {
    final s = _stats;
    final live = _streaming;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Radar(
              size: 150,
              icon: live ? Icons.videocam_rounded : Icons.sync_rounded,
              gradient: live ? Palette.live : Palette.brand,
              ringColor: live ? Palette.green : Palette.blue,
            ),
            const SizedBox(width: 24),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      live ? 'Streaming live' : 'Connecting…',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'to $_targetName',
                      style: const TextStyle(
                        color: Palette.textDim,
                        fontSize: 15,
                      ),
                    ),
                    if (_targetAddr.isNotEmpty)
                      Text(
                        _targetAddr,
                        style: const TextStyle(
                          color: Color(0x66FFFFFF),
                          fontSize: 12,
                        ),
                      ),
                    if (live && s != null) ...[
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          StatTile(
                            label: 'SIZE',
                            value: s.height.toDouble(),
                            unit: 'p',
                          ),
                          const SizedBox(width: 8),
                          StatTile(
                            label: 'RATE',
                            value: s.fps.toDouble(),
                            unit: 'fps',
                          ),
                          const SizedBox(width: 8),
                          StatTile(
                            label: 'SPEED',
                            value: s.kbps / 1000,
                            unit: 'Mbps',
                            decimals: 1,
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Reveal(
                        delay: const Duration(milliseconds: 250),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.layers_rounded,
                              size: 16,
                              color: Palette.blue,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                [
                                  'You can switch apps; CamNexo keeps streaming.',
                                  if (s.dropped > 0)
                                    '${s.dropped} frames dropped.',
                                ].join(' '),
                                style: const TextStyle(
                                  color: Palette.textDim,
                                  fontSize: 12,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _streamPanel(BuildContext context, bool land) {
    if (land) return _streamPanelWide(context);
    final s = _stats;
    final live = _streaming;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 380),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 8),
            Radar(
              icon: live ? Icons.videocam_rounded : Icons.sync_rounded,
              gradient: live ? Palette.live : Palette.brand,
              ringColor: live ? Palette.green : Palette.blue,
            ),
            const SizedBox(height: 8),
            Text(
              live ? 'Streaming live' : 'Connecting…',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              live ? 'to $_targetName' : 'to $_targetName',
              style: const TextStyle(color: Palette.textDim, fontSize: 15),
              textAlign: TextAlign.center,
            ),
            if (_targetAddr.isNotEmpty)
              Text(
                _targetAddr,
                style: const TextStyle(color: Color(0x66FFFFFF), fontSize: 12),
              ),
            if (live && s != null) ...[
              const SizedBox(height: 22),
              Row(
                children: [
                  StatTile(
                    label: 'RESOLUTION',
                    value: s.height.toDouble(),
                    unit: 'p',
                  ),
                  const SizedBox(width: 10),
                  StatTile(
                    label: 'FRAME RATE',
                    value: s.fps.toDouble(),
                    unit: 'fps',
                  ),
                  const SizedBox(width: 10),
                  StatTile(
                    label: 'SPEED',
                    value: s.kbps / 1000,
                    unit: 'Mbps',
                    decimals: 1,
                  ),
                ],
              ),
              if (s.dropped > 0 ||
                  (s.orientation != null && s.orientation != 'auto')) ...[
                const SizedBox(height: 10),
                Text(
                  [
                    if (s.dropped > 0) '${s.dropped} frames dropped',
                    if (s.orientation != null && s.orientation != 'auto')
                      'Frame: ${s.orientation}${s.flip ? ' (flipped)' : ''}',
                  ].join('  ·  '),
                  style: const TextStyle(color: Palette.textDim, fontSize: 12),
                ),
              ],
              const SizedBox(height: 18),
              Reveal(
                delay: const Duration(milliseconds: 250),
                child: Panel(
                  radius: 18,
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.layers_rounded,
                        size: 20,
                        color: Palette.blue,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'You can switch to other apps. CamNexo keeps streaming in the background; '
                          'stop it here or from the notification.\n'
                          'Pick "CamNexo" as the camera in your video app.',
                          style: const TextStyle(
                            color: Palette.textDim,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _preview(bool land) {
    final c = _controller;
    if (_error != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Panel(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: Palette.red.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.videocam_off_rounded,
                    size: 28,
                    color: Palette.red,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Palette.textDim, height: 1.4),
                ),
                const SizedBox(height: 18),
                FilledButton(onPressed: _start, child: const Text('Retry')),
              ],
            ),
          ),
        ),
      );
    }
    if (_starting || c == null || !c.value.isInitialized) {
      return const Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }
    return Padding(
      padding: land
          ? const EdgeInsets.fromLTRB(20, 4, 12, 12)
          : const EdgeInsets.symmetric(horizontal: 20),
      child: Center(
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: Palette.outline, width: 1.2),
            boxShadow: [
              BoxShadow(
                color: Palette.violet.withValues(alpha: 0.18),
                blurRadius: 40,
                spreadRadius: -6,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(25),
            child: Stack(
              alignment: Alignment.topLeft,
              children: [
                // CameraPreview sizes and turns itself to match how the phone is held.
                land
                    ? CameraPreview(c)
                    : AspectRatio(
                        aspectRatio: 1 / c.value.aspectRatio,
                        child: CameraPreview(c),
                      ),
                Positioned(
                  left: 12,
                  top: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'PREVIEW',
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Zoom, torch and camera switch: one slim bar above the bottom panel.
  Widget _controls(BuildContext context, bool land) {
    final ready = _streaming || (_controller?.value.isInitialized ?? false);
    final canZoom = ready && _maxZoom > _minZoom;
    return Padding(
      padding: land
          ? const EdgeInsets.only(bottom: 10)
          : const EdgeInsets.fromLTRB(20, 10, 20, 12),
      child: Panel(
        radius: 26,
        padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
        child: Row(
          children: [
            const Icon(Icons.zoom_in_rounded, size: 22, color: Palette.textDim),
            Expanded(
              child: Slider(
                value: _zoom.clamp(_minZoom, _maxZoom),
                min: _minZoom,
                max: _maxZoom > _minZoom ? _maxZoom : _minZoom + 0.01,
                onChanged: canZoom ? _setZoom : null,
              ),
            ),
            SizedBox(
              width: 42,
              child: Text(
                '${_zoom.toStringAsFixed(1)}x',
                textAlign: TextAlign.end,
                style: const TextStyle(
                  color: Palette.textDim,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 10),
            RoundToggle(
              icon: _torch ? Icons.flash_on_rounded : Icons.flash_off_rounded,
              tooltip: 'Torch',
              selected: _torch,
              onPressed: ready ? _toggleTorch : null,
            ),
            const SizedBox(width: 8),
            RoundToggle(
              icon: Icons.cameraswitch_rounded,
              tooltip: 'Switch camera',
              onPressed:
                  _streaming || (_cameras.length > 1 && !_starting && !_busy)
                  ? _switchCamera
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  /// The bottom panel: nearby computers when idle, the Stop button while connecting or streaming.
  Widget _dock(BuildContext context, bool land) {
    final content = AnimatedSize(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        switchInCurve: Curves.easeOutCubic,
        transitionBuilder: (child, anim) =>
            FadeTransition(opacity: anim, child: child),
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          children: [...previous, ?current],
        ),
        child: _busy
            ? SizedBox(
                key: const ValueKey('stop'),
                width: double.infinity,
                child: BigButton(
                  label: _streaming ? 'Stop streaming' : 'Cancel',
                  icon: Icons.stop_rounded,
                  gradient: Palette.stop,
                  onPressed: _disconnect,
                ),
              )
            : KeyedSubtree(
                key: const ValueKey('nearby'),
                child: _nearby(context),
              ),
      ),
    );
    if (land) {
      // Side panel: a rounded card that scrolls if the list is longer than the screen.
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Palette.surface,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: Palette.outline),
        ),
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(child: content),
      );
    }
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Palette.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        border: Border(top: BorderSide(color: Palette.outline)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: content,
    );
  }

  /// Opens the download page for the Windows app in the browser.
  Future<void> _openDesktopDownload() async {
    var opened = false;
    try {
      opened = await launchUrl(_desktopDownloadUrl, mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Open camnexo.yantrixlab.com on your computer to download it.')),
      );
    }
  }

  Widget _nearby(BuildContext context) {
    // One row per machine: leftover announcements of the same computer share its address.
    final byAddress = <String, DiscoveredPc>{};
    for (final pc in _pcs.values) {
      byAddress['${pc.host}:${pc.port}'] = pc;
    }
    final pcs = byAddress.values.toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Computers nearby',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: pcs.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'Searching your Wi-Fi… Install the free CamNexo app on your Windows PC to connect.',
                          style: TextStyle(
                            color: Palette.textDim,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    for (var i = 0; i < pcs.length; i++)
                      Reveal(
                        key: ValueKey(pcs[i].name),
                        delay: Duration(milliseconds: 60 * i),
                        child: _pcTile(pcs[i]),
                      ),
                  ],
                ),
        ),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          children: [
            TextButton(
              onPressed: () => setState(() => _showManual = !_showManual),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 36),
              ),
              child: Text(
                _showManual ? 'Hide manual address' : 'Enter address manually',
              ),
            ),
            TextButton.icon(
              onPressed: _openDesktopDownload,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 36),
              ),
              icon: const Icon(Icons.desktop_windows_outlined, size: 18),
              label: const Text('Get the Windows app'),
            ),
          ],
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _showManual
              ? Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _host,
                          keyboardType: TextInputType.url,
                          decoration: const InputDecoration(
                            labelText: 'Computer IP address',
                            hintText: '192.168.1.20',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: _connect,
                        child: const Text('Connect'),
                      ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _pcTile(DiscoveredPc pc) {
    final remembered = pc.baseName == _rememberedPc;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Palette.surfaceHi,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _connectToPc(pc),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Palette.outline),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    gradient: Palette.brand,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Icon(
                    Icons.desktop_windows_rounded,
                    size: 21,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pc.displayName,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        remembered
                            ? '${pc.host} · connects automatically'
                            : pc.host,
                        style: const TextStyle(
                          color: Palette.textDim,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  onPressed: () => _connectToPc(pc),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    minimumSize: const Size(0, 38),
                  ),
                  child: const Text('Connect'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
