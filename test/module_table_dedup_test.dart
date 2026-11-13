// Audit F-10 regression: CampusKIT served the SAME exam attempt five times
// as byte-identical rows, so the module page rendered five identical
// "Wed, 24.02.2027 11:00 - 13:00" lines. ModuleInfoTable.parseFromHtml now
// drops a row whose whole cell set was already seen; anything that differs
// (text, whitespace-normalized content, favorite-event value) must survive.
// Fixture shape mirrors the live table-container markup (see
// module_info_table_test.dart for the tablehead/tablecontent precedent).
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/module_info_table/models/module_info_table.dart';

/// One exam-attempt row: title + the cascampus .date/.time span cell.
String _examRow(String title, String date, String time) => '''
<tr><td>$title</td>
<td><span class="date">$date</span> <span class="time">$time</span></td></tr>''';

/// A favorite-toggle row: same appointment text, star button carrying the
/// event's object value (that value is what makes two alike rows different).
String _favRow(String eventValue) => '''
<tr><td>Klausur MACH</td>
<td><span class="date">Mi, 24.02.2027</span> <span class="time">11:00 - 13:00 Uhr</span></td>
<td><button name="btn_addEventFavorite" value="$eventValue">★</button></td></tr>''';

String _table(List<String> rows) => '''
<div class="table-container"><table>
<thead class="tablehead"><tr><th>Titel</th><th>Termin</th></tr></thead>
<tbody class="tablecontent">
${rows.join("\n")}
</tbody></table></div>''';

void main() {
  final fiveDupes = [_examRow("Klausur MACH", "Mi, 24.02.2027", "11:00 - 13:00 Uhr")];

  test('five identical rows collapse to one, distinct row survives', () {
    final table = ModuleInfoTable.parseFromHtml(_table([
      ...fiveDupes,
      ...fiveDupes,
      ...fiveDupes,
      ...fiveDupes,
      ...fiveDupes,
      _examRow("Mündliche Prüfung", "Fr, 12.03.2027", "14:00 - 15:00 Uhr"),
    ]));
    expect(table, isNotNull);
    expect(table!.rows.length, 2);
    final kept = table.rows.first;
    expect(kept.cells.first.body.trim(), "Klausur MACH");
    expect(kept.appointmentCell?.dateStr, "Mi, 24.02.2027");
    expect(kept.appointmentCell?.timeStr, "11:00 - 13:00 Uhr");
    expect(table.rows.last.cells.first.body.trim(), "Mündliche Prüfung");
  });

  test('duplicates differing only in indentation still dedup', () {
    const spaced = '''
<tr><td>
        Klausur MACH
</td>
<td>  <span class="date">Mi, 24.02.2027</span>
    <span class="time">11:00 - 13:00 Uhr</span>  </td></tr>''';
    final table = ModuleInfoTable.parseFromHtml(_table([
      _examRow("Klausur MACH", "Mi, 24.02.2027", "11:00 - 13:00 Uhr"),
      spaced,
      _examRow("Klausur MACH", "Mi, 24.02.2027", "11:00 - 13:00 Uhr"),
    ]));
    expect(table!.rows.length, 1);
  });

  test('same text but different favorite-event values are kept apart', () {
    final table = ModuleInfoTable.parseFromHtml('''
<div class="table-container"><table>
<thead class="tablehead"><tr><th>Titel</th><th>Termin</th><th></th></tr></thead>
<tbody class="tablecontent">
${_favRow("0xAAA1111111111111111111111111111")}
${_favRow("0xBBB2222222222222222222222222222")}
${_favRow("0xAAA1111111111111111111111111111")}
</tbody></table></div>''');
    // two schedulable events with the same label, not five phantom rows
    expect(table!.rows.length, 2);
    expect(table.rows.map((r) => r.favoriteToggleCell?.objectValue).toSet(), {
      "0xAAA1111111111111111111111111111",
      "0xBBB2222222222222222222222222222",
    });
  });
}
