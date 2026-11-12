import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import 'mei_notifications.dart';
import 'notification_payload.dart';

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
///
/// R22: [MeiNotifications.resyncOnStartup] blanket-cancels every pending
/// notification on cold start (ghost sweep), and a device reboot drops all
/// zoned alarms regardless - yet the whole purpose of this ping is the
/// app-closed case. Pending pings therefore persist under ANN_checkin and
/// [replayPending] re-arms the still-future ones after startup resync (the
/// exam family's snapshot-replay precedent). The snapshot stores the
/// NOTIFICATION id, not just the booking id: String.hashCode is randomized
/// per Dart process, so re-deriving idFor across a restart would land the
/// ping on a different slot - double-posting and orphaning the old one.
/// ANN_* is inside the logout sweep, so a replay can never resurrect A.
class LibraryNotifications {
  LibraryNotifications._();

  static const idBase = 800;
  static const idCount = 20;

  /// Snapshot of armed check-in pings: [{id, nid, start, room}, ...].
  static const pendingKey = "ANN_checkin";

  @visibleForTesting
  static int idFor(String bookingId) =>
      idBase + (bookingId.hashCode.abs() % idCount);

  static Future<List<Map<String, dynamic>>> _loadPending() async {
    try {
      // LEGACY instance: written by this (main) isolate, and the file
      // documents Async-vs-legacy read disagreement for foreground keys -
      // the replay must read from the same store the scheduler wrote.
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(pendingKey);
      if (raw == null || raw.isEmpty) return [];
      return (jsonDecode(raw) as List)
          .whereType<Map>()
          .map(Map<String, dynamic>.from)
          .toList();
    } on Object catch (_) {
      return [];
    }
  }

