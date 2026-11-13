// ignore_for_file: constant_identifier_names

const Map<String, String> de_settings = {
  // settings page
  "settings.title": "Einstellungen",
  "settings.sectionHomepage": "Homepage",
  // R35.3: showProfile/showAvgGrade deleted with their prefs; the
  // one-release revert switch took their seat (temporary key - remove
  // it together with PREF_legacyHome next wave).
  "settings.legacyHome": "Alte Startseite anzeigen",
  // R36.2: the one gate for the merged campus-now strip (reuses the old
  // "…-Bereich" wording of the two deleted section toggles)
  "settings.campusNow": "Campus-jetzt-Bereich",
  "settings.iliasStartPage": "Startseite",
  "settings.iliasPageDashboard": "Dashboard",
  "settings.iliasPageCourses": "Meine Kurse & Gruppen",
  "settings.sectionOwnTimetable": "Eigener Stundenplan (ICS)",
  "settings.ownIcsNone": "Kein eigener Kalender importiert",
  "settings.ownIcsLoaded": "{0} Kurse aus eigenem Kalender importiert",
  "settings.ownIcsUrlHint": "Link zu deiner .ics-Datei (optional)",
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
  "settings.sectionSupport": "Support",
  "settings.shareBundle": "Support-Infos teilen",
  // R29 (X4): visible state of the silent opt-ins
  "settings.sectionSetup": "Einrichtung",
  "settings.setupPersonalIcs": "Persönlicher Kalender",
  "settings.setupAnny": "Bibliothek (Anny)",
  // R34.1: manually noted deadlines (fristenbuch_page.dart)
  "settings.setupFristenbuch": "Fristenbuch",
  "settings.setupOn": "aktiv",
  "settings.setupOff": "nicht eingerichtet",
  // R29 (X3): storage manifest - claims verified against manifest,
  // logout sweep and secure storage
  "settings.sectionStorage": "Daten auf diesem Gerät",
  "settings.storageIntro":
      "Diese App hat keine eigenen Server. Alles Folgende liegt nur auf "
      "diesem Gerät:",
  "settings.storageCreds":
      "Zugangsdaten – systemsicher Speicher (Keychain/Keystore)",
  "settings.storageCache":
      "Geladene Inhalte: Stundenplan, Noten, Prüfungen, ILIAS, Mensa, "
      "Karten",
  "settings.storagePrefs": "Ansichts- und Karteneinstellungen",
  "settings.storageBundle":
      "Anonymisierte Fehlerprotokolle (für den Support-Export)",
  "settings.storageOutro":
      "Kein Cloud-Backup, keine Telemetrie. Beim Ausloggen werden alle "
      "personenbezogenen Daten gelöscht.",
  // R34.6 + R34.2 + R34.3: Bureaucracy section — document expiry watch,
  // starter pack, Papierkram launcher. Every wording is deliberately
  // advisory; the document card NEVER promises a reminder.
  "settings.sectionBureaucracy": "Bürokratie",
  "settings.docsTitle": "Dokumente",
  "settings.docsIntro":
      "Ablaufdaten, die du selbst notierst (Reisepass, Aufenthaltstitel, Versicherung). Diese App erinnert dich nicht aktiv daran – die Liste zeigt nur, was bald abläuft.",
  "settings.docsEmpty": "Noch keine Frist notiert",
  "settings.docsAdd": "Dokument hinzufügen…",
  "settings.docsAddTitle": "Neues Dokument",
  "settings.docsLabelHint": "z. B. Reisepass, Aufenthaltstitel",
  "settings.docsExpiry": "Ablaufdatum",
  "settings.docsPickDate": "Datum wählen…",
  "settings.docsSave": "Hinzufügen",
  "settings.docsNeedLabel": "Bitte zuerst einen Namen eintragen",
  "settings.docsNeedDate": "Bitte zuerst ein Ablaufdatum wählen",
  "settings.docsSaved": "Dokument gespeichert",
  "settings.docsDeleted": "Dokument entfernt",
  "settings.docsLoadFailed": "Liste konnte nicht geladen werden",
  "settings.docsDueToday": "läuft heute ab",
  "settings.docsDueTomorrow": "läuft morgen ab",
  "settings.docsExpiresIn": "läuft ab in {0} Tagen",
  "settings.docsExpiredFor": "seit {0} Tagen abgelaufen",
  "settings.docsExpiresOn": "läuft ab am {0}",
  "settings.docsDelete": "Entfernen",
  "settings.starterTitle": "Erste Schritte: Bürokratie",
  "settings.starterIntro":
      "Offizielle Seiten für den Start in Karlsruhe. Angaben ohne Gewähr – bitte die verlinkte Seite selbst prüfen; „stand“ zeigt, wann wir die Angaben zuletzt kontrolliert haben.",
  "settings.starterStand": "stand: {0}",
  "settings.papierkramTitle": "Papierkram",
  "settings.papierkramIntro":
      "Offizielle KIT- und Karlsruhe-Seiten direkt aufrufen. Die App öffnet nur den Browser – die Inhalte kommen unverändert von der jeweiligen Seite.",
  "settings.copyMatr": "Matrikelnummer kopieren",
  "settings.matrCopied": "Matrikelnummer kopiert",
  "settings.logout": "Ausloggen",
  "settings.loggedOut": "Ausgeloggt, alle Daten gelöscht",
  "settings.logoutFailed": "Ausloggen fehlgeschlagen – bitte erneut versuchen",
  "settings.loggedOutPartial":
      "Ausgeloggt – einige Daten konnten nicht vollständig gelöscht werden (erneut versuchen)",
  "settings.ownIcsErrorClear": "Kalender konnte nicht entfernt werden",
  "settings.cancel": "Abbrechen",
  "settings.logoutConfirmTitle": "Ausloggen?",
  "settings.logoutConfirmBody":
      "Alle lokal gespeicherten Daten und Dateien werden von diesem Gerät gelöscht. Du kannst dich jederzeit wieder einloggen.",
  // module-tree diagnostic (settings > Debug)
  "settings.debugFetch": "Modul-Baum (Debug)",
  "settings.debugFetchHint":
      "Zeigt jeden Modul-Eintrag des CampusKIT-Baums: Level, Treffer auf dem Stundenplan, geladene Seite. Lange drücken kopiert den Titel.",
  "settings.debugTreeCopyHint":
      "Lange auf einen Titel drücken, um ihn zu kopieren.",
  "settings.debugTreeCopied": "„{0}“ kopiert",
  "settings.debugTreeNoPage": "(noch keine Seite geladen)",
  "settings.debugTreeEmpty":
      "Noch kein Modul-Baum gelaufen – auf der Startseite ziehen",
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
  "settings.welcomeKarlsruhe": "Willkommen in Karlsruhe",
  "settings.usernamePlaceholder": "Benutzername (uxxxx)",
  "settings.password": "Passwort",
  "settings.login": "Einloggen",
  // profile view
  "settings.degreeProgram": "Studiengang",
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
      "Wie kann ich mir sicher sein, dass meine Daten nicht gestohlen werden?",
  "settings.faqSecurityBody":
      "Alles wird nur auf deinem Gerät verarbeitet, als würdest du das Campus-Portal in deinem Web-Browser benutzen. Die App ist auch open-source. Das heißt, du kannst dir den Code anschauen, um sicherzustellen, dass alles in Ordnung ist. Du kannst auch das Repo klonen und deine eigene Version benutzen.",
  "settings.faqContributeTitle": "Kann ich zur Entwicklung beitragen?",
  "settings.faqContributeBody":
      "Ja! Wir würden uns darüber sehr freuen! Wenn du dich mit Flutter auskennst und beitragen möchtest, kontaktiere uns per Telegram: @XtremeUserInterfaces.",
  "settings.faqRoadmapTitle": "Wie geht es weiter?",
  "settings.faqRoadmapBody":
      "Viele Features sind geplant, wie z.B. ILIAS, Benachrichtigungen über Änderungen und noch mehr! Daran arbeiten wir jetzt. Wenn du Ideen hast, welche Features es noch in der App geben soll und/oder wie wir die App noch verbessern könnten, dann schreibe uns gerne!",
};

