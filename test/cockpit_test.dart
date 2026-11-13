import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/agenda/logic/cockpit.dart';
import 'package:kit_mobile/exams/models/exam_list.dart';
import 'package:kit_mobile/signmeup/signmeup_manager.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';

/// Wave C R25: one timeline, three sources; the fences the card relies on.
void main() {
  final now = DateTime(2026, 11, 12, 9); // Thursday

  IcsOccurrence occ(String uid, DateTime start, String title) => IcsOccurrence(
      start: start,
      end: start.add(const Duration(hours: 1)),
      title: title,
      room: "",
      uid: uid);

  ExamEntry exam(String title,
          {bool registered = false,
          ExamWindowStatus status = ExamWindowStatus.open,
          DateTime? wStart,
          DateTime? wEnd,
          DateTime? deregEnd}) =>
      ExamEntry(
          examNumber: "01-XX",
          title: title,
          examiners: "",
          examType: "",
          registered: registered,
          windowStatus: status,
          windowStart: wStart,
          windowEnd: wEnd,
          deregEnd: deregEnd);

  SignMeUpProcedure proc(int id, String name,
          {DateTime? start, DateTime? end}) =>
      SignMeUpProcedure.fromJson({
        "id": id,
        "name": name,
        "registrationStart": start?.toIso8601String(),
        "registrationEnd": end?.toIso8601String(),
      });

  test("sources merge into one date-sorted timeline", () {
    final plan = cockpitPlan(
      occurrences: [
        occ("kauni-due-3038952-x", DateTime(2026, 11, 20, 18),
            "Due: AdvMath - Übungsblatt 3"),
        occ("kauni-exam-1-a", DateTime(2026, 12, 20, 8), "Klausur: Mech I"),
        occ("regular-event", DateTime(2026, 11, 18), "Vorlesung"),
      ],
      exams: [
        exam("Thermodynamik",
            wEnd: DateTime(2026, 11, 17, 12), wStart: DateTime(2026, 11, 1)),
      ],
      procedures: [
        proc(7, "Solid Mechanics Tutorial",
            end: DateTime(2026, 11, 25, 12),
            start: DateTime(2026, 11, 10, 8)),
      ],
      registeredProcedureIds: {},
      smuProven: true,
      now: now,
    );
    expect(plan.map((i) => i.kind).toList(), [
      CockpitKind.examSignupOpen,
      CockpitKind.due,
      CockpitKind.smuOpen,
      CockpitKind.examSitting,
    ]);
  });

  test("today is the day sections' job; cockpit starts at tomorrow", () {
    final plan = cockpitPlan(
      occurrences: [occ("kauni-due-1-a", DateTime(2026, 11, 12, 23, 45), "Due: today")],
      exams: [],
      procedures: [],
      registeredProcedureIds: {},
      smuProven: true,
      now: now,
    );
    expect(plan, isEmpty);
  });

  test("horizon caps the tail", () {
    final plan = cockpitPlan(
      occurrences: [
        occ("kauni-due-1-b", DateTime(2027, 1, 30, 18), "far out")
      ],
      exams: [],
      procedures: [],
      registeredProcedureIds: {},
      smuProven: true,
      now: now,
    );
    expect(plan, isEmpty);
  });

  test("registered exams and procedures never show signups", () {
    final plan = cockpitPlan(
      occurrences: [],
      exams: [
        exam("Registered",
            registered: true, wEnd: DateTime(2026, 11, 17), wStart: null),
        exam("Impossible",
            status: ExamWindowStatus.impossible,
            wEnd: DateTime(2026, 11, 17)),
        exam("Opens later",
            status: ExamWindowStatus.closed,
            wStart: DateTime(2026, 11, 16, 9),
            wEnd: DateTime(2026, 11, 30)),
      ],
      procedures: [
        proc(1, "mine",
            start: DateTime(2026, 11, 10), end: DateTime(2026, 11, 20))
      ],
      registeredProcedureIds: {1},
      smuProven: true,
      now: now,
    );
    expect(plan.map((i) => i.kind).toList(), [CockpitKind.examSignupOpens]);
  });

  // R32.3: the deregistration deadline of a REGISTERED exam is the one
  // date on a registered exam that still has a decision to make
  test("registered exam shows a dereg row only for a future in-horizon "
      "deregEnd", () {
    final plan = cockpitPlan(
      occurrences: [],
      exams: [
        exam("Wind Energy",
            registered: true, deregEnd: DateTime(2026, 11, 19, 23, 59)),
        exam("Fired", registered: true, deregEnd: DateTime(2026, 11, 10)),
        exam("Plain registered", registered: true),
        exam("Unregistered", deregEnd: DateTime(2026, 11, 19, 23, 59)),
      ],
      procedures: [],
      registeredProcedureIds: {},
      smuProven: false,
      now: now,
    );
    // past deadline: history, not a row. No deregEnd: nothing to show.
    // UNREGISTERED with a stray deregEnd: nothing to deregister from.
    expect(plan.map((i) => i.kind).toList(), [CockpitKind.examDereg]);
    expect(plan.single.title, "Wind Energy");
    expect(plan.single.when, DateTime(2026, 11, 19, 23, 59));
  });

  test("dereg deadline today belongs to the today section, far out to "
      "nobody", () {
    final plan = cockpitPlan(
      occurrences: [],
      exams: [
        exam("Tonight",
            registered: true, deregEnd: now.add(const Duration(hours: 9))),
        exam("Far out",
            registered: true,
            deregEnd: now.add(const Duration(days: 29, hours: 1))),
      ],
      procedures: [],
      registeredProcedureIds: {},
      smuProven: false,
      now: now,
    );
    expect(plan, isEmpty);
  });

  test("existing rows keep sorting with the dereg row", () {
    final plan = cockpitPlan(
      occurrences: [
        occ("kauni-due-7-d", DateTime(2026, 11, 20, 18), "Due: Blatt 4"),
      ],
      exams: [
        exam("Wind Energy",
            registered: true, deregEnd: DateTime(2026, 11, 17, 23, 59)),
      ],
      procedures: [],
      registeredProcedureIds: {},
      smuProven: true,
      now: now,
    );
    expect(plan.map((i) => i.kind).toList(),
        [CockpitKind.examDereg, CockpitKind.due]);
  });

  test("unproven SignMeUp fetch stays silent", () {
    final plan = cockpitPlan(
      occurrences: [],
      exams: [],
      procedures: [
        proc(9, "Tutorial",
            start: DateTime(2026, 11, 10), end: DateTime(2026, 11, 20, 12))
      ],
      registeredProcedureIds: {},
      smuProven: false,
      now: now,
    );
    expect(plan, isEmpty);
  });

  test("urgent = <3 days runway, exactly-3d is not urgent", () {
    final item =
        CockpitItem(CockpitKind.due, now.add(const Duration(days: 3)), "x");
    expect(item.urgent(now), isFalse);
    final sooner =
        CockpitItem(CockpitKind.due, now.add(const Duration(days: 2, hours: 23)),
            "x");
    expect(sooner.urgent(now), isTrue);
  });

  test("maxItems keeps the nearest dates", () {
    final plan = cockpitPlan(
      occurrences: [
        for (var d = 1; d <= 10; d++)
          occ("kauni-due-1-$d", DateTime(2026, 11, 12 + d, 18), "due $d"),
      ],
      exams: [],
      procedures: [],
      registeredProcedureIds: {},
      smuProven: true,
      now: now,
      maxItems: 4,
    );
    expect(plan.length, 4);
    expect(plan.last.when, DateTime(2026, 11, 16, 18));
  });

  test("8 sittings never evict an in-horizon due", () {
    // the constructed crowd-out from the audit: Klaus phase, one late due
    final plan = cockpitPlan(
      occurrences: [
        for (final d in [1, 3, 5, 7, 9, 11, 13, 15])
          occ("kauni-exam-1-$d", DateTime(2027, 1, 25).add(Duration(days: d)),
              "Klausur $d"),
        occ("kauni-due-9-z", DateTime(2027, 2, 20, 23, 45),
            "Due: Last Course (blatt)"),
      ],
      exams: [],
      procedures: [],
      registeredProcedureIds: {},
      smuProven: true,
      now: DateTime(2027, 1, 25),
      maxItems: 8,
    );
    expect(plan.any((i) => i.kind == CockpitKind.due), isTrue);
    // due-first reservation still renders in date order
    for (var i = 1; i < plan.length; i++) {
      expect(plan[i - 1].when.isBefore(plan[i].when) ||
          plan[i - 1].when == plan[i].when, isTrue);
    }
  });
}
