import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/notifications/mei_notifications.dart';

/// Pure slot math of the 1000-1019 CHANGED heads-up band (C63 follow-up):
/// the slot is derived PER PUSH from the wall clock, because two
/// ++-rotating per-process sequences modulo 20 intersect REGARDLESS of how
/// far apart the processes started - a fresh WorkManager poll used to
/// silently replace the main process's still-unopened heads-up.
void main() {
  int slotAt(int minute, [int rotation = 0]) =>
      MeiNotifications.changeSlot(minute * 60000, rotation);

  test("two processes starting fresh share an id only within one minute", () {
    // both isolates begin their rotation at 0: pushes minutes apart (the
    // real-world case: agenda push + a poll minutes later) never collide,
    // not even at the old 30-min poll cadence
    expect(slotAt(0), isNot(slotAt(30)));
    expect(slotAt(7), isNot(slotAt(8)));
    // within one band cycle every minute maps to a distinct slot
    expect({for (var m = 0; m < 20; m++) slotAt(m)}.length, 20);
  });

  test("same minute + same rotation is the documented collision residual", () {
    // no id scheme without cross-process state can separate two isolates
    // pushing in the same minute; the band merely rotates every 20 min
    expect(slotAt(5), slotAt(5));
    expect(slotAt(0), slotAt(20)); // 20-min wrap replaces the oldest slot
  });

  test("a burst of pushes spreads over distinct slots", () {
    // the ILIAS watcher pushes up to 3 announcements back-to-back: a pure
    // minute bucket without rotation would collapse them into ONE visible
    // notification
    final burst = {for (var r = 0; r < 3; r++) slotAt(42, r)};
    expect(burst.length, 3);
  });

  test("ids stay inside the documented 1000-1019 band", () {
    for (final ms in [0, 1762761600123, 4102444800000]) {
      for (var r = 0; r < 60; r++) {
        expect(1000 + MeiNotifications.changeSlot(ms, r),
            inInclusiveRange(1000, 1019));
      }
    }
  });

  // R32.2: morning digest slot = max(07:30, first lecture - 75 min)
  // (same pure-slot-math pattern as changeSlot above)
  group("digestSlot", () {
    final day = DateTime(2026, 11, 15);
    DateTime slotAt(int h, [int m = 0]) =>
        MeiNotifications.digestSlot(day, DateTime(2026, 11, 15, h, m));

    test("a 09:30 lecture pulls the digest to 08:15", () {
      expect(slotAt(9, 30), DateTime(2026, 11, 15, 8, 15));
    });

    test("never before 07:30, free/unknown days keep the plain slot", () {
      // -75 min of an 08:00 lecture would mean a 06:45 wake-up: refused
      expect(slotAt(8), DateTime(2026, 11, 15, 7, 30));
      expect(slotAt(7, 45), DateTime(2026, 11, 15, 7, 30));
      // no lecture to catch (free day / day we cannot name) -> 07:30
      expect(MeiNotifications.digestSlot(day, null),
          DateTime(2026, 11, 15, 7, 30));
    });

    test("exact boundary: 08:45 start is still the plain slot", () {
      // 08:45 - 75min == 07:30 -> the max resolves to the same instant,
      // and a hair later already moves the alarm
      expect(slotAt(8, 45), DateTime(2026, 11, 15, 7, 30));
      expect(slotAt(8, 46), DateTime(2026, 11, 15, 7, 31));
    });

    test("an evening lecture moves the digest, never off the day", () {
      expect(slotAt(20), DateTime(2026, 11, 15, 18, 45));
    });
  });
}
