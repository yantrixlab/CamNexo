import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_controller.dart';
import 'preview_reader.dart';

const _glass = Color(0xB3101418); // translucent dark panel over the picture
const _border = Color(0x24FFFFFF);
const _brand = Color(0xFF2563EB);

/// Stands for "Auto" in the resolution menu (a menu entry needs a non-null value).
const _autoResolution = Resolution(0, 0);

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
  bool _panelOpen = false;

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
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 1. The picture, or the quiet waiting background.
              if (picture)
                RawImage(image: _image, fit: BoxFit.contain, filterQuality: FilterQuality.medium)
              else
                const _WaitingBackground(),
              if (!picture) Center(child: _waitingCard(context)),

              // 2. Notices (setup needed, errors).
              Positioned(
                top: 56,
                left: 12,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _showHud ? 1 : 0,
                  child: _notices(context),
                ),
              ),

              // 3. Details panel.
              if (_panelOpen) Positioned(top: 52, right: 12, child: _detailsPanel(context)),

              // 4. Top bar and bottom strip.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _fade(child: _topBar(context)),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _fade(child: _bottomBar(context)),
              ),
            ],
          ),
        ),
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
        final labels = box.maxWidth >= 940;
        return Row(
          children: [
            const SizedBox(width: 12),
            _logo(),
            const SizedBox(width: 8),
            const Text('CamNexo', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            const SizedBox(width: 12),
            _statusPill(),
            const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
            _resolutionMenu(labels),
            const SizedBox(width: 6),
            _orientationControl(labels),
            const SizedBox(width: 6),
            _iconButton(
              icon: Icons.flip,
              tooltip: 'Turn the picture 180° (for a phone mounted upside down)',
              selected: c.flip,
              onPressed: c.toggleFlip,
            ),
            _iconButton(
              icon: Icons.info_outline,
              tooltip: 'Connection details',
              selected: _panelOpen,
              onPressed: () => setState(() => _panelOpen = !_panelOpen),
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

  /// Picks the picture size the phone captures and sends: Auto, or any size the phone reports.
  /// The change applies at once; the phone rebuilds its camera and encoder without disconnecting.
  Widget _resolutionMenu(bool labels) {
    final available = c.resolutions.isNotEmpty;
    final current = c.currentResolution;
    final label = !available
        ? 'Resolution'
        : c.resolutionAuto
            ? (labels ? 'Auto · ${current?.shortName ?? ''}' : 'Auto')
            : (current?.shortName ?? 'Resolution');

    PopupMenuItem<Resolution> item(Resolution value, Widget child, bool selected) => PopupMenuItem<Resolution>(
          value: value,
          height: 38,
          child: Row(
            children: [
              SizedBox(
                width: 18,
                child: selected ? const Icon(Icons.check, size: 16, color: Color(0xFF60A5FA)) : null,
              ),
              const SizedBox(width: 6),
              Expanded(child: child),
            ],
          ),
        );

    return Tooltip(
      message: available ? 'Picture size (applies instantly)' : 'Connect a phone to choose a size',
      waitDuration: const Duration(milliseconds: 400),
      child: PopupMenuButton<Resolution>(
        enabled: available,
        tooltip: '',
        position: PopupMenuPosition.under,
        offset: const Offset(0, 6),
        color: const Color(0xF2141A22),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: _border),
        ),
        constraints: const BoxConstraints(minWidth: 250),
        onSelected: (r) => c.setResolution(r == _autoResolution ? null : r),
        itemBuilder: (context) => [
          item(
            _autoResolution,
            Row(
              children: [
                const Text('Auto', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.resolutionAuto && current != null ? 'now ${current.shortName}' : 'phone picks the size',
                    style: const TextStyle(fontSize: 11.5, color: Colors.white54),
                  ),
                ),
              ],
            ),
            c.resolutionAuto,
          ),
          const PopupMenuDivider(height: 8),
          for (final r in c.resolutions)
            item(
              r,
              Row(
                children: [
                  Text(r.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text(r.dimensions, style: const TextStyle(fontSize: 11.5, color: Colors.white54)),
                ],
              ),
              !c.resolutionAuto && current == r,
            ),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            color: _glass,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: _border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.high_quality_rounded, size: 15, color: available ? Colors.white70 : Colors.white30),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: available ? Colors.white : Colors.white38,
                ),
              ),
              Icon(Icons.arrow_drop_down, size: 18, color: available ? Colors.white70 : Colors.white30),
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
          if (streaming)
            _Pill(
              dot: Colors.greenAccent.shade400,
              text: '${c.streamSize ?? '1280x720'} · ${c.fpsDecoded} fps · '
                  '${(c.kbps / 1000).toStringAsFixed(1)} Mbps',
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
            '"Computers nearby". Tap Connect once, then it connects by itself.',
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
              if (c.phoneAddress != null) row('From', c.phoneAddress!),
              if (c.currentResolution != null)
                row('Resolution',
                    '${c.currentResolution!.dimensions}${c.resolutionAuto ? ' (auto)' : ''}'),
              if (c.phone == PhoneState.streaming) ...[
                row('Rotation', '${c.rotation}°'),
                row('Decode errors', '${c.decodeErrors}'),
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
