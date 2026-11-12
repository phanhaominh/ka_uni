import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';
import 'mei_notifications.dart';

/// Check-in reminders for library seat bookings (plan W5).
///
/// KIT library desks need a QR check-in at the desk within 15 minutes of
/// the slot start or the booking dies (live capture lesson + the room's
/// own description text). The card shows a live countdown; this is the
/// safety net for when the app is closed: ONE notification AT the slot
/// start is what the 15-minute rule needs - a second ping inside the
/// death window would only add panic.
///
/// Id family 800..819 keyed by booking id (same rotation trick as
/// MeiNotifications.changeSlot): re-scheduling the same booking replaces
/// its own notification instead of stacking.
class LibraryNotifications {
  LibraryNotifications._();

  static const idBase = 800;
  static const idCount = 20;

  @visibleForTesting
  static int idFor(String bookingId) =>
      idBase + (bookingId.hashCode.abs() % idCount);

  /// Schedule the check-in ping for a freshly booked slot. Wall-clock
  /// [start] is Berlin time (AnnyBooking contract). Safe to await from a
  /// button handler: every platform path is try-wrapped, a dead
  /// notification stack must never sink a SUCCESSFUL booking.
  static Future<void> scheduleCheckin(
      {required String bookingId,
      required DateTime start,
      required String room}) async {
    if (!MeiNotifications.supported) return;
    final when = start;
    if (!when.isAfter(DateTime.now().add(const Duration(seconds: 30)))) {
      return; // starts (almost) now or earlier: card countdown covers it
    }
    final hhmm = '${when.hour.toString().padLeft(2, '0')}:'
        '${when.minute.toString().padLeft(2, '0')}';
    try {
      await MeiNotifications.scheduleLibraryPing(
        idFor(bookingId),
        L10n.t("library.checkinBanner", [room, hhmm]),
        L10n.t("library.checkinHint"),
        when,
        payload: "library:checkin",
      );
    } on Object catch (e) {
      if (kDebugMode) print("library checkin schedule failed: $e");
    }
  }

  /// Booking gone (cancelled / expired) -> nothing may fire for it.
  static Future<void> cancelCheckin(String bookingId) async {
    if (!MeiNotifications.supported) return;
    try {
      await MeiNotifications.cancelLibraryPing(idFor(bookingId));
    } on Object catch (e) {
      if (kDebugMode) print("library checkin cancel failed: $e");
    }
  }

  /// Logout sweep. The app's global teardown already fires
  /// [MeiNotifications.cancelAllScheduled] (covers every id including
  /// this family), but AnnyManager.signOut runs BEFORE the credentials
  /// wipe - purge here too so a lingering ping can never outlive the
  /// account whose booking it announced.
  static Future<void> cancelAll() async {
    if (!MeiNotifications.supported) return;
    try {
      for (var i = 0; i < idCount; i++) {
        await MeiNotifications.cancelLibraryPing(idBase + i);
      }
    } on Object catch (e) {
      if (kDebugMode) print("library checkin sweep failed: $e");
    }
  }
}
