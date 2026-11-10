// Module-detail table scraping regression tests (audit on b47):
// 1) German CampusKIT captions must not render on the English UI,
// 2) the "Veranstaltungen" table must not show the weekly RRULE line AND
//    every expanded single date of the same lecture side by side.
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/module/models/module.dart';
import 'package:kit_mobile/module_info_table/models/module_info_table.dart';
import 'package:kit_mobile/module_info_table/models/module_info_table_cell.dart';
import 'package:kit_mobile/module_info_table/models/module_info_table_type.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> useLanguage(String lang) async {
  SharedPreferences.setMockInitialValues({"PREF_language": lang});
  await L10n.reload();
}

/// A td as cascampus prints appointment cells: .date + .time spans inside
/// one cell (ModuleInfoTableCell.isAppointment needs both). Rows live in a
/// `tbody.tablecontent` (parseFromHtml takes the <tr> from that container).
String _apptRow(String date, String time) => '''
<tr><td>Übung 1</td>
<td><span class="date">$date</span> <span class="time">$time</span></td></tr>''';

String appointmentTableHtml() => '''
<h2 class="table-caption">Veranstaltungen</h2>
<div class="table-container"><table>
<thead class="tablehead"><tr><th>Titel</th><th>Termin</th></tr></thead>
<tbody class="tablecontent">
${_apptRow("Do, wöchentlich", "16:00 - 18:00 Uhr c.t.")}
${_apptRow("Do, 05.11.2026", "16:00 - 18:00 Uhr c.t.")}
${_apptRow("Do, 12.11.2026", "16:00 - 18:00 Uhr c.t.")}
${_apptRow("Fr, 20.11.2026", "10:00 - 12:00 Uhr s.t.")}
${_apptRow("Do, 07.01.2027", "09:00 - 11:00 Uhr c.t.")}
</tbody></table></div>''';

String examTableHtml() => '''
<h2 class="table-caption">Prüfungen (WS 26/27)</h2>
<div class="table-container"><table>
<thead class="tablehead"><tr><th>Semester</th><th>Titel</th></tr></thead>
<tbody class="tablecontent">
<tr><td>WS 2026</td><td>Klausur MACH</td></tr>
</tbody></table></div>''';

void main() {
  setUp(() => useLanguage("de"));

  group("weekly occurrence dedupe (Veranstaltungen)", () {
    test("dated rows covered by the weekly rule collapse into the rule line",
        () async {
      final table = ModuleInfoTable.extractAllFromHtml(appointmentTableHtml())
          .firstWhere((t) => t.type == ModuleInfoTableType.appointments);
      table.prepare(KITModule());

      // the two 16:00 c.t. Thursdays are gone; the rule line, the Friday
      // Einzeltermin and the Thursday with the different time stay
      expect(
        table.rows.map((r) => r.appointmentCell?.dateStr).toList(),
        ["Do, wöchentlich", "Fr, 20.11.2026", "Do, 07.01.2027"],
      );
    });

    test("a table without a rule line keeps every dated row", () async {
      final html = appointmentTableHtml().replaceAll(
          _apptRow("Do, wöchentlich", "16:00 - 18:00 Uhr c.t."), "");
      final table = ModuleInfoTable.extractAllFromHtml(html)
          .firstWhere((t) => t.type == ModuleInfoTableType.appointments);
      table.prepare(KITModule());

      expect(table.rows.length, 4);
    });

    test("weekly-rule tagging and weekday parse", () {
      final rule = ModuleInfoTableCell()
        ..dateStr = "Do, wöchentlich"
        ..timeStr = "16:00 - 18:00 Uhr c.t.";
      final dated = ModuleInfoTableCell()
        ..dateStr = "Fr, 20.11.2026"
        ..timeStr = "10:00 - 12:00 Uhr s.t.";

      expect(rule.isWeeklyRule, isTrue);
      expect(dated.isWeeklyRule, isFalse);
      expect(rule.appointmentWeekday, 4); // Do
      expect(dated.appointmentWeekday, 5); // Fr
      expect(dated.appointmentRest, "20.11.2026");
      final undated = ModuleInfoTableCell()..dateStr = "05.11.2026";
      expect(undated.appointmentWeekday, isNull);
    });
  });

  group("caption localisation", () {
    test("English UI translates the known CampusKIT captions", () async {
      await useLanguage("en");

      final exam = ModuleInfoTable.extractAllFromHtml(examTableHtml()).single;
      expect(exam.localisedCaption, "Exams (WS 26/27)");

      final appt = ModuleInfoTable.extractAllFromHtml(appointmentTableHtml())
          .firstWhere((t) => t.type == ModuleInfoTableType.appointments);
      expect(appt.localisedCaption, "Courses");

      final suffixed = ModuleInfoTable();
      // live b48: KIT serves the semester suffix on this caption too -
      // the exact match that missed it leaked German into the EN UI
      suffixed.caption = "Veranstaltungen (WS 26/27)";
      expect(suffixed.localisedCaption, "Courses (WS 26/27)");

      final other = ModuleInfoTable();
      other.caption = "Sondertermine";
      expect(other.localisedCaption, "Sondertermine"); // unknown: verbatim
      other.caption = "Teilleistungen";
      expect(other.localisedCaption, "Component achievements");
      other.caption = "Leistungsnachweise";
      expect(other.localisedCaption, "Module examinations");
    });

    test("German UI keeps the served captions verbatim", () async {
      final exam = ModuleInfoTable.extractAllFromHtml(examTableHtml()).single;
      expect(exam.localisedCaption, "Prüfungen (WS 26/27)");
    });
  });

  group("appointment label localisation", () {
    test("English UI translates weekday and the weekly marker", () async {
      await useLanguage("en");
      final rule = ModuleInfoTableCell()..dateStr = "Do, wöchentlich";
      final dated = ModuleInfoTableCell()..dateStr = "Sa, 05.12.2026";

      expect(rule.localisedDateLabel, "Thu, weekly");
      expect(dated.localisedDateLabel, "Sat, 05.12.2026");
    });

    test("German UI renders the scraped label unchanged", () async {
      final rule = ModuleInfoTableCell()..dateStr = "Do, wöchentlich";
      expect(rule.localisedDateLabel, "Do, wöchentlich");
    });
  });
}
