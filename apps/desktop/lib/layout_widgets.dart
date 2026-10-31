import 'package:flutter/material.dart';

import 'desktop_controller.dart';
import 'layout_model.dart';

const glass = Color(0xB3101418); // translucent dark panel over the picture
const glassBorder = Color(0x24FFFFFF);
const brandBlue = Color(0xFF2563EB);
const _accent = Color(0xFF60A5FA);

/// Small drawing of a layout: one rounded block per cell, numbered in the order cameras fill them.
class LayoutThumbnail extends StatelessWidget {
  const LayoutThumbnail({super.key, required this.root, this.selected = false, this.width = 92});

  final LayoutNode root;
  final bool selected;
  final double width;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(width, width * 9 / 16),
      painter: _ThumbPainter(root, selected),
    );
  }
}

class _ThumbPainter extends CustomPainter {
  _ThumbPainter(this.root, this.selected);

  final LayoutNode root;
  final bool selected;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(5));
    canvas.drawRRect(frame, Paint()..color = const Color(0xFF0B0F16));
    final placed = placedLeaves(root);
    var number = 0;
    for (final p in placed) {
      final r = insetCell(p.rect, gap: placed.length > 1);
      final box = Rect.fromLTRB(r.left * size.width, r.top * size.height, r.right * size.width, r.bottom * size.height)
          .deflate(1.5);
      if (p.leaf.empty) continue;
      number++;
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, const Radius.circular(3)),
        Paint()..color = (selected ? _accent : const Color(0xFF8AA4C8)).withValues(alpha: selected ? 0.9 : 0.55),
      );
      if (box.shortestSide >= 10) {
        final tp = TextPainter(
          text: TextSpan(
            text: '$number',
            style: TextStyle(fontSize: box.shortestSide >= 16 ? 10 : 8, fontWeight: FontWeight.w700, color: const Color(0xFF0B0F16)),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, box.center - Offset(tp.width / 2, tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(_ThumbPainter old) => old.root != root || old.selected != selected;
}

/// Picture shape: Auto (each cell decides) or Fixed Landscape or Portrait (every camera keeps that
/// shape inside its cell, whatever the layout or the way the phone is held).
class PictureShapeControl extends StatelessWidget {
  const PictureShapeControl({super.key, required this.controller, this.labels = true, this.expand = false});

  final DesktopController controller;
  final bool labels;

  /// Fill the available width with three equal parts (used in the Layout panel).
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    Widget seg(OrientationMode mode, IconData icon, String label, String tip) {
      final selected = c.orientation == mode;
      final child = AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.symmetric(horizontal: labels || expand ? 9 : 7, vertical: expand ? 8 : 5),
        decoration: BoxDecoration(
          color: selected ? brandBlue : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: selected ? Colors.white : Colors.white70),
            if (labels || expand) ...[
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
      );
      final button = Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 400),
        child: InkWell(borderRadius: BorderRadius.circular(7), onTap: () => c.setOrientation(mode), child: child),
      );
      return expand ? Expanded(child: button) : button;
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: glass, borderRadius: BorderRadius.circular(9), border: Border.all(color: glassBorder)),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: [
          seg(OrientationMode.auto, Icons.screen_rotation, 'Auto',
              'Auto: every cell decides how its picture is shaped (Fill or Fit), so the picture follows the cell'),
          Container(width: 1, height: 16, margin: EdgeInsets.symmetric(horizontal: labels || expand ? 6 : 3), color: glassBorder),
          if (labels && !expand)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Text('Fixed', style: TextStyle(fontSize: 11, color: Colors.white54)),
            ),
          seg(OrientationMode.landscape, Icons.crop_landscape, 'Landscape',
              'Fixed landscape: every camera keeps a wide 16:9 frame, centred in its cell and cropped to fill it'),
          seg(OrientationMode.portrait, Icons.crop_portrait, 'Portrait',
              'Fixed portrait: every camera keeps a tall 9:16 frame, centred in its cell and cropped to fill it'),
        ],
      ),
    );
  }
}

/// The Layout menu: Auto, the ready-made templates and a way into the manual editor.
class LayoutPicker extends StatelessWidget {
  const LayoutPicker({
    super.key,
    required this.controller,
    required this.onEdit,
    required this.onClose,
  });

