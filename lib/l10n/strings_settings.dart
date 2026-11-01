// ignore_for_file: constant_identifier_names

const Map<String, String> de_settings = {
  // settings page
  "settings.title": "Einstellungen",
  "settings.sectionHomepage": "Homepage",
  "settings.showProfile": "Profil anzeigen",
  "settings.showAvgGrade": "Durchschnittsnote anzeigen",
  "settings.iliasStartPage": "Startseite",
  "settings.iliasPageDashboard": "Dashboard",
  "settings.iliasPageCourses": "Meine Kurse & Gruppen",
  "settings.sectionOwnTimetable": "Eigener Stundenplan (ICS)",
  "settings.ownIcsNone": "Kein eigener Kalender importiert",
  "settings.ownIcsLoaded": "{0} Kurse aus eigenem Kalender importiert",
  "settings.ownIcsUrlHint": "Link zu Ihrer .ics-Datei (optional)",
  "settings.ownIcsSave": "Link speichern",
  "settings.ownIcsFile": "Datei importieren…",
  "settings.ownIcsClear": "Entfernen",
  "settings.ownIcsSaved": "Stundenplan importiert",
  "settings.ownIcsCleared": "Eigener Kalender entfernt",
  "settings.ownIcsErrorBad":
      "Keine gültige ICS-Kalenderdatei mit Veranstaltungen.",
  "settings.ownIcsErrorFetch": "Der Link konnte nicht geladen werden.",
  "settings.sectionFileCache": "Dateicache",
  "settings.cacheSize": "Größe",
  "settings.manage": "Verwalten",
  "settings.logout": "Ausloggen",
  "settings.loggedOut": "Ausgeloggt, alle Daten gelöscht",
  "settings.logoutFailed": "Ausloggen fehlgeschlagen – bitte erneut versuchen",
  // module-tree diagnostic (settings > Debug)
  "settings.debugFetch": "Modul-Baum (Debug)",
  "settings.debugFetchHint":
      "Zeigt jeden Modul-Eintrag des CampusKIT-Baums: Level, Treffer auf dem Stundenplan, geladene Seite. Lange drücken kopiert den Titel.",
  "settings.debugTreeCopyHint": "Lange auf einen Titel drücken, um ihn zu kopieren.",
  "settings.debugTreeCopied": "„{0}“ kopiert",
  "settings.debugTreeNoPage": "(noch keine Seite geladen)",
  "settings.debugTreeEmpty": "Noch kein Modul-Baum gelaufen – auf der Startseite ziehen",
  "settings.debugTreeShown": "auf der Karte",
  "settings.debugTreeFeedMiss": "nicht auf dem Stundenplan",
  "settings.debugTreeClash": "Dublette - schon auf der Karte",
  "settings.debugTreeGhost": "Platzhalter - geladene Karte vorhanden",
  "settings.debugTreeUnexplained": "noch nicht aufgenommen",
  "settings.debugTreeNoModule": "(kein Modul)",
  // manual ILIAS link (module page)
  "settings.moduleAttachIlias": "ILIAS verknüpfen",
  "settings.moduleAttachIliasHint":
      "URL der ILIAS-Seite (ilias.studium.kit.edu)",
  "settings.moduleAttachIliasSaved": "ILIAS-Link verknüpft",
  "settings.moduleAttachIliasInvalid":
      "Es können nur https-Links zu ilias.studium.kit.edu verknüpft werden",
  // login view
  "settings.hello": "Hallo",
  "settings.helloName": "Hallo, {0}",
  "settings.welcomeKarlsruhe": "Wilkommen in Karlsruhe",
  "settings.password": "Passwort",
  "settings.login": "Einloggen",
  // profile view
  "settings.degreeProgram": "Studiengang",
  "settings.creditPoints": "Leistungspunkte",
  "settings.avgGrade": "Note (⌀)",
  "settings.creditsShort": "LP",
  // home page
  "settings.editTimetable": "Stundenplan bearbeiten",
  "settings.currentModulesIn": "Aktuelle Module im {0}",
  "settings.reloadingModules": "Module werden neu geladen...",
  "settings.pinnedFiles": "Angeheftete Dateien",
  "settings.viewAll": "Alle ansehen",
  "settings.myModules": "Meine Module",
  // info page
  "settings.aboutIntro":
      "Wir sind sehr froh, dass du dich für diese App interessiert! Von Studenten für Studenten: Diese App dient dazu, dein Studentenleben am KIT freundlicher und einfacher zu machen. ",
  "settings.faqSecurityTitle":
      "Wie kann ich mir sicher sein, dass meine Daten nicht gestolen werden?",
  "settings.faqSecurityBody":
      "Alles wird nur auf deinem Gerät verarbeitet, als würdest du das Campus-Portal in deinem Web-Browser benutzen. Die App ist auch open-source. Das heißt, du kannst dir den Code anschauen, um sicherzustellen, dass alles in Ordnung ist. Du kannst auch das Repo klonen und deine eigene Version benutzen.",
  "settings.faqContributeTitle": "Kann ich zur Entwicklung beitragen?",
  "settings.faqContributeBody":
      "Ja! Wir würden uns darüber sehr freuen! Wenn du dich mit Flutter auskennst und beitragen möchtest, kontaktiere uns per Telegram: @XtremeUserInterfaces.",
  "settings.faqRoadmapTitle": "Wie geht es weiter?",
  "settings.faqRoadmapBody":
      "Viele Features sind geplannt, wie z.B. ILIAS, Benachrichtigungen über Änderungen und noch mehr! Daran arbeiten wir jetzt. Wenn du Ideen hast, welche Features es noch in der App geben soll und/oder wie wir die App noch verbessern könnten, dann schreibe uns gerne!",
};

