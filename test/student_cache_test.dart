import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/state_management/campus/campus_manager.dart';
import 'package:kit_mobile/student/student.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// loadStudentData is the FIRST parse of the warm-start chain
/// (tryPreloadCache -> loadCachedDataAndNotify). It was also the last
/// unguarded one: one unreadable DATA_student blob made the whole boot
/// throw before ready=true, and main's error path parked the app on the
/// LOGIN FORM on every cold start despite valid stored sessions - only a
/// manual re-login could ever rewrite the key (R23).
void main() {
  Future<SharedPreferences> seed(String raw) async {
    SharedPreferences.setMockInitialValues({"DATA_student": raw});
    return SharedPreferences.getInstance();
  }

  test("unreadable student blob is a cache miss, not a boot failure",
      () async {
    // one truncated line, one non-object payload, one renamed-shape
    // object, one null - each used to escape loadStudentData and brick
    // the warm start
    for (final bad in ["{", "[1,2]", '{"name": 5}', "null"]) {
      final prefs = await seed(bad);
      final cm = CampusManager(Student.empty, () {});
      await cm.loadStudentData(); // must NOT throw
      expect(prefs.getString("DATA_student"), isNull,
          reason: "corrupt blob ($bad) must be dropped, "
              "or every later boot repeats the failure");
      expect(cm.student.matriculationNumber, "",
          reason: "student stays empty on a cache miss");
    }
  });

  test("valid blob still round-trips through load", () async {
    SharedPreferences.setMockInitialValues({});
    final cm = CampusManager(Student.empty, () {});
    cm.student.matriculationNumber = "2778369";
    cm.student.degreeProgram = "Maschinenbau International";
    await cm.writeStudentData();

    final cm2 = CampusManager(Student.empty, () {});
    await cm2.loadStudentData();
    expect(cm2.student.matriculationNumber, "2778369");
    expect(cm2.student.degreeProgram, "Maschinenbau International");
  });

  test("absent blob is a silent no-op", () async {
    SharedPreferences.setMockInitialValues({});
    final cm = CampusManager(Student.empty, () {});
    await cm.loadStudentData();
    expect(cm.student.matriculationNumber, "");
  });
}
