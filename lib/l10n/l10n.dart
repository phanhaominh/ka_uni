import 'dart:ui' show Locale;

import 'package:shared_preferences/shared_preferences.dart';

import 'strings_exams.dart';
import 'strings_files.dart';
import 'strings_notifs.dart';
import 'strings_settings.dart';
import 'strings_timetable.dart';

/// Tiny hand-rolled localization layer.
///
/// Chosen over gen-l10n because much of this app renders strings from model
/// and service code (notifications, exam statuses, scrapers) that has no
/// BuildContext. Keys are `area.name`; `de` is the source of truth and `en`
/// falls back to it, so a missing translation degrades to German, never to a
/// raw key.
///
/// Interpolation uses `{0}`, `{1}` ... positional placeholders:
///   L10n.t("exams.until", ["22.11.2026"])
class L10n {
  static const languagePrefKey = "PREF_language"; // "system" | "de" | "en"

  static String _language = "de";
  static String _systemLanguage = "de";

  /// Effective language code: "de" or "en".
  static String get language => _language;
  static bool get isEnglish => _language == "en";
  static Locale get locale => Locale(_language);

  /// Resolve effective language from the stored preference + system locale.
  /// Called at startup and whenever the language setting changes.
  static Future<void> reload({String? prefOverride}) async {
    final prefs = await SharedPreferences.getInstance();
    final pref = prefOverride ?? prefs.getString(languagePrefKey) ?? "system";
    if (pref != "system") {
      _language = pref;
      return;
    }
    final sys = _systemLanguage;
    _language = sys == "en" ? "en" : "de";
  }

  /// System locale code captured at startup (preference "system" uses this).
  static void setSystemLanguage(String code) => _systemLanguage = code == "en" ? "en" : "de";

  static String t(String key, [List<Object> args = const []]) {
    var raw = (_language == "en" ? _en[key] : null) ?? _de[key] ?? key;
    for (var i = 0; i < args.length; i++) {
      raw = raw.replaceAll("{$i}", "${args[i]}");
    }
    return raw;
  }

  /// Localized short weekday abbreviation: "Mo", "Di" / "Mon", "Tue".
  static String weekday(int w) =>
      (isEnglish ? _enWeekdays : _deWeekdays)[w - 1];

  /// "So, 25.10. 00:00" / "Sun, 25.10. 00:00" — shared agenda stamp format.
  static String stamp(DateTime d) =>
      "${weekday(d.weekday)}, ${d.day.toString().padLeft(2, "0")}."
      "${d.month.toString().padLeft(2, "0")}. "
      "${d.hour.toString().padLeft(2, "0")}:"
      "${d.minute.toString().padLeft(2, "0")}";

  /// "bis 22.11.2026" / "until 22.11.2026" — deadline suffix.
  static String until(DateTime d) => t(isEnglish ? "dates.until" : "dates.bis",
      ["${d.day}.${d.month}.${d.year}"]);

  /// Whole calendar days from [now] to [at] (not 24-h windows): an exam
  /// tomorrow at 08:00 seen at 23:00 is "tomorrow", not "today".
  static int daysFromNow(DateTime at, DateTime now) =>
      DateTime(at.year, at.month, at.day)
          .difference(DateTime(now.year, now.month, now.day))
          .inDays;

  /// "heute" / "morgen" / "in 5 Tagen" - the app's shared relative-date
  /// countdown wording (agenda exam card and SignMeUp status card).
  static String dayOffset(DateTime at, DateTime now) {
    final days = daysFromNow(at, now);
    if (days == 0) return t("agenda.examToday");
    if (days == 1) return t("agenda.examTomorrow");
    return t("agenda.examInDays", [days]);
  }

  static const _deWeekdays = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"];
  static const _enWeekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

