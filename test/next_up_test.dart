import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/agenda/logic/next_up.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';

IcsOccurrence _occ(String title, DateTime start,
        {int minutes = 90, String room = "AVI 105"}) =>
    IcsOccurrence(
        start: start,
        end: start.add(Duration(minutes: minutes)),
        title: title,
        room: room,
        uid: title);

/// The home hero and the agenda banner share [NextUp.compute]; these pins
/// keep the extracted thresholds at exactly what the banner always used.
void main() {
  final morning = DateTime(2026, 11, 3, 8, 0);

  test("running lecture wins and reports its end time", () {
    final running = _occ("Analysis I", DateTime(2026, 11, 3, 7, 30));
    final later = _occ("Physik", DateTime(2026, 11, 3, 10, 0));
    final up = NextUp.compute([later, running], morning);
    expect(up, isNotNull);
    expect(up!.running, isTrue);
    expect(up.occ.title, "Analysis I");
    expect(up.detail, L10n.t("agenda.nowRunning", ["09:00"]));
  });

  test("thresholds: <3 min soon, <60 min minutes, <=12 h hours", () {
    final soon = NextUp.compute(
        [_occ("A", morning.add(const Duration(minutes: 2, seconds: 59)))],
        morning);
    expect(soon!.detail, L10n.t("agenda.startsSoon"));

    final mins = NextUp.compute(
        [_occ("B", morning.add(const Duration(minutes: 45)))], morning);
    expect(mins!.detail, L10n.t("agenda.startsInMin", [45]));

    final hours = NextUp.compute(
        [_occ("C", morning.add(const Duration(minutes: 720)))], morning);
    expect(hours!.detail, L10n.t("agenda.startsInHours", [12]));
  });

  test("beyond 12 h and past lectures stay silent (null)", () {
    expect(
        NextUp.compute(
            [_occ("far", morning.add(const Duration(minutes: 721)))], morning),
        isNull);
    expect(
        NextUp.compute(
            [_occ("done", morning.subtract(const Duration(hours: 3)))],
            morning),
        isNull);
    expect(NextUp.compute(const [], morning), isNull);
  });

  test("onDay keeps the overnight straddler and per-room rows", () {
    final feed = WebcalFeed(occurrences: [
      _occ("Spaet", DateTime(2026, 11, 2, 23, 0), minutes: 90), // ends 00:30
      _occ("Heute", DateTime(2026, 11, 3, 10, 0)),
      _occ("Parallel", DateTime(2026, 11, 3, 12, 0), room: "HS 104"),
      _occ("Parallel", DateTime(2026, 11, 3, 12, 0), room: "HS 30.30"),
      _occ("Morgen", DateTime(2026, 11, 4, 9, 0)),
    ], raw: "");
    final today = NextUp.onDay(feed, DateTime(2026, 11, 3));
    expect(
        today.map((o) => o.title), ["Spaet", "Heute", "Parallel", "Parallel"]);
    expect(NextUp.onDay(null, morning), isEmpty);
  });

  test("heroWindow spans today into tomorrow", () {
    final feed = WebcalFeed(occurrences: [
      _occ("Heute", DateTime(2026, 11, 3, 16, 0)),
      _occ("Morgen", DateTime(2026, 11, 4, 8, 0)),
      _occ("Uebermorgen", DateTime(2026, 11, 5, 8, 0)),
    ], raw: "");
    final w = NextUp.heroWindow(feed, DateTime(2026, 11, 3, 8));
    expect(w.map((o) => o.title), ["Heute", "Morgen"]);
  });
}
