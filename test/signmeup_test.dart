import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/signmeup/signmeup_manager.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';

/// Fixtures are live captures (2026-10-31) of the two Campus+ endpoints:
/// the public offer list and the student's own registrations.
void main() {
  List<SignMeUpProcedure> loadProcedures() {
    final decoded =
        jsonDecode(File('test/fixtures/smuprocedures.json').readAsStringSync());
    return (decoded['procedures'] as List)
        .map((e) => SignMeUpProcedure.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  List<SignMeUpRegistration> loadMine() {
    final decoded =
        jsonDecode(File('test/fixtures/myregs.json').readAsStringSync());
    return (decoded['registrations'] as List)
        .map((e) => SignMeUpRegistration.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  group("offer list", () {
    test('parses the live procedure list', () {
      final procs = loadProcedures();
      expect(procs.length, greaterThan(100));
      final now = DateTime.parse('2026-10-30T18:00:00+01:00');
      final open = procs.where((p) => p.isOpen(now)).toList();
      expect(open, isNotEmpty);
      expect(open.every((p) => p.registrationEnd!.isAfter(now)), isTrue);
    });

    test('registered students drop out of needsAction', () {
      final procs = loadProcedures();
      final now = DateTime.parse('2026-10-30T18:00:00+01:00');
      final someOpen =
          procs.firstWhere((p) => p.isOpen(now) && p.needsAction(now, {}));
      expect(someOpen.needsAction(now, {someOpen.id}), isFalse);
    });
  });

  group("my registrations", () {
    test('live fixture states', () {
      final mine = loadMine();
      expect(mine.length, 5);
      final math = mine.firstWhere((r) => r.name == 'Advanced Mathematics I');
      expect(math.accepted, isTrue);
      expect(math.topicName, contains('Group 2'));
      // accepted -> the student acted; the two state 0 drafts are still open
      expect(
          {for (final r in mine) if (r.submitted) r.procedureId},
          {6964, 6965, 7345});
    });

    test('group slot parsed from instructor HTML', () {
      final math =
          loadMine().firstWhere((r) => r.name == 'Advanced Mathematics I');
      final s = math.schedules.single;
      expect(s.dayOfWeek, DateTime.tuesday);
      expect(s.startMinutes, 15 * 60 + 45);
      expect(s.endMinutes, 17 * 60 + 15);
      expect(s.room, contains('Neuer Hörsaal Architektur'));
    });

    test('single appointment parsed from display name', () {
      final welcome =
          loadMine().firstWhere((r) => r.name.startsWith('Welcome Event'));
      final one = welcome.singleAppointment!;
      expect(one.start, DateTime(2026, 10, 23, 14, 0));
      expect(one.end.difference(one.start), const Duration(hours: 2, minutes: 30));
    });

    test('two weekly slots on one line both become schedules', () {
      // the most common instructor format:
      // "Dienstag 15:45-17:15 / Donnerstag 09:00-10:30, HS 10.30"
      // the old one-slot-per-line parser silently dropped the second
      final reg = SignMeUpRegistration.fromJson({
        "id": 1,
        "procedureId": 2,
        "name": "T",
        "state": 3,
        "assignedTopic": {
          "name": "G1",
          "description":
              "<p>Dienstag 15:45-17:15 / Donnerstag 09:00-10:30, HS 10.30</p>",
        },
      });
      final s = reg.schedules;
      expect(s.length, 2);
      expect(s[0].dayOfWeek, DateTime.tuesday);
      expect(s[0].startMinutes, 15 * 60 + 45);
      expect(s[0].endMinutes, 17 * 60 + 15);
      expect(s[1].dayOfWeek, DateTime.thursday);
      expect(s[1].startMinutes, 9 * 60);
      expect(s[1].room, contains("HS 10.30"));
    });

    test('repeated abbreviated days bind each range to its nearest day', () {
      // firstMatch used to bind a range to the EARLIEST abbreviation in
      // its prefix, so the third "Di" range below landed on Wednesday,
      // and the room residue kept a leading day abbreviation
      final reg = SignMeUpRegistration.fromJson({
        "id": 1,
        "procedureId": 2,
        "name": "T",
        "state": 3,
        "assignedTopic": {
          "name": "G5",
          "description":
              "<p>Di 14:00-16:00 20.40 Geb. 11.20 / Mi 09:00-11:00 / "
              "Di 16:00-18:00</p>",
        },
      });
      final s = reg.schedules;
      expect(s.length, 3);
      expect(s[0].dayOfWeek, DateTime.tuesday);
      expect(s[1].dayOfWeek, DateTime.wednesday);
      expect(s[2].dayOfWeek, DateTime.tuesday,
          reason: 'third range must bind to its nearest preceding "Di"');
      expect(s[2].startMinutes, 16 * 60);
      expect(s[2].endMinutes, 18 * 60);
      for (final slot in s) {
        expect(slot.room, "20.40 Geb. 11.20");
      }
    });

    test('minute-less ranges parse ("Mo 10-12")', () {
      final reg = SignMeUpRegistration.fromJson({
        "id": 1,
        "procedureId": 2,
        "name": "T",
        "state": 3,
        "assignedTopic": {
          "name": "G2",
          "description": "<p>Mo 10-12 Uhr, SGS 35</p>",
        },
      });
      final s = reg.schedules.single;
      expect(s.dayOfWeek, DateTime.monday);
      expect(s.startMinutes, 10 * 60);
      expect(s.endMinutes, 12 * 60);
    });

    test('date ranges in descriptions are not schedules', () {
      // "Vermietung 25.10.2026 - 15.02.2027" must not parse as a time
      final reg = SignMeUpRegistration.fromJson({
        "id": 1,
        "procedureId": 2,
        "name": "T",
        "state": 3,
        "assignedTopic": {
          "name": "G3",
          "description": "<p>Zeitraum 25.10.2026 - 15.02.2027</p>",
        },
      });
      expect(reg.schedules, isEmpty);
    });

    test('synthetic block carries the accepted group as a weekly series', () {
      final mgr = SignMeUpManager();
      mgr.mine = loadMine();
      mgr.loadedMine = true;
      mgr.termStart = DateTime(2026, 10, 1);
      final block = mgr.buildSynthBlock();
      expect(block, contains('SUMMARY:Advanced Mathematics I (Group 2)'));
      expect(block, contains('RRULE:FREQ=WEEKLY'));
      expect(block, contains('UNTIL=20270213T000000'));
      expect(block, contains('LOCATION:20.40 Neuer H'));
      // unaccepted drafts (state 0) add nothing; the accepted single
      // appointments (welcome event, rally) are in the past and get dropped
      expect(block, isNot(contains('Welcome Event')));
      expect(block, isNot(contains('Campus Rally')));
      expect(RegExp('BEGIN:VEVENT').allMatches(block).length, 1);
    });

    test('synthetic events survive the webcal parser', () {
      final mgr = SignMeUpManager();
      mgr.mine = loadMine();
      mgr.loadedMine = true;
      mgr.termStart = DateTime(2026, 10, 1);
      final base = File('test/fixtures/wc_now.ics').readAsStringSync();
      final at = base.lastIndexOf('END:VCALENDAR');
      final synth = base.replaceRange(at, at, mgr.buildSynthBlock());
      final feed = WebcalFeed.parse(synth)!;
      final tue = feed.occurrences
          .where((o) => o.title.startsWith('Advanced Mathematics I') &&
              o.title.contains('Group 2'))
          .toList();
      expect(tue, isNotEmpty);
      expect(tue.every((o) => o.start.weekday == DateTime.tuesday), isTrue);
      expect(tue.first.room, contains('Architektur'));
      // parser horizon clamps to ~now..now+56d: first surviving instance is
      // a Tuesday after the capture date, the series runs into February;
      // wall time must stay 15:45 even though the series starts in CEST
      // (Duration(days:7) expansion used to slide it to 14:45 after Oct 26)
      expect(tue.first.start, DateTime(2026, 11, 3, 15, 45));
      expect(tue.last.seriesEnd!.isAfter(DateTime(2027, 2, 1)), isTrue);
    });
  });
}