  static Future<void> _savePending(List<Map<String, dynamic>> entries) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (entries.isEmpty) {
        await prefs.remove(pendingKey);
        return;
      }
      await prefs.setString(pendingKey, jsonEncode(entries));
    } on Object catch (_) {}
  }

  static String _hhmm(DateTime d) =>
      "${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}";

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
    // the banner's {1} is the check-in DEADLINE (start + 15 min rule) —
    // printing the start read as "already expired" at the moment it fired
    final hhmm = _hhmm(start.add(const Duration(minutes: 15)));
    // logout-during-await fence (house rule on every _zoned caller): if a
    // global logout tears the session down while the platform call is in
    // flight, cancel what we just posted instead of resurrecting a ping
    final epoch = MeiNotifications.teardownEpoch;
    try {
      final pending = await _loadPending();
      final known = pending
          .where((e) => e["id"] == bookingId)
          .map((e) => e["nid"])
          .whereType<int>()
          .toList();
      // stable slot across restarts: reuse the persisted id if known
      var nid = known.isNotEmpty ? known.first : idFor(bookingId);
      if (known.isEmpty) {
        // R23: idFor buckets into only idCount slots - two live bookings
        // sharing a bucket (~5% per pair) shared ONE notification id:
        // the later zonedSchedule replaced the earlier ping, replay won
        // twice more, and cancelling either booking silenced the
        // survivor. Probe forward for a slot not held by a DIFFERENT
        // pending booking (live bookings stay far below idCount, so the
        // probe always lands)
        final taken = pending
            .where((e) => e["id"] != bookingId)
            .map((e) => e["nid"])
            .whereType<int>()
            .toSet();
        for (var k = 0; k < idCount && taken.contains(nid); k++) {
          nid = idBase + (nid - idBase + 1) % idCount;
        }
      }
      await MeiNotifications.scheduleLibraryPing(
        nid,
        L10n.t("library.checkinBanner", [room, hhmm]),
        L10n.t("library.checkinBody"),
        when,
        payload: NotificationPayload.library,
      );
      if (epoch != MeiNotifications.teardownEpoch) {
        await MeiNotifications.cancelLibraryPing(nid);
      } else {
        pending.removeWhere((e) => e["id"] == bookingId);
        pending.add({
          "id": bookingId,
          "nid": nid,
          "start": when.millisecondsSinceEpoch,
          "room": room,
        });
        await _savePending(pending);
      }
    } on Object catch (e) {
      if (kDebugMode) print("library checkin schedule failed: $e");
    }
  }

  /// Booking gone (cancelled / expired) -> nothing may fire for it.
  static Future<void> cancelCheckin(String bookingId) async {
    if (!MeiNotifications.supported) return;
    try {
      final pending = await _loadPending();
      final e = pending.where((p) => p["id"] == bookingId).toList();
      final nid = e.isNotEmpty ? e.first["nid"] as int? : null;
      await MeiNotifications.cancelLibraryPing(nid ?? idFor(bookingId));
      if (e.isNotEmpty) {
        pending.removeWhere((p) => p["id"] == bookingId);
        await _savePending(pending);
      }
    } on Object catch (e) {
      if (kDebugMode) print("library checkin cancel failed: $e");
    }
  }

  /// Startup replay: [MeiNotifications.resyncOnStartup] ran its cold-start
  /// cancelAll (and a reboot wipes every zoned alarm); re-arm every pending
  /// check-in whose slot start still lies ahead. Scheduling with the
  /// PERSISTED nid is idempotent - the same id replaces, never stacks.
  static Future<void> replayPending() async {
    if (!MeiNotifications.supported) return;
    try {
      final pending = await _loadPending();
      if (pending.isEmpty) return;
      final now = DateTime.now();
      final live = <Map<String, dynamic>>[];
      for (final e in pending) {
        final id = e["id"];
        final startMs = e["start"];
        if (id is! String || startMs is! int) continue;
        final start = DateTime.fromMillisecondsSinceEpoch(startMs);
        if (!start.isAfter(now.add(const Duration(seconds: 30)))) {
          // R23: the check-in WINDOW outlives the ping: fired at slot
          // start, a brief cold start cancelAll'd the shade, and dropping
          // the entry here left the booking expiring at start+15 with no
          // reminder at all. Inside the window -> repost NOW (same nid:
          // show replaces, never stacks), then retire the entry.
          if (now.isBefore(start.add(const Duration(minutes: 15)))) {
            await MeiNotifications.showLibraryPingNow(
                e["nid"] is int ? e["nid"] as int : idFor(id),
                L10n.t("library.checkinBanner", [
                  e["room"] as String? ?? "",
                  _hhmm(start.add(const Duration(minutes: 15)))
                ]),
                L10n.t("library.checkinBody"),
                payload: NotificationPayload.library);
          }
          continue; // dead/expired while the app was gone
        }
        final room = e["room"] as String? ?? "";
        final nid = e["nid"] is int ? e["nid"] as int : idFor(id);
        await MeiNotifications.scheduleLibraryPing(
          nid,
          L10n.t("library.checkinBanner", [room, _hhmm(start.add(const Duration(minutes: 15)))]),
          L10n.t("library.checkinBody"),
          start,
          payload: NotificationPayload.library,
        );
        live.add(e);
      }
      await _savePending(live);
    } on Object catch (e) {
      if (kDebugMode) print("library checkin replay failed: $e");
    }
  }

  /// Logout sweep. The app's global teardown already fires
  /// [MeiNotifications.cancelAllScheduled] (covers every id including
  /// this family), but AnnyManager.signOut runs BEFORE the credentials
  /// wipe - purge here too so a lingering ping can never outlive the
  /// account whose booking it announced, and drop the replay snapshot
  /// with it (its ANN_checkin key rides the prefs sweep, but the in-app
  /// cancel path must not leave pending entries for a dead account).
  static Future<void> cancelAll() async {
    if (!MeiNotifications.supported) return;
    try {
      for (var i = 0; i < idCount; i++) {
        await MeiNotifications.cancelLibraryPing(idBase + i);
      }
      await _savePending(const []);
    } on Object catch (e) {
      if (kDebugMode) print("library checkin sweep failed: $e");
    }
  }
}
