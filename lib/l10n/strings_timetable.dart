// ignore_for_file: constant_identifier_names

const Map<String, String> de_timetable = {
  "timetable.editTitle": "Stundenplan anpassen",
  "timetable.tutorials": "Tutorien",
  "timetable.tutorialsDescription":
      "Verknüpfe Tutorien mit deinen Modulen und lege deren Zeitfenster fest. Die Zeiten entsprechen den regulären Campus-Blöcken.",
  "timetable.noTutorials":
      "Noch keine Tutorien gespeichert. Nutze den Plus-Button, um das erste Tutorium zu erstellen.",
  "timetable.addAppointmentsHint":
      "Füge Termine zum Stundenplan hinzu, indem du auf das Stern-Icon klickst.",
  "timetable.addTutorial": "Tutorium hinzufügen",
  "timetable.editTutorial": "Tutorium bearbeiten",
  "timetable.selectModule": "Modul auswählen",
  "timetable.weekdayLabel": "Wochentag",
  "timetable.timeBlock": "Zeitblock",
  "timetable.cancel": "Abbrechen",
  "timetable.save": "Speichern",
  "timetable.deleteTutorial": "Tutorium löschen",
  "timetable.deleteTutorialConfirm":
      "Möchtest du das Tutorium für \"{0}\" wirklich entfernen?",
  "timetable.delete": "Löschen",
  "timetable.noModulesTitle": "Keine Module verfügbar",
  "timetable.noModulesBody":
      "Aktuell sind noch keine Module im Cache. Öffne ein Modul in der App, damit es für die Tutorien verwendet werden kann.",
  "timetable.monday": "Montag",
  "timetable.tuesday": "Dienstag",
  "timetable.wednesday": "Mittwoch",
  "timetable.thursday": "Donnerstag",
  "timetable.friday": "Freitag",
  "timetable.saturday": "Samstag",
  "timetable.sunday": "Sonntag",
  "timetable.tutorialPrefix": "Tutorium: {0}",
  "timetable.tutorial": "Tutorium",
  "timetable.dayMonth": "{0}. {1}",
  "timetable.yesterdayFull": "Gestern, {0}",
  "timetable.month1": "Januar",
  "timetable.month2": "Februar",
  "timetable.month3": "März",
  "timetable.month4": "April",
  "timetable.month5": "Mai",
  "timetable.month6": "Juni",
  "timetable.month7": "Juli",
  "timetable.month8": "August",
  "timetable.month9": "September",
  "timetable.month10": "Oktober",
  "timetable.month11": "November",
  "timetable.month12": "Dezember",
  "timetable.weekend": "Wochenende :)",
  "timetable.changeAdded": "Neu: {0} · {1}{2}",
  "timetable.changeRemoved": "Entfällt: {0} · {1}",
  "timetable.changeMoved": "Verschoben: {0} · {1} → {2}{3}",
  "timetable.changeChanged": "Geändert: {0} · {1}{2}",
  "timetable.changeRoomDelta": " · Raum {0} → {1}",
  // R32.7 CHRONICLE ("letzte Änderungen" page) + its agenda band entry;
  // R32.6 hero line needs no string (struck room → new room, rooms are
  // identifiers and the arrow is punctuation)
  "timetable.chronicleTitle": "Letzte Änderungen",
  "timetable.chronicleCoverage":
      "Änderungen, die die App beim Abfragen selbst sah",
  "timetable.chronicleCap":
      "{0} / max. {1} gespeichert · ältester Eintrag: {2}",
  "timetable.chronicleEmpty": "Noch keine Änderungen gespeichert.",
  // R34.1 FRISTENBUCH ("Fristenbuch" page, settings > Einrichtung): the
  // coverage header's honesty is load-bearing — these rows are the
  // student's own notes, never scraped truth, and the header says so.
  "timetable.frbTitle": "Fristenbuch",
  "timetable.frbCoverage":
      "Termine, die du selbst notierst – Fristen ohne KIT-Quelle, die die "
      "App nicht kennen kann (Formulare, Wohnung, Anmeldungen außerhalb von "
      "SignMeUp). Sie laufen wie alle anderen Fristen durch Agenda, "
      "Cockpit, Morgengruß und Erinnerungen – geprüft wird nichts: das hier "
      "ist deine eigene Notiz, nicht die Wahrheit des Servers.",
  "timetable.frbEmpty": "Noch keine Fristen notiert.",
  "timetable.frbAdd": "Frist hinzufügen",
  "timetable.frbNew": "Neue Frist",
  "timetable.frbLabelHint": "Was ist zu tun? (z. B. Wohnungs-Zusage annehmen)",
  "timetable.frbDate": "Fällig am",
  "timetable.frbNoteHint": "Notiz (optional)",
  "timetable.frbYou": "selbst notiert",
  "timetable.frbDelete": "Frist löschen",
  "timetable.frbSave": "Hinzufügen",
  // cockpit row label for CockpitKind.frb (agenda cockpit card)
  "agenda.cockpitFrist": "Frist",
  "timetable.olderChanges": "Ältere Änderungen",
  // appointment detail sheet; home.profileLoading rides the flat l10n
  // map from here because slice rules confine new strings to this file
  "timetable.idLabel": "ID:",
  "timetable.placeLabel": "Ort:",
  "timetable.timeLabel": "Zeit:",
  "timetable.aliasesLabel": "Auch bekannt als:",
  "timetable.openCampusMap": "Auf dem Campusplan öffnen",
  "timetable.directions": "Route",
  "timetable.collapseDetails": "Details ausblenden",
  "timetable.expandDetails": "Details anzeigen",
  // round 12: daily-view now line, ghost cards, free-gap + room-varies
  // chips, course-page link
  "timetable.nowLineLabel": "Aktuelle Zeit: {0}",
  "timetable.ghostCancelled": "Entfällt",
  "timetable.freeGap": "Frei · {0}",
  "timetable.dayFree": "Freier Tag",
  "timetable.mittagspause": "Mittagspause",
  "timetable.lectureFree": "Vorlesungsfreie Zeit",
  "timetable.roomVaries": "Raum wchs.",
  "timetable.openCoursePage": "Kursseite öffnen",
  // R33.5 SOP early-warning cockpit row. The wording is load-bearing:
  // "mindestens" stays because imported/catalogue-unknown CP can exceed
  // the ledger×handbook product, and the exposure clause is hedged
  // ("laut Prüfungsledger") because the app only ever counts RECORDED
  // fails - the PO claim is conditional on the next sitting.
  "agenda.sopWarnTitle": "SOP: dritter Versuch = endgültig nicht bestanden",
  "agenda.sopWarnCp": "Mindestens {0} LP errungen",
  "agenda.sopWarnExposed":
      "Nach PO endgültig nicht bestanden im dritten Versuch — laut Prüfungsledger: {0}",
  // R34.5 "Nächste 90 Tage"-Karte. Die Fristenbuch-Zeile sagt ausdrücklich
  // "selbst notiert": ein manuell eingetragener Termin ist niemals
  // GeScraper-te Wahrheit, und die Karte darf ihn nicht als solche
  // ausgeben. Die Semesterzeilen tragen pro Zeile den Quellen-Hinweis
  // "(SignMeUp terms)" — die only-Zitierung, woher Start/Ende kommen.
  "agenda.ninetyTitle": "Nächste 90 Tage",
  "agenda.ninetyFrb": "Selbst notiert",
  "agenda.ninetyTermStart": "Semesterbeginn",
  "agenda.ninetyTermEnd": "Semesterende",
  "agenda.ninetySrcTerms": "(SignMeUp terms)",
};

