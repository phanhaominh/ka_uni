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

  test("unproven SignMeUp fetch never shouts - and says so out loud "
      "(R35.1: the old pending card is a first-class unknown row now)", () {
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
    // no act-now row may be minted off unproven registration state...
    expect(plan.where((i) => i.kind == CockpitKind.smuOpen), isEmpty);
    // ...but the unknown itself renders (a collapsed list is only
    // honest while the unknown still shows)
    expect(plan.map((i) => i.kind), [CockpitKind.unknownSmu]);
  });

  test("unproven fetch WITHOUT procedures renders no unknown", () {
    // the old silence was right in this corner: nothing fetched,
    // nothing pending - there is no question to leave open
    final plan = cockpitPlan(
      occurrences: [],
      exams: [],
      procedures: [],
      registeredProcedureIds: {},
      smuProven: false,
      now: now,
    );
    expect(plan, isEmpty);
  });

  // ----------------------------------------------------------- R35.1

  test("per-kind floors: a Klaus phase can never evict the open "
      "Anmeldungen (the core-purpose miss of the global cap)", () {
    final plan = cockpitPlan(
      occurrences: [
        for (final d in [1, 3, 5, 7, 9, 11, 13, 15])
          occ("kauni-exam-1-$d", DateTime(2026, 11, 13).add(Duration(days: d)),
              "Klausur $d"),
        occ("kauni-due-9-z", DateTime(2026, 11, 27, 23, 45),
            "Due: Last Course (blatt)"),
      ],
      exams: [
        exam("Anmelde-Pflichtklausur",
            wStart: now.subtract(const Duration(days: 1)),
            wEnd: now.add(const Duration(days: 10))),
      ],
      procedures: [
        proc(9, "Tutorial open",
            start: now.subtract(const Duration(days: 1)),
            end: now.add(const Duration(days: 8)))
      ],
      registeredProcedureIds: {},
      smuProven: true,
      now: now,
      maxItems: 8,
    );
    // every kind that ACTS on the student keeps a seat despite 8
    // sitting rows crowding the timeline
    expect(plan.any((i) => i.kind == CockpitKind.examSignupOpen), isTrue);
    expect(plan.any((i) => i.kind == CockpitKind.smuOpen), isTrue);
    expect(plan.any((i) => i.kind == CockpitKind.due), isTrue);
    expect(plan.length, 8); // unknowns aside, the cap still holds
    for (var i = 1; i < plan.length; i++) {
      expect(plan[i - 1].when.isBefore(plan[i].when), isTrue);
    }
  });

  test("per-kind floors: every present kind keeps one seat before any "
      "kind keeps its second", () {
    final plan = cockpitPlan(
      occurrences: [
        for (var d = 1; d <= 5; d++)
          occ("kauni-exam-1-$d", DateTime(2026, 11, 12 + d), "Klausur $d"),
        for (var d = 1; d <= 5; d++)
          occ("kauni-due-1-$d", DateTime(2026, 11, 12 + d, 18), "due $d"),
        for (var d = 1; d <= 5; d++)
          occ("kauni-frb-1-$d", DateTime(2026, 11, 12 + d, 23, 59),
              "Frist: note $d"),
      ],
      exams: [],
      procedures: [
        for (var id = 1; id <= 3; id++)
          proc(id, "soon $id",
              start: now.add(Duration(days: 2)),
              end: now.add(Duration(days: 12)))
      ],
      registeredProcedureIds: {},
      smuProven: true,
      now: now,
      maxItems: 6,
    );
    // due + frb + smuOpens + examSitting each keep a seat before any
    // kind claims more than one; the 5-item kinds may NOT hog the
    // 6-row budget (sitting rows - the OLD evictors - get one seat
    // exactly like the deadlines do)
    expect(plan.where((i) => i.kind == CockpitKind.smuOpens).length, 1);
    expect(plan.where((i) => i.kind == CockpitKind.examSitting).length, 1);
    expect(plan.where((i) => i.kind == CockpitKind.due).length,
        greaterThan(0));
    expect(plan.where((i) => i.kind == CockpitKind.frb).length,
        greaterThan(0));
    expect(plan.length, 6);
  });

  test("status unknowns sit OUTSIDE the cap: a full timeline still "
      "renders them", () {
    final plan = cockpitPlan(
      occurrences: [
        for (var d = 1; d <= 10; d++)
          occ("kauni-due-1-$d", DateTime(2026, 11, 12 + d, 18), "due $d"),
      ],
      exams: [],
      procedures: [
        proc(9, "Tutorial",
            start: now.subtract(const Duration(days: 1)),
            end: now.add(const Duration(days: 8)))
      ],
      registeredProcedureIds: {},
      smuProven: false,
      examsPending: true,
      now: now,
      maxItems: 4,
    );
    expect(
        plan.where((i) =>
            i.kind == CockpitKind.unknownExams ||
            i.kind == CockpitKind.unknownSmu),
        hasLength(2));
    expect(plan.where((i) => i.kind == CockpitKind.due), hasLength(4));
    // unknowns sort ahead of every future row (when = now) and never
    // paint as urgent deadlines
    expect(plan.first.kind, CockpitKind.unknownExams);
    expect(plan[1].kind, CockpitKind.unknownSmu);
    expect(plan.first.urgent(now), isFalse);
    expect(plan[1].urgent(now), isFalse);
  });

  String dayLabel(DateTime d) =>
      "${d.day.toString().padLeft(2, "0")}."
      "${d.month.toString().padLeft(2, "0")}."
      "${d.year}";

  ExamEntry registeredExam(String title, DateTime sittingStart,
      {List<ExamTerm> terms = const []}) {
    final e = exam(title, registered: true, status: ExamWindowStatus.closed);
    e.terms.addAll(terms.isEmpty
        ? [ExamTerm(dayLabel(sittingStart), "09:00 - 11:00", "HS 100")]
        : terms);
    return e;
  }

  test("next-exam port: registered-term selection and the 45d gate", () {
    final in45 = DateTime(now.year, now.month, now.day + 45, 9);
    final in46 = DateTime(now.year, now.month, now.day + 46, 9);
    // an UNregistered exam with parsed terms never yields the row
    final unreg = exam("Ghost Klausur")
      ..terms.add(ExamTerm(dayLabel(in45), "09:00 - 11:00", "HS 100"));
    var plan = cockpitPlan(
        occurrences: [],
        exams: [unreg],
        procedures: [],
        registeredProcedureIds: {},
        smuProven: true,
        now: now);
    expect(plan.where((i) => i.kind == CockpitKind.examNext), isEmpty);
    // day 45 inclusive: still rendered
    plan = cockpitPlan(
        occurrences: [],
        exams: [registeredExam("AM I", in45)],
        procedures: [],
        registeredProcedureIds: {},
        smuProven: true,
        now: now);
    expect(plan.where((i) => i.kind == CockpitKind.examNext), hasLength(1));
    expect(plan.single.room, "HS 100");
    // day 46: the deleted card printed nothing, and neither does this
    plan = cockpitPlan(
        occurrences: [],
        exams: [registeredExam("AM I", in46)],
        procedures: [],
        registeredProcedureIds: {},
        smuProven: true,
        now: now);
    expect(plan.where((i) => i.kind == CockpitKind.examNext), isEmpty);
  });

  test("next-exam port: today's registered sitting still prints "
      "(the card's strictly-future exception)", () {
    final today = DateTime(now.year, now.month, now.day, 18);
    final plan = cockpitPlan(
        occurrences: [],
        exams: [
          registeredExam("Heute-Klausur", today,
              terms: [
                ExamTerm(dayLabel(today), "18:00 - 20:00", "HS 100")
              ])
        ],
        procedures: [],
        registeredProcedureIds: {},
        smuProven: true,
        now: now);
    expect(plan.single.kind, CockpitKind.examNext);
    expect(plan.single.when, today);
  });

  test("next-exam port: room disambiguation - shared starts drop the "
      "room label, single rooms keep it", () {
    final at = DateTime(now.year, now.month, now.day + 10, 9);
    final pool = exam("Pool-Klausur", registered: true)
      ..terms.addAll([
        ExamTerm(dayLabel(at), "09:00 - 11:00", "HS 100"),
        ExamTerm(dayLabel(at), "09:00 - 11:00", "HS 200"),
      ]);
    var plan = cockpitPlan(
        occurrences: [],
        exams: [pool],
        procedures: [],
        registeredProcedureIds: {},
        smuProven: true,
        now: now);
    expect(plan.single.kind, CockpitKind.examNext);
    expect(plan.single.room, isNull);
    // placeholder-only rooms ("-") never label either
    final anon = exam("Raumlose Klausur", registered: true)
      ..terms.add(ExamTerm(dayLabel(at), "09:00 - 11:00", "-"));
    plan = cockpitPlan(
        occurrences: [],
        exams: [anon],
        procedures: [],
        registeredProcedureIds: {},
        smuProven: true,
        now: now);
    expect(plan.single.room, isNull);
  });

  test("next-exam port REPLACES the matching synth sitting row instead "
      "of duplicating it", () {
    final at = DateTime(now.year, now.month, now.day + 20, 9);
    final plan = cockpitPlan(
      occurrences: [
        occ("kauni-exam-7-$at", at, "Klausur: MSE"),
        occ("kauni-exam-8-$at", at.add(const Duration(days: 5)),
            "Klausur: Other"),
      ],
      exams: [registeredExam("MSE", at)],
      procedures: [],
      registeredProcedureIds: {},
      smuProven: true,
      now: now,
    );
    final rows = plan.where((i) =>
        i.kind == CockpitKind.examNext || i.kind == CockpitKind.examSitting);
    expect(rows, hasLength(2)); // one next + the UNMATCHED sitting
    expect(rows.first.kind, CockpitKind.examNext);
    expect(rows.first.title, "MSE"); // bare title, as the old card
    expect(rows.first.room, "HS 100");
    expect(rows.last.kind, CockpitKind.examSitting);
  });

  test("deep links: every row kind keeps the deleted card's target "
      "(R35.1 link preservation)", () {
    expect(cockpitAction(CockpitKind.examSignupOpen),
        CockpitAction.examsPage);
    expect(cockpitAction(CockpitKind.examSignupOpens),
        CockpitAction.examsPage);
    expect(cockpitAction(CockpitKind.examDereg), CockpitAction.examsPage);
    expect(cockpitAction(CockpitKind.examSitting), CockpitAction.examsPage);
    expect(cockpitAction(CockpitKind.examNext), CockpitAction.examsPage);
    expect(cockpitAction(CockpitKind.smuOpen), CockpitAction.signMeUpPortal);
    expect(cockpitAction(CockpitKind.smuOpens),
        CockpitAction.signMeUpPortal);
    // dues/own notes/status rows never had a tap target (F12)
    expect(cockpitAction(CockpitKind.due), CockpitAction.none);
    expect(cockpitAction(CockpitKind.frb), CockpitAction.none);
    expect(cockpitAction(CockpitKind.unknownExams), CockpitAction.none);
    expect(cockpitAction(CockpitKind.unknownSmu), CockpitAction.none);
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
