import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Live camera preview with the phone-side controls from the product flow:
/// front/back, resolution, torch and zoom. Streaming to the desktop is added later.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

enum _Quality {
  p720('720p', ResolutionPreset.high),
  p1080('1080p', ResolutionPreset.veryHigh);

  const _Quality(this.label, this.preset);
  final String label;
  final ResolutionPreset preset;
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  List<CameraDescription> _cameras = const [];
  CameraController? _controller;
  CameraLensDirection _lens = CameraLensDirection.back;
  _Quality _quality = _Quality.p720;
  bool _torch = false;
  double _zoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  String? _error;
  bool _starting = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The camera is released when the app is backgrounded and reopened on return.
    if (state == AppLifecycleState.inactive) {
      final old = _controller;
      _controller = null;
      old?.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      _start();
    }
  }

  Future<void> _start() async {
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
        _quality.preset,
        enableAudio: false,
      );
      await controller.initialize();
      final min = await controller.getMinZoomLevel();
      final max = await controller.getMaxZoomLevel();
      if (!mounted) {
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

  Future<void> _switchCamera() async {
    _lens = _lens == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    await _start();
  }

  Future<void> _setQuality(_Quality q) async {
    if (q == _quality) return;
    _quality = q;
    await _start();
  }

  Future<void> _toggleTorch() async {
    final c = _controller;
    if (c == null) return;
    try {
      final next = !_torch;
      await c.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      setState(() => _torch = next);
    } on CameraException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This camera has no torch.')),
      );
    }
  }

  Future<void> _setZoom(double value) async {
    setState(() => _zoom = value);
    await _controller?.setZoomLevel(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _header(context),
            Expanded(child: _preview()),
            _controls(context),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Text('CamNexo',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const Spacer(),
          Chip(
            avatar: const Icon(Icons.circle, size: 10, color: Colors.amber),
            label: const Text('Not connected'),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _preview() {
    final c = _controller;
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off, size: 48),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 16),
              FilledButton(onPressed: _start, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_starting || c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: AspectRatio(
          aspectRatio: 1 / c.value.aspectRatio,
          child: CameraPreview(c),
        ),
      ),
    );
  }

  Widget _controls(BuildContext context) {
    final ready = _controller?.value.isInitialized ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.zoom_in),
              Expanded(
                child: Slider(
                  value: _zoom.clamp(_minZoom, _maxZoom),
                  min: _minZoom,
                  max: _maxZoom > _minZoom ? _maxZoom : _minZoom + 0.01,
                  onChanged: ready && _maxZoom > _minZoom ? _setZoom : null,
                ),
              ),
              SizedBox(
                width: 44,
                child: Text('${_zoom.toStringAsFixed(1)}x',
                    textAlign: TextAlign.end),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              SegmentedButton<_Quality>(
                segments: [
                  for (final q in _Quality.values)
                    ButtonSegment(value: q, label: Text(q.label)),
                ],
                selected: {_quality},
                onSelectionChanged: (s) => _setQuality(s.first),
                showSelectedIcon: false,
              ),
              Row(
                children: [
                  IconButton.filledTonal(
                    tooltip: 'Torch',
                    isSelected: _torch,
                    onPressed: ready ? _toggleTorch : null,
                    icon: const Icon(Icons.flash_off),
                    selectedIcon: const Icon(Icons.flash_on),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Switch camera',
                    onPressed: _cameras.length > 1 && !_starting
                        ? _switchCamera
                        : null,
                    icon: const Icon(Icons.cameraswitch),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
