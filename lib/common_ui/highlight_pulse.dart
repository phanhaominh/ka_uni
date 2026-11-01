import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Brief (2 s by default) emphasis glow around [child], armed only when the
/// widget is BUILT with [armed] — the deep-link arrival effect for the
/// agenda's CHANGED band.
///
/// TweenAnimationBuilder instead of a controller: the emphasis follows
/// sin(t·pi), i.e. 0 -> full -> 0 in one forward sweep, so the pulse
/// extinguishes itself without a reverse pass, leaves no ticker behind, and
/// settles under fake pumps in tests.
class HighlightPulse extends StatelessWidget {
  const HighlightPulse({
    super.key,
    required this.armed,
    required this.color,
    this.duration = const Duration(seconds: 2),
    required this.child,
  });

  final bool armed;
  final Color color;
  final Duration duration;
  final Widget child;

  /// Identifies the glow layer (tests, and nothing else needs it).
  static const pulseKey = ValueKey("highlight-pulse");

  /// 0 -> 1 -> 0 over a single forward sweep; nothing lingers at rest.
  @visibleForTesting
  static double emphasis(double t) => math.sin(t * math.pi);

  @override
  Widget build(BuildContext context) {
    if (!armed) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: duration,
      curve: Curves.linear,
      // MUST forward to the builder's child parameter, or it arrives null
      child: child,
      builder: (context, t, child) {
        final e = emphasis(t);
        return DecoratedBox(
          key: pulseKey,
          decoration: BoxDecoration(
            // Material card corner (12) + Card's default margin (4): the
            // glow hugs the card edge instead of floating around the
            // margin box
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: color.withValues(alpha: 0.9 * e),
              // static width: a lerped border re-laid out the child every
              // frame (visible jitter); only the opacity breathes
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.35 * e),
                blurRadius: 16,
                spreadRadius: 2,
              ),
            ],
          ),
          child: child,
        );
      },
    );
  }
}
