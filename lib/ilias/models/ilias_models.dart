import 'dart:convert';

// Data models for the ILIAS surfaces the agenda needs: enrolments,
// per-course files ("sheets"), announcements and unread counters.

class IliasCourse {
  final int refId;
  final String number; // 7-digit course number, e.g. 0140000
  final String title;

  IliasCourse({required this.refId, required this.number, required this.title});

  String get url => "https://ilias.studium.kit.edu/goto.php/crs/$refId";

  @override
  String toString() => "IliasCourse($number, $title, ref=$refId)";
}

class IliasFile {
  final int courseRefId;
  final String courseTitle;
  final String title;
  final String url;
  final DateTime? modified;

  IliasFile(
      {required this.courseRefId,
      required this.courseTitle,
      required this.title,
      required this.url,
      this.modified});

  @override
  String toString() =>
      "IliasFile($courseTitle: $title${modified != null ? " @ $modified" : ""})";
}

class IliasAnnouncement {
  final int courseRefId;
  final String courseTitle;
  final String title;
  final DateTime? when;
  final String url;

  IliasAnnouncement(
      {required this.courseRefId,
      required this.courseTitle,
      required this.title,
      required this.url,
      this.when});

  @override
  String toString() => "IliasAnnouncement($courseTitle: $title)";
}

class IliasUnread {
  final int notifications;
  final int mails;

  const IliasUnread({this.notifications = 0, this.mails = 0});

  int get total => notifications + mails;

  @override
  String toString() => "IliasUnread(n=$notifications, m=$mails)";
}

/// Prefs JSON for the ILIAS card cache. The live fetch costs two round
/// trips behind the SSO gate (~40 s on a cold session), so the card renders
/// this snapshot instantly and refreshes it in place.
String encodeIliasCard(IliasUnread? unread, List<IliasAnnouncement> anns) =>
    jsonEncode({
      "unread": [unread?.notifications, unread?.mails],
      "fetchedAt": DateTime.now().toIso8601String(),
      "announcements": [
        for (final a in anns)
          {
            "r": a.courseRefId,
            "c": a.courseTitle,
            "t": a.title,
            "u": a.url,
            "w": a.when?.toIso8601String(),
          }
      ],
    });

/// Returns null on any parse failure; a stale/corrupt cache must fall back
/// to the plain loading state, never to a half-rendered card.
(IliasUnread?, List<IliasAnnouncement>)? decodeIliasCard(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final u = map["unread"] as List<dynamic>?;
    final unread = (u == null || u[0] == null)
        ? null
        : IliasUnread(
            notifications: (u[0] as num).toInt(),
            mails: (u[1] as num).toInt());
    final anns = [
      for (final e
          in (map["announcements"] as List).cast<Map<String, dynamic>>())
        IliasAnnouncement(
          courseRefId: (e["r"] as num).toInt(),
          courseTitle: e["c"] as String,
          title: e["t"] as String,
          url: e["u"] as String,
          when: e["w"] == null ? null : DateTime.parse(e["w"] as String),
        )
    ];
    return (unread, anns);
  } catch (_) {
    return null;
  }
}
