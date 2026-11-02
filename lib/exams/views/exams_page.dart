import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../toasts/models/toasts_provider.dart';
import '../../state_management/kit_provider.dart';
import '../models/exam_list.dart';

/// Exam registration overview: Anmeldung windows, status, red flag for
/// "window open but not registered" (missing it = failed attempt).
class ExamsPage extends StatelessWidget {
  const ExamsPage({super.key});

  static const routeName = "/exams";

  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<KITProvider>(context);
    final cm = vm.campusManager;
    if (!cm.examsLoaded && !cm.isFetchingExams && !cm.examsSurfaceBroken) {
      // self-heal: a stale session that never ran fetchExams (e.g. login
      // predates this build) must not leave the user on an endless spinner
      SchedulerBinding.instance.addPostFrameCallback((_) => cm.fetchExams());
    }
    final exams = cm.exams;
    final now = DateTime.now();

    // cascampus lists the exam offers of the whole degree-programme
    // catalogue: exams of lectures that are NOT on the current timetable
    // are other semesters' business - keep them listed but never urgent.
    // C38: the relevance gate runs exactly once per exam and the
    // cross-section exclusions consult one-shot Sets - the five list
    // scans used to re-run isTakingThisSemester and O(n) list.contains
    // against the whole catalogue on every pass
    final taking = {for (final e in exams) e: cm.isTakingThisSemester(e)};
    final catalog = exams
        .where((e) => !e.registered && taking[e] == false)
        .toList()
      ..sort(byWindowEnd);
    final inCatalog = catalog.toSet();
    final open = exams
        .where((e) => e.needsAction(now) && !inCatalog.contains(e))
        .toList()
      ..sort(byWindowEnd);
    final registered = exams.where((e) => e.registered).toList()
      ..sort(byWindowEnd);
    final upcoming = exams
        .where((e) =>
            !e.registered &&
            !inCatalog.contains(e) &&
            !e.needsAction(now) &&
            e.windowStart != null &&
            now.isBefore(e.windowStart!))
        .toList()
      ..sort(byWindowStart);
    final upcomingSet = upcoming.toSet();
    final rest = exams
        .where((e) =>
            !e.registered &&
            !inCatalog.contains(e) &&
            !e.needsAction(now) &&
            !upcomingSet.contains(e))
        .toList()
      ..sort(byWindowEnd);