  final DesktopController controller;
  final VoidCallback onEdit;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final shown = c.visibleSources.length;
    Widget tile({
      required Widget thumb,
      required String title,
      required String hint,
      required bool selected,
      required VoidCallback onTap,
    }) {
      return Tooltip(
        message: hint,
        waitDuration: const Duration(milliseconds: 350),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 104,
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 7),
            decoration: BoxDecoration(
              color: selected ? brandBlue.withValues(alpha: 0.22) : const Color(0x0DFFFFFF),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: selected ? _accent : Colors.transparent, width: 1.2),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                thumb,
                const SizedBox(height: 5),
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5, fontWeight: selected ? FontWeight.w600 : FontWeight.w500, color: Colors.white)),
              ],
            ),
          ),
        ),
      );
    }

    final auto = autoTemplateFor(shown);
    return PanelShell(
      width: 372,
      title: 'Layout',
      subtitle: c.sources.isEmpty
          ? 'What apps see when several cameras are connected'
          : 'Showing $shown of ${c.sources.length} camera${c.sources.length == 1 ? '' : 's'}',
      onClose: onClose,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Picture shape', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          PictureShapeControl(controller: c, expand: true),
          const SizedBox(height: 6),
          Text(
            switch (c.orientation) {
              OrientationMode.auto => 'Auto: each camera fills or fits its own cell, so a narrow cell crops a wide picture.',
              OrientationMode.landscape =>
                'Fixed landscape: every camera keeps a wide 16:9 frame in its cell, however the phone is held.',
              OrientationMode.portrait =>
                'Fixed portrait: every camera keeps a tall 9:16 frame in its cell, however the phone is held.',
            },
            style: const TextStyle(fontSize: 11, color: Colors.white54, height: 1.3),
          ),
          const SizedBox(height: 12),
          const Text('Layout', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              tile(
                thumb: Stack(
                  alignment: Alignment.center,
                  children: [
                    LayoutThumbnail(root: auto.build(), selected: c.layoutMode == LayoutMode.auto),
                    const Positioned(
                      right: 3,
                      top: 3,
                      child: Icon(Icons.auto_awesome, size: 13, color: Color(0xFFFDE68A)),
                    ),
                  ],
                ),
                title: 'Auto',
                hint: 'Picks the layout from the number of cameras shown, and fills the cells for you',
                selected: c.layoutMode == LayoutMode.auto,
                onTap: c.useAutoLayout,
              ),
              for (final t in layoutTemplates)
                tile(
                  thumb: LayoutThumbnail(
                    root: t.build(),
                    selected: c.layoutMode == LayoutMode.template && c.templateId == t.id,
                  ),
                  title: t.name,
                  hint: t.hint,
                  selected: c.layoutMode == LayoutMode.template && c.templateId == t.id,
                  onTap: () => c.applyTemplate(t),
                ),
              if (c.layoutMode == LayoutMode.custom)
                tile(
                  thumb: LayoutThumbnail(root: c.layout, selected: true),
                  title: 'Custom',
                  hint: 'Your own layout',
                  selected: true,
                  onTap: () {},
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onEdit,
                  style: FilledButton.styleFrom(
                    backgroundColor: brandBlue,
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.dashboard_customize_outlined, size: 17),
                  label: const Text('Edit layout', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Hand the cameras out in the order they connected',
                child: OutlinedButton(
                  onPressed: () => c.editLayout(clearAssignments),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: glassBorder),
                    padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Reset cameras', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Zoom, Meet, Teams and OBS see exactly this picture as one camera.',
            style: TextStyle(fontSize: 11, color: Colors.white54, height: 1.3),
          ),
        ],
      ),
    );
  }
}

/// Floating glass card with a title, used for the Layout and Cameras panels.
class PanelShell extends StatelessWidget {
  const PanelShell({super.key, required this.width, required this.title, this.subtitle, required this.onClose, required this.child});

  final double width;
  final String title;
  final String? subtitle;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xF2121820),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: glassBorder),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    if (subtitle != null)
                      Text(subtitle!, style: const TextStyle(fontSize: 11, color: Colors.white54)),
                  ],
                ),
              ),
              IconButton(
                onPressed: onClose,
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                color: Colors.white60,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Flexible(child: SingleChildScrollView(child: child)),
        ],
      ),
    );
  }
}