  // German = source of truth: exactly the strings shipped so far.
  static const Map<String, String> _de = {
    ...de_exams,
    ...de_files,
    ...de_notifs,
    ...de_settings,
    ...de_timetable,
    // shared / dates
    "dates.bis": "bis {0}",
    "dates.until": "bis {0}",
    // agenda
    "agenda.title": "Agenda",
    "agenda.today": "Heute",
    "agenda.todayFull": "Heute, {0}",
    "agenda.tomorrow": "Morgen",
    "agenda.tomorrowFull": "Morgen, {0}",
    "agenda.noEvents": "Keine Veranstaltungen",
    "agenda.noEventsUntil": "Nichts vor {0}",
    "agenda.timetableLoading": "Stundenplan wird geladen…",
    "agenda.timetableChangedN": "Stundenplan geändert ({0})",
    "agenda.roomChanges": "Raumänderungen, Ausfälle, neue Mitteilungen",
    "agenda.lecturesExercises": "Vorlesungen und Übungen",
    "agenda.ilias": "ILIAS",
    "agenda.iliasLoading": "Meldungen werden geladen…",
    "agenda.iliasUnreachable": "ILIAS gerade nicht erreichbar",
    "agenda.iliasNone": "Keine neuen Meldungen",
    "agenda.nNew": "{0} neu",
    "agenda.examsOpen": "Prüfungsanmeldung offen",
    "agenda.examsLoading": "Prüfungsanmeldungen werden geprüft…",
    "agenda.toRegistration": "Zur Anmeldung",
    "agenda.moreChanges": "… und {0} weitere",
    "agenda.dismiss": "Verstanden",
    "common.dismiss": "Schließen",
    "common.refreshFailed": "Aktualisierung fehlgeschlagen – bitte erneut versuchen",
    "info.privacyPolicy": "Datenschutzerklärung",
    "files.document": "Dokument",
    "settings.language": "Sprache",
    "settings.languageSystem": "System",
    "settings.languageDe": "Deutsch",
    "settings.languageEn": "English",
    "settings.appearance": "Erscheinungsbild",
    "settings.themeSystem": "System",
    "settings.themeLight": "Hell",
    "settings.themeDark": "Dunkel",
    "settings.semester": "Semester",
    "auth.invalidCredentials": "Ungültige Zugangsdaten!",
    "auth.fail": "Anmeldung fehlgeschlagen – bitte erneut versuchen.",
    "ilias.downloading": "Wird heruntergeladen...",
    "ilias.downloadFailed": "Download fehlgeschlagen – bitte erneut versuchen",
    "ilias.refreshError": "Fehler beim Aktualisieren!",
    "easter.currywerk": "Currywerk ist überschätzt",
    // round 1: next-up banner
    "agenda.nowRunning": "läuft · bis {0}",
    "agenda.startsSoon": "startet gleich",
    "agenda.startsInMin": "startet in {0} Min",
    "agenda.startsInHours": "startet in {0} Std",
    "agenda.nextUp": "Als Nächstes",
    // round 1: next exam countdown
    "agenda.nextExam": "Nächste Prüfung",
    "agenda.examToday": "heute",
    "agenda.examTomorrow": "morgen",
    "agenda.examInDays": "in {0} Tagen",
    // round 1: stale-data footer
    "agenda.asOf": "Stand: {0} Uhr",
    "agenda.staleData": "Keine Aktualisierung seit {0}",
    "agenda.staleUnknown": "Stundenplan evtl. veraltet – zum Aktualisieren ziehen",
    // round 1: home empty-state
    "home.modulesEmpty": "Noch keine Module geladen",
    "home.modulesEmptyBtn": "Jetzt aktualisieren",
    "home.lastUpdated": "Zuletzt aktualisiert: {0}",
    // round 3: SignMeUp
    "agenda.signmeupTitle": "SignMeUp-Anmeldungen",
    "agenda.signmeupEnds": "{0} · bis {1}",
    "agenda.signmeupOpens": "{0} · ab {1}",
    "agenda.signmeupUntil": "bis {0}",
    "agenda.signmeupFrom": "ab {0}",
    "notifs.signmeupTitle": "SignMeUp-Frist endet bald",
    "notifs.signmeupBody": "{0} – Anmeldung endet um {1}",
    // SignMeUp "Meine Anmeldungen" status card
    "agenda.signmeupMineTitle": "Meine Anmeldungen",
    "agenda.signmeupMineRank": "Platz {0}",
    "agenda.signmeupMineAccepted": "angenommen",
    "agenda.signmeupMineRejected": "abgelehnt",
    "agenda.signmeupMineOpen": "offen",
    "agenda.signmeupMineMore": "+{0} mehr",
    // round 3: morning digest
    "notifs.digestTitle": "Heute: {0} Veranstaltungen",
    "notifs.digestBody": " Erste um {0}{1}",
    "notifs.digestChanges": " · Stundenplan geändert",
    // round 3: travel hints
    "agenda.walkOk": "Fußweg ca. {0} Min",
    "agenda.walkTight": "Nur {0} Min Pause – Fußweg ca. {1} Min",
    // ICS export (agenda share button + settings own-timetable section)
    "export.timetable": "Stundenplan exportieren…",
    "export.timetableFull": "Stundenplan exportieren (alle Quellen)…",
    "export.done": "{0} Termine exportiert",
    "export.doneOne": "1 Termin exportiert",
    "export.empty":
        "Noch kein Stundenplan gespeichert – auf der Startseite nach unten ziehen, um ihn zu laden",
    "export.failed": "Export fehlgeschlagen – bitte erneut versuchen",
  };

