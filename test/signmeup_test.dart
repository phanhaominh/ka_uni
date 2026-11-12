import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/signmeup/signmeup_manager.dart';
import 'package:kit_mobile/state_management/campus/campus_manager.dart';
import 'package:kit_mobile/student/student.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
      expect({
        for (final r in mine)
          if (r.submitted) r.procedureId
      }, {
        6964,
        6965,
        7345
      });
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
      expect(
          one.end.difference(one.start), const Duration(hours: 2, minutes: 30));
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

    test('foreign newline cannot split the emitted ICS lines (R23)', () {
      // name/topicName are instructor-set free text straight off the
      // wire; _icsEscape escapes \ ; , but NOT CR/LF. Before the shared
      // icsFoldable guard a pasted newline smuggled a physical property
      // line INTO the cache: strict export consumers reject the whole
      // document, and a forged END:VEVENT/sentinel desyncs the splice
      // logic that carries the user's personal block
      final mgr = SignMeUpManager();
      mgr.mine = [
        SignMeUpRegistration.fromJson({
          "id": 7,
          "procedureId": 8,
          "name": "Bad Name\r\nEND:VEVENT\r\nX-Injected: yes",
          "state": 3,
          "assignedTopic": {
            "name": "G1",
            "description": "<div>Monday&nbsp;10:00-12:00</div>",
          },
        })
      ];
      mgr.loadedMine = true;
      mgr.termStart = DateTime(2026, 10, 1);
      final block = mgr.buildSynthBlock();
      expect(block, isNotEmpty, reason: "schedule must still emit");
      // the text SURVIVES (folded into the value) - what must not
      // survive is any second physical line or smuggled property, so
      // the counters look at PHYSICAL lines only (the folded title
      // legitimately contains the literal "END:VEVENT" as its text)
      final lines = block.split('\r\n');
      expect(lines.where((l) => l == 'BEGIN:VEVENT').length, 1);
      expect(lines.where((l) => l == 'END:VEVENT').length, 1);
      expect(
          lines.every((l) => !l.startsWith('X-Injected')),
          isTrue,
          reason: "forged property became its own physical line");
      final summary = block
          .split('\r\n')
          .firstWhere((l) => l.startsWith('SUMMARY:'));
      expect(summary, contains('Bad Name'));
      expect(summary, contains('END:VEVENT')); // folded INTO the value text
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
          .where((o) =>
              o.title.startsWith('Advanced Mathematics I') &&
              o.title.contains('Group 2'))
          .toList();
      expect(tue, isNotEmpty);
      expect(tue.every((o) => o.start.weekday == DateTime.tuesday), isTrue);
      expect(tue.first.room, contains('Architektur'));
      // parser horizon clamps to ~now..now+56d: the first surviving
      // instance is the EARLIEST Tuesday the wall clock still admits -
      // computed, not pinned, so the suite survives its own birthdays.
      // The invariant actually under test is the 15:45 wall time: the
      // series starts in CEST and Duration(days:7) expansion used to
      // slide it to 14:45 after the Oct 26 DST switch
      final ref = DateTime.now();
      var expectFirst = DateTime(ref.year, ref.month, ref.day, 15, 45);
      // back off below the trim cutoff (now-1d) to a Tuesday more than a
      // week early, then step by the series period (7d) until the cutoff
      // admits it: exactly the parser's first survivor, whatever today is
      final cutoff = ref.subtract(const Duration(days: 1));
      expectFirst = expectFirst.subtract(
          Duration(days: (expectFirst.weekday - DateTime.tuesday + 7) % 7 + 7));
      while (expectFirst.isBefore(cutoff)) {
        expectFirst = expectFirst.add(const Duration(days: 7));
      }
      expect(tue.first.start, expectFirst);
      expect(tue.last.seriesEnd!.isAfter(DateTime(2027, 2, 1)), isTrue);
    });

    test('block is byte-identical across rebuilds (deterministic emitter)', () {
      // the exam_synth lesson, applied to SignMeUp: positional UID seqs and
      // DTSTAMP:DateTime.now() made every rebuild differ, so
      // reapplySignMeUpSynth's byte-equality no-op never fired - every
      // pull rewrote the ICS cache and re-armed all lecture alarms
      final mgr = SignMeUpManager();
      mgr.mine = loadMine();
      mgr.loadedMine = true;
      mgr.termStart = DateTime(2026, 10, 1);
      expect(mgr.buildSynthBlock(), mgr.buildSynthBlock());
    });

    test('UIDs key the slot, not the emission order', () {
      final reg = SignMeUpRegistration.fromJson({
        "id": 7,
        "procedureId": 3,
        "name": "T",
        "state": 3,
        "assignedTopic": {
          "name": "G1",
          "description": "<p>Mo 10-12 SGS 35<br>Di 14:00-16:00</p>",
        },
      });
      final mgr = SignMeUpManager();
      mgr.mine = [reg];
      mgr.loadedMine = true;
      mgr.termStart = DateTime(2026, 10, 1);
      final uids = RegExp(r"UID:(signmeup-[^\r\n]+)")
          .allMatches(mgr.buildSynthBlock())
          .map((m) => m.group(1)!)
          .toSet();
      expect(uids, contains('signmeup-7-1-600-720@ka_uni'));
      expect(uids, contains('signmeup-7-2-840-960@ka_uni'));
    });

    test('reordering registrations keeps the UID set stable', () {
      // a positional seq meant any reorder in the registrations list
      // churned every UID -> exported calendars DUPLICATED the tutorial
      // instead of updating it
      final mgr = SignMeUpManager();
      final regs = loadMine();
      mgr.mine = regs;
      mgr.loadedMine = true;
      mgr.termStart = DateTime(2026, 10, 1);
      Set<String> uids() => RegExp(r"UID:(signmeup-[^\r\n]+)")
          .allMatches(mgr.buildSynthBlock())
          .map((m) => m.group(1)!)
          .toSet();
      final first = uids();
      mgr.mine = regs.reversed.toList();
      expect(uids(), first);
    });
  });

  group("synth/feed overlap dedupe", () {
    // live capture b47: the webcal feed already carries some of the
    // courses SignMeUp assigns groups for -> the agenda listed each of
    // them twice (feed row with "<nr> - ... (V), lecturer" next to the
    // synth row with the bare "(Lecture)" title, same 08:00 slot)
    String local(DateTime d) => "${d.year.toString().padLeft(4, "0")}"
        "${d.month.toString().padLeft(2, "0")}${d.day.toString().padLeft(2, "0")}"
        "T${d.hour.toString().padLeft(2, "0")}"
        "${d.minute.toString().padLeft(2, "0")}00";

    DateTime nextSlot(int weekday, int hour, int minute) {
      final now = DateTime.now();
      var d = DateTime(now.year, now.month, now.day, hour, minute);
      while (d.weekday != weekday) {
        d = d.add(const Duration(days: 1));
      }
      return d;
    }

    String feedEvent(String uid, String title, DateTime start, int durMin) =>
        "BEGIN:VEVENT\r\nUID:$uid\r\nSUMMARY:$title\r\n"
        "DTSTART:${local(start)}\r\n"
        "DTEND:${local(start.add(Duration(minutes: durMin)))}\r\n"
        "RRULE:FREQ=WEEKLY;UNTIL=${local(start.add(const Duration(days: 120)))}"
        "\r\nEND:VEVENT\r\n";
    String feedWith(String events) =>
        "BEGIN:VCALENDAR\r\n$events END:VCALENDAR\r\n";

    String synthEvent(String uid, DateTime start, int durMin, String summary) =>
        "BEGIN:VEVENT\r\nUID:$uid\r\n"
        "DTSTAMP:${local(DateTime(2000, 1, 1))}\r\n"
        "DTSTART;TZID=Europe/Berlin:${local(start)}\r\n"
        "DTEND;TZID=Europe/Berlin:"
        "${local(start.add(Duration(minutes: durMin)))}\r\n"
        "RRULE:FREQ=WEEKLY;UNTIL=${local(start.add(const Duration(days: 100)))}"
        "\r\nSUMMARY:$summary\r\nEND:VEVENT\r\n";

    late DateTime mon8;
    late DateTime mon16;
    late DateTime tue8;
    late String mseBlock;

    setUp(() {
      mon8 = nextSlot(DateTime.monday, 8, 0);
      mon16 = nextSlot(DateTime.monday, 16, 0);
      tue8 = nextSlot(DateTime.tuesday, 8, 0);
      mseBlock = synthEvent('signmeup-1-1-480-570@ka_uni', mon8, 90,
              'Materials Science and Engineering I (Lecture)') +
          synthEvent('signmeup-2-2-480-570@ka_uni', tue8, 90,
              'Advanced Mathematics I (Lecture)');
    });

    test('feed-carried event suppressed, synth-only event kept', () {
      final feed = feedWith(feedEvent(
          'evt-mse',
          '3173008 - Materials Science and Engineering I (Lecture) (V), '
              'Gibmeier, MACH',
          mon8.subtract(const Duration(days: 14)),
          90));
      final out = CampusManager.dropSignMeUpSynthCoveredByFeed(feed, mseBlock);
      expect(out, isNot(contains('signmeup-1-1-480-570')),
          reason: 'feed already carries the Monday 08:00 MSE lecture');
      expect(out, contains('signmeup-2-2-480-570'),
          reason: 'no feed event Tuesday 08:00: synthesis is genuinely needed');
    });

    test('"(Tutorial - Group 2)" matches the feed\'s "(Group 2)" spelling', () {
      final feed = feedWith(feedEvent(
          'evt-am',
          '4510001 - Advanced Mathematics (Group 2), Prof. Dr. Mustermann',
          mon16.subtract(const Duration(days: 14)),
          90));
      final block = synthEvent('signmeup-3-1-960-1050@ka_uni', mon16, 90,
          'Advanced Mathematics (Tutorial - Group 2)');
      expect(
          CampusManager.dropSignMeUpSynthCoveredByFeed(feed, block), isEmpty);
    });

    test('different time never suppresses, unjudgeable feed never suppresses',
        () {
      // same title at a different weekday+time is a different appointment
      final feed = feedWith(feedEvent('evt-mse',
          'Materials Science and Engineering I (Lecture)', tue8, 90));
      final block = synthEvent('signmeup-1-1-480-570@ka_uni', mon8, 90,
          'Materials Science and Engineering I (Lecture)');
      expect(CampusManager.dropSignMeUpSynthCoveredByFeed(feed, block), block);
      // garbage feed -> the judgement keeps everything (a visible duplicate
      // beats a silently lost tutorial)
      expect(
          CampusManager.dropSignMeUpSynthCoveredByFeed(
              'BEGIN:VCALENDAR\r\nbroken', mseBlock),
          mseBlock);
    });

    test('reapplySignMeUpSynth embeds the deduped block and is then a no-op',
        () async {
      var notified = 0;
      final cm = CampusManager(Student.empty, () => notified++);
      final feed = feedWith(feedEvent(
          'evt-mse',
          '3173008 - Materials Science and Engineering I (Lecture) (V), '
              'Gibmeier, MACH',
          mon8.subtract(const Duration(days: 14)),
          90));
      SharedPreferences.setMockInitialValues({
        "DATA_webcalUrl": "https://cascampus.invalid/wc.ics",
        "DATA_webcalIcsCache": feed,
      });
      await cm.reapplySignMeUpSynth(mseBlock);
      expect(cm.signMeUpSynth, isNot(contains('signmeup-1-1-480-570')));
      expect(cm.signMeUpSynth, contains('signmeup-2-2-480-570'));
      final prefs = await SharedPreferences.getInstance();
      final cache = prefs.getString("DATA_webcalIcsCache")!;
      expect(cache, contains("X-SIGNMEUP-SYNTH-BEGIN"));
      expect(cache, isNot(contains('signmeup-1-1-480-570')));
      expect(notified, 1);
      await cm.reapplySignMeUpSynth(mseBlock); // byte-identical rebuild
      expect(notified, 1); // filtered == stored: no rewrite, no alarm storm
    });
  });
}
