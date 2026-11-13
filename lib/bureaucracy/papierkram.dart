/// R34.3 — the "Papierkram" launcher: the official portals a KIT paper-push
/// task sends you to, one tap each.
///
/// Every `url` was fetched and its page title read on 2026-11-13 (the
/// launcher ships no alarm, no scraping, no interpretation — it only opens
/// the official page in the browser; the Matrikelnummer copy action copies
/// whatever the live profile shows, it certifies nothing).
///
/// Rows carry BOTH texts on purpose: an English label (what the user reads)
/// and the German official jargon (what the portal and every letter calls
/// it) — that pairing is the entire service this card provides.
class PortalRow {
  final String id;

  /// English label.
  final String en;

  /// German official jargon, verbatim from the portal's own vocabulary.
  final String de;
  final String url;

  const PortalRow(
      {required this.id,
      required this.en,
      required this.de,
      required this.url});
}

const kPortalRows = [
  PortalRow(
    id: "ilias",
    en: "ILIAS",
    de: "Lernplattform · ilias.studium.kit.edu",
    url: "https://ilias.studium.kit.edu/",
  ),
  PortalRow(
    // KIP's student functions run in KIT's Campus Management portal;
    // "Studierendenportal" is the SCC page's own name for it
    // (www.scc.kit.edu/dienste/12210.php), title verified "KIT - Startseite".
    id: "portal",
    en: "Campus portal",
    de: "Studierendenportal · CampusKIT",
    url: "https://campus.studium.kit.edu/",
  ),
  PortalRow(
    id: "catalog",
    en: "Course catalog",
    de: "Vorlesungsverzeichnis",
    url: "https://campus.studium.kit.edu/events/catalog.php",
  ),
  PortalRow(
    id: "library",
    en: "Library account",
    de: "KIT-Bibliothek · Katalog & Konto",
    url: "https://katalog.bibliothek.kit.edu/",
  ),
  PortalRow(
    id: "mensa",
    en: "Mensa menu",
    de: "Speiseplan · Studierendenwerk Karlsruhe",
    url: "https://www.sw-ka.de/de/hochschulgastronomie/speiseplan/",
  ),
  PortalRow(
    // the self-service report page; "Studienverlauf" is one of its own tabs
    id: "studyrecord",
    en: "Study record (PDF)",
    de: "Studienverlauf · Bescheinigungen",
    url: "https://campus.studium.kit.edu/reports/studyprocess.php",
  ),
];
