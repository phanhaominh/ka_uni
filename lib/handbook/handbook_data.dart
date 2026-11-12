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

  const HandbookModule({
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
  String get titleKey => handbookKey(title);
}

class HandbookPart {
  final String code;
  final String title;
  final double ects;
  final String type;
  final String attendsTo;

  const HandbookPart(
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

  String get titleKey => handbookKey(title);
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

  /// Load-once asset read; a corrupt/missing asset yields null and the
  /// UI hides itself — the handbook is an enhancement, never a crash path.
  static Future<Handbook?> load() async {
    if (_cached != null) return _cached;
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
      if (h.modules.isEmpty) return null;
      return _cached = h;
    } catch (_) {
      return null;
    }
  }

  /// Test hook: bypass the bundle without clearing real caches.
  static void injectForTest(Handbook? h) => _cached = h;
}

/// Shared title→ledger-key normalization (GradeBook._ledgerTitleKey minus
/// HTML entities, which handbook JSON never carries).
String handbookKey(String raw) =>
    raw.replaceAll(RegExp(r"\s+"), " ").trim().toLowerCase();
