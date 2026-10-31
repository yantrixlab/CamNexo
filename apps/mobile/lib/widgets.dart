import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Fades and slides its child in when it first appears. [delay] staggers lists.
class Reveal extends StatefulWidget {
  const Reveal({super.key, required this.child, this.delay = Duration.zero});

  final Widget child;
  final Duration delay;

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _t;

  @override
  void initState() {
    super.initState();
    const run = Duration(milliseconds: 480);
    final total = widget.delay + run;
    _c = AnimationController(vsync: this, duration: total)..forward();
    _t = CurvedAnimation(
      parent: _c,
      curve: Interval(widget.delay.inMilliseconds / total.inMilliseconds, 1, curve: Curves.easeOutCubic),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: _t.value,
        child: Transform.translate(offset: Offset(0, (1 - _t.value) * 14), child: child),
      ),
    );
  }
}

/// A small dot that gives off a soft pulse while [active].
class PulsingDot extends StatefulWidget {
  const PulsingDot({super.key, required this.color, this.active = true, this.size = 9});

  final Color color;
  final bool active;
  final double size;

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat();
  }

  @override
  void didUpdateWidget(PulsingDot old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.active && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox(
      width: s * 2.4,
      height: s * 2.4,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => CustomPaint(
          painter: _DotPainter(widget.color, _c.value, widget.active, s),
        ),
      ),
    );
  }
}

class _DotPainter extends CustomPainter {
  _DotPainter(this.color, this.t, this.active, this.size);

  final Color color;
  final double t;
  final bool active;
  final double size;

  @override
  void paint(Canvas canvas, Size box) {
    final c = box.center(Offset.zero);
    if (active) {
      final r = size / 2 + t * size * 0.9;
      canvas.drawCircle(c, r, Paint()..color = color.withValues(alpha: (1 - t) * 0.35));
    }
    canvas.drawCircle(c, size / 2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_DotPainter old) => old.t != t || old.color != color || old.active != active;
}

/// Rings that spread out from a centre icon: the "live" look of the streaming screen.
class Radar extends StatefulWidget {
  const Radar({super.key, required this.icon, required this.gradient, required this.ringColor, this.size = 190});

  final IconData icon;
  final Gradient gradient;
  final Color ringColor;
  final double size;

  @override
  State<Radar> createState() => _RadarState();
}

class _RadarState extends State<Radar> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2800))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final core = widget.size * 0.42;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _c,
            builder: (context, _) => CustomPaint(
              size: Size.square(widget.size),
              painter: _RingPainter(widget.ringColor, _c.value, core / 2),
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOutCubic,
            width: core,
            height: core,
            decoration: BoxDecoration(
              gradient: widget.gradient,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: widget.ringColor.withValues(alpha: 0.45), blurRadius: 28, spreadRadius: 1),
              ],
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: FadeTransition(opacity: anim, child: child)),
              child: Icon(widget.icon, key: ValueKey(widget.icon), color: Colors.white, size: core * 0.46),
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.color, this.t, this.core);

  final Color color;
  final double t;
  final double core;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final maxR = size.width / 2;
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1.0;
      final r = core + (maxR - core) * Curves.easeOut.transform(p);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = color.withValues(alpha: math.pow(1 - p, 1.6).toDouble() * 0.55);
      canvas.drawCircle(c, r, paint);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.t != t || old.color != color;
}

/// A rounded panel with a thin border, the base of every card in the app.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.radius = 22});

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Palette.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Palette.outline),
      ),
      child: child,
    );
  }
}

/// A wide button with a gradient fill that presses in slightly when touched.
class BigButton extends StatefulWidget {
  const BigButton({super.key, required this.label, required this.onPressed, this.icon, this.gradient = Palette.brand});

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Gradient gradient;

  @override
  State<BigButton> createState() => _BigButtonState();
}

class _BigButtonState extends State<BigButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: enabled
            ? () {
                HapticFeedback.lightImpact();
                widget.onPressed!();
              }
            : null,
        child: AnimatedScale(
          scale: _down ? 0.97 : 1,
          duration: const Duration(milliseconds: 110),
          child: AnimatedOpacity(
            opacity: enabled ? 1 : 0.45,
            duration: const Duration(milliseconds: 200),
            child: Container(
              height: 56,
              decoration: BoxDecoration(
                gradient: widget.gradient,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Palette.outline),
              ),
              alignment: Alignment.center,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.icon != null) ...[
                    Icon(widget.icon, size: 20, color: Colors.white),
                    const SizedBox(width: 8),
                  ],
                  Text(widget.label,
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A round icon button that glows when switched on (torch) and fades when unavailable.
class RoundToggle extends StatelessWidget {
  const RoundToggle({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: enabled
            ? () {
                HapticFeedback.selectionClick();
                onPressed!();
              }
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            gradient: selected ? Palette.brand : null,
            color: selected ? null : Palette.surfaceHi,
            shape: BoxShape.circle,
            border: Border.all(color: Palette.outline),
            boxShadow: selected
                ? [BoxShadow(color: Palette.blue.withValues(alpha: 0.4), blurRadius: 16)]
                : const [],
          ),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: enabled ? 1 : 0.35,
            child: Icon(icon, size: 21, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// One live number (size, frame rate, speed) that counts smoothly to its new value.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, required this.unit, this.decimals = 0});

  final String label;
  final double value;
  final String unit;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Panel(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        radius: 18,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Palette.textDim, fontSize: 12, letterSpacing: 0.3)),
            const SizedBox(height: 6),
            TweenAnimationBuilder<double>(
              tween: Tween(end: value),
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(v.toStringAsFixed(decimals),
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, height: 1.1)),
                    const SizedBox(width: 4),
                    Text(unit, style: const TextStyle(color: Palette.textDim, fontSize: 12)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
