import 'package:flutter/foundation.dart';
import 'package:http/http.dart';
import 'package:html/parser.dart' as htmlparser;

import '../state_management/ilias/ilias_manager.dart';
import 'models/ilias_models.dart';

const _base = "https://ilias.studium.kit.edu";

// Scraping side of ILIAS: enrolments, per-course material files,
// announcements and the top-bar unread counters. All GET-only; the
// IliasManager session (authorize()) must be valid beforehand.
//
// Verified against the live session 2026-10-30:
// * enrolments: anchors goto.php/crs/<ref> with "NNNNNNN – Title" text
// * container rows: h3.il_ContainerItemTitle > a.goto.php/<kind>/<ref>
// * personal news: dashboard cmdNode=a5:xx&cmdClass=ilPDNewsGUI&cmd=view
// * unread badges: first <span class="badge"> in the top bar = notifications
//
// All page parsing runs through compute() on a worker isolate: ILIAS
// dashboard pages are megabytes of HTML, and package:html parsing of them
// on the root isolate froze the UI long enough to trip the Android
// "KA.Uni isn't responding" dialog while the agenda loaded its ILIAS card.
extension IliasScraper on IliasManager {
  Future<Response> _getResp(String url) async {
    for (var attempt = 0;; attempt++) {
      try {
        final response = await netGet(Uri.parse(url));
        if (response.statusCode != 200) {
          throw Exception("ILIAS GET $url -> ${response.statusCode}");
        }
        return response;
      } on Exception catch (e) {
        // "ILIAS GET" = status!=200 (an SSO redirect): retrying plain GETs
        // cannot fix it, only _withSessionBody's re-authorize can -> rethrow
        if (attempt >= 2 || e.toString().contains("ILIAS GET")) {
          rethrow;
        }
        await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }
  }

  /// Re-runs SSO when the ILIAS session died, then retries once; the
  /// wrapper itself lives on IliasManager ([withSessionResponse]) so
  /// [IliasManager.downloadFile] recovers through the exact same path.
  /// If the retried page still shows a login wall the session is NOT
  /// revived - throwing beats parsing login HTML as empty course data.
  Future<String> _withSessionBody(Future<Response> Function() action) async {
    return bodyOf(await withSessionResponse(action));
  }

  /// Enrolled courses of the current semester from "Meine Kurse und Gruppen".
  Future<List<IliasCourse>> fetchCourses() async {
    final body = await _withSessionBody(() =>
        _getResp("$_base/ilias.php?baseClass=ilmembershipoverviewgui"));
    final courses = await compute(coursesFrom, body);
    if (courses.isEmpty && body.contains("goto.php/crs/")) {
      // 200 + live session + enrolment anchors on the page, yet nothing
      // parsed: the "NNNNNNN - Title" shape drifted past the regex.
      // Shout it - "0 courses" must never look like an honest empty term.
      if (kDebugMode) {
        print("ILIAS courses: anchors present but ZERO parsed - title regex drifted");
      }
    }
    return courses;
  }

  /// Top-bar unread counters (notifications badge + mail text).
  Future<IliasUnread> fetchUnread() async {
    final body = await _withSessionBody(
        () => _getResp("$_base/ilias.php?baseClass=ilDashboardGUI"));
    return compute(unreadFrom, body);
  }

  /// Material files of a course: walks "Course Materials" and its
  /// subfolders (depth ≤ 2) collecting non-folder container items.
  Future<List<IliasFile>> fetchCourseFiles(IliasCourse course) async {
    final courseBody = await _withSessionBody(() => _getResp(
        "$_base/ilias.php?baseClass=ilrepositorygui&cmdClass=ilobjcoursegui&ref_id=${course.refId}"));
    final rootFolders =
        await compute(_childRefsFrom, (courseBody, "fold"));

    final files = <IliasFile>[];
    final queue = <MapEntry<int, String>>[...rootFolders];
    final visited = <int>{...rootFolders.map((e) => e.key)};
    for (var depth = 0; depth < 3 && queue.isNotEmpty; depth++) {
      final level = List.of(queue);
      queue.clear();
      for (final folder in level) {
        // folders go through the session wrapper too: mid-crawl expiry used
        // to yield login-HTML whose parse "succeeded" with 0 files
        final folderBody = await _withSessionBody(() => _getResp(
            "$_base/ilias.php?baseClass=ilrepositorygui&cmdClass=ilObjFolderGUI&ref_id=${folder.key}"));
        final rows = await compute(_fileRowsFrom, folderBody);
        for (final row in rows) {
          files.add(IliasFile(
              courseRefId: course.refId,
              courseTitle: course.title,
              title: row.$1,
              url: row.$2,
              modified: _parseGermanDate(row.$3)));
        }
        final subs = await compute(_childRefsFrom, (folderBody, "fold"));
        for (final sub in subs) {
          if (visited.add(sub.key)) {
            queue.add(sub);
          }
        }
      }
    }
    return files;
  }

  /// Personal news aggregate (per-object announcements) from the dashboard.
  Future<List<IliasAnnouncement>> fetchAnnouncements() async {
    final dash = await _withSessionBody(() =>
        _getResp("$_base/ilias.php?baseClass=ilDashboardGUI&cmd=jumpToNews"));
    final node = await compute(newsNodeFrom, dash);
    if (node == null) {
      if (kDebugMode) print("ILIAS news: no PDNews block on dashboard");
      return [];
    }
    final newsBody = await _withSessionBody(() => _getResp(
        "$_base/ilias.php?baseClass=ildashboardgui&cmdNode=$node&cmdClass=ilPDNewsGUI&cmd=view"));
    return compute(_announcementsFrom, newsBody);
  }
}

// ---- pure page parsers: top-level so compute() can run them off the UI ----

@visibleForTesting
List<IliasCourse> coursesFrom(String body) {
  final doc = htmlparser.parse(body);
  final courses = <IliasCourse>[];
  final seen = <int>{};
  for (final a in doc.getElementsByTagName("a")) {
    final href = a.attributes["href"] ?? "";
    final m = RegExp(r"goto\.php/crs/(\d+)").firstMatch(href);
    final text = a.text.trim();
    final tm = RegExp(r"^(\d{7})\s*[–-]\s*(.+)$").firstMatch(text);
    if (m == null || tm == null) {
      continue;
    }
    final refId = int.parse(m.group(1)!);
    if (seen.add(refId)) {
      courses.add(IliasCourse(
          refId: refId, number: tm.group(1)!, title: tm.group(2)!.trim()));
    }
  }
  return courses;
}

/// The unread counters live in the top bar; a badge rendered EARLIER on
/// the dashboard (tab markers etc.) must never be read as the count, so
/// the search starts at the top bar marker - and only falls back to the
/// whole document when that marker itself vanished (markup drift).
@visibleForTesting
IliasUnread unreadFrom(String body) {
  final at = body.indexOf(RegExp("ilTopBar", caseSensitive: false));
  final topBar = at < 0 ? body : body.substring(at);
  final badge =
      RegExp(r'class="badge[^"]*"[^>]*>\s*(\d{1,4})').firstMatch(topBar);
  final mailRe = RegExp(r"(\d+)[^<]*neue[^<]*Mail");
  final mails =
      mailRe.hasMatch(body) ? int.parse(mailRe.firstMatch(body)!.group(1)!) : (body.contains("ungelesene Mail") ? 1 : 0);
  return IliasUnread(
      notifications: badge == null ? 0 : int.parse(badge.group(1)!),
      mails: mails);
}

List<MapEntry<int, String>> _childRefsFrom((String, String) args) {
  final (body, kind) = args;
  final doc = htmlparser.parse(body);
  final out = <MapEntry<int, String>>[];
  final seen = <int>{};
  for (final a in doc.getElementsByTagName("a")) {
    final href = a.attributes["href"] ?? "";
    final m = RegExp("goto\\.php/$kind/(\\d+)").firstMatch(href);
    if (m == null) continue;
    final ref = int.parse(m.group(1)!);
    final title = a.text.trim();
    if (seen.add(ref) && title.isNotEmpty) {
      out.add(MapEntry(ref, title));
    }
  }
  return out;
}

// container rows: h3.il_ContainerItemTitle > a — keep the non-folder ones
List<(String, String, String?)> _fileRowsFrom(String body) {
  final doc = htmlparser.parse(body);
  final rows = <(String, String, String?)>[];
  final seen = <String>{};
  for (final h3 in doc.querySelectorAll("h3.il_ContainerItemTitle")) {
    final a = h3.querySelector("a");
    final href = a?.attributes["href"] ?? "";
    final title = a?.text.trim() ?? "";
    if (title.isEmpty || !seen.add(title)) continue;
    if (RegExp(r"goto\.php/fold/").hasMatch(href)) continue; // subfolder
    final url = href.startsWith("http")
        ? href
        : (href.startsWith("ilias.php") ? "https://ilias.studium.kit.edu/$href" : href);
    final rowText = h3.parent?.parent?.text ?? "";
    final dm =
        RegExp(r"(\d{1,2}\.\s*\d{1,2}\.\s*\d{2,4})").firstMatch(rowText);
    rows.add((title, url, dm?.group(1)));
  }
  return rows;
}

const _months = {
  "Jan": 1, "Feb": 2, "Mär": 3, "Apr": 4, "Mai": 5, "Jun": 6, "Jul": 7,
  "Aug": 8, "Sep": 9, "Okt": 10, "Nov": 11, "Dez": 12,
};

/// "25.10.2026" and "25. Okt 2026, 11:48" both parse.
DateTime? _parseGermanDate(String? s) {
  if (s == null) return null;
  final full =
      RegExp(r"(\d{1,2})\.\s*(\d{1,2})\.\s*(\d{4})").firstMatch(s);
  if (full != null) {
    return DateTime(int.parse(full.group(3)!), int.parse(full.group(2)!),
        int.parse(full.group(1)!));
  }
  final month = RegExp(
          r"(\d{1,2})\.\s*(Jan|Feb|Mär|Apr|Mai|Jun|Jul|Aug|Sep|Okt|Nov|Dez)"
          r"\s*(\d{4})")
      .firstMatch(s);
  if (month != null) {
    return DateTime(int.parse(month.group(3)!),
        _months[month.group(2)!]!, int.parse(month.group(1)!));
  }
  return null;
}

@visibleForTesting
String? newsNodeFrom(String body) {
  final m = RegExp(r"cmdNode=([a-z0-9:]+)&cmdClass=ilPDNewsGUI&cmd=view")
      .firstMatch(body);
  return m?.group(1);
}

List<IliasAnnouncement> _announcementsFrom(String body) {
  final doc = htmlparser.parse(body);
  final items = <IliasAnnouncement>[];
  for (final panel in doc.querySelectorAll("div.ilTimelinePanel")) {
    final head = panel.querySelector("p.ilNewsTimelineObjHead a");
    final title = head?.text.trim() ?? "";
    final href = head?.attributes["href"] ?? "";
    if (title.isEmpty || href.isEmpty) continue;
    final when = _parseGermanDate(panel
        .querySelector("div.ilNewsTimelineEditInfo")
        ?.text
        .replaceAll("\u00a0", " "));
    final rm = RegExp(r"(?:ref_id=|goto\.php/\w+/)(\d+)").firstMatch(href);
    final url = href.startsWith("http")
        ? href
        : (href.startsWith("ilias.php") ? "https://ilias.studium.kit.edu/$href" : href);
    items.add(IliasAnnouncement(
        courseRefId: rm == null ? 0 : int.parse(rm.group(1)!),
        courseTitle: "",
        title: title,
        when: when,
        url: url));
  }
  return items;
}
