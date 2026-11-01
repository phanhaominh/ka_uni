/// Payload strings attached to every notification (Android `payload` field)
/// and read back from the tap response. Mapped to destinations by
/// `NotificationDeepLink.parse` in navigation/notification_deep_links.dart.
///
/// Pure Dart on purpose: also imported by the WorkManager background
/// isolate, which must never drag the widget tree into its snapshot.
class NotificationPayload {
  NotificationPayload._();

  /// Morning digest -> agenda, top. Also the destination of SignMeUp
  /// registration reminders: the open procedures they name render only
  /// in the agenda's SignMeUp card, never on the exams page.
  static const agenda = 'agenda';

  /// Lecture reminder -> agenda, scrolled to the today section.
  static const agendaToday = 'agenda:today';

  /// CHANGED timetable-delta push -> agenda with a brief emphasis on the
  /// CHANGED band.
  static const agendaChanges = 'agenda:changes';

  /// Exam-registration deadline -> exams page. (SignMeUp registration ->
  /// agenda via [agenda]; /exams renders no SignMeUp content.)
  static const exams = 'exams';
}