  static const Map<String, String> _en = {
    ...en_exams,
    ...en_files,
    ...en_notifs,
    ...en_settings,
    ...en_timetable,
    // shared / dates
    "dates.bis": "until {0}",
    "agenda.lecturesExercises": "Lectures and tutorials",
    "agenda.title": "Agenda",
    "agenda.today": "Today",
    "agenda.todayFull": "Today, {0}",
    "agenda.tomorrow": "Tomorrow",
    "agenda.tomorrowFull": "Tomorrow, {0}",
    "agenda.noEvents": "No events",
    "agenda.noEventsUntil": "Nothing before {0}",
    "agenda.timetableLoading": "Loading timetable…",
    "agenda.timetableChangedN": "Timetable changed ({0})",
    "agenda.roomChanges": "Room changes, cancellations, new messages",
    "agenda.iliasLoading": "Loading messages…",
    "agenda.iliasUnreachable": "ILIAS currently unreachable",
    "agenda.iliasNone": "No new messages",
    "agenda.nNew": "{0} new",
    "agenda.examsOpen": "Exam registration open",
    "agenda.examsLoading": "Checking exam registrations…",
    "agenda.toRegistration": "Register",
    "agenda.moreChanges": "… and {0} more",
    "agenda.dismiss": "Got it",
    "common.dismiss": "Dismiss",
    "common.refreshFailed": "Refresh failed - please try again",
    "info.privacyPolicy": "Privacy Policy",
    "files.document": "Document",
    "settings.language": "Language",
    "settings.languageSystem": "System",
    "settings.languageDe": "Deutsch",
    "settings.languageEn": "English",
    "settings.appearance": "Appearance",
    "settings.themeSystem": "System",
    "settings.themeLight": "Light",
    "settings.themeDark": "Dark",
    "settings.semester": "Semester",
    "dates.until": "until {0}",
    "agenda.ilias": "ILIAS",
    "auth.invalidCredentials": "Invalid credentials!",
    "auth.fail": "Login failed – please try again.",
    "ilias.downloading": "Downloading...",
    "ilias.downloadFailed": "Download failed - please try again",
    "ilias.refreshError": "Refresh failed!",
    "easter.currywerk": "Currywerk is overrated",
    "agenda.nowRunning": "running · until {0}",
    "agenda.startsSoon": "starting soon",
    "agenda.startsInMin": "starts in {0} min",
    "agenda.startsInHours": "starts in {0} h",
    "agenda.nextUp": "Next up",
    "agenda.nextExam": "Next exam",
    "agenda.examToday": "today",
    "agenda.examTomorrow": "tomorrow",
    "agenda.examInDays": "in {0} days",
    "agenda.asOf": "As of {0}",
    "agenda.staleData": "No update since {0}",
    "agenda.staleUnknown": "Timetable may be outdated – pull to refresh",
    "home.modulesEmpty": "No modules loaded yet",
    "home.modulesEmptyBtn": "Refresh now",
    "home.lastUpdated": "Last updated: {0}",
    "agenda.signmeupTitle": "SignMeUp registrations",
    "agenda.signmeupEnds": "{0} · until {1}",
    "agenda.signmeupOpens": "{0} · from {1}",
    "agenda.signmeupUntil": "until {0}",
    "agenda.signmeupFrom": "from {0}",
    "notifs.signmeupTitle": "SignMeUp deadline approaching",
    "notifs.signmeupBody": "{0} – registration ends at {1}",
    "agenda.signmeupMineTitle": "My registrations",
    "agenda.signmeupMineRank": "rank {0}",
    "agenda.signmeupMineAccepted": "accepted",
    "agenda.signmeupMineRejected": "rejected",
    "agenda.signmeupMineOpen": "pending",
    "agenda.signmeupMineMore": "+{0} more",
    "notifs.digestTitle": "Today: {0} classes",
    "notifs.digestBody": " First at {0}{1}",
    "notifs.digestChanges": " · timetable changed",
    "agenda.walkOk": "~{0} min walk",
    "agenda.walkTight": "Only {0} min break – ~{1} min walk",
    "export.timetable": "Export timetable…",
    "export.timetableFull": "Export timetable (all sources)…",
    "export.done": "{0} events exported",
    "export.doneOne": "1 event exported",
    "export.empty":
        "No timetable stored yet – pull down on the home page to load it",
    "export.failed": "Export failed – please try again",
  };
}
