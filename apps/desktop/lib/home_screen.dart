import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_controller.dart';
import 'layout_widgets.dart';
import 'preview_reader.dart';

const _glass = glass;
const _border = glassBorder;
const _brand = brandBlue;

/// The whole window is the camera picture. Status and controls float on top of it as compact
/// glass overlays that fade out while streaming and the mouse is idle.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller, this.preview});

  final DesktopController controller;
  final PreviewReader? preview;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  StreamSubscription<ui.Image>? _sub;
  Timer? _ticker;
  Timer? _hideTimer;
  ui.Image? _image;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  bool _hudVisible = true;
  bool _infoOpen = false;
  bool _camerasOpen = false;
  bool _layoutOpen = false;
  bool _editing = false;

  bool get _panelOpen => _infoOpen || _camerasOpen || _layoutOpen || _editing;

  DesktopController get c => widget.controller;

  bool get _hasPicture =>
      _image != null && DateTime.now().difference(_lastFrame) < const Duration(milliseconds: 1500);

  @override
  void initState() {
    super.initState();
    c.addListener(_refresh);
    _sub = widget.preview?.images.listen((image) {
      final old = _image;
      setState(() {
        _image = image;
        _lastFrame = DateTime.now();
      });
      old?.dispose();
    });
    // Notice when frames stop arriving, so the waiting screen comes back.
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    c.removeListener(_refresh);
    _sub?.cancel();
    _ticker?.cancel();
    _hideTimer?.cancel();
    _image?.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  /// Shows the overlays and hides them again after a few idle seconds (only while streaming).
  void _poke() {
    if (!_hudVisible) setState(() => _hudVisible = true);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _hasPicture && !_panelOpen) setState(() => _hudVisible = false);
    });
  }

  bool get _showHud => _hudVisible || !_hasPicture || _panelOpen;

  @override
  Widget build(BuildContext context) {
    final picture = _hasPicture;
    return Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        onHover: (_) => _poke(),
        child: Listener(
          onPointerDown: (_) => _poke(),
          child: LayoutBuilder(builder: (context, box) {
            // Where the 16:9 frame sits inside the window (the picture is fitted, never stretched).
            final fitted = applyBoxFit(BoxFit.contain, const Size(16, 9), box.biggest).destination;
            final frame = Rect.fromLTWH(
              (box.maxWidth - fitted.width) / 2,
              (box.maxHeight - fitted.height) / 2,
              fitted.width,
              fitted.height,
            );
            final cells = c.resolvedCells();
            return Stack(
              fit: StackFit.expand,
              children: [
                // 1. The picture, or the quiet waiting background.
                if (picture)
                  RawImage(image: _image, fit: BoxFit.contain, filterQuality: FilterQuality.medium)
                else
                  const _WaitingBackground(),
                if (!picture && !_editing) Center(child: _waitingCard(context)),

                // 2. Names on the cells, when several cameras share the frame.
                if (picture && !_editing && cells.length > 1)
                  for (final cell in cells)
                    if (cell.camera != null)
                      Positioned(
                        left: frame.left + cell.rect.left * frame.width + 10,
                        top: frame.top + cell.rect.top * frame.height + 10 + (cell.rect.top < 0.02 ? 38 : 0), // clear of the top bar
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 200),
                          opacity: _showHud ? 1 : 0,
                          child: _Pill(
                            dot: cell.camera!.streaming ? Colors.greenAccent.shade400 : Colors.amber,
                            text: cell.camera!.label,
                          ),
                        ),
                      ),

                // 3. The manual layout editor.
                if (_editing) Positioned.fill(child: LayoutEditor(controller: c, picture: frame)),

                // 4. Notices (setup needed, errors).
                Positioned(
                  top: 56,
                  left: 12,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: _showHud ? 1 : 0,
                    child: _notices(context),
                  ),
                ),

                // 5. Panels, one at a time on the right.
                if (_infoOpen) Positioned(top: 52, right: 12, child: _detailsPanel(context)),
                if (_camerasOpen)
                  Positioned(
                    top: 52,
                    right: 12,
                    bottom: 56,
                    child: CamerasPanel(controller: c, onClose: () => setState(() => _camerasOpen = false)),
                  ),
                if (_layoutOpen)
                  Positioned(
                    top: 52,
                    right: 12,
                    bottom: 56,
                    child: LayoutPicker(
                      controller: c,
                      onClose: () => setState(() => _layoutOpen = false),
                      onEdit: () => setState(() {
                        _layoutOpen = false;
                        _editing = true;
                      }),
                    ),
                  ),

                // 6. Top bar and bottom strip.
                Positioned(top: 0, left: 0, right: 0, child: _fade(child: _topBar(context))),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: _editing ? _editBar(context) : _fade(child: _bottomBar(context)),
                ),
              ],
            );
          }),
        ),
      ),
    );
  }

  /// Opens one of the right-hand panels and closes the others.
  void _openPanel({bool info = false, bool cameras = false, bool layout = false}) {
    setState(() {
      _infoOpen = info && !_infoOpen;
      _camerasOpen = cameras && !_camerasOpen;
      _layoutOpen = layout && !_layoutOpen;
    });
  }

  /// Shown instead of the status strip while editing the layout.
  Widget _editBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xE6000000), Color(0x00000000)],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
              decoration: BoxDecoration(
                color: const Color(0xF2121820),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.dashboard_customize_outlined, size: 17, color: Color(0xFF93C5FD)),
                  const SizedBox(width: 10),
                  const Flexible(
                    child: Text(
                      'Editing layout. Drag the dividers, split a cell, or pick which camera goes where.',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: c.useAutoLayout,
                    child: const Text('Use Auto', style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: () => setState(() => _editing = false),
                    style: FilledButton.styleFrom(
                      backgroundColor: _brand,
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                    ),
                    child: const Text('Done', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fade({required Widget child}) => AnimatedOpacity(
        duration: const Duration(milliseconds: 220),
        opacity: _showHud ? 1 : 0,
        child: IgnorePointer(ignoring: !_showHud, child: child),
      );

  // ---------------------------------------------------------------- top bar

  Widget _topBar(BuildContext context) {
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
      child: LayoutBuilder(builder: (context, box) {
        final labels = box.maxWidth >= 1180;
        final compact = box.maxWidth < 1000;
        final single = c.sources.length <= 1;
        return Row(
          children: [
            const SizedBox(width: 12),
            _logo(),
            const SizedBox(width: 8),
            const Text('CamNexo', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            const SizedBox(width: 12),
            _statusPill(),
            const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
            // Quick controls for the one camera, when there is only one (the Cameras panel
            // has them for every camera).
            if (single && !compact) ...[
              ResolutionMenu(controller: c, source: c.primary, labels: labels),
              const SizedBox(width: 6),
              _orientationControl(labels),
              const SizedBox(width: 6),
              if (c.primary != null)
                _iconButton(
                  icon: Icons.flip,
                  tooltip: 'Turn the picture 180° (for a phone mounted upside down)',
                  selected: c.primary!.flip,
                  onPressed: () => c.toggleFlip(c.primary!),
                ),
              const SizedBox(width: 6),
            ],
            _layoutButton(),
            const SizedBox(width: 6),
            _camerasButton(),
            _iconButton(
              icon: Icons.info_outline,
              tooltip: 'Connection details',
              selected: _infoOpen,
              onPressed: () => _openPanel(info: true),
            ),
            const SizedBox(width: 4),
            WindowCaptionButton.minimize(
              brightness: Brightness.dark,
              onPressed: windowManager.minimize,
            ),
            WindowCaptionButton.maximize(
              brightness: Brightness.dark,
              onPressed: () async {
                if (await windowManager.isMaximized()) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              },
            ),
            WindowCaptionButton.close(
              brightness: Brightness.dark,
              onPressed: windowManager.close,
            ),
          ],
        );
      }),
    );
  }

  Widget _logo() => Image.asset(
        'assets/brand/logo.png',
        width: 26,
        height: 26,
        filterQuality: FilterQuality.medium,
        semanticLabel: 'CamNexo',
      );

  Widget _statusPill() {
    final (label, color) = switch (c.phone) {
      PhoneState.streaming => ('Streaming', Colors.greenAccent.shade400),
      PhoneState.connected => ('Connected', Colors.lightBlueAccent),
      PhoneState.waiting => ('Waiting for phone', Colors.amber),
    };
    return _Pill(
      dot: color,
      text: label,
    );
  }

  /// Opens the Layout menu: Auto, templates and the manual editor.
  Widget _layoutButton() {
    final open = _layoutOpen;
    return Tooltip(
      message: 'How several cameras share the frame',
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () => _openPanel(layout: true),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: open ? _brand : _glass,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: _border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.grid_view_rounded, size: 15, color: Colors.white70),
              const SizedBox(width: 6),
              const Text('Layout', style: TextStyle(fontSize: 12, color: Colors.white54)),
              const SizedBox(width: 6),
              Text(c.layoutName, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              const Icon(Icons.arrow_drop_down, size: 18, color: Colors.white70),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens the Cameras panel; the number is how many phones are connected.
  Widget _camerasButton() {
    final open = _camerasOpen;
    final count = c.sources.length;
    return Tooltip(
      message: 'Connected cameras',
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () => _openPanel(cameras: true),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: open ? _brand : _glass,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: _border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_outlined, size: 15, color: Colors.white70),
              const SizedBox(width: 6),
              const Text('Cameras', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: count > 0 ? const Color(0x3322C55E) : const Color(0x22FFFFFF),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('$count',
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w700, color: count > 0 ? const Color(0xFF86EFAC) : Colors.white54)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _orientationControl(bool labels) {
    Widget seg(OrientationMode mode, IconData icon, String label, String tip) {
      final selected = c.orientation == mode;
      return Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 400),
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: () => c.setOrientation(mode),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: EdgeInsets.symmetric(horizontal: labels ? 9 : 7, vertical: 5),
            decoration: BoxDecoration(
              color: selected ? _brand : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: selected ? Colors.white : Colors.white70),
                if (labels) ...[
                  const SizedBox(width: 5),
                  Text(label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: selected ? Colors.white : Colors.white70,
                      )),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: _glass,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: _border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg(OrientationMode.auto, Icons.screen_rotation, 'Auto',
              'Auto: the picture is always upright, and the frame follows how the phone is held'),
          Container(
            width: 1,
            height: 16,
            margin: EdgeInsets.symmetric(horizontal: labels ? 6 : 3),
            color: _border,
          ),
          if (labels)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Text('Fixed', style: TextStyle(fontSize: 11, color: Colors.white54)),
            ),
          seg(OrientationMode.landscape, Icons.crop_landscape, 'Landscape',
              'Fixed landscape: always a wide frame with an upright picture, cropped to fill. '
              'Turning the phone does not change it.'),
          seg(OrientationMode.portrait, Icons.crop_portrait, 'Portrait',
              'Fixed portrait: always a narrow upright frame, cropped to fill. '
              'Turning the phone does not change it.'),
        ],
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    bool selected = false,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      iconSize: 18,
      style: IconButton.styleFrom(
        foregroundColor: selected ? Colors.white : Colors.white70,
        backgroundColor: selected ? _brand : Colors.transparent,
      ),
      icon: Icon(icon),
    );
  }

  // ------------------------------------------------------------- bottom bar

  Widget _bottomBar(BuildContext context) {
    final cam = switch (c.camera) {
      CameraState.ready => ('Camera ready', Colors.greenAccent.shade400),
      CameraState.starting => ('Camera starting', Colors.lightBlueAccent),
      CameraState.setupRequired => ('Camera setup needed', Colors.amber),
      CameraState.failed => ('Camera problem', Colors.redAccent),
      CameraState.stopped => ('Camera stopped', Colors.grey),
    };
    final streaming = c.phone == PhoneState.streaming;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 22, 12, 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (streaming && c.sources.length == 1)
            _Pill(
              dot: Colors.greenAccent.shade400,
              text: '${c.sources.first.streamSize ?? '1280x720'} · ${c.sources.first.fps} fps · '
                  '${(c.sources.first.kbps / 1000).toStringAsFixed(1)} Mbps',
            ),
          if (c.sources.length > 1)
            _Pill(
              dot: Colors.greenAccent.shade400,
              text: '${c.sources.length} cameras · ${(c.sources.fold<int>(0, (a, s) => a + s.kbps) / 1000).toStringAsFixed(1)} Mbps in total',
            ),
          _Pill(dot: cam.$2, text: cam.$1),
          _Pill(
            dot: c.receiverListening ? Colors.greenAccent.shade400 : Colors.redAccent,
            text: c.receiverListening ? 'Receiver on' : 'Receiver off',
          ),
          if (c.discoveryName != null)
            _Pill(
              dot: Colors.greenAccent.shade400,
              text: 'Visible as ${c.discoveryName!.replaceFirst('CamNexo-', '')}',
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------- waiting + panels

  Widget _waitingCard(BuildContext context) {
    final address = c.addresses.isEmpty ? null : c.addresses.first;
    return Container(
      width: 400,
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
      decoration: BoxDecoration(
        color: _glass,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _brand.withValues(alpha: 0.18),
            ),
            child: const Icon(Icons.phone_android_rounded, size: 26, color: Color(0xFF93C5FD)),
          ),
          const SizedBox(height: 12),
          const Text('Waiting for your phone',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text(
            'Open CamNexo on your phone, on the same Wi-Fi. This computer shows up under '
            '"Computers nearby". Tap Connect once, then it connects by itself. '
            'You can connect several phones; they share the frame.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: Colors.white70, height: 1.35),
          ),
          if (address != null) ...[
            const SizedBox(height: 14),
            _AddressChip(address: address),
            const SizedBox(height: 4),
            const Text('Not found? Enter this address on the phone.',
                style: TextStyle(fontSize: 11, color: Colors.white54)),
          ],
        ],
      ),
    );
  }

  Widget _notices(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget card(Color accent, IconData icon, Widget body) => Container(
          width: 420,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: _glass,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: accent.withValues(alpha: 0.6)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: accent),
              const SizedBox(width: 10),
              Expanded(child: body),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (c.camera == CameraState.setupRequired)
          card(
            Colors.amber,
            Icons.build_circle_outlined,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('One-time setup needed',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                const Text(
                  'Open PowerShell as administrator, run this, then restart CamNexo:',
                  style: TextStyle(fontSize: 11.5, color: Colors.white70),
                ),
                const SizedBox(height: 6),
                SelectableText(c.registerCommand,
                    style: const TextStyle(fontSize: 11, fontFamily: 'Consolas')),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => Clipboard.setData(ClipboardData(text: c.registerCommand)),
                    icon: const Icon(Icons.copy, size: 14),
                    label: const Text('Copy command', style: TextStyle(fontSize: 11.5)),
                  ),
                ),
              ],
            ),
          ),
        if (c.error != null)
          card(
            scheme.error,
            Icons.error_outline,
            Text(c.error!, style: const TextStyle(fontSize: 12)),
          ),
      ],
    );
  }

  Widget _detailsPanel(BuildContext context) {
    Widget row(String name, String value, [Color? dot]) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              if (dot != null) ...[Icon(Icons.circle, size: 8, color: dot), const SizedBox(width: 8)],
              Expanded(
                  child: Text(name, style: const TextStyle(fontSize: 12, color: Colors.white70))),
              Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
            ],
          ),
        );
    final ok = Colors.greenAccent.shade400;
    final address = c.addresses.isEmpty ? null : c.addresses.first;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          width: 300,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          decoration: BoxDecoration(
            color: _glass,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Connection', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              row('Virtual camera', switch (c.camera) {
                CameraState.ready => 'Ready',
                CameraState.starting => 'Starting…',
                CameraState.setupRequired => 'Setup needed',
                CameraState.failed => 'Problem',
                CameraState.stopped => 'Stopped',
              }, c.camera == CameraState.ready ? ok : Colors.amber),
              row('Receiver', c.receiverListening ? 'Listening' : 'Not running',
                  c.receiverListening ? ok : Colors.redAccent),
              row('Visible to phones', c.discoveryName?.replaceFirst('CamNexo-', '') ?? '—',
                  c.discoveryName != null ? ok : Colors.amber),
              row('Phone', switch (c.phone) {
                PhoneState.streaming => 'Streaming',
                PhoneState.connected => 'Connected',
                PhoneState.waiting => 'Waiting',
              }, c.phone == PhoneState.streaming ? ok : Colors.amber),
              row('Cameras', '${c.sources.length} connected, ${c.visibleSources.length} shown'),
              for (final s in c.sources) ...[
                const Divider(height: 14, color: Color(0x1FFFFFFF)),
                row(s.label, s.address),
                if (s.currentResolution != null)
                  row('  Resolution', '${s.currentResolution!.dimensions}${s.resolutionAuto ? ' (auto)' : ''}'),
                if (s.streaming) row('  Rotation · decode errors', '${s.rotation}° · ${s.decodeErrors}'),
              ],
              if (address != null) ...[
                const Divider(height: 14, color: Color(0x1FFFFFFF)),
                const Text('Phone address (if not found automatically)',
                    style: TextStyle(fontSize: 11, color: Colors.white54)),
                const SizedBox(height: 4),
                _AddressChip(address: address),
              ],
              const Divider(height: 14, color: Color(0x1FFFFFFF)),
              const Text(
                'In Zoom, Meet, Teams or OBS, choose "CamNexo (Windows Virtual Camera)".',
                style: TextStyle(fontSize: 11, color: Colors.white60, height: 1.3),
              ),
              if (c.camera == CameraState.failed || c.camera == CameraState.stopped)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: c.restartCamera,
                    icon: const Icon(Icons.refresh, size: 14),
                    label: const Text('Restart camera', style: TextStyle(fontSize: 11.5)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small translucent label with an optional status dot.
class _Pill extends StatelessWidget {
  const _Pill({required this.text, this.dot});

  final String text;
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: _glass,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[Icon(Icons.circle, size: 8, color: dot), const SizedBox(width: 6)],
          Text(text, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

/// The phone-entry address with a copy button.
class _AddressChip extends StatelessWidget {
  const _AddressChip({required this.address});

  final String address;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => Clipboard.setData(ClipboardData(text: address.split(':').first)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0x1AFFFFFF),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(address,
                style: const TextStyle(fontSize: 13, fontFamily: 'Consolas', fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            const Icon(Icons.copy, size: 14, color: Colors.white60),
          ],
        ),
      ),
    );
  }
}

/// Quiet dark background with a soft glow, shown while no picture is arriving.
class _WaitingBackground extends StatelessWidget {
  const _WaitingBackground();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.1),
          radius: 0.9,
          colors: [Color(0xFF12203A), Color(0xFF080C14), Color(0xFF05070C)],
          stops: [0, 0.6, 1],
        ),
      ),
    );
  }
}
