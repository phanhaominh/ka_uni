import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// Wave D (R26): the official MEI module handbook (SPO 2024) shipped as an
/// asset. `assets/mei/handbook_spo2024.json` was extracted from the KIT
/// PDF with per-rule page citations in `meta` — the ONLY structure this
/// app trusts for prerequisite gates and the module catalogue; everything
/// user-specific comes from the live ledger, never from this file.
class HandbookModule {
  final String code;
  final String title;
  final double ects;

  /// Offer terms, e.g. ["WS"], ["SS"], ["WS","SS"].
  final List<String> terms;
  final String examType;

  /// Sub-parts (0-CP homework/"Prüfungs-vorleistung" courses) attached to
  /// the module; `attendsTo` == this module's code.
  final List<HandbookPart> parts;

  /// Prerequisite/admission rules copied from the handbook, each with the
  /// PDF page that proves it.
  final List<HandbookGate> gates;

  // Not a const constructor anymore: the memo below is mutable by design
  // (a const class cannot carry non-final fields); nothing in the repo
  // const-constructs a module, so the loss is invisible.
  HandbookModule({
    required this.code,
    required this.title,
    required this.ects,
    required this.terms,
    required this.examType,
    required this.parts,
    required this.gates,
  });

  factory HandbookModule.fromJson(Map<String, dynamic> j) => HandbookModule(
        code: j["code"] as String? ?? "",
        title: j["title"] as String? ?? "",
        ects: (j["ects"] as num?)?.toDouble() ?? 0,
        terms: [
          for (final t in (j["terms"] as List? ?? const [])) "$t",
        ],
        examType: j["examType"] as String? ?? "",
        parts: [
          for (final p in (j["parts"] as List? ?? const []))
            HandbookPart.fromJson(Map<String, dynamic>.from(p as Map)),
        ],
        gates: [
          for (final g in (j["gates"] as List? ?? const []))
            HandbookGate.fromJson(Map<String, dynamic>.from(g as Map)),
        ],
      );

  /// Ledger-compatible dedup key (same normalization as the GradeBook
  /// ledger key: cleaned + lowercased). Handbook and ledger titles come
  /// from the same Campus catalogue, so exact-key equality is the honest
  /// match; a mismatch reads as "not yet taken" — the Ampel under-reports,
  /// never inflates.
  /// Memoized: [title] is final, so the key is stable, and the Ampel's
  /// nested build loops ask every module's key once per rebuild per row -
  /// two regex passes each time, for a string that can never change.
  String? _titleKey;
  String get titleKey => _titleKey ??= handbookKey(title);
}

class HandbookPart {
  final String code;
  final String title;
  final double ects;
  final String type;
  final String attendsTo;

  // const dropped for the same reason as HandbookModule: the memo field
  // below is mutable by design.
  HandbookPart(
      {required this.code,
      required this.title,
      required this.ects,
      required this.type,
      required this.attendsTo});

  factory HandbookPart.fromJson(Map<String, dynamic> j) => HandbookPart(
        code: j["code"] as String? ?? "",
        title: j["title"] as String? ?? "",
        ects: (j["ects"] as num?)?.toDouble() ?? 0,
        type: j["type"] as String? ?? "",
        attendsTo: j["attendsTo"] as String? ?? "",
      );

  /// Memoized for the same reason as HandbookModule.titleKey: parts are
  /// walked inside the module loop, key computed once per rebuild each.
  String? _titleKey;
  String get titleKey => _titleKey ??= handbookKey(title);
}

class HandbookGate {
  final String requires;
  final String edge;

  /// PDF page of the cited edition that states the rule (display: provenance).
  final int page;

  const HandbookGate(
      {required this.requires, required this.edge, required this.page});

  factory HandbookGate.fromJson(Map<String, dynamic> j) => HandbookGate(
        requires: j["requires"] as String? ?? "",
        edge: j["edge"] as String? ?? "",
        page: (j["page"] as num?)?.toInt() ?? 0,
      );
}

class Handbook {
  final String version;
  final String source;
  final List<HandbookModule> modules;

  const Handbook(
      {required this.version, required this.source, required this.modules});

  static Handbook? _cached;
  static Future<Handbook?>? _inFlight;

  /// Load-once asset read; a corrupt/missing asset yields null and the
  /// UI hides itself — the handbook is an enhancement, never a crash
  /// path. The FUTURE is memoized, not just the result: _ampelCard calls
  /// this from build, and an unmemoized future re-parses concurrently
  /// for every rebuild that lands while the first read is in flight.
  static Future<Handbook?> load() {
    if (_cached != null) return Future.value(_cached);
    return _inFlight ??= () async {
      try {
        final raw =
            await rootBundle.loadString("assets/mei/handbook_spo2024.json");
        final j = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        final meta = Map<String, dynamic>.from(j["meta"] as Map);
        final h = Handbook(
          version: meta["version"] as String? ?? "?",
          source: meta["source"] as String? ?? "",
          modules: [
            for (final m in (j["modules"] as List? ?? const []))
              HandbookModule.fromJson(Map<String, dynamic>.from(m as Map)),
          ],
        );
        return _cached = h.modules.isEmpty ? null : h;
      } catch (_) {
        return null;
      }
    }();
  }

  /// Test hook: bypass the bundle without clearing real caches.
  static void injectForTest(Handbook? h) => _cached = h;
}

/// Shared title→ledger-key normalization (GradeBook._ledgerTitleKey minus
/// HTML entities, which handbook JSON never carries). Typographic dashes
/// fold to ASCII: the handbook PDF renders "Do it! – Service-Learning…"
/// with an en-dash where CampusKIT's tree uses a hyphen, and an unfixed
/// mismatch would silently read a PASSED module as "planned".
// Hoisted: handbookKey runs per titleKey access, and those getters sit inside
// the Ampel's nested build loops over every module/part row - recompiling
// both programs per call repeated the same parse hundreds of times per
// rebuild. RegExp matching never mutates the object, so one shared instance
// is exactly equivalent.
final _dashFold = RegExp("[\u2013\u2014\u2212]");
final _whitespace = RegExp(r"\s+");

String handbookKey(String raw) => raw
    .replaceAll(_dashFold, "-")
    .replaceAll(_whitespace, " ")
    .trim()
    .toLowerCase();
