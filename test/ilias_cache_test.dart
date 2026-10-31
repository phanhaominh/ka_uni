import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/ilias/models/ilias_models.dart';

void main() {
  test("ilias card cache survives a round-trip", () {
    final anns = [
      IliasAnnouncement(
          courseRefId: 4711,
          courseTitle: "0140000 – Analysis für Maschbau I",
          title: "Übungsblatt 3 online",
          url: "https://ilias.kit.edu/goto.php?target=crs_4711",
          when: DateTime(2026, 11, 2, 9, 15)),
      IliasAnnouncement(
          courseRefId: 815,
          courseTitle: "2145191 – Mechanical Design A",
          title: "Termverschiebung",
          url: "https://ilias.kit.edu/x"),
    ];
    final raw = encodeIliasCard(const IliasUnread(notifications: 3, mails: 1), anns);
    final back = decodeIliasCard(raw)!;
    expect(back.$1!.notifications, 3);
    expect(back.$1!.mails, 1);
    expect(back.$2.length, 2);
    expect(back.$2.first.title, "Übungsblatt 3 online");
    expect(back.$2.first.when, DateTime(2026, 11, 2, 9, 15));
    expect(back.$2.last.when, isNull);
    expect(back.$2.last.courseRefId, 815);
  });

  test("zero-unread snapshot keeps its zero (not null)", () {
    final raw = encodeIliasCard(const IliasUnread(), []);
    final back = decodeIliasCard(raw)!;
    expect(back.$1, isNotNull);
    expect(back.$1!.total, 0);
    expect(back.$2, isEmpty);
  });

  test("corrupt cache decodes to null, never to garbage", () {
    expect(decodeIliasCard(null), isNull);
    expect(decodeIliasCard(""), isNull);
    expect(decodeIliasCard("{oops"), isNull);
    expect(decodeIliasCard('{"unread":[1,2]}'), isNull); // missing list
  });
}