const Map<String, String> en_settings = {
  // settings page
  "settings.title": "Settings",
  "settings.sectionHomepage": "Home",
  // R35.3 mirror of the de block (temporary one-release switch key)
  "settings.legacyHome": "Show previous home layout",
  "settings.campusNow": "Campus now section",
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
  "settings.sectionSupport": "Support",
  "settings.shareBundle": "Share support info",
  // R29 (X4): visible state of the silent opt-ins
  "settings.sectionSetup": "Setup",
  "settings.setupPersonalIcs": "Personal calendar",
  "settings.setupAnny": "Library (Anny)",
  // R34.1: manually noted deadlines (fristenbuch_page.dart)
  "settings.setupFristenbuch": "Deadline notes",
  "settings.setupOn": "active",
  "settings.setupOff": "not set up",
  // R29 (X3): storage manifest - claims verified against manifest,
  // logout sweep and secure storage
  "settings.sectionStorage": "Data on this device",
  "settings.storageIntro":
      "This app has no servers of its own. All of the following lives "
      "only on this device:",
  "settings.storageCreds":
      "Credentials – system secure storage (Keychain/Keystore)",
  "settings.storageCache":
      "Loaded content: timetable, grades, exams, ILIAS, mensa, maps",
  "settings.storagePrefs": "View and map preferences",
  "settings.storageBundle":
      "Anonymized error logs (for the support export)",
  "settings.storageOutro":
      "No cloud backup, no telemetry. Logging out deletes all personal "
      "data.",
  // R34.6 + R34.2 + R34.3 mirror — keep key-set equal with de_settings
  // (test/l10n_parity_test.dart guards the full table).
  "settings.sectionBureaucracy": "Bureaucracy",
  "settings.docsTitle": "Documents",
  "settings.docsIntro":
      "Expiry dates you note yourself (passport, residence permit, insurance). This app never pings you about them – the list only shows what is about to expire.",
  "settings.docsEmpty": "No deadlines noted yet",
  "settings.docsAdd": "Add document…",
  "settings.docsAddTitle": "New document",
  "settings.docsLabelHint": "e.g. passport, residence permit",
  "settings.docsExpiry": "Expiry date",
  "settings.docsPickDate": "Choose date…",
  "settings.docsSave": "Add",
  "settings.docsNeedLabel": "Enter a name first",
  "settings.docsNeedDate": "Pick an expiry date first",
  "settings.docsSaved": "Document saved",
  "settings.docsDeleted": "Document removed",
  "settings.docsLoadFailed": "Could not load the list",
  "settings.docsDueToday": "expires today",
  "settings.docsDueTomorrow": "expires tomorrow",
  "settings.docsExpiresIn": "expires in {0} days",
  "settings.docsExpiredFor": "expired {0} days ago",
  "settings.docsExpiresOn": "expires on {0}",
  "settings.docsDelete": "Remove",
  "settings.starterTitle": "First steps: paperwork",
  "settings.starterIntro":
      "Official pages for your start in Karlsruhe. No guarantees – always check the linked page yourself; “stand” shows when we last verified the entries.",
  "settings.starterStand": "as of: {0}",
  "settings.papierkramTitle": "Paperwork",
  "settings.papierkramIntro":
      "Open official KIT and Karlsruhe pages directly. The app only launches the browser – the content comes unchanged from each page.",
  "settings.copyMatr": "Copy matriculation number",
  "settings.matrCopied": "Matriculation number copied",
  "settings.logout": "Log out",
  "settings.loggedOut": "Logged out, all data deleted",
  "settings.logoutFailed": "Logout failed - please try again",
  "settings.cancel": "Cancel",
  "settings.logoutConfirmTitle": "Log out?",
  "settings.loggedOutPartial":
      "Signed out - some data could not be erased fully (try again)",
  "settings.ownIcsErrorClear": "Could not remove own calendar",
  "settings.logoutConfirmBody":
      "All locally stored data and files will be deleted from this device. You can log in again at any time.",
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
  "settings.usernamePlaceholder": "Username (uxxxx)",
  "settings.password": "Password",
  "settings.login": "Log in",
  // profile view
  "settings.degreeProgram": "Degree program",
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
