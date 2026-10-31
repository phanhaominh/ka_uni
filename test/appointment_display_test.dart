import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/timetable/models/timetable_appointment.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';
import 'package:kit_mobile/geo/models/kit_place.dart';

void main() {
  test("displayTitle/displayPlace", () {
    final a = TimetableAppointment()
      ..title = "Engineering Mechanics I (Tutorial) - 3161011"
      ..place = (KITPlace()..title = "Gottlieb-Daimler-HS HS bldg 10.21");
    expect(a.displayTitle, "Engineering Mechanics I (Tutorial)");
    expect(a.displayPlace, "Gottlieb-Daimler-HS bldg 10.21");

    final b = TimetableAppointment()
      ..title = "Mechanical Design A (Lecture/Tutorial) - 2145191/2145192"
      ..place = (KITPlace()..title = "10.21 Carl-Benz-Hörsaal");
    expect(b.displayTitle, "Mechanical Design A (Lecture/Tutorial)");
    expect(b.displayPlace, "10.21 Carl-Benz-Hörsaal");

    // no false strip when the tail is part of the name
    final c = TimetableAppointment()..title = "Advanced Mathematics I (Problem Class)";
    expect(c.displayTitle, c.title);
  });

  test("IcsOccurrence displayTitle/displayRoom", () {
    final occ = IcsOccurrence(
      start: DateTime(2026, 10, 12, 8, 0),
      end: DateTime(2026, 10, 12, 10, 0),
      title: "Engineering Mechanics I (Tutorial) - 3161011",
      room: "Gottlieb-Daimler-HS HS bldg 10.21",
      uid: "em1@kit",
    );
    expect(occ.displayTitle, "Engineering Mechanics I (Tutorial)");
    expect(occ.displayRoom, "Gottlieb-Daimler-HS bldg 10.21");

    final occ2 = IcsOccurrence(
      start: DateTime(2026, 10, 13, 8, 0),
      end: DateTime(2026, 10, 13, 10, 0),
      title: "Mechanical Design A (Lecture/Tutorial) - 2145191/2145192",
      room: "10.21 Carl-Benz-Hörsaal",
      uid: "mda@kit",
    );
    expect(occ2.displayTitle, "Mechanical Design A (Lecture/Tutorial)");
    expect(occ2.displayRoom, "10.21 Carl-Benz-Hörsaal");

    // no false strip when the tail is part of the name
    final occ3 = IcsOccurrence(
      start: DateTime(2026, 10, 14, 8, 0),
      end: DateTime(2026, 10, 14, 10, 0),
      title: "Advanced Mathematics I (Problem Class)",
      room: "",
      uid: "am1@kit",
    );
    expect(occ3.displayTitle, occ3.title);
    expect(occ3.displayRoom, "");

    // statics clean arbitrary strings without an instance
    expect(IcsOccurrence.cleanTitle("Thermodynamics II - 3161022"),
        "Thermodynamics II");
    expect(IcsOccurrence.cleanRoom("Lecture Hall HS HS 76.41"),
        "Lecture Hall HS 76.41");
  });
}
