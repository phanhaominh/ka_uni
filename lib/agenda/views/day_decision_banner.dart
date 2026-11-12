import 'package:flutter/material.dart';

/// R24 wave A: one calm line answering the morning question when the
/// answer is NOT "next lecture at HH:MM" (that case is the hero card
/// below). Empty day, cancelled day, or an untrusted feed - never a
/// silent void, never a false "free day" claim.
class DayDecisionBanner extends StatelessWidget {
  final String text;

  /// neutral (free) vs. attention (cancelled/stale) - same color dialect
  /// as MeiFailureBanner (mid-shades stay legible on both brightnesses)
  final bool attention;
  final VoidCallback? onTap;

  const DayDecisionBanner(
      {super.key, required this.text, this.attention = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = attention
        ? (isDark ? Colors.orange.shade300 : Colors.orange.shade800)
        : (isDark ? Colors.teal.shade200 : Colors.teal.shade800);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              border: Border.all(color: color.withValues(alpha: 0.6)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(attention ? Icons.event_busy : Icons.self_improvement,
                    color: color, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(color: color, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
