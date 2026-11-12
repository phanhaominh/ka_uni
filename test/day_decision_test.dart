import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/agenda/logic/day_decision.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';

/// Wave A R24: "do I even have lecture today?" — the one judgment behind
/// the home banner and the morning digest. The cardinal rule: emptiness
/// only means "free" while the feed is provably fresh.
void main() {
  final day = DateTime(2026, 11, 12);

  IcsOccurrence occ(String title, int hour, {bool personal = false}) =>
      IcsOccurrence(
          start: DateTime(2026, 11, 12, hour),
          end: DateTime(2026, 11, 12, hour + 1),
          title: title,
          room: "HS",
          uid: "u-$title",
          seriesEnd: null,
          endGuessed: false,
          fromPersonalIcs: personal,
          url: null);

  WebcalFeed feed(List<IcsOccurrence> o) =>
      WebcalFeed(occurrences: o, raw: "BEGIN:VCALENDAR", now: day);

  IcsChange removed(String title, {DateTime? when}) => IcsChange(
      kind: IcsChangeKind.removed,
      title: title,
      when: when ?? day.add(const Duration(hours: 8)),
      room: "");

  test("lecture day: hero answers, banner stays silent", () {
    final d = DayDecision.compute(
        feed: feed([occ("Thermo II", 11), occ("Analysis I", 8)]),
        day: day,
        feedFresh: true);
    expect(d.kind, DayDecisionKind.lectureDay);
    expect(d.bannerText(), isNull);
    expect(d.lectures.first.title, "Analysis I"); // sorted
  });

  test("free day is claimed only off a fresh feed", () {
    final d =
        DayDecision.compute(feed: feed([]), day: day, feedFresh: true);
    expect(d.kind, DayDecisionKind.freeDay);
    expect(d.bannerText(), L10n.t("agenda.dayFree"));
  });

  test("stale or absent feed NEVER says 'free'", () {
    final stale =
        DayDecision.compute(feed: feed([]), day: day, feedFresh: false);
    expect(stale.kind, DayDecisionKind.staleFeed);
    expect(stale.bannerText(), L10n.t("agenda.dayStale"));
    final none = DayDecision.compute(
        feed: null, day: day, feedFresh: true, changes: [removed("X")]);
    expect(none.kind, DayDecisionKind.noData);
    expect(none.bannerText(), isNotNull);
    // never the free wording:
    expect(none.bannerText(), isNot(L10n.t("agenda.dayFree")));
    expect(stale.bannerText(), isNot(L10n.t("agenda.dayFree")));
  });

  test("cancelled day names the delta; other days' deltas don't count", () {
    final d = DayDecision.compute(
        feed: feed([]),
        day: day,
        feedFresh: true,
        changes: [removed("21451 – Thermodynamik II"), removed("AdM V", when: DateTime(2026, 11, 15, 10))]);
    expect(d.kind, DayDecisionKind.cancelledDay);
    expect(d.cancelledTitles, ["21451 – Thermodynamik II"]); // verbatim, band-style
    expect(d.bannerText(), contains("Thermodynamik II"));
    // a busy day KEEPS the hero (banner silent) even with removals
    final busy = DayDecision.compute(
        feed: feed([occ("Lab", 14)]),
        day: day,
        feedFresh: true,
        changes: [removed("AdM V")]);
    expect(busy.kind, DayDecisionKind.lectureDay);
    expect(busy.bannerText(), isNull);
    expect(busy.cancelledTitles, ["AdM V"]); // still visible to the digest
  });

  test("personal appointments never make a lecture day", () {
    final d = DayDecision.compute(
        feed: feed([occ("Zahnarzt", 9, personal: true)]),
        day: day,
        feedFresh: true);
    expect(d.kind, DayDecisionKind.freeDay);
    expect(d.lectures, isEmpty);
  });

  test("digest wording matrix", () {
    final (t1, b1) = DayDecision.digestTexts([], []);
    expect(t1, L10n.t("notifs.digestTitleFree"));
    expect(b1, L10n.t("notifs.digestBodyFree"));

    final (t2, b2) = DayDecision.digestTexts([], ["Analysis I"]);
    expect(b2, contains("Analysis I"));

    final (t3, b3) = DayDecision.digestTexts([occ("Klausur: AdM I", 9)], []);
    expect(t3, L10n.t("notifs.digestTitleExam"));
    expect(b3, contains("09:00"));

    final (t4, b4) = DayDecision.digestTexts([occ("AdM V", 8)], ["Übung"]);
    expect(t4, L10n.t("notifs.digestTitle", [1]));
    expect(b4, contains("Übung")); // cancel hint rides along
  });
}