const Map<String, String> en_settings = {
  // settings page
  "settings.title": "Settings",
  "settings.sectionHomepage": "Home",
  "settings.showProfile": "Show profile",
  "settings.showAvgGrade": "Show average grade",
  "settings.iliasStartPage": "Start page",
  "settings.iliasPageDashboard": "Dashboard",
  "settings.iliasPageCourses": "My Courses & Groups",
  "settings.sectionOwnTimetable": "Own timetable (ICS)",
  "settings.ownIcsNone": "No own calendar imported",
  "settings.ownIcsLoaded": "{0} courses imported from own calendar",
  "settings.ownIcsUrlHint": "Link to your .ics file (optional)",
  "settings.ownIcsSave": "Save link",
  "settings.ownIcsFile": "Import file…",
  "settings.ownIcsClear": "Remove",
  "settings.ownIcsSaved": "Timetable imported",
  "settings.ownIcsCleared": "Own calendar removed",
  "settings.ownIcsErrorBad": "Not a valid ICS calendar with events.",
  "settings.ownIcsErrorFetch": "Could not download that link.",
  "settings.sectionFileCache": "File cache",
  "settings.cacheSize": "Size",
  "settings.manage": "Manage",
  "settings.logout": "Log out",
  "settings.loggedOut": "Logged out, all data deleted",
  "settings.logoutFailed": "Logout failed - please try again",
  // module-tree diagnostic (settings > Debug)
  "settings.debugFetch": "Module tree (debug)",
  "settings.debugFetchHint":
      "Every module entry of the CampusKIT tree: level, timetable hit, loaded page. Long-press to copy a title.",
  "settings.debugTreeCopyHint": "Long-press a title to copy it.",
  "settings.debugTreeCopied": "Copied “{0}”",
  "settings.debugTreeNoPage": "(no page yet)",
  "settings.debugTreeEmpty": "No module tree yet - pull down on the home page",
  "settings.debugTreeShown": "on the card",
  "settings.debugTreeFeedMiss": "not on the timetable",
  "settings.debugTreeClash": "duplicate - already on card",
  "settings.debugTreeGhost": "placeholder - fetched card exists",
  "settings.debugTreeUnexplained": "not admitted yet",
  "settings.debugTreeNoModule": "(not a module)",
  // manual ILIAS link (module page)
  "settings.moduleAttachIlias": "Link ILIAS",
  "settings.moduleAttachIliasHint":
      "URL of the ILIAS page (ilias.studium.kit.edu)",
  "settings.moduleAttachIliasSaved": "ILIAS link attached",
  "settings.moduleAttachIliasInvalid":
      "Only https links to ilias.studium.kit.edu can be attached",
  // login view
  "settings.hello": "Hello",
  "settings.helloName": "Hello, {0}",
  "settings.welcomeKarlsruhe": "Welcome to Karlsruhe",
  "settings.password": "Password",
  "settings.login": "Log in",
  // profile view
  "settings.degreeProgram": "Degree program",
  "settings.creditPoints": "Credits",
  "settings.avgGrade": "Grade (avg)",
  "settings.creditsShort": "CP",
  // home page
  "settings.editTimetable": "Edit timetable",
  "settings.currentModulesIn": "Current modules in {0}",
  "settings.reloadingModules": "Reloading modules…",
  "settings.pinnedFiles": "Pinned files",
  "settings.viewAll": "View all",
  "settings.myModules": "My modules",
  // info page
  "settings.aboutIntro":
      "We are very glad that you are interested in this app! From students for students: this app aims to make your student life at KIT friendlier and easier. ",
  "settings.faqSecurityTitle":
      "How can I be sure that my data won't be stolen?",
  "settings.faqSecurityBody":
      "Everything is processed only on your device, just as if you were using the campus portal in your web browser. The app is also open-source, so you can look at the code to make sure everything is fine. You can also clone the repo and run your own version.",
  "settings.faqContributeTitle": "Can I contribute to development?",
  "settings.faqContributeBody":
      "Yes, we would love that! If you know Flutter and would like to contribute, contact us on Telegram: @XtremeUserInterfaces.",
  "settings.faqRoadmapTitle": "What's next?",
  "settings.faqRoadmapBody":
      "Many features are planned, e.g. ILIAS, notifications about changes and much more! That is what we are working on now. If you have ideas for new features or ways to improve the app, feel free to write to us!",
};
