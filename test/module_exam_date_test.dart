import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/module/models/module.dart';

/// A student who browses Campus in ENGLISH gets dates two ways, and the
/// old parser understood neither: the cagr_examdate-field in US spelling,
/// or - when the brick carries NO field at all (live case: Advanced
/// Mathematics I, exam 7700085) - the sitting only exists inside the
/// #EXAMLIST table's hidden collapsible sub-rows.
void main() {
  String brickPage({required String field, required String examRows}) => '''
<html><body>
<div id="csbr_id-field"><span class="element">0xBEEF</span></div>
<div id="cabr_name-field"><span class="element">Advanced Mathematics I</span></div>
<div id="cagr_examdate-field"><span class="element">$field</span></div>
<table id="EXAMLIST" class="listview"><tbody>
$examRows
</tbody></table>
</body></html>''';

  // verbatim structure captured live from specificBrickView.asp (EN view)
  const mathRow = '''
<tr class="odd"><td>7700085</td><td>Written exam</td></tr>
<tr class="collapsible odd" style="display: none"><td>&nbsp;</td>
<td class="collapsible" colspan="17"><span class="date">Wed, 2/24/2027</span>,
<span class="time">11:00 AM - 1:00 PM</span>,
<a class="room" href="#">30.41 Chemie-Hörsaal Nr. 3 (HS3)</a></td></tr>''';

  test('US-spelled exam date field parses', () {
    final m = KITModule()..parseModulePage(brickPage(field: "2/24/2027", examRows: ""));
    expect(m.examDateParsed, isTrue);
    expect(m.examDate, DateTime(2027, 2, 24));
    expect(m.examDateStr, "2/24/2027"); // display string stays verbatim
  });

  test('german exam date field still parses', () {
    final m = KITModule()..parseModulePage(brickPage(field: "24.02.2027", examRows: ""));
    expect(m.examDateParsed, isTrue);
    expect(m.examDate, DateTime(2027, 2, 24));
  });

  test('field-less brick takes the date from #EXAMLIST', () {
    final m = KITModule()
      ..parseModulePage(brickPage(field: "unbekannt", examRows: mathRow));
    expect(m.examDateParsed, isTrue);
    // hour comes from the span.time, in 24-h terms
    expect(m.examDate, DateTime(2027, 2, 24, 11, 0));
    expect(m.examDateStr, "24.02.2027");
  });

  test('field wins over the table', () {
    final m = KITModule()
      ..parseModulePage(brickPage(field: "3/3/2027", examRows: mathRow));
    expect(m.examDate, DateTime(2027, 3, 3));
  });

  test('cancelled sittings never become the exam date', () {
    const cancelled = '''
<tr class="odd"><td>7700085</td><td>Written exam</td></tr>
<tr class="collapsible odd"><td>&nbsp;</td><td class="collapsible"><span
class="date">Sat, 2/27/2027</span>, <span class="time">entfällt</span></td></tr>''';
    final m = KITModule()
      ..parseModulePage(brickPage(field: "unbekannt", examRows: cancelled));
    expect(m.examDateParsed, isFalse);
  });

  test('multiple sittings pick the nearest future one', () {
    const twoRows = mathRow +
        '''
<tr class="collapsible even"><td>&nbsp;</td><td class="collapsible">
<span class="date">Sat, 6/12/2027</span>, <span class="time">2:00 PM - 4:00 PM</span>
</td></tr>''';
    final m = KITModule()
      ..parseModulePage(brickPage(field: "unbekannt", examRows: twoRows));
    // both are in the future relative to any plausible "now" in 2026/27;
    // the February sitting is the next attempt and must win
    expect(m.examDate, DateTime(2027, 2, 24, 11, 0));
  });
}
