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
    final catalog = exams
        .where((e) => !e.registered && cm.isTakingThisSemester(e) == false)
        .toList()
      ..sort(byWindowEnd);
    final open = exams
        .where((e) => e.needsAction(now) && !catalog.contains(e))
        .toList()
      ..sort(byWindowEnd);
    final registered = exams.where((e) => e.registered).toList()
      ..sort(byWindowEnd);
    final upcoming = exams
        .where((e) =>
            !e.registered &&
            !catalog.contains(e) &&
            !e.needsAction(now) &&
            e.windowStart != null &&
            now.isBefore(e.windowStart!))
        .toList()
      ..sort(byWindowStart);
    final rest = exams
        .where((e) =>
            !e.registered &&
            !catalog.contains(e) &&
            !e.needsAction(now) &&
            !upcoming.contains(e))
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
        L10n.t("exams.detailWindow", [_fmt(e.windowStart!), _fmt(e.windowEnd!)])
      else if (e.windowEnd != null)
        L10n.t("exams.detailDeadline", [_fmt(e.windowEnd!)]),
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
                _chip(
                    e.registered
                        ? L10n.t("exams.chipRegistered")
                        : urgent
                            ? L10n.t("exams.chipNotRegisteredNow")
                            : L10n.t("exams.chipNotRegistered"),
                    e.registered
                        ? scheme.tertiary
                        : urgent
                            ? scheme.error
                            : scheme.outline),
                if (e.examNumber.isNotEmpty)
                  _chip(e.examNumber, scheme.secondary),
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

  static String _fmt(DateTime d) =>
      "${d.day.toString().padLeft(2, "0")}.${d.month.toString().padLeft(2, "0")}.${d.year} "
      "${d.hour.toString().padLeft(2, "0")}:${d.minute.toString().padLeft(2, "0")}";
}
