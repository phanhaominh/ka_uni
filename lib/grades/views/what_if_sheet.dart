import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../logic/grade_sim.dart';
import '../models/grade_book.dart';

/// R29 (D1): "what grade do I need on module X to still land at average Y?"
/// - opened by tapping a pending/failed row on the grades page.
///
/// Honesty first: every number here is a SIMULATION. The official average
/// in CasCAMPUS counts modules this view cannot see (pending ones land
/// later, "bestanden" passes carry no number), and the footer says exactly
/// that on every open. The sheet never retracts or overwrites the official
/// figure - it only ever answers a question about the future.
class WhatIfSheet extends StatefulWidget {
  const WhatIfSheet({super.key, required this.sim, required this.entry});

  final GradeSim sim;
  final GradeEntry entry;

  @override
  State<WhatIfSheet> createState() => _WhatIfSheetState();
}

class _WhatIfSheetState extends State<WhatIfSheet> {
  // default: the current weighted mean (that is the question a student
  // actually asks: "what do I need to keep / reach where I am now?");
  // 2.5 as the floor for a ledger with nothing weighted yet
  double? _target;

  static String _deDecimal(num v) =>
      v.toStringAsFixed(1).replaceAll(".", ",");

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final target = _target ?? (widget.sim.selfAverage ?? 2.5).clamp(1.0, 4.0);
    final needed = neededFor(
        base: widget.sim, pending: widget.entry, targetAverage: target);
    final noCp =
        (widget.entry.moduleEcts ?? 0) <= 0; // cannot move the average
    final result = noCp
        ? L10n.t("grades.simNoCp")
        : needed == null
            ? L10n.t("grades.simImpossible")
            : L10n.t("grades.simNeeded", [_deDecimal(needed)]);
    return Padding(
      // keyboard-safe bottom padding for the system inset
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          Text(widget.entry.title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(L10n.t("grades.simTarget"),
                  style: TextStyle(
                      fontSize: 13, color: scheme.onSurfaceVariant)),
              const Spacer(),
              Text(_deDecimal(target),
                  style:
                      const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ],
          ),
          Slider(
            value: target,
            min: 1.0,
            max: 4.0,
            divisions: 30,
            label: _deDecimal(target),
            onChanged: (v) => setState(() => _target = v),
          ),
          const SizedBox(height: 4),
          Text(
            result,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: noCp || needed == null ? scheme.error : scheme.tertiary),
          ),
          const SizedBox(height: 8),
          Text(L10n.t("grades.simNote"),
              style: TextStyle(fontSize: 11, color: scheme.outline)),
        ],
      ),
    );
  }
}
