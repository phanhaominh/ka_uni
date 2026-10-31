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
