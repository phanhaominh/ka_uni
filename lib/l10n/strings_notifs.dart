// ignore_for_file: constant_identifier_names // names fixed by the l10n merge contract
const Map<String, String> de_notifs = {
  "notifs.channelTimetable": "Zeitplan",
  "notifs.channelTimetableDesc": "Heutige und zukünftige Termine",
  "notifs.channelDeadlines": "Fristen",
  "notifs.channelDeadlinesDesc": "Abgaben, SignMeUp, Prüfungsanmeldung",
  "notifs.channelChanges": "Änderungen",
  "notifs.channelLibrary": "Bibliothek",
  "notifs.channelLibraryDesc": "Check-in für gebuchte Lernplätze",
  "notifs.examDeadlineTitle": "Prüfungsanmeldung schließt bald",
  "notifs.examDeadlineBody": "{0} — noch nicht angemeldet, Frist {1}",
  // R32.3: T−24h ping for the deregistration deadline of a REGISTERED
  // exam ("Abmelden bis"); {1} is the long L10n.deadline stamp.
  "notifs.deregTitle": "Prüfungs-Abmeldung endet bald",
  "notifs.deregBody": "{0} — Abmelden bis {1}",
  // R32.5: prereq-gate heads-up. "bekannte Sperre" on purpose: only
  // already-FAILED prerequisite parts count, so the push must never
  // claim the list is complete (prereqNote says so out loud).
  "notifs.prereqTitle": "Neue bekannte Sperre",
  "notifs.prereqLine": "{0} — bekannte Sperre durch: {1}",
  "notifs.prereqNote":
      "Nur bereits nicht bestandene Zulassungsvoraussetzungen zählen — "
      "weitere Sperren möglich.",
  // R32.3 cockpit row label (agenda.* rides the flattened merge — the
  // R32 lane's strings live in this file, the prefix does namespacing)
  "agenda.cockpitDereg": "Abmeldefrist",
  "notifs.changesDetails": "Details in der Agenda.",
  // R32.1: placeholder/empty rooms in the morning digest lecture line —
  // the feed says "there is a room we do not know", never "no room".
  "notifs.digestRoomTba": "Raum folgt",
  // R33.1: T-0 "window opens" ping. No "closes tonight" twin by design —
  // closing deadlines live in the morning digest, one ping per opening.
  "notifs.smuOpensTitle": "Anmeldung jetzt offen",
  "notifs.smuOpensBody": "{0} — das Anmeldefenster hat geöffnet.",
  // R33.2: inline action; pure navigation, marks nothing, claims nothing.
  "notifs.actionOpenSignMeUp": "Jetzt anmelden",
  // R33.4: last-lecture soft-alarm. "laut Plan" is load-bearing: the
  // schedule can still change; the app certifies the feed, not the future.
  "notifs.lastLectureTitle": "Letzte Vorlesung — laut Plan",
  "notifs.lastLectureBody":
      "Laut Plan ist {0} am {1} um {2} deine letzte Vorlesung des "
      "Semesters.",
  "notifs.digestLastLecture": "Letzte Vorlesung laut Plan: {0} um {1}",
  // R34.1 FRISTENBUCH: a day made only of hand-noted "Frist:" rows is
  // neither an Abgabe (ILIAS assignment) nor a lecture — honest word: Frist
  "notifs.digestTitleFrb": "Heute: Frist",
  "notifs.bannerBotProtection":
      "KIT hat ihren Bot-Schutz geändert — Datenabruf bis auf Weiteres gestört. Update nötig.",
  "notifs.bannerBoth":
      "Prüfungen & Stundenplan konnten nicht gelesen werden (KIT-Seite geändert?).",
  "notifs.bannerExams":
      "Prüfungsliste konnte nicht gelesen werden (KIT-Seite geändert?).",
  "notifs.bannerTimetable":
      "Stundenplan konnte nicht aktualisiert werden (KIT-Seite geändert?).",
  "notifs.bannerOffline":
      "KIT gerade nicht erreichbar — Verbindung prüfen, die Daten können veraltet sein.",
  // ---- ilias.* (appended for IliasWatcher; kept in this table per the
  // l10n merge contract — the maps are flattened, prefix is namespacing) ----
  // Push title when the news feed names no course (scraper leaves it empty).
  "ilias.notifyFallbackTitle": "ILIAS",
};

const Map<String, String> en_notifs = {
  "notifs.channelTimetable": "Timetable",
  "notifs.channelTimetableDesc": "Today's and upcoming appointments",
  "notifs.channelDeadlines": "Deadlines",
  "notifs.channelDeadlinesDesc": "Assignments, SignMeUp, exam registration",
  "notifs.channelChanges": "Changes",
  "notifs.channelLibrary": "Library",
  "notifs.channelLibraryDesc": "Check-in for booked study seats",
  "notifs.examDeadlineTitle": "Exam registration closing soon",
  "notifs.examDeadlineBody": "{0} — not registered yet, deadline {1}",
  // R32.3: deregistration-deadline ping (see de_notifs)
  "notifs.deregTitle": "Exam deregistration closing soon",
  "notifs.deregBody": "{0} — unregister until {1}",
  // R32.5: prereq-gate heads-up — "known block" wording mirrors DE: the
  // app only ever sees already-failed prerequisite parts, never the full
  // admission ruleset, so completeness is never asserted.
  "notifs.prereqTitle": "New known block",
  "notifs.prereqLine": "{0} — known block by: {1}",
  "notifs.prereqNote":
      "Only already-failed prerequisite parts count — other blocks "
      "may exist.",
  // R32.3 cockpit row label (see de_notifs)
  "agenda.cockpitDereg": "Deregistration deadline",
  "notifs.changesDetails": "Details in the agenda.",
  "notifs.digestRoomTba": "Room TBA",
  "notifs.smuOpensTitle": "Registration open now",
  "notifs.smuOpensBody": "{0} — the registration window has opened.",
  "notifs.actionOpenSignMeUp": "Sign up now",
  "notifs.lastLectureTitle": "Last lecture — schedule says",
  "notifs.lastLectureBody":
      "The schedule says {0} on {1} at {2} is your last lecture of the "
      "semester.",
  "notifs.digestLastLecture": "Last lecture (schedule says): {0} at {1}",
  // R34.1 FRISTENBUCH: Fristenbuch-only day wording (see de_notifs)
  "notifs.digestTitleFrb": "Today: deadline",
  "notifs.bannerBotProtection":
      "KIT changed its bot protection — data retrieval is disrupted until further notice. An update is needed.",
  "notifs.bannerBoth": "Could not read exams & timetable (KIT site changed?).",
  "notifs.bannerExams": "Could not read the exam list (KIT site changed?).",
  "notifs.bannerTimetable":
      "Could not update the timetable (KIT site changed?).",
  "notifs.bannerOffline":
      "Can't reach KIT right now — check the connection, the data may be stale.",
  // ---- ilias.* — see de_notifs note ----
  "ilias.notifyFallbackTitle": "ILIAS",
};
