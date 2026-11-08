import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../state_management/kit_provider.dart';

/// Loud-failure strip: never let a parse/bot failure degrade into an empty
/// grid. Session death self-heals via re-login and is NOT surfaced here.
class MeiFailureBanner extends StatelessWidget {
  final KITProvider vm;

  const MeiFailureBanner({super.key, required this.vm});

  @override
  Widget build(BuildContext context) {
    final cm = vm.campusManager;
    String? text;
    Color? color;
    // the -600/-700/-800 shades sit at ~3:1 on the dark scaffold; the
    // same hues at -300/-400 stay legible on both brightnesses
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (cm.botChallengeAlgorithmChanged) {
      text = L10n.t("notifs.bannerBotProtection");
      color = isDark ? Colors.red.shade400 : Colors.red.shade700;
    } else if (cm.examsSurfaceBroken && cm.timetableSurfaceBroken) {
      text = L10n.t("notifs.bannerBoth");
      color = isDark ? Colors.red.shade400 : Colors.red.shade600;
    } else if (cm.examsSurfaceBroken) {
      text = L10n.t("notifs.bannerExams");
      color = isDark ? Colors.orange.shade300 : Colors.orange.shade800;
    } else if (cm.timetableSurfaceBroken) {
      text = L10n.t("notifs.bannerTimetable");
      color = isDark ? Colors.orange.shade300 : Colors.orange.shade800;
    } else {
      text = null;
    }
    if (text == null || color == null) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