const Map<String, String> en_timetable = {
  "timetable.editTitle": "Adjust timetable",
  "timetable.tutorials": "Tutorials",
  "timetable.tutorialsDescription":
      "Link tutorials to your modules and set their time slots. Times match the regular campus blocks.",
  "timetable.noTutorials":
      "No tutorials saved yet. Use the plus button to create your first tutorial.",
  "timetable.addAppointmentsHint":
      "Add appointments to your timetable by tapping the star icon.",
  "timetable.addTutorial": "Add tutorial",
  "timetable.editTutorial": "Edit tutorial",
  "timetable.selectModule": "Select module",
  "timetable.weekdayLabel": "Day of week",
  "timetable.timeBlock": "Time slot",
  "timetable.cancel": "Cancel",
  "timetable.save": "Save",
  "timetable.deleteTutorial": "Delete tutorial",
  "timetable.deleteTutorialConfirm": "Really remove the tutorial for \"{0}\"?",
  "timetable.delete": "Delete",
  "timetable.noModulesTitle": "No modules available",
  "timetable.noModulesBody":
      "No modules are cached yet. Open a module in the app so it can be used for tutorials.",
  "timetable.monday": "Monday",
  "timetable.tuesday": "Tuesday",
  "timetable.wednesday": "Wednesday",
  "timetable.thursday": "Thursday",
  "timetable.friday": "Friday",
  "timetable.saturday": "Saturday",
  "timetable.sunday": "Sunday",
  "timetable.tutorialPrefix": "Tutorial: {0}",
  "timetable.tutorial": "Tutorial",
  "timetable.dayMonth": "{1} {0}",
  "timetable.yesterdayFull": "Yesterday, {0}",
  "timetable.month1": "January",
  "timetable.month2": "February",
  "timetable.month3": "March",
  "timetable.month4": "April",
  "timetable.month5": "May",
  "timetable.month6": "June",
  "timetable.month7": "July",
  "timetable.month8": "August",
  "timetable.month9": "September",
  "timetable.month10": "October",
  "timetable.month11": "November",
  "timetable.month12": "December",
  "timetable.weekend": "Weekend :)",
  "timetable.changeAdded": "New: {0} · {1}{2}",
  "timetable.changeRemoved": "Cancelled: {0} · {1}",
  "timetable.changeMoved": "Moved: {0} · {1} → {2}{3}",
  "timetable.changeChanged": "Changed: {0} · {1}{2}",
  "timetable.changeRoomDelta": " · Room {0} → {1}",
  // R32.7 CHRONICLE + agenda band entry (see de_timetable)
  "timetable.chronicleTitle": "Recent changes",
  "timetable.chronicleCoverage":
      "Changes the app itself saw while polling",
  "timetable.chronicleCap": "{0} / max {1} stored · oldest entry: {2}",
  "timetable.chronicleEmpty": "No changes stored yet.",
  // R34.1 FRISTENBUCH (see de_timetable)
  "timetable.frbTitle": "Deadline notes",
  "timetable.frbCoverage":
      "Dates you noted yourself – deadlines with no KIT source the app "
      "could scrape (authorities forms, housing, registrations outside "
      "SignMeUp). They flow through the same pipeline as every other "
      "deadline: agenda, cockpit, morning digest and reminders – nothing "
      "is verified: this is your own note, not the server's truth.",
  "timetable.frbEmpty": "No deadlines noted yet.",
  "timetable.frbAdd": "Add deadline",
  "timetable.frbNew": "New deadline",
  "timetable.frbLabelHint": "What is due? (e.g. accept housing offer)",
  "timetable.frbDate": "Due",
  "timetable.frbNoteHint": "Note (optional)",
  "timetable.frbYou": "noted by me",
  "timetable.frbDelete": "Delete deadline",
  "timetable.frbSave": "Add",
  "agenda.cockpitFrist": "Deadline",
  "timetable.olderChanges": "Older changes",
  "timetable.timeLabel": "Time:",
  "timetable.aliasesLabel": "Also known as:",
  "timetable.openCampusMap": "Open in campus map",
  "timetable.directions": "Directions",
  "timetable.collapseDetails": "Hide details",
  "timetable.expandDetails": "Show details",
  "timetable.idLabel": "ID:",
  "timetable.placeLabel": "Room:",
  // round 12: see de_timetable
  "timetable.nowLineLabel": "Current time: {0}",
  "timetable.ghostCancelled": "Cancelled",
  "timetable.freeGap": "Free · {0}",
  "timetable.dayFree": "No lectures",
  "timetable.mittagspause": "Lunch break",
  "timetable.lectureFree": "No lectures this week",
  "timetable.roomVaries": "Room varies",
  "timetable.openCoursePage": "Open course page",
  // R33.5 SOP early-warning cockpit row; mirrors the de hedge wording
  // ("at least", "per the grades ledger") - see de_timetable for why both
  // are mandatory.
  "agenda.sopWarnTitle": "SOP: a third fail ends the module for good",
  "agenda.sopWarnCp": "At least {0} CP earned",
  "agenda.sopWarnExposed":
      "Under the exam regulations a third fail is final — per the grades ledger: {0}",
  // R34.5 "Next 90 days" card; mirrors de_timetable — the self-noted
  // provenance and the per-row "(SignMeUp terms)" citation are mandatory
  // in BOTH languages.
  "agenda.ninetyTitle": "Next 90 days",
  "agenda.ninetyFrb": "Self-noted",
  "agenda.ninetyTermStart": "Term starts",
  "agenda.ninetyTermEnd": "Term ends",
  "agenda.ninetySrcTerms": "(SignMeUp terms)",
};