/// The Cameras panel: every connected phone, with show or hide, size, flip and disconnect.
class CamerasPanel extends StatelessWidget {
  const CamerasPanel({super.key, required this.controller, required this.onClose});

  final DesktopController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return PanelShell(
      width: 360,
      title: 'Cameras',
      subtitle: c.sources.isEmpty
          ? 'No phone connected yet'
          : '${c.sources.length} connected, ${c.visibleSources.length} shown',
      onClose: onClose,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (c.sources.isEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: const Color(0x0DFFFFFF), borderRadius: BorderRadius.circular(10)),
              child: const Text(
                'Open CamNexo on a phone, on the same Wi-Fi, and tap Connect. Connect more phones the same '
                'way: each one gets its own place in the layout.',
                style: TextStyle(fontSize: 12, color: Colors.white70, height: 1.35),
              ),
            ),
          for (final s in c.sources) ...[
            _CameraCard(controller: c, source: s),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => c.addSimulatedCameras(c.sources.length >= 2 ? 1 : 2),
              style: TextButton.styleFrom(foregroundColor: Colors.white60, padding: const EdgeInsets.symmetric(horizontal: 4)),
              icon: const Icon(Icons.science_outlined, size: 15),
              label: const Text('Try layouts with test cameras', style: TextStyle(fontSize: 11.5)),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraCard extends StatelessWidget {
  const _CameraCard({required this.controller, required this.source});

  final DesktopController controller;
  final CameraSource source;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = source;
    final shown = s.visible;
    final live = s.streaming;
    final res = s.currentResolution;
    final stats = live
        ? '${s.streamSize ?? res?.dimensions ?? ''} · ${s.fps} fps · ${(s.kbps / 1000).toStringAsFixed(1)} Mbps'
        : 'Connecting…';

    Widget action(IconData icon, String tip, VoidCallback onTap, {bool on = false}) => IconButton(
          tooltip: tip,
          onPressed: onTap,
          visualDensity: VisualDensity.compact,
          iconSize: 17,
          style: IconButton.styleFrom(
            foregroundColor: on ? Colors.white : Colors.white70,
            backgroundColor: on ? brandBlue : const Color(0x0FFFFFFF),
          ),
          icon: Icon(icon),
        );

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      opacity: shown ? 1 : 0.55,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 9, 8, 9),
        decoration: BoxDecoration(
          color: const Color(0x0FFFFFFF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: glassBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(color: brandBlue.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(9)),
                  child: Icon(s.isSimulated ? Icons.science_outlined : Icons.smartphone_rounded,
                      size: 18, color: _accent),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      Row(
                        children: [
                          Icon(Icons.circle, size: 7, color: live ? Colors.greenAccent.shade400 : Colors.amber),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(stats,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11, color: Colors.white60)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                action(
                  shown ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                  shown ? 'Shown in the layout. Click to hide' : 'Hidden. Click to show in the layout',
                  () => c.setVisible(s, !shown),
                  on: shown,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: ResolutionMenu(controller: c, source: s, labels: true, wide: true)),
                const SizedBox(width: 6),
                action(Icons.flip, 'Turn the picture 180° (for a phone mounted upside down)', () => c.toggleFlip(s),
                    on: s.flip),
                const SizedBox(width: 4),
                action(Icons.link_off, 'Disconnect this phone', () => c.disconnectCamera(s)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Picks the size a phone captures and sends: Auto, or any size the phone reports. The change
/// applies at once; the phone rebuilds its camera and encoder without disconnecting.
class ResolutionMenu extends StatelessWidget {
  const ResolutionMenu({super.key, required this.controller, required this.source, required this.labels, this.wide = false});

  final DesktopController controller;
  final CameraSource? source;
  final bool labels;
  final bool wide;

  static const _auto = Resolution(0, 0);

  @override
  Widget build(BuildContext context) {
    final s = source;
    final available = s != null && s.resolutions.isNotEmpty;
    final current = s?.currentResolution;
    final label = !available
        ? 'Resolution'
        : s.resolutionAuto
            ? (labels ? 'Auto · ${current?.shortName ?? ''}' : 'Auto')
            : (current?.shortName ?? 'Resolution');

    PopupMenuItem<Resolution> item(Resolution value, Widget child, bool selected) => PopupMenuItem<Resolution>(
          value: value,
          height: 38,
          child: Row(
            children: [
              SizedBox(width: 18, child: selected ? const Icon(Icons.check, size: 16, color: _accent) : null),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: glassBorder)),
        constraints: const BoxConstraints(minWidth: 250),
        onSelected: (r) => controller.setResolution(s!, r == _auto ? null : r),
        itemBuilder: (context) => [
          item(
            _auto,
            Row(
              children: [
                const Text('Auto', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s != null && s.resolutionAuto && current != null ? 'now ${current.shortName}' : 'phone picks the size',
                    style: const TextStyle(fontSize: 11.5, color: Colors.white54),
                  ),
                ),
              ],
            ),
            s?.resolutionAuto ?? true,
          ),
          const PopupMenuDivider(height: 8),
          for (final r in s?.resolutions ?? const <Resolution>[])
            item(
              r,
              Row(
                children: [
                  Text(r.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text(r.dimensions, style: const TextStyle(fontSize: 11.5, color: Colors.white54)),
                ],
              ),
              s != null && !s.resolutionAuto && current == r,
            ),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            color: wide ? const Color(0x0FFFFFFF) : glass,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: glassBorder),
          ),
          child: Row(
            mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
            children: [
              Icon(Icons.high_quality_rounded, size: 15, color: available ? Colors.white70 : Colors.white30),
              const SizedBox(width: 6),
              Expanded(
                flex: wide ? 1 : 0,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: available ? Colors.white : Colors.white38),
                ),
              ),
              Icon(Icons.arrow_drop_down, size: 18, color: available ? Colors.white70 : Colors.white30),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------- manual editor

/// Drawn over the picture while editing: every cell with its tools, and the dividers to drag.
/// [picture] is where the 16:9 frame sits inside the window.
class LayoutEditor extends StatelessWidget {
  const LayoutEditor({super.key, required this.controller, required this.picture});

  final DesktopController controller;
  final Rect picture;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final cells = c.resolvedCells();
    final onlyOne = cells.length <= 1;

    Rect px(Rect r) => Rect.fromLTRB(
          picture.left + r.left * picture.width,
          picture.top + r.top * picture.height,
          picture.left + r.right * picture.width,
          picture.top + r.bottom * picture.height,
        );

    return Stack(
      fit: StackFit.expand,
      children: [
        for (final cell in cells)
          Positioned.fromRect(
            rect: px(cell.rect).deflate(2),
            child: _EditCell(controller: c, cell: cell, canRemove: !onlyOne),
          ),
        for (final d in splitDividers(c.layout)) _DividerHandle(controller: c, divider: d, picture: picture),
      ],
    );
  }
}

class _EditCell extends StatelessWidget {
  const _EditCell({required this.controller, required this.cell, required this.canRemove});

  final DesktopController controller;
  final ResolvedCell cell;
  final bool canRemove;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final leaf = cell.leaf;
    final cam = cell.camera;

    void assign(Leaf Function(Leaf) change) => c.editLayout((root) => updateLeaf(root, leaf.id, change));

    Widget tool(IconData icon, String tip, VoidCallback? onTap, {bool on = false}) => Tooltip(
          message: tip,
          child: InkWell(
            borderRadius: BorderRadius.circular(7),
            onTap: onTap,
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: on ? brandBlue : const Color(0x1FFFFFFF),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(icon, size: 17, color: onTap == null ? Colors.white30 : Colors.white),
            ),
          ),
        );

    final camButton = PopupMenuButton<String>(
      tooltip: 'Choose the camera for this cell',
      color: const Color(0xF2141A22),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: glassBorder)),
      onSelected: (v) {
        if (v == '*auto') {
          assign((l) => l.copyWith(clearCamera: true, empty: false));
        } else if (v == '*none') {
          assign((l) => l.copyWith(clearCamera: true, empty: true));
        } else {
          assign((l) => l.copyWith(cameraKey: v, empty: false));
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: '*auto',
          height: 36,
          child: Row(children: [
            Icon(Icons.auto_awesome, size: 15, color: !leaf.empty && leaf.cameraKey == null ? _accent : Colors.white54),
            const SizedBox(width: 8),
            const Text('Next free camera', style: TextStyle(fontSize: 12.5)),
          ]),
        ),
        for (final s in controller.sources)
          PopupMenuItem(
            value: s.key,
            height: 36,
            child: Row(children: [
              Icon(Icons.smartphone_rounded, size: 15, color: leaf.cameraKey == s.key ? _accent : Colors.white54),
              const SizedBox(width: 8),
              Expanded(child: Text(s.label, style: const TextStyle(fontSize: 12.5), overflow: TextOverflow.ellipsis)),
              if (!s.visible) const Text('hidden', style: TextStyle(fontSize: 10.5, color: Colors.white38)),
            ]),
          ),
        PopupMenuItem(
          value: '*none',
          height: 36,
          child: Row(children: [
            Icon(Icons.hide_image_outlined, size: 15, color: leaf.empty ? _accent : Colors.white54),
            const SizedBox(width: 8),
            const Text('Empty', style: TextStyle(fontSize: 12.5)),
          ]),
        ),
      ],
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(color: const Color(0x1FFFFFFF), borderRadius: BorderRadius.circular(7)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_outlined, size: 15, color: Colors.white70),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 130),
              child: Text(
                leaf.empty ? 'Empty' : (cam?.label ?? 'No camera'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 17, color: Colors.white70),
          ],
        ),
      ),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x33000000),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xCC60A5FA), width: 1.5),
      ),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xE6101418),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: glassBorder),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  camButton,
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      tool(Icons.vertical_split_outlined, 'Split into two side by side',
                          () => c.editLayout((r) => splitLeaf(r, leaf.id, SplitAxis.horizontal))),
                      const SizedBox(width: 5),
                      tool(Icons.horizontal_split_outlined, 'Split into two, one above the other',
                          () => c.editLayout((r) => splitLeaf(r, leaf.id, SplitAxis.vertical))),
                      const SizedBox(width: 5),
                      tool(
                        leaf.cover ? Icons.crop_free : Icons.fit_screen,
                        leaf.cover ? 'Filling the cell (crops the edges). Click to fit the whole picture' : 'Fitting the whole picture. Click to fill the cell',
                        () => assign((l) => l.copyWith(cover: !l.cover)),
                        on: !leaf.cover,
                      ),
                      const SizedBox(width: 5),
                      tool(Icons.delete_outline, canRemove ? 'Remove this cell' : 'The last cell cannot be removed',
                          canRemove ? () => c.editLayout((r) => removeLeaf(r, leaf.id)) : null),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DividerHandle extends StatelessWidget {
  const _DividerHandle({required this.controller, required this.divider, required this.picture});

  final DesktopController controller;
  final SplitDivider divider;
  final Rect picture;

  @override
  Widget build(BuildContext context) {
    final area = divider.area;
    final split = divider.split;
    final horizontal = split.axis == SplitAxis.horizontal;
    final areaPx = Rect.fromLTRB(
      picture.left + area.left * picture.width,
      picture.top + area.top * picture.height,
      picture.left + area.right * picture.width,
      picture.top + area.bottom * picture.height,
    );
    final at = horizontal ? areaPx.left + areaPx.width * split.ratio : areaPx.top + areaPx.height * split.ratio;
    const hit = 16.0;

    void drag(double delta) {
      final total = horizontal ? areaPx.width : areaPx.height;
      if (total <= 0) return;
      controller.editLayout((root) => setRatio(root, split.id, split.ratio + delta / total));
    }

    return Positioned(
      left: horizontal ? at - hit / 2 : areaPx.left,
      top: horizontal ? areaPx.top : at - hit / 2,
      width: horizontal ? hit : areaPx.width,
      height: horizontal ? areaPx.height : hit,
      child: MouseRegion(
        cursor: horizontal ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: horizontal ? (d) => drag(d.delta.dx) : null,
          onVerticalDragUpdate: horizontal ? null : (d) => drag(d.delta.dy),
          child: Center(
            child: Container(
              width: horizontal ? 4 : 44,
              height: horizontal ? 44 : 4,
              decoration: BoxDecoration(
                color: const Color(0xFF60A5FA),
                borderRadius: BorderRadius.circular(3),
                boxShadow: const [BoxShadow(color: Color(0x88000000), blurRadius: 6)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
