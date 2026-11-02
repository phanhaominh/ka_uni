import 'package:html/parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/grades/models/grade_book.dart';
import 'package:kit_mobile/parsing/models/hierarchic_table_row.dart';

// Rows are constructed directly: the model is pure computation over the
// already-parsed tree, so no HTML fixtures are involved here.
HierarchicTableRow _row({
  required int level,
  required String title,
  String grade = "&nbsp;",
  String pointsAcquired = "0,0",
  String pointsMax = "6,00",
}) =>
    HierarchicTableRow(
      level: level,
      title: title,
      href: "",
      type: "",
      statusStr: "",
      grade: grade,
      pointsAcquired: pointsAcquired,
      pointsMax: pointsMax,
    );

GradeBook _book(List<HierarchicTableRow> rows,
        {String ects = "0,0", String avg = "0,0"}) =>
    GradeBook.fromRows(rows, ectsAcquiredTotal: ects, avgMark: avg);

void main() {
  group("row filtering", () {
    test("degree and group rows are not modules", () {
      final book = _book([
        _row(level: 1, title: "Maschinenbau B.Sc.", pointsAcquired: "30,0"),
        _row(level: 2, title: "Pflichtmodule"),
        _row(level: 3, title: "Analysis 1", grade: "1,0"),
      ]);
      expect(book.modules, hasLength(1));
      expect(book.modules.single.title, "Analysis 1");
      expect(book.modules.single.level, 3);
    });

    test("tree order is preserved across the whole fetch", () {
      final book = _book([
        _row(level: 3, title: "Erstes Modul", grade: "bestanden"),
        _row(level: 2, title: "Wahlpflichtmodule"),
        _row(level: 3, title: "Zweites Modul"),
        _row(level: 3, title: "Drittes Modul", grade: "5,0"),
      ]);
      expect(
          book.modules.map((m) => m.title),
          ["Erstes Modul", "Zweites Modul", "Drittes Modul"]);
      expect(book.passed.map((m) => m.title), ["Erstes Modul"]);
      expect(book.failed.map((m) => m.title), ["Drittes Modul"]);
      expect(book.pending.map((m) => m.title), ["Zweites Modul"]);
    });
  });

  group("dedup", () {
    test("entity/whitespace noise copies merge and the graded copy wins", () {
      final book = _book([
        _row(
            level: 3,
            // real innerHtml shape: nbsp re-escapes as ENTITY, the thin
            // space arrives already decoded (&thinsp; never arrives as text)
            title: "Numerische&nbsp;Methoden\u2009I",
            grade: "&nbsp;"),
        _row(
            level: 3,
            title: "  Numerische   Methoden  I ",
            grade: "2,3"),
      ]);
      expect(book.modules, hasLength(1));
      final m = book.modules.single;
      expect(m.state, GradeState.passed);
      expect(m.gradeLabel, "2,3");
      expect(m.numericGrade, 2.3);
      expect(m.title, "Numerische Methoden I");
    });

    test("graded copy is kept when the pending duplicate comes later", () {
      final book = _book([
        _row(level: 3, title: "Technische Mechanik I", grade: "1,7"),
        _row(level: 3, title: "Technische Mechanik&nbsp;I"),
        _row(level: 3, title: "Fachenglisch"),
      ]);
      expect(book.modules, hasLength(2));
      expect(book.modules[0].gradeLabel, "1,7");
      expect(book.modules[0].state, GradeState.passed);
      expect(book.modules[1].title, "Fachenglisch");
    });

    test("retake supersedes the failed attempt, credits land", () {
      final book = _book([
        _row(level: 3, title: "Analysis 1", grade: "nicht bestanden"),
        // the Studienverlauf lists attempts chronologically under one title
        _row(level: 3, title: "Analysis 1", grade: "1,0"),
      ]);
      expect(book.modules, hasLength(1));
      expect(book.modules.single.state, GradeState.passed);
      expect(book.passedEcts, 6.0);
    });

    test("a recorded pass is never demoted by a later failed row", () {
      final book = _book([
        _row(level: 3, title: "Analysis 1", grade: "1,0"),
        _row(level: 3, title: "Analysis 1", grade: "nicht bestanden"),
      ]);
      expect(book.modules.single.state, GradeState.passed);
    });

    test("Brückenkurs stays a module of its own next to Analysis 1", () {
      // the loose feed matcher used to run here and swallowed the
      // Brückenkurs (with its credits) into the graded Analysis 1
      final book = _book([
        _row(level: 3, title: "Analysis 1", grade: "1,0"),
        _row(level: 3, title: "Brückenkurs Analysis 1", grade: "1,0"),
      ]);
      expect(book.modules, hasLength(2));
      expect(book.passedEcts, 12.0);
    });

    test("titles differing only after a comma stay distinct modules", () {
      // lectureTitleKey cut both of these at the first ", " (past position
      // 10) into one key - the second module silently vanished from the
      // ledger along with its CP; the ledger keys on the exact title now
      final book = _book([
        _row(level: 3, title: "Wahlpflichtbereich, Energie", grade: "1,0"),
        _row(level: 3, title: "Wahlpflichtbereich, Produktion", grade: "1,0"),
      ]);
      expect(book.modules, hasLength(2));
      expect(book.passedEcts, 12.0);
    });

    test("EM I and EM III stay distinct modules", () {
      final book = _book([
        _row(level: 3, title: "Engineering Mechanics I", grade: "1,0"),
        _row(level: 3, title: "Engineering Mechanics III"),
      ]);
      expect(book.modules, hasLength(2));
      expect(book.modules[0].state, GradeState.passed);
      expect(book.modules[1].state, GradeState.pending);
    });

    test("joined sequence wording does not absorb the single course", () {
      final book = _book([
        _row(level: 3, title: "Engineering Mechanics I", grade: "1,0"),
        _row(level: 3, title: "Engineering Mechanics I und II"),
      ]);
      expect(book.modules, hasLength(2));
    });
  });

  group("classification", () {
    test("'nicht bestanden' fails even though it contains 'bestanden'", () {
      final m = _book([
        _row(level: 3, title: "Klausur A", grade: "nicht bestanden"),
      ]).modules.single;
      expect(m.state, GradeState.failed);
      expect(m.gradeLabel, "nicht bestanden");
      expect(m.numericGrade, isNull);
    });

    test("capitalized 'Nicht Bestanden' fails", () {
      final m = _book([
        _row(level: 3, title: "Klausur B", grade: "Nicht Bestanden"),
      ]).modules.single;
      expect(m.state, GradeState.failed);
    });

    test("'Bestanden' passes without a numeric grade", () {
      final m = _book([
        _row(level: 3, title: "Praktikum", grade: "Bestanden"),
      ]).modules.single;
      expect(m.state, GradeState.passed);
      expect(m.gradeLabel, "Bestanden");
      expect(m.numericGrade, isNull);
    });

    test("grade boundaries 1,0 / 4,0 pass, 5,0 fails", () {
      final book = _book([
        _row(level: 3, title: "A", grade: "1,0"),
        _row(level: 3, title: "B", grade: "4,0"),
        _row(level: 3, title: "C", grade: "5,0"),
      ]);
      expect(book.passed.map((m) => m.title), ["A", "B"]);
      expect(book.failed.single.title, "C");
      expect(book.failed.single.numericGrade, 5.0);
    });

    test("grade cells survive inner spaces and nbsp padding", () {
      // nbsp becomes a space during cleaning, so the scrape really yields
      // cells like "1 , 3" - anchoring the decimal across whitespace keeps
      // the grade out of the pending bucket instead of silently losing it
      final book = _book([
        _row(level: 3, title: "A", grade: "1\u00a0,3"),
        _row(level: 3, title: "B", grade: "  2 , 0 "),
      ]);
      expect(book.passedEcts, 12.0);
      expect(book.modules[0].gradeLabel, "1,3");
      expect(book.modules[0].numericGrade, 1.3);
      expect(book.modules[1].numericGrade, 2.0);
    });

    test("'&nbsp;' grade is pending with an empty label", () {
      final m = _book([
        _row(level: 3, title: "Noch offen", grade: "&nbsp;", pointsMax: "&nbsp;"),
      ]).modules.single;
      expect(m.state, GradeState.pending);
      expect(m.gradeLabel, "");
      expect(m.numericGrade, isNull);
    });

    test("unparseable pointsMax yields null ECTS", () {
      final m = _book([
        _row(level: 3, title: "Fremdformat", grade: "1,0", pointsMax: "6 LP"),
      ]).modules.single;
      expect(m.moduleEcts, isNull);
    });

    test("pointsMax '6,00' parses", () {
      final m = _book([
        _row(level: 3, title: "Normal", grade: "1,0", pointsMax: "6,00"),
      ]).modules.single;
      expect(m.moduleEcts, 6.0);
    });
  });

  group("grade cell parsing (parseTr)", () {
    // the corrupting extraction used to happen HERE, before the ledger
    // could see anything: the raw cell was cut to a 3-char window around
    // the last comma
    HierarchicTableRow? row(String gradeCell) {
      final doc = parse('<table><tr class="hierarchy3">'
          '<td></td><td><a href="x">Analysis 1</a></td><td>V</td><td></td>'
          '<td>$gradeCell</td><td></td><td>6,00</td><td>6,00</td></tr></table>');
      return HierarchicTableRow.parseTr(
          doc.getElementsByTagName("tr").single, {});
    }

    test("spaced and padded decimals keep the mark", () {
      expect(row("1,&nbsp;3")!.grade, "1,3");
      expect(row("1 , 3")!.grade, "1,3");
      expect(row("  5 , 0 ")!.grade, "5,0");
      expect(row("2,7")!.grade, "2,7");
    });

    test("prose cells survive whole instead of becoming garbage", () {
      expect(row("keine Angabe, s. o.")!.grade, "keine Angabe, s. o.");
      expect(row("bestanden")!.grade, "bestanden");
      expect(row("&nbsp;")!.grade, "");
      expect(row("")!.grade, "");
      expect(row("0,0")!.grade, "0,0");
    });

    test("a parsed spaced decimal still classifies in the ledger", () {
      final book = _book([row("5 , 0")!]);
      expect(book.failed.single.numericGrade, 5.0);
    });
  });

  group("ECTS totals and SOP", () {
    test("official total wins over the module sum", () {
      final book = _book(
        [_row(level: 3, title: "A", grade: "1,0", pointsMax: "6,00")],
        ects: "30,0",
      );
      expect(book.passedEcts, 6.0);
      expect(book.totalEcts, 30.0);
      expect(book.sopReached, isTrue);
      expect(book.sopProgress, 1.0);
    });

    test("progress clamps above the target", () {
      final book = _book([], ects: "45,0");
      expect(book.totalEcts, 45.0);
      expect(book.sopProgress, 1.0);
    });

    test("entity-padded official total parses", () {
      final book = _book(
        [_row(level: 3, title: "A", grade: "1,0", pointsMax: "6,00")],
        ects: "&nbsp;30,0&nbsp;",
      );
      expect(book.totalEcts, 30.0);
      expect(book.sopReached, isTrue);
    });

    test("fallback sum rounds once: display and sopReached cannot disagree",
        () {
      // 9.2+10.6+10.2 folds to 29.999999999999996 - which the page renders
      // "30,0"; rounding inside the model keeps text, bar and threshold in
      // lockstep instead of claiming 30,0/30 while saying "noch offen"
      final book = _book([
        _row(level: 3, title: "A", grade: "1,0", pointsMax: "9,2"),
        _row(level: 3, title: "B", grade: "2,0", pointsMax: "10,6"),
        _row(level: 3, title: "C", grade: "3,0", pointsMax: "10,2"),
      ]);
      expect(book.totalEcts, 30.0);
      expect(book.sopReached, isTrue);
      expect(book.sopProgress, 1.0);
    });

    test("'0,0' total falls back to passed-module ECTS on a fresh start", () {
      final book = _book(
        [_row(level: 3, title: "A", grade: "1,0", pointsMax: "6,00")],
        ects: "&nbsp;0,0", // degree-row cells may carry layout entities too
      );
      expect(book.totalEcts, 6.0);
    });

    test("'0,0' total is trusted when nothing is passed with ECTS", () {
      final book = _book([
        _row(level: 3, title: "A"),
        // passed, but its ECTS cell is broken -> nothing to fall back to
        _row(level: 3, title: "B", grade: "bestanden", pointsMax: "&nbsp;"),
      ]);
      expect(book.passedEcts, 0.0);
      expect(book.totalEcts, 0.0);
      expect(book.sopProgress, 0.0);
    });

    test("half the target shows as 0.5", () {
      final book = _book([], ects: "15,0");
      expect(book.sopProgress, 0.5);
      expect(book.sopReached, isFalse);
    });

    test("failed modules never contribute ECTS", () {
      final book = _book(
        [_row(level: 3, title: "A", grade: "5,0", pointsMax: "6,00")],
        ects: "0,0",
      );
      expect(book.passedEcts, 0.0);
      expect(book.totalEcts, 0.0);
    });

    test("sopTarget is 30 CP", () {
      expect(GradeBook.sopTarget, 30.0);
    });
  });

  group("average", () {
    test("'2,3' parses", () {
      final book = _book([], avg: "2,3");
      expect(book.average, 2.3);
    });

    test("'0,0', empty and garbage averages are null", () {
      expect(_book([], avg: "0,0").average, isNull);
      expect(_book([], avg: "").average, isNull);
      expect(_book([], avg: "&nbsp;").average, isNull);
      expect(_book([], avg: "durchschnitt").average, isNull);
    });
  });
}
