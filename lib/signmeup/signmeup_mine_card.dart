import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:url_launcher/url_launcher.dart';
import '../l10n/l10n.dart';
import 'signmeup_manager.dart';

/// "Meine Anmeldungen": the student's own SignMeUp registrations with their
/// lottery outcome, rank and next deadline - visible on the agenda instead
/// of only implicitly via the synthetic tutorial event a draw produces.
/// Display-only; the row set is produced by [activeRows].
class SignMeUpMineCard extends StatelessWidget {
  final List<SignMeUpRegistration> rows;
  final DateTime now;

  const SignMeUpMineCard(
      {super.key, required this.rows, required this.now});

  static const int maxRows = 4;

  /// Rows worth showing, in card order: confirmation-pending first (an
  /// action beats a countdown), then by the nearest upcoming milestone,
  /// date-less rows last. The card only renders [maxRows] of them, so this
  /// order is what fills the visible slots.
  static List<SignMeUpRegistration> activeRows(
      List<SignMeUpRegistration> mine, DateTime now) {
    final rows = [
      for (final r in mine)
        if (r.isLive(now) && _rendersSomething(r, now)) r
    ];
    rows.sort((a, b) {
      final byConfirm =
          (b.canConfirm ? 1 : 0) - (a.canConfirm ? 1 : 0); // trues first
      if (byConfirm != 0) return byConfirm;
      final am = a.nextMilestone(now), bm = b.nextMilestone(now);
      if (am == null || bm == null) {
        if (am == bm) return 0;
        return am == null ? 1 : -1;
      }
      return am.compareTo(bm);
    });
    return rows;
  }

  /// Whether the row renders anything beyond its bare name: a chip label
  /// (unknown outcomes show the raw server text), a positive rank or a
  /// pending milestone. Content-free rows would be dead weight in the
  /// scarce visible slots.
  static bool _rendersSomething(SignMeUpRegistration r, DateTime now) =>
      r.outcome != SignMeUpOutcome.unknown ||
      r.stateLabel.trim().isNotEmpty ||
      (r.rank ?? 0) > 0 ||
      r.nextMilestone(now) != null;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.fact_check, color: scheme.primary),
              const SizedBox(width: 6),
              Text(L10n.t("agenda.signmeupMineTitle"),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ]),
            for (final r in rows.take(maxRows)) _row(r, context, scheme),
            if (rows.length > maxRows)
              // the sorted head of activeRows is what the slots show; say
              // so instead of silently cutting the tail
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                    L10n.t(
                        "agenda.signmeupMineMore", [rows.length - maxRows]),
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant)),
              ),
          ],
        ),
      ),
    );
  }

  /// Launchable target of a row: the procedure's page in the Campus+
  /// SignMeUp SPA (`procedures/<id>` — the `SMUProcedureView` route of the
  /// deployed bundle). A registration without a real procedureId (the
  /// model's -1 sentinel) has no launchable URL.
  static String? _procedureUrl(SignMeUpRegistration r) =>
      r.procedureId >= 0
          ? "https://plus.campus.kit.edu/signmeup/procedures/${r.procedureId}"
          : null;

  /// Mirror of agenda_page's private `_launchExternal` (importing it from
  /// a view would invert the dependency): only a well-formed http(s) URL
  /// reaches the launcher and a missing/refusing launcher never throws
  /// inside the tap.
  void _launchExternal(String raw) {
    try {
      final uri = Uri.parse(raw);
      if (uri.host.isEmpty ||
          (uri.scheme != "http" && uri.scheme != "https")) {
        return;
      }
      launchUrl(uri, mode: LaunchMode.externalApplication)
          .catchError((_) => false);
    } on Object catch (_) {}
  }

  Widget _row(
      SignMeUpRegistration r, BuildContext context, ColorScheme scheme) {
    final milestone = r.nextMilestone(now);
    final rank = r.rank;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(r.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600)),
        Wrap(
          spacing: 6,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _stateChip(r, context, scheme),
            // a rank of 0/negative/null means "no draw position";
            // descriptive, so it sits back at outline level while the
            // countdown (an actionable deadline) stays w500
            if (rank != null && rank > 0)
              Text(L10n.t("agenda.signmeupMineRank", [rank]),
                  style: TextStyle(fontSize: 12, color: scheme.outline)),
            if (milestone != null)
              Text(L10n.dayOffset(milestone, now),
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurfaceVariant)),
          ],
        ),
      ],
    );
    final url = _procedureUrl(r);
    if (url == null) {
      // no target page -> no tap target, no chevron (no dead affordance)
      return Padding(
        // same stacked name/detail rows as the procedures card: a long
        // course name must not push the chip line around
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: content,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _launchExternal(url),
        child: Row(
          children: [
            Expanded(child: content),
            // chevron only where there is actually something to open
            Icon(Icons.chevron_right, size: 18, color: scheme.outline),
          ],
        ),
      ),
    );
  }

  Widget _stateChip(
      SignMeUpRegistration r, BuildContext context, ColorScheme scheme) {
    // accepted/rejected use the Cupertino semantic colors resolved through
    // the ambient theme (brightness-aware), tinted to a 15 % fill with a
    // full-strength foreground; everything without a decision - open or an
    // unmapped raw server label - gets the same neutral chip
    final green =
        CupertinoDynamicColor.resolve(CupertinoColors.systemGreen, context);
    final red =
        CupertinoDynamicColor.resolve(CupertinoColors.systemRed, context);
    final (label, bg, fg) = switch (r.outcome) {
      SignMeUpOutcome.accepted => (
          L10n.t("agenda.signmeupMineAccepted"),
          green.withValues(alpha: 0.15),
          green
        ),
      SignMeUpOutcome.rejected => (
          L10n.t("agenda.signmeupMineRejected"),
          red.withValues(alpha: 0.15),
          red
        ),
      SignMeUpOutcome.open => (
          L10n.t("agenda.signmeupMineOpen"),
          scheme.surfaceContainerHighest,
          scheme.onSurfaceVariant
        ),
      SignMeUpOutcome.unknown => (
          r.stateLabel.trim(),
          scheme.surfaceContainerHighest,
          scheme.onSurfaceVariant
        ),
    };
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      // cloned from the agenda's badge chips
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Text(label, style: TextStyle(fontSize: 11, color: fg)),
    );
  }
}
