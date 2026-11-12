import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../common_ui/block_container.dart';
import '../../handbook/ampel.dart';
import '../../handbook/handbook_data.dart';
import '../../l10n/l10n.dart';
import '../../state_management/campus/campus_manager.dart';
import '../../state_management/kit_provider.dart';
import '../../toasts/models/toasts_provider.dart';
import '../logic/grade_sim.dart';
import '../models/grade_book.dart';
import 'what_if_sheet.dart';

/// Grades overview: SOP (30 CP) progress + the whole Studienverlauf tree
/// grouped into failed / passed / not-yet-graded modules.
class GradesPage extends StatelessWidget {
  const GradesPage({super.key});

  static const routeName = "/grades";

  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<KITProvider>(context);
    final cm = vm.campusManager;
    final book = GradeBook.fromRows(cm.moduleRows,
        ectsAcquiredTotal: cm.student.ectsAcquired,
        avgMark: cm.student.avgMark);
    // R29 (D1): one fold for the weighted stat AND the what-if sheets;
    // pure math over the same rows the cards below already render
    final sim = simulate(
        entries: book.modules, officialAverage: book.average);
    // R29 (D2): grade-publish chips mirror the push - the exact titleKeys
    // the last diff announced, on whichever section the reclassified row
    // now sits in
    final newKeys = cm.ledgerNewKeys.toSet();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(L10n.t("grades.title"))),
      // same affordance as exams/agenda: an empty or stale tree needs an
      // in-page re-sync (offline auto-login leaves moduleRows empty with
      // cached ECTS on the profile above - no other retry path is visible)
      body: RefreshIndicator(
        onRefresh: () async {
          final toasts = context.read<ToastsProvider>();
          // moduleRows are produced by exactly this scrape; the whole
          // forceRefetchEverything cascade would be overkill for one page
          //
          // cm.ready can NOT report this pull's outcome: it is
          // deliberately never cleared once the first schedule ever
          // loaded, so the old `!cm.ready` toast could never fire and
          // failures stayed silent forever. scheduleFetchFailed is set
          // by _fetchScheduleInner's silent early-return failure paths
          // and reset here before the fetch starts.
          cm.scheduleFetchFailed = false;
          await cm.fetchSchedule(refreshSession: false);
          if (cm.scheduleFetchFailed) {
            toasts.showTextToast(L10n.t("grades.loadError"));
          }
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 130),
          children: [
            if (book.modules.isEmpty)
              // not logged in / tree not scraped yet: say so instead of an
              // unexplained wall of empty cards
              BlockContainer(
                child: Text(L10n.t("grades.empty"),
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurfaceVariant)),
              )
            else ...[
              _sopCard(context, book, scheme),
              const SizedBox(height: 8),
              _ampelCard(context, book, scheme),
              const SizedBox(height: 8),
              _summaryCard(context, book, sim, scheme),
              // failed first: those are the attempts the student must act on
              if (book.failed.isNotEmpty)
                _section(context, L10n.t("grades.sectionFailed"), book.failed,
                    danger: true, sim: sim, newKeys: newKeys),
              if (book.passed.isNotEmpty)
                _section(context, L10n.t("grades.sectionPassed"), book.passed,
                    newKeys: newKeys),
              if (book.pending.isNotEmpty)
                _section(context, L10n.t("grades.sectionPending"), book.pending,
                    pending: true, sim: sim),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sopCard(BuildContext context, GradeBook book, ColorScheme scheme) {
    final green =
        CupertinoDynamicColor.resolve(CupertinoColors.systemGreen, context);
    final overdue =
        !book.sopReached && !DateTime.now().isBefore(GradeBook.sopDeadline);
    final (statusLabel, statusColor) = book.sopReached
        ? (L10n.t("grades.sopReached"), green)
        : overdue
            ? (L10n.t("grades.sopOverdue"), scheme.error)
            : (L10n.t("grades.sopOpen"), scheme.onSurfaceVariant);
    return BlockContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(L10n.t("grades.sopTitle"),
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: book.sopProgress,
              minHeight: 8,
              backgroundColor: scheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(
                  book.sopReached ? green : scheme.primary),
            ),
          ),
          const SizedBox(height: 8),
          Text(
              L10n.t("grades.sopProgress",
                  [_deDecimal(book.totalEcts), _whole(GradeBook.sopTarget)]),
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(statusLabel,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: statusColor)),
        ],
      ),
    );
  }

  /// Wave D (R26): Schein-Ampel — official MEI handbook crossed with the
  /// live ledger + exam registration. Static catalogue, live status: if
  /// either side is missing (no ledger) the card hides itself rather than
  /// showing a catalogue as if it were progress.
  Widget _ampelCard(BuildContext context, GradeBook book, ColorScheme scheme) {
    return FutureBuilder<Handbook?>(
      future: Handbook.load(),
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final cm = context.read<KITProvider>().campusManager;
        if (cm.enrolledLectureTitles.isEmpty) return const SizedBox.shrink();
        final now = DateTime.now();
        final plan = ampelPlan(
            handbook: snap.data!,
            book: book,
            signupOpenKeys: {
              for (final e in cm.exams)
                if (e.needsAction(now) &&
                    cm.isTakingThisSemester(e) != false)
                  CampusManager.lectureTitleKey(e.title)
            },
            takingKeys: cm.enrolledLectureTitles);
        final failed = plan.by(AmpelState.failed);
        final signup = plan.by(AmpelState.signupOpen);
        final running = plan.by(AmpelState.inProgress);
        // blocked rows that already print under signup/failed/running
        // carry their block suffix there - this section adds only the
        // otherwise-invisible ones (planned with a failed prerequisite)
        final blocked = plan
            .by(AmpelState.planned)
            .where((m) => m.blockedBy.isNotEmpty);
        final nextTerm = currentTerm(now) == "WS" ? "SS" : "WS";
        final nextUp = plan
            .by(AmpelState.planned)
            .where((m) =>
                m.offeredIn(nextTerm) &&
                m.blockedBy.isEmpty &&
                !book.pending
                    .any((g) => g.titleKey == m.module.titleKey))
            .take(5)
            .toList();
        final green =
            CupertinoDynamicColor.resolve(CupertinoColors.systemGreen, context);
        final pct = (book.passedEcts / AmpelPlan.degreeEctsTarget)
            .clamp(0.0, 1.0);
        Widget list(String label, Color color, List<AmpelModule> mods) =>
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final m in mods)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      "$label: ${m.module.title}"
                      "${m.blockedBy.isEmpty ? "" : " — ${L10n.t("grades.ampelBlocked", [m.blockedBy.join(", ")])}"}",
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13,
                          color: color == scheme.error
                              ? scheme.error
                              : scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            );
        return BlockContainer(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(L10n.t("grades.ampelTitle"),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: pct,
                  minHeight: 8,
                  backgroundColor: scheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation(green),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                  L10n.t("grades.ampelCp", [
                    _deDecimal(book.passedEcts),
                    _whole(AmpelPlan.degreeEctsTarget)
                  ]),
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (running.isNotEmpty)
                    _chip(L10n.t("grades.ampelRunning"), scheme.secondary),
                  if (signup.isNotEmpty)
                    _chip(L10n.t("grades.ampelSignup"), scheme.error),
                  if (failed.isNotEmpty)
                    _chip(L10n.t("grades.ampelFailed"), scheme.error),
                ],
              ),
              if (signup.isNotEmpty) list(L10n.t("grades.ampelSignup"), scheme.error, signup),
              if (failed.isNotEmpty) list(L10n.t("grades.ampelFailed"), scheme.error, failed),
              if (running.isNotEmpty) list(L10n.t("grades.ampelRunning"), scheme.secondary, running),
              if (blocked.isNotEmpty)
                list(L10n.t("grades.ampelBlockedTitle"), scheme.error,
                    blocked.toList()),
              if (nextUp.isNotEmpty)
                list(
                    L10n.t("grades.ampelNextTerm", [nextTerm]),
                    scheme.onSurfaceVariant,
                    nextUp),
              const SizedBox(height: 6),
              Text(L10n.t("grades.ampelSource", [snap.data!.version]),
                  style: TextStyle(fontSize: 11, color: scheme.outline)),
            ],
          ),
        );
      },
    );
  }

  Widget _summaryCard(BuildContext context, GradeBook book, GradeSim sim,
      ColorScheme scheme) {
    final green =
        CupertinoDynamicColor.resolve(CupertinoColors.systemGreen, context);
    final average = book.average;
    return BlockContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: _stat(L10n.t("grades.totalLabel"),
                      _deDecimal(book.totalEcts), scheme)),
              Expanded(
                  child: _stat(
                      L10n.t("grades.avgLabel"),
                      average == null
                          ? L10n.t("grades.valueNone")
                          : _deDecimal(average),
                      scheme)),
              // R29 (D1): own CP-weighted figure next to the official one -
              // same card, so a difference cannot be hidden by scroll
              Expanded(
                  child: _stat(
                      L10n.t("grades.simWeightedLabel"),
                      sim.selfAverage == null
                          ? L10n.t("grades.valueNone")
                          : _deDecimal(sim.selfAverage!),
                      scheme)),
            ],
          ),
          // loud honesty whenever the two averages disagree: our view is
          // PARTIAL (pending and "bestanden" modules carry no number), so
          // a divergence must never read as "the portal is wrong"
          if (sim.divergesFromOfficial) ...[
            const SizedBox(height: 6),
            Text(L10n.t("grades.simDiverges"),
                style: TextStyle(fontSize: 11, color: scheme.tertiary)),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              // a zero count stays grey: a fresh student must not get a
              // confident green "0 passed"; only real results colour
              _chip(L10n.t("grades.countPassed", [book.passed.length]),
                  book.passed.isEmpty ? scheme.outline : green),
              // only real failures may shout red
              _chip(L10n.t("grades.countFailed", [book.failed.length]),
                  book.failed.isEmpty ? scheme.outline : scheme.error),
              _chip(L10n.t("grades.countPending", [book.pending.length]),
                  book.pending.isEmpty ? scheme.outline : scheme.secondary),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value, ColorScheme scheme) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          Text(value,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ],
      );

  Widget _section(BuildContext context, String title, List<GradeEntry> entries,
      {bool danger = false,
      bool pending = false,
      GradeSim? sim,
      Set<String> newKeys = const {}}) {
    final scheme = Theme.of(context).colorScheme;
    final accent = danger
        ? scheme.error
        : pending
            ? scheme.outline
            : CupertinoDynamicColor.resolve(
                CupertinoColors.systemGreen, context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
          child: Text(title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: danger ? scheme.error : null,
                  fontWeight: FontWeight.bold)),
        ),
        BlockContainer(
          child: Column(
            children: [
              for (var i = 0; i < entries.length; i++) ...[
                if (i > 0) const Divider(height: 1, thickness: 1),
                // R29 (D1): rows WITHOUT a grade are exactly the ones a
                // what-if question makes sense for - pending modules and
                // recorded fails awaiting a retake. Passed rows stay inert:
                // swapping a finished 1,3 is arithmetic, not a decision.
                if (sim == null)
                  _row(context, entries[i],
                      accent: accent,
                      tinted: danger,
                      isNew: newKeys.contains(entries[i].titleKey),
                      label: pending
                          ? L10n.t("grades.pendingState")
                          : entries[i].gradeLabel.trim())
                else
                  InkWell(
                    onTap: () => showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        showDragHandle: true,
                        builder: (_) =>
                            WhatIfSheet(sim: sim, entry: entries[i])),
                    child: _row(context, entries[i],
                        accent: accent,
                        tinted: danger,
                        isNew: newKeys.contains(entries[i].titleKey),
                        label: pending
                            ? L10n.t("grades.pendingState")
                            : entries[i].gradeLabel.trim()),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, GradeEntry e,
      {required Color accent,
      required bool tinted,
      required String label,
      bool isNew = false}) {
    final scheme = Theme.of(context).colorScheme;
    // pending rows may not carry CP yet -> null or 0: omit the trailing unit
    final ects = e.moduleEcts;
    return Container(
      // failed rows carry their own error tint inside the card: re-takes
      // must surface when skimming the list, not just via the section title
      color: tinted ? accent.withValues(alpha: 0.08) : null,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(e.title,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          ),
          const SizedBox(width: 8),
          // R29 (D2): "neu" = the grade on THIS row was announced by the
          // last ledger diff (the same event that fired the push). Tertiary
          // tint, sibling of the grade chip - quieter than the red the
          // failed section already owns, so a pass reads as news not alarm
          if (isNew) _chip(L10n.t("grades.newBadge"), scheme.tertiary),
          if (isNew) const SizedBox(width: 6),
          // Flexible: the grade cell is arbitrary unvalidated text from the
          // scrape ("nicht bestanden (2. Versuch)" overflows a bare chip on
          // a 360dp phone); ellipsize instead of RenderFlex-crashing
          if (label.isNotEmpty) Flexible(child: _chip(label, accent)),
          if (ects != null && ects > 0)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(L10n.t("grades.cp", [_whole(ects)]),
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }

  Widget _chip(String label, Color color) => Chip(
        visualDensity: VisualDensity.compact,
        // scheme-based colors keep tinted labels contrast-safe per theme
        label: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 11, color: color, fontWeight: FontWeight.w600)),
        backgroundColor: color.withValues(alpha: 0.18),
        side: BorderSide(color: color.withValues(alpha: 0.6)),
      );

  /// "30,0" — German one-decimal style (comma); the app renders grades
  /// German-first in both UI languages, so no locale lookup.
  static String _deDecimal(num v) => v.toStringAsFixed(1).replaceAll(".", ",");

  /// ECTS are integral in the overwhelming majority of cases: "6 CP",
  /// "12 CP"; only real halves get the German-decimal form ("7,5 CP").
  static String _whole(num v) => _deDecimal(v).replaceAll(RegExp(r",0$"), "");
}
