// ignore_for_file: constant_identifier_names
/// L10n keys for the exam-registration area (lib/exams/).
const Map<String, String> de_exams = {
  "exams.title": "Prüfungsanmeldung",
  "exams.loadError": "Prüfungsliste konnte nicht geladen werden.\n"
      "(Session abgelaufen oder Seite geändert.)",
  "exams.retry": "Erneut versuchen",
  "exams.empty": "Keine Prüfungen gefunden.\n(Zieht beim nächsten Start neu.)",
  "exams.sectionActNow": "Jetzt handeln",
  "exams.sectionOpensSoon": "Fenster öffnet bald",
  "exams.sectionRegistered": "Angemeldet",
  "exams.sectionOther": "Sonstige",
  "exams.sectionCatalog": "Nur im Prüfungsangebot · nicht belegt",
  "exams.detailExamTerm": "Prüfung: {0} {1}{2}",
  "exams.detailWindow": "Anmeldung: {0} – {1}",
  "exams.detailDeadline": "Anmelden bis: {0}",
  "exams.detailExaminers": "Prüfer: {0}",
  "exams.chipRegistered": "angemeldet",
  // R29: countdown card + exam-clash warner
  "exams.countdownTitle": "Countdown",
  // R31 D1: "If you register" tier sub-line: "<prefix> · <registerBy> <date>"
  "exams.countdownIfRegister": "Bei Anmeldung",
  "exams.countdownRegisterBy": "Anmelden bis",
  "exams.clashOverlapTitle": "Zeitgleiche Prüfungen",
  "exams.clashSameDayTitle": "Prüfungen am selben Tag",
  "exams.clashLine": "{0} + {1} · {2}",
  "exams.clashUnknown":
      "{0} Prüfungen ohne Uhrzeit – Überschneidung nicht prüfbar",
  "exams.chipNotRegisteredNow": "NICHT angemeldet",
  "exams.chipNotRegistered": "nicht angemeldet",
  // R32.4: seats-filled sub-line ("13/20 belegt · First Come First Served")
  // on exam cards and the SignMeUp "mine" card
  "exams.seatsFilled": "{0}/{1} belegt",
  // R32.3: muted deregistration-deadline chip on registered exam cards
  "exams.chipDeregUntil": "abmelden bis {0}",
};

const Map<String, String> en_exams = {
  "exams.title": "Exam Registration",
  "exams.loadError": "Could not load the exam list.\n"
      "(Session expired or the page has changed.)",
  "exams.retry": "Try again",
  "exams.empty": "No exams found.\n(It re-syncs on next start.)",
  "exams.sectionActNow": "Act now",
  "exams.sectionOpensSoon": "Registration opens soon",
  "exams.sectionRegistered": "Registered",
  "exams.sectionOther": "Other",
  "exams.sectionCatalog": "Offered, but not taken this semester",
  "exams.detailExamTerm": "Exam: {0} {1}{2}",
  "exams.detailWindow": "Registration: {0} – {1}",
  "exams.detailDeadline": "Register by: {0}",
  "exams.detailExaminers": "Examiner: {0}",
  "exams.chipRegistered": "registered",
  // R29: countdown card + exam-clash warner
  "exams.countdownTitle": "Countdown",
  // R31 D1: "If you register" tier sub-line: "<prefix> · <registerBy> <date>"
  "exams.countdownIfRegister": "If you register",
  "exams.countdownRegisterBy": "Register by",
  "exams.clashOverlapTitle": "Overlapping exams",
  "exams.clashSameDayTitle": "Exams on the same day",
  "exams.clashLine": "{0} + {1} · {2}",
  "exams.clashUnknown":
      "{0} exams without a time – overlap cannot be checked",
  "exams.chipNotRegisteredNow": "NOT registered",
  "exams.chipNotRegistered": "not registered",
  // R32.4: seats-filled sub-line ("13/20 seats taken · First Come First
  // Served") on exam cards and the SignMeUp "mine" card
  "exams.seatsFilled": "{0}/{1} seats taken",
  // R32.3: muted deregistration-deadline chip on registered exam cards
  "exams.chipDeregUntil": "unregister until {0}",
};
