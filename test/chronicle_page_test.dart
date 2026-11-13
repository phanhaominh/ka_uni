import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/agenda/views/chronicle_page.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';

Widget chronicle(List<IcsChange> changes) =>
    MaterialApp(home: ChroniclePage(changes: changes));

void main() {
  testWidgets(
      "stored deltas group by lecture day (newest day first) and the header discloses the /50 cap",
      (tester) async {
    final dTue = DateTime(2026, 11, 17, 10);
    final dThu8 = DateTime(2026, 11, 19, 8);
    final dThu14 = DateTime(2026, 11, 19, 14);
    final changes = [
      IcsChange(
          kind: IcsChangeKind.added,
          title: "Neu A",
          when: dTue,
          room: "HS 1"),
      IcsChange(
          kind: IcsChangeKind.removed,
          title: "Weg B",
          when: dTue,
          room: "HS 2"),
      IcsChange(
          kind: IcsChangeKind.changed,
          title: "Raum C",
          when: dThu8,
          room: "HS 4",
          oldRoom: "HS 3"),
      IcsChange(
          kind: IcsChangeKind.moved,
          title: "Um D",
          when: dThu14,
          room: "HS 5",
          oldRoom: "HS 6",
          oldWhen: DateTime(2026, 11, 19, 10)),
    ];
    await tester.pumpWidget(chronicle(changes));

    // coverage admission + cap disclosure with the oldest stored stamp
    expect(find.text(L10n.t("timetable.chronicleTitle")), findsOneWidget);
    expect(find.text(L10n.t("timetable.chronicleCoverage")), findsOneWidget);
    expect(
        find.text(L10n.t("timetable.chronicleCap", [
          changes.length,
          ChroniclePage.storedCap,
          L10n.stamp(dTue)
        ])),
        findsOneWidget);

    // one header per lecture day; every stored row renders its sentence
    final thu = find.text(L10n.stamp(DateTime(2026, 11, 19)));
    final tue = find.text(L10n.stamp(DateTime(2026, 11, 17)));
    expect(thu, findsOneWidget);
    expect(tue, findsOneWidget);
    for (final c in changes) {
      expect(find.text(c.describe()), findsOneWidget);
    }
    // newest day on top — the reading order a "what changed?" log needs
    expect(tester.getTopLeft(thu).dy, lessThan(tester.getTopLeft(tue).dy));
    // inside Thursday the 14:00 delta precedes the 08:00 one
    expect(
        tester
            .getTopLeft(find.text(changes[3].describe()))
            .dy,
        lessThan(tester.getTopLeft(find.text(changes[2].describe())).dy));

    // kind coloring: one icon per kind, no kind shares another's glyph
    expect(find.byIcon(Icons.add_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.remove_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.edit), findsOneWidget);
    expect(find.byIcon(Icons.swap_horiz), findsOneWidget);
  });

  testWidgets("a full 50-entry store reads as full, not as the whole history",
      (tester) async {
    final base = DateTime(2026, 11, 16, 8);
    final changes = [
      for (var i = 0; i < ChroniclePage.storedCap; i++)
        IcsChange(
            kind: IcsChangeKind.changed,
            title: "Delta $i",
            when: base.add(Duration(hours: i)),
            room: "10.3${i % 10}",
            oldRoom: "10.1${i % 10}"),
    ];
    await tester.pumpWidget(chronicle(changes));
    expect(
        find.text(L10n.t("timetable.chronicleCap", [
          ChroniclePage.storedCap,
          ChroniclePage.storedCap,
          L10n.stamp(base)
        ])),
        findsOneWidget);
  });

  testWidgets("an empty store says none yet instead of hiding the header",
      (tester) async {
    await tester.pumpWidget(chronicle(const []));
    expect(find.text(L10n.t("timetable.chronicleEmpty")), findsOneWidget);
    // the coverage line stays honest even when there is nothing to show
    expect(find.text(L10n.t("timetable.chronicleCoverage")), findsOneWidget);
    expect(find.byIcon(Icons.edit), findsNothing);
  });
}
