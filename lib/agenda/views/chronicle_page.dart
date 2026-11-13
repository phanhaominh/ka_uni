import 'package:flutter/material.dart';

import '../../common_ui/max_width_body.dart';
import '../../l10n/l10n.dart';
import '../../timetable/models/webcal.dart';

/// R32.7 CHRONICLE: every timetable delta still sitting in
/// [WebcalKeys.changes] (DATA_webcalChanges), pushed from the agenda's
/// CHANGED band footer ("Ältere Änderungen"). Where the band filters to
/// `when >= today` and shows at most 6 rows, this page shows the WHOLE
/// stored history of the current store — and says so: the header admits
/// the coverage (only what the app itself saw while polling), the visible
/// count against the storage cap, and the oldest stored entry. What the
/// app never polled into the store, or what a "Verstanden" dismiss
/// cleared, is NOT here and the header never claims it is.
///
/// Grouping is by the lecture day a delta concerns (its `when`): the codec
/// carries no per-entry fetch stamp, so "when the app saw it" is not a
/// fact the store can render — the affected occurrence's day is.
class ChroniclePage extends StatelessWidget {
  const ChroniclePage({super.key, required this.changes});

  static const routeName = "/chronicle";

  /// The storage cap of `mergeIcsChanges`: the store keeps at most the
  /// newest 50 deltas — disclosed verbatim in the header, never silently.
  static const storedCap = 50;

  final List<IcsChange> changes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // group by lecture day, newest day first; inside a day, newest delta
    // first — the same "freshest on top" reading order as the band
    final byDay = <DateTime, List<IcsChange>>{};
    DateTime? oldest;
    for (final c in changes) {
      byDay
          .putIfAbsent(DateTime(c.when.year, c.when.month, c.when.day),
              () => <IcsChange>[])
          .add(c);
      if (oldest == null || c.when.isBefore(oldest)) oldest = c.when;
    }
    final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final list in byDay.values) {
      list.sort((a, b) => b.when.compareTo(a.when));
    }
    return Scaffold(
      appBar: AppBar(title: Text(L10n.t("timetable.chronicleTitle"))),
      body: MaxWidthBody(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.info_outline,
                          size: 16, color: scheme.outline),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(L10n.t("timetable.chronicleCoverage"),
                            style: TextStyle(
                                fontSize: 12, color: scheme.outline)),
                      ),
                    ]),
                    if (oldest != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                            // year-bearing on purpose: the 50-entry cap is
                            // count-based, so the store can stretch back
                            // into a past term — a year-less stamp would
                            // then silently read as this year's date
                            L10n.t("timetable.chronicleCap", [
                              changes.length,
                              storedCap,
                              L10n.deadline(oldest)
                            ]),
                            style: TextStyle(
                                fontSize: 12, color: scheme.outline)),
                      ),
                  ],
                ),
              ),
            ),
            if (changes.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(L10n.t("timetable.chronicleEmpty"),
                      style: TextStyle(fontSize: 13, color: scheme.outline)),
                ),
              ),
            for (final day in days) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
                child: Text(L10n.stamp(day),
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              for (final c in byDay[day]!) _changeRow(context, c),
            ],
          ],
        ),
      ),
    );
  }

  /// One delta: kind-colored icon + the same localized sentence the band
  /// rows use ([IcsChange.describe]) — one phrasing, two surfaces.
  Widget _changeRow(BuildContext context, IcsChange c) {
    final scheme = Theme.of(context).colorScheme;
    final IconData icon;
    final Color color;
    switch (c.kind) {
      case IcsChangeKind.added:
        icon = Icons.add_circle_outline;
        color = scheme.primary;
      case IcsChangeKind.removed:
        icon = Icons.remove_circle_outline;
        color = scheme.error;
      case IcsChangeKind.moved:
        icon = Icons.swap_horiz;
        color = scheme.tertiary;
      case IcsChangeKind.changed:
        icon = Icons.edit;
        color = scheme.secondary;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
      child: Row(children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
            child: Text(c.describe(), style: const TextStyle(fontSize: 13))),
      ]),
    );
  }
}
