import '../../exams/models/exam_list.dart';
import '../../l10n/l10n.dart';
import '../../timetable/models/webcal.dart';

/// The answer to "do I even have lecture today?" - ONE judgment shared by
/// the home banner and the 07:30 morning digest (Wave A / R24). Pure: the
/// callers feed parsed state, this decides and words it.
///
/// Honesty rule (the app's core lesson from the phantom-delta incident):
/// an EMPTY cache is never evidence of a free day. "free" may only be
/// claimed while the feed is provably fresh; otherwise the answer is
/// "timetable unavailable", never "nothing on".
enum DayDecisionKind { noData, staleFeed, freeDay, cancelledDay, lectureDay }

class DayDecision {
  final DayDecisionKind kind;

  /// The day's study-relevant occurrences, sorted, PERSONAL appointments
  /// excluded (a dentist visit is not a lecture - the line says
  /// "no LECTURES today", the hero below still shows private events).
  final List<IcsOccurrence> lectures;

  /// Titles of feed events a pending delta removed on this day - so a
  /// free day can NAME the cancellation instead of looking like an error.
  final List<String> cancelledTitles;

  const DayDecision(
      {required this.kind,
      required this.lectures,
      required this.cancelledTitles});

  static DayDecision compute(
      {required WebcalFeed? feed,
      required DateTime day,
      required bool feedFresh,
      List<IcsChange> changes = const []}) {
    final dayMid = DateTime(day.year, day.month, day.day);
    final dayEnd = dayMid.add(const Duration(days: 1));
    bool onDay(DateTime t) =>
        !t.isBefore(dayMid) && t.isBefore(dayEnd);
    // personal rows never count; VALUE=DATE all-days sit at midnight and
    // still land inside the window - the hero already tolerates them and
    // the digest wording is about lectures starting later, harmless
    final lectures = <IcsOccurrence>[
      if (feed != null)
        for (final o in feed.occurrences)
          if (!o.fromPersonalIcs && onDay(o.start)) o
    ]..sort((a, b) => a.start.compareTo(b.start));
    final cancelled = <String>[
      // titles verbatim, exactly as the agenda CHANGED band shows them -
      // one vocabulary for "what got cancelled" across banner, band, digest
      for (final c in changes)
        if (c.kind == IcsChangeKind.removed &&
            onDay(c.when) &&
            !c.title.startsWith("Due:"))
          c.title
    ];
    if (feed == null) {
      return DayDecision(
          kind: DayDecisionKind.noData, lectures: [], cancelledTitles: []);
    }
    if (lectures.isNotEmpty) {
      return DayDecision(
          kind: DayDecisionKind.lectureDay,
          lectures: lectures,
          cancelledTitles: cancelled);
    }
    // nothing study-relevant scheduled: only NOW is the staleness gate
    // load-bearing
    if (!feedFresh) {
      return DayDecision(
          kind: DayDecisionKind.staleFeed,
          lectures: [],
          cancelledTitles: cancelled);
    }
    return DayDecision(
        kind: cancelled.isNotEmpty
            ? DayDecisionKind.cancelledDay
            : DayDecisionKind.freeDay,
        lectures: [],
        cancelledTitles: cancelled);
  }

  /// One-line wording for the home banner (which renders ONLY when this is
  /// non-null - a lecture day is already answered by the hero card below
  /// it, no duplicate line).
  String? bannerText() {
    switch (kind) {
      case DayDecisionKind.noData:
      case DayDecisionKind.staleFeed:
        return L10n.t("agenda.dayStale");
      case DayDecisionKind.freeDay:
        return L10n.t("agenda.dayFree");
      case DayDecisionKind.cancelledDay:
        return L10n.t("agenda.dayCancelled", [cancelledTitles.join(", ")]);
      case DayDecisionKind.lectureDay:
        return null;
    }
  }

  /// Title/body pair for the 07:30 digest (pure, testable).
  static (String, String) digestTexts(
      List<IcsOccurrence> occ, List<String> cancelledTitles) {
    String hm(DateTime d) =>
        "${d.hour.toString().padLeft(2, "0")}:${d.minute.toString().padLeft(2, "0")}";
    if (occ.isEmpty) {
      // free day: the answer IS the message (was: silent `continue`)
      return cancelledTitles.isEmpty
          ? (L10n.t("notifs.digestTitleFree"), L10n.t("notifs.digestBodyFree"))
          : (
              L10n.t("notifs.digestTitleFree"),
              L10n.t("notifs.digestBodyCancelled",
                  [cancelledTitles.take(2).join(", ")])
            );
    }
    // a submission deadline is no "Veranstaltung"/class: a due-only day
    // must not read "Today: 1 classes", mixed days must not count it in
    // the class total, and the stated time must name a real lecture
    // (the due time itself was always honest)
    final lectureList =
        occ.where((o) => !o.title.startsWith("Due: ")).toList();
    final examOnly = lectureList.isNotEmpty &&
        lectureList.every((o) => o.title.startsWith("Klausur: "));
    final firstOcc = lectureList.isEmpty ? occ.first : lectureList.first;
    final first = hm(firstOcc.start);
    // R32.1: the lecture line names the door of that first lecture.
    // KIT placeholder rooms ("-", "--", "ILIAS", empty — the single
    // set ExamTerm.isPlaceholderRoom knows) carry no location, so the
    // line says the localized "Raum folgt" instead of going silent.
    final roomHint = lectureList.isEmpty
        ? ""
        : " · ${ExamTerm.isPlaceholderRoom(firstOcc.displayRoom)
            ? L10n.t("notifs.digestRoomTba")
            : firstOcc.displayRoom}";
    final cancelHint = cancelledTitles.isEmpty
        ? ""
        : " · ${L10n.t("notifs.digestCancelHint", [cancelledTitles.first])}";
    if (lectureList.isEmpty) {
      return (
        L10n.t("notifs.digestTitleDue"),
        L10n.t("notifs.digestBodyDue", [first, cancelHint]),
      );
    }
    return examOnly
        ? (
            L10n.t("notifs.digestTitleExam"),
            L10n.t("notifs.digestBodyExam", [first, cancelHint]),
          )
        : (
            L10n.t("notifs.digestTitle", [lectureList.length]),
            // R32.1: the lecture line names the FIRST lecture's room -
            // the door you actually walk to. KIT placeholders ("-", "--",
            // "ILIAS", empty) are no location, so they get the localized
            // "Raum folgt" instead of an empty or lying segment.
            L10n.t("notifs.digestBody",
                [first, "$roomHint$cancelHint"]),
          );
  }
}
