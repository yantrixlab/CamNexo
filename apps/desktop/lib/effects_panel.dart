import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'desktop_controller.dart';
import 'effects_model.dart';
import 'layout_widgets.dart';

const _accent = Color(0xFF60A5FA);

/// The Effects panel: blur or replace the background, pick a look, and adjust colours. Everything is
/// applied to the picture the virtual camera sends, so every app sees it.
class EffectsPanel extends StatefulWidget {
  const EffectsPanel({super.key, required this.controller, required this.onClose});

  final DesktopController controller;
  final VoidCallback onClose;

  @override
  State<EffectsPanel> createState() => _EffectsPanelState();
}

class _EffectsPanelState extends State<EffectsPanel> {
  String? _selectedKey;

  DesktopController get c => widget.controller;

  CameraSource? get _selected {
    for (final s in c.sources) {
      if (s.key == _selectedKey) return s;
    }
    return c.sources.isEmpty ? null : c.sources.first;
  }

  void _set(CameraSource s, CameraEffects e) => c.setEffects(s, e);

  Future<void> _chooseImage(CameraSource s) async {
    const types = XTypeGroup(label: 'Pictures', extensions: ['jpg', 'jpeg', 'png', 'bmp', 'gif']);
    final file = await openFile(acceptedTypeGroups: [types]);
    if (file == null) return;
    _set(s, s.effects.copyWith(background: BackgroundMode.image, customImage: file.path));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = _selected;
        return PanelShell(
          width: 372,
          title: 'Effects',
          subtitle: s == null ? 'Connect a phone to use effects' : 'Applied to what Zoom, Meet, Teams and OBS see',
          onClose: widget.onClose,
          child: s == null ? _empty() : _body(s),
        );
      },
    );
  }

  Widget _empty() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: const Color(0x0DFFFFFF), borderRadius: BorderRadius.circular(10)),
        child: const Text(
          'Once a phone is connected you can blur or replace the background behind you and choose a colour look.',
          style: TextStyle(fontSize: 12, color: Colors.white70, height: 1.35),
        ),
      );

  Widget _section(String title, Widget child) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            child,
          ],
        ),
      );

  Widget _chip(String label, bool selected, VoidCallback onTap) => ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 11.5)),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
        selectedColor: brandBlue,
        backgroundColor: const Color(0x0FFFFFFF),
        side: const BorderSide(color: glassBorder),
        showCheckmark: false,
      );

  Widget _body(CameraSource s) {
    final fx = s.effects;
    Widget modeButton(BackgroundMode mode, IconData icon, String label) {
      final on = fx.background == mode;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _set(s, fx.copyWith(background: mode)),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(color: on ? brandBlue : Colors.transparent, borderRadius: BorderRadius.circular(8)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: on ? Colors.white : Colors.white70),
                const SizedBox(height: 3),
                Text(label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: on ? Colors.white : Colors.white70)),
              ],
            ),
          ),
        ),
      );
    }

    final look = fx.look;
    final showWarning = !c.fxAvailable && c.receiverListening;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (c.sources.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final cam in c.sources) _chip(cam.label, cam.key == s.key, () => setState(() => _selectedKey = cam.key))],
            ),
          ),
        if (showWarning)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0x1AF59E0B),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0x66F59E0B)),
            ),
            child: Text(
              'Background effects are not available in this install${c.fxMessage == null ? '' : ' (${c.fxMessage})'}. '
              'Colour looks still work.',
              style: const TextStyle(fontSize: 11.5, color: Color(0xFFFCD34D), height: 1.3),
            ),
          ),
        _section(
          'Background',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(color: const Color(0x0FFFFFFF), borderRadius: BorderRadius.circular(10)),
                child: Row(children: [
                  modeButton(BackgroundMode.none, Icons.block, 'None'),
                  modeButton(BackgroundMode.blur, Icons.blur_on, 'Blur'),
                  modeButton(BackgroundMode.image, Icons.image_outlined, 'Picture'),
                ]),
              ),
              if (fx.background == BackgroundMode.blur) ...[
                const SizedBox(height: 10),
                _FxSlider(label: 'Blur strength', value: fx.blur, min: 0, max: 100, onChanged: (v) => _set(s, fx.copyWith(blur: v))),
              ],
              if (fx.background == BackgroundMode.image) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final b in builtInBackgrounds)
                      _BackgroundTile(
                        label: b.name,
                        selected: fx.customImage == null && fx.builtIn == b.id,
                        onTap: () => _set(s, fx.copyWith(builtIn: b.id, clearCustomImage: true)),
                        child: Image.asset('assets/backgrounds/${b.id}.jpg', fit: BoxFit.cover, cacheWidth: 220),
                      ),
                    _BackgroundTile(
                      label: fx.customImage == null ? 'Choose your own picture' : fx.customImage!.split(RegExp(r'[\\/]')).last,
                      selected: fx.customImage != null,
                      onTap: () => _chooseImage(s),
                      child: Container(
                        color: const Color(0xFF1B2230),
                        child: const Icon(Icons.add_photo_alternate_outlined, color: Colors.white70, size: 22),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        _section(
          'Look',
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final p in lookPresets) _chip(p.name, look?.id == p.id, () => _set(s, fx.withLook(p)))],
          ),
        ),
        _section(
          'Adjust',
          Column(
            children: [
              _FxSlider(label: 'Brightness', value: fx.brightness, min: -100, max: 100, onChanged: (v) => _set(s, fx.copyWith(brightness: v))),
              _FxSlider(label: 'Contrast', value: fx.contrast, min: -100, max: 100, onChanged: (v) => _set(s, fx.copyWith(contrast: v))),
              _FxSlider(label: 'Colour', value: fx.saturation, min: -100, max: 100, onChanged: (v) => _set(s, fx.copyWith(saturation: v))),
              _FxSlider(label: 'Warmth', value: fx.warmth, min: -100, max: 100, onChanged: (v) => _set(s, fx.copyWith(warmth: v))),
            ],
          ),
        ),
        Row(
          children: [
            if (c.sources.length > 1) ...[
              Expanded(
                child: OutlinedButton(
                  onPressed: () => c.setEffectsForAll(fx),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: glassBorder),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Apply to all cameras', style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
            ],
            OutlinedButton(
              onPressed: fx.isOff ? null : () => _set(s, const CameraEffects()),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white70,
                side: const BorderSide(color: glassBorder),
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('Reset', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Effects run on this computer, on the picture from each phone. A background effect works best with '
          'even light and one person in front of the camera.',
          style: TextStyle(fontSize: 11, color: Colors.white54, height: 1.3),
        ),
      ],
    );
  }
}

/// A slider with its name and value on one line.
class _FxSlider extends StatelessWidget {
  const _FxSlider({required this.label, required this.value, required this.min, required this.max, required this.onChanged});

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 82, child: Text(label, style: const TextStyle(fontSize: 11.5, color: Colors.white70))),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7)),
            child: Slider(
              value: value.toDouble().clamp(min.toDouble(), max.toDouble()),
              min: min.toDouble(),
              max: max.toDouble(),
              onChanged: (v) => onChanged(v.round()),
            ),
          ),
        ),
        SizedBox(width: 34, child: Text('$value', textAlign: TextAlign.end, style: const TextStyle(fontSize: 11.5, color: Colors.white54))),
      ],
    );
  }
}

class _BackgroundTile extends StatelessWidget {
  const _BackgroundTile({required this.label, required this.selected, required this.onTap, required this.child});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 76,
          height: 46,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: selected ? _accent : glassBorder, width: selected ? 2 : 1),
          ),
          child: ClipRRect(borderRadius: BorderRadius.circular(6), child: SizedBox.expand(child: child)),
        ),
      ),
    );
  }
}