    return Scaffold(
      appBar: AppBar(title: Text(L10n.t("exams.title"))),
      // one refresh affordance for ALL branches (loading/error/empty/list):
      // the empty list especially needs a manual re-sync
      body: RefreshIndicator(
        onRefresh: () async {
          final toasts = context.read<ToastsProvider>();
          final ok = await cm.fetchExams();
          if (!ok) toasts.showTextToast(L10n.t("exams.loadError"));
        },
        child: !cm.examsLoaded
            ? (cm.examsSurfaceBroken
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 200),
                      Center(child: Text(L10n.t("exams.loadError"))),
                      const SizedBox(height: 12),
                      Center(
                        child: FilledButton(
                          onPressed: () => cm.fetchExams(),
                          child: Text(L10n.t("exams.retry")),
                        ),
                      ),
                    ],
                  )
                : ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 240),
                      Center(child: CircularProgressIndicator()),
                    ],
                  ))
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 130),
                children: [
                  if (exams.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 200),
                      child: Center(child: Text(L10n.t("exams.empty"))),
                    ),
                  if (open.isNotEmpty)
                    _section(
                        context, L10n.t("exams.sectionActNow"), open, now,
                        danger: true),
                  if (upcoming.isNotEmpty)
                    _section(context, L10n.t("exams.sectionOpensSoon"),
                        upcoming, now),
                  if (registered.isNotEmpty)
                    _section(context, L10n.t("exams.sectionRegistered"),
                        registered, now),
                  if (rest.isNotEmpty)
                    _section(context, L10n.t("exams.sectionOther"), rest, now),
                  if (catalog.isNotEmpty)
                    _section(context, L10n.t("exams.sectionCatalog"), catalog,
                        now,
                        quiet: true),
                ],
              ),
      ),
    );
  }

  @visibleForTesting
  static int byWindowEnd(ExamEntry a, ExamEntry b) {
    final c = (a.windowEnd ?? DateTime(2100))
        .compareTo(b.windowEnd ?? DateTime(2100));
    if (c != 0) return c;
    // six exam groups of one lecture share deadline AND title; the pool
    // letter lives in the exam number ("20.21 Pool A"…) - sorting on it
    // beats the cascampus source order (…, Pool E, Pool D)
    final t = a.title.compareTo(b.title);
    return t != 0 ? t : a.examNumber.compareTo(b.examNumber);
  }

  @visibleForTesting
  static int byWindowStart(ExamEntry a, ExamEntry b) =>
      (a.windowStart ?? DateTime(2100))
          .compareTo(b.windowStart ?? DateTime(2100));

  Widget _section(BuildContext context, String title, List<ExamEntry> exams,
      DateTime now,
      {bool danger = false, bool quiet = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
          child: Text(title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: danger ? Theme.of(context).colorScheme.error : null,
                  fontWeight: FontWeight.bold)),
        ),
        ...exams.map(
            (e) => _card(context, e, now, danger: danger, quiet: quiet)),
      ],
    );
  }

  Widget _card(BuildContext context, ExamEntry e, DateTime now,
      {bool danger = false, bool quiet = false}) {
    // quiet = not on the current timetable: an open window here is NOT
    // something the student must act on, so no red chip
    final urgent = !quiet && e.needsAction(now);
    final scheme = Theme.of(context).colorScheme;
    final details = <String>[
      ...e.terms.map((t) => L10n.t("exams.detailExamTerm", [
            t.dayLabel,
            t.time,
            t.room.isNotEmpty ? "  •  ${t.room}" : "",
          ])),
      if (e.windowStart != null && e.windowEnd != null)
        L10n.t("exams.detailWindow",
            [L10n.deadline(e.windowStart!), L10n.deadline(e.windowEnd!)])
      else if (e.windowEnd != null)
        L10n.t("exams.detailDeadline", [L10n.deadline(e.windowEnd!)]),
      if (e.examiners.isNotEmpty)
          L10n.t("exams.detailExaminers", [e.examiners]),
      e.examType,
    ];

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: danger
            ? BorderSide(color: scheme.error, width: 1.4)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(e.title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(details.join("\n"),
                style:
                    TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: [
                if (e.registered)
                  _chip(L10n.t("exams.chipRegistered"), scheme.tertiary)
                else if (urgent)
                  // #11: filled - the one chip on the page meaning "act
                  // now" must not differ from its benign sibling only by
                  // a red-vs-grey tint of the same thin outline
                  _urgentChip(L10n.t("exams.chipNotRegisteredNow"), scheme)
                else
                  _chip(L10n.t("exams.chipNotRegistered"), scheme.outline),
                if (e.examNumber.isNotEmpty)
                  // plain caption, not a second pill: an identical chip
                  // for the module number invites taps that do nothing
                  Text(e.examNumber,
                      style: TextStyle(
                          fontSize: 11, color: scheme.outline)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, Color color) => Chip(
        visualDensity: VisualDensity.compact,
        // scheme-based colors keep tinted labels contrast-safe per theme
        label: Text(label,
            style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
        backgroundColor: color.withValues(alpha: 0.18),
        side: BorderSide(color: color.withValues(alpha: 0.6)),
      );

  Widget _urgentChip(String label, ColorScheme scheme) => Chip(
        visualDensity: VisualDensity.compact,
        // errorContainer is the solid M3 destructive surface - unmistakable
        // against the outline chips and contrast-safe in both brightnesses
        label: Text(label,
            style: TextStyle(
                fontSize: 11,
                color: scheme.onErrorContainer,
                fontWeight: FontWeight.w700)),
        backgroundColor: scheme.errorContainer,
        side: BorderSide(color: scheme.error),
      );
}
