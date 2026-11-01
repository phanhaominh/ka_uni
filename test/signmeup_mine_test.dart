import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/signmeup/signmeup_manager.dart';
import 'package:kit_mobile/signmeup/signmeup_mine_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Status-card round on top of the existing signmeup_test.dart: parsing of
/// the raw-JSON fields that used to be dropped (rank / canConfirm /
/// firstDrawDate), the stateLabel -> outcome mapping and the agenda row
/// selection. Rows here are synthetic minimal payloads, never fixture text.
void main() {
  SignMeUpRegistration reg(Map<String, dynamic> extra) =>
      SignMeUpRegistration.fromJson({"id": 1, ...extra});

  group("new field parsing", () {
    test('live fixture: rank null, canConfirm false, firstDrawDate null', () {
      final decoded = jsonDecode(
          File('test/fixtures/myregs.json').readAsStringSync());
      final mine = (decoded['registrations'] as List)
          .map((e) => SignMeUpRegistration.fromJson(e as Map<String, dynamic>))
          .toList();
      expect(mine, hasLength(5));
      for (final r in mine) {
        expect(r.rank, isNull, reason: r.name);
        expect(r.canConfirm, isFalse, reason: r.name);
        expect(r.firstDrawDate, isNull, reason: r.name);
      }
    });

    test('missing keys degrade to null/false', () {
      final r = reg({"name": "X"});
      expect(r.rank, isNull);
      expect(r.canConfirm, isFalse);
      expect(r.firstDrawDate, isNull);
    });

    test('firstDrawDate parses ISO with seven fractional digits', () {
      // the wire format observed on confirmationDeadline:
      // "2026-10-31T11:20:02.4388606Z"
      final r = reg({"firstDrawDate": "2026-12-04T14:00:00.4388606Z"});
      expect(r.firstDrawDate, isNotNull);
      // Dart keeps microsecond precision and drops the 7th digit
      expect(
          r.firstDrawDate!.toUtc().difference(DateTime.utc(2026, 12, 4, 14)),
          const Duration(microseconds: 438860));
    });

    test('firstDrawDate tolerates epoch seconds, millis and strings', () {
      final instant =
          DateTime.fromMillisecondsSinceEpoch(1793416802000);
      for (final v in [1793416802, 1793416802000, "1793416802"]) {
        expect(reg({"firstDrawDate": v}).firstDrawDate,
            instant.toLocal(),
            reason: "$v");
      }
    });

    test('garbage dates degrade to null', () {
      expect(reg({"firstDrawDate": "morgen"}).firstDrawDate, isNull);
      expect(reg({"firstDrawDate": ""}).firstDrawDate, isNull);
    });

    test('rank and canConfirm pass through', () {
      expect(reg({"rank": 7, "canConfirm": true}).rank, 7);
      expect(reg({"rank": 7, "canConfirm": true}).canConfirm, isTrue);
    });
  });

  group("outcome mapping", () {
    test('fixture labels and their German variants map', () {
      expect(reg({"stateLabel": "accepted"}).outcome,
          SignMeUpOutcome.accepted);
      expect(reg({"stateLabel": "Open"}).outcome, SignMeUpOutcome.open);
      expect(reg({"stateLabel": "ABGELEHNT"}).outcome,
          SignMeUpOutcome.rejected);
      expect(reg({"stateLabel": "angenommen"}).outcome,
          SignMeUpOutcome.accepted);
      expect(reg({"stateLabel": "nicht zugelassen"}).outcome,
          SignMeUpOutcome.rejected);
      expect(reg({"stateLabel": "Warteliste"}).outcome,
          SignMeUpOutcome.open);
    });

    test('unknown label stays unknown for the raw fallback chip', () {
      expect(reg({"stateLabel": "Gewonnen"}).outcome,
          SignMeUpOutcome.unknown);
    });

    test('empty label falls back to the state code', () {
      expect(reg({"stateLabel": "", "state": 3}).outcome,
          SignMeUpOutcome.accepted);
      expect(reg({"stateLabel": "", "state": 0}).outcome,
          SignMeUpOutcome.open);
    });
  });

  group("row selection", () {
    final now = DateTime(2026, 11, 8, 8);

    test('nextMilestone picks the nearest future date', () {
      final r = reg({
        "confirmationDeadline": "2026-11-20T10:00:00",
        "firstDrawDate": "2026-11-12T09:00:00",
      });
      expect(r.nextMilestone(now), DateTime(2026, 11, 12, 9));
    });

    test('nextMilestone is null once both dates passed', () {
      final r = reg({
        "confirmationDeadline": "2026-11-01T10:00:00",
        "firstDrawDate": "2026-11-05T09:00:00",
      });
      expect(r.nextMilestone(now), isNull);
    });

    test('a row drops once every known expiry is past; registrationEnd '
        'bounds rows without confirmationDeadline', () {
      final dead = reg({
        "confirmationDeadline": "2026-11-01T10:00:00",
        "firstDrawDate": "2026-11-05T09:00:00",
      });
      final dateless = reg({"stateLabel": "accepted"});
      final onePast = reg({
        "confirmationDeadline": "2026-11-01T10:00:00",
        "firstDrawDate": "2026-11-12T09:00:00",
      });
      expect(SignMeUpMineCard.activeRows([dead, dateless, onePast], now),
          [onePast, dateless]);
      // no confirmationDeadline: registrationEnd is the expiry bound
      final endAhead = reg({
        "stateLabel": "open",
        "registrationEnd": "2026-11-20T23:59:00",
      });
      final endPast = reg({
        "stateLabel": "open",
        "registrationEnd": "2026-11-02T23:59:00",
      });
      expect(
          SignMeUpMineCard.activeRows([endAhead, endPast], now), [endAhead]);
    });

    test('confirm-pending first, then nearest milestone, dateless last',
        () {
      final plain = reg({
        "name": "plain",
        "stateLabel": "accepted",
        "confirmationDeadline": "2026-11-15T10:00:00",
      });
      final soon = reg({
        "name": "soon",
        "stateLabel": "open",
        "firstDrawDate": "2026-11-10T09:00:00",
      });
      final late = reg({
        "name": "late",
        "stateLabel": "open",
        "firstDrawDate": "2026-11-20T09:00:00",
      });
      final dateless = reg({"name": "dateless", "stateLabel": "accepted"});
      // canConfirm outranks even a later deadline: an action to take
      // beats a countdown to wait for
      final confirm = reg({
        "name": "confirm",
        "stateLabel": "accepted",
        "canConfirm": true,
        "confirmationDeadline": "2026-11-25T10:00:00",
      });
      expect(
          SignMeUpMineCard.activeRows(
              [late, dateless, plain, confirm, soon], now),
          [confirm, soon, plain, late, dateless]);
    });

    test('rows that would render nothing but a name are dropped', () {
      // unknown outcome + blank label (no decision code either) + no rank
      // + no pending milestone = an empty detail row
      final empty = reg({"name": "empty", "stateLabel": "", "state": 7});
      final raw = reg({"name": "raw", "stateLabel": "Gewonnen"});
      final rankOnly =
          reg({"name": "rank", "stateLabel": "", "state": 7, "rank": 2});
      final milestoneOnly = reg({
        "name": "draw",
        "stateLabel": "",
        "state": 7,
        "firstDrawDate": "2026-11-12T09:00:00",
      });
      final kept = SignMeUpMineCard.activeRows(
          [empty, raw, rankOnly, milestoneOnly], now);
      expect(kept.first, milestoneOnly);
      expect(kept.toSet(), {raw, rankOnly, milestoneOnly});
    });
  });

  group("countdown wording", () {
    test('calendar days, not 24-h windows', () {
      // tomorrow 08:00 seen at 23:00 today: one calendar day
      expect(L10n.daysFromNow(DateTime(2026, 11, 3, 8),
              DateTime(2026, 11, 2, 23)),
          1);
    });

    test('de: heute / morgen / in N Tagen', () {
      final now = DateTime(2026, 11, 8, 8);
      expect(L10n.dayOffset(DateTime(2026, 11, 8, 23), now), "heute");
      expect(L10n.dayOffset(DateTime(2026, 11, 9, 6), now), "morgen");
      expect(L10n.dayOffset(DateTime(2026, 11, 13, 12), now), "in 5 Tagen");
    });

    test('en: today / tomorrow / in N days', () async {
      SharedPreferences.setMockInitialValues({});
      await L10n.reload(prefOverride: "en");
      addTearDown(() => L10n.reload(prefOverride: "de"));
      final now = DateTime(2026, 11, 8, 8);
      expect(L10n.dayOffset(DateTime(2026, 11, 8, 23), now), "today");
      expect(L10n.dayOffset(DateTime(2026, 11, 9, 6), now), "tomorrow");
      expect(L10n.dayOffset(DateTime(2026, 11, 13, 12), now), "in 5 days");
      expect(L10n.t("agenda.signmeupMineRank", [3]), "rank 3");
      // the chip says "pending" - "open" was the server's label, not a
      // word a student would put on a status chip
      expect(L10n.t("agenda.signmeupMineOpen"), "pending");
    });
  });

  group("status card widget", () {
    Future<void> pumpCard(
        WidgetTester tester, List<SignMeUpRegistration> rows) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SignMeUpMineCard(
                rows: rows, now: DateTime(2026, 11, 8, 8)),
          ),
        ),
      ));
    }

    testWidgets('title, state chip and countdown render', (tester) async {
      await pumpCard(tester, [
        reg({
          "name": "Testkurs EMI",
          "stateLabel": "open",
          "confirmationDeadline": "2026-11-10T10:00:00",
        }),
      ]);
      expect(find.text("Meine Anmeldungen"), findsOneWidget);
      expect(find.text("Testkurs EMI"), findsOneWidget);
      expect(find.text("offen"), findsOneWidget);
      expect(find.text("in 2 Tagen"), findsOneWidget);
    });

    testWidgets('only a positive rank shows a Platz chip text',
        (tester) async {
      await pumpCard(tester, [
        reg({"name": "Mit Rang", "stateLabel": "open", "rank": 3}),
        reg({"name": "Ohne Rang", "stateLabel": "accepted", "rank": 0}),
      ]);
      expect(find.text("Platz 3"), findsOneWidget);
      expect(find.textContaining("Platz 0"), findsNothing);
      expect(find.text("angenommen"), findsOneWidget);
    });

    testWidgets('unknown label falls back to its raw text', (tester) async {
      await pumpCard(tester, [
        reg({"name": "Überraschung", "stateLabel": "Gewonnen"}),
      ]);
      expect(find.text("Gewonnen"), findsOneWidget);
      expect(find.text("offen"), findsNothing);
    });

    testWidgets('+N mehr caption beyond maxRows, none within it',
        (tester) async {
      final rows = [
        for (var i = 0; i < 5; i++)
          reg({"name": "Kurs $i", "stateLabel": "accepted"}),
      ];
      await pumpCard(tester, rows);
      expect(find.text("+1 mehr"), findsOneWidget);
      expect(find.text("Kurs 4"), findsNothing);
      await pumpCard(tester, rows.take(4).toList());
      expect(find.textContaining("mehr"), findsNothing);
    });

    testWidgets('accepted/rejected tint the Cupertino semantics, open '
        'and unknown stay neutral', (tester) async {
      await pumpCard(tester, [
        reg({"stateLabel": "accepted"}),
        reg({"stateLabel": "rejected"}),
        reg({"stateLabel": "open"}),
        reg({"stateLabel": "Gewonnen"}),
      ]);
      final scheme =
          Theme.of(tester.element(find.byType(SignMeUpMineCard))).colorScheme;
      BoxDecoration chip(String label) => tester.widget<Container>(find
              .ancestor(
                  of: find.text(label), matching: find.byType(Container))
              .first)
          .decoration! as BoxDecoration;
      Color fg(String label) =>
          tester.widget<Text>(find.text(label)).style!.color!;
      final green = CupertinoDynamicColor.resolve(
          CupertinoColors.systemGreen,
          tester.element(find.text("angenommen")));
      final red = CupertinoDynamicColor.resolve(CupertinoColors.systemRed,
          tester.element(find.text("abgelehnt")));
      expect(chip("angenommen").color, green.withValues(alpha: 0.15));
      expect(fg("angenommen"), green);
      expect(chip("abgelehnt").color, red.withValues(alpha: 0.15));
      expect(fg("abgelehnt"), red);
      for (final label in ["offen", "Gewonnen"]) {
        expect(chip(label).color, scheme.surfaceContainerHighest);
        expect(fg(label), scheme.onSurfaceVariant);
      }
    });

    testWidgets('deadline outranks the descriptive rank in color',
        (tester) async {
      await pumpCard(tester, [
        reg({
          "stateLabel": "open",
          "rank": 3,
          "confirmationDeadline": "2026-11-10T10:00:00",
        }),
      ]);
      final scheme =
          Theme.of(tester.element(find.byType(SignMeUpMineCard))).colorScheme;
      final countdown = tester.widget<Text>(find.text("in 2 Tagen")).style!;
      expect(countdown.color, scheme.onSurfaceVariant);
      expect(countdown.fontWeight, FontWeight.w500);
      expect(tester.widget<Text>(find.text("Platz 3")).style!.color,
          scheme.outline);
    });
  });
}
