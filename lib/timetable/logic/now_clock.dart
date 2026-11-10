import 'dart:async';

import 'package:flutter/widgets.dart';

/// Single shared minute heartbeat for all wall-time UI (now-line, running
/// chips, countdowns). One Timer chain serves every consumer instead of one
/// periodic Timer per widget; publish-on-change means a steady minute costs
/// nothing.
///
/// Repaint / ValueListenable boundaries are the CONSUMERS' job: subscribe to
/// [minutesOfDay] with a ValueListenableBuilder or a CustomPaint `repaint:`
/// around only the pixels that move. Whole-page per-tick rebuilds are
/// forbidden - the clock exists precisely so nobody rebuilds a page a minute.
class NowClock {
  NowClock._();

  /// Wall-clock minutes since midnight, published on arm and on every tick.
  static final ValueNotifier<int> minutesOfDay = ValueNotifier(0);

  /// Date of the wall clock, published ONLY when the date flips (midnight),
  /// i.e. at most once per day. Day-truncated so the notifier's equality
  /// check is the "did the day change" check.
  static final ValueNotifier<DateTime> dateOfDay =
      ValueNotifier(_dayOf(DateTime.now()));

  /// Test seam: swap in a fixed clock before arm()/debugPublish().
  static DateTime Function() timeSource = DateTime.now;

  static int _refs = 0;
  static Timer? _timer;
  static AppLifecycleListener? _lifecycle;

  /// Refcounted start: the first arm publishes immediately and schedules a
  /// one-shot timer onto the next wall-minute boundary, from then on a
  /// 60 s periodic. Every tick re-reads [timeSource], so no accumulated
  /// drift - the alignment is against wall time, not against tick count.
  static void arm() {
    if (_refs == 0) {
      _lifecycle ??=
          AppLifecycleListener(onPause: _onPaused, onResume: _onResumed);
      _publish();
      _scheduleBoundaryTick();
    }
    _refs++;
  }

  /// Release one reference; at zero refs everything is cancelled and the
  /// listeners disposed (a later arm() rebuilds them).
  static void disarm() {
    if (_refs == 0) return;
    _refs--;
    if (_refs > 0) return;
    _timer?.cancel();
    _timer = null;
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  /// Publish at [at] WITHOUT touching any timer - tests drive the two
  /// notifiers directly.
  static void debugPublish(DateTime at) {
    minutesOfDay.value = at.hour * 60 + at.minute;
    // ValueNotifier(DateTime ==) makes the once-per-day rule implicit:
    // re-publishing the same day is a silent no-op.
    dateOfDay.value = _dayOf(at);
  }

  static void _publish() {
    final now = timeSource();
    minutesOfDay.value = now.hour * 60 + now.minute;
    dateOfDay.value = _dayOf(now);
  }

  static void _scheduleBoundaryTick() {
    final now = timeSource();
    final toBoundary =
        Duration(milliseconds: (60 - now.second) * 1000 - now.millisecond);
    _timer?.cancel();
    _timer = Timer(toBoundary, () {
      _timer = null;
      if (_refs == 0) return;
      _publish();
      _timer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (_refs > 0) _publish();
      });
    });
  }

  static void _onPaused() {
    // While invisible nobody watches the line; refs stay held so a resume
    // can re-publish + realign to the next boundary immediately.
    _timer?.cancel();
    _timer = null;
  }

  static void _onResumed() {
    if (_refs == 0) return;
    _publish();
    _scheduleBoundaryTick();
  }

  static DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);
}
