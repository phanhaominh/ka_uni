import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../timetable/models/webcal.dart';

/// The agenda's "next up" hero, extracted so the home card and the agenda
/// share ONE computation and ONE card (R12): a countdown that lives twice
/// drifts twice. Thresholds unchanged from the banner: running ->
/// nowRunning, <3 min startsSoon, <60 min startsInMin, <=12 h
/// startsInHours; nothing within 12 h -> null (weekends and evenings must
/// stay silent, the hero never nags).
class NextUp {
  const NextUp(
      {required this.occ,
      required this.now,
      required this.running,
      required this.detail});

  /// The lecture the hero shows: the running one, else the next start.
  final IcsOccurrence occ;

  /// The clock reading the hero was computed against.
  final DateTime now;

  /// True when [occ] is in progress right now (drives the icon).
  final bool running;

  /// Localized countdown line ("läuft · bis 12:00", "startet in 5 Min").
  final String detail;

  /// Pure selection over an unsorted candidate list; null when nothing is
  /// live or starting within the horizon.
  static NextUp? compute(List<IcsOccurrence> occs, DateTime now) {
    final candidates = [...occs]..sort((a, b) => a.start.compareTo(b.start));
    IcsOccurrence? running;
    IcsOccurrence? next;
    for (final o in candidates) {
      if (!o.end.isAfter(now)) continue;
      if (running == null && !o.start.isAfter(now)) running = o;
      if (next == null && o.start.isAfter(now)) next = o;
      if (running != null && next != null) break;
    }
    final hero = running ?? next;
    if (hero == null) return null;
    String detail;
    if (running != null) {
      detail = L10n.t("agenda.nowRunning", [_hm(hero.end)]);
    } else {
      final until = hero.start.difference(now);
      if (until.inMinutes < 3) {
        detail = L10n.t("agenda.startsSoon");
      } else if (until.inMinutes < 60) {
        detail = L10n.t("agenda.startsInMin", [until.inMinutes]);
      } else if (until.inMinutes <= 720) {
        detail = L10n.t("agenda.startsInHours", [until.inHours]);
      } else {
        return null;
      }
    }
    return NextUp(
        occ: hero, now: now, running: running != null, detail: detail);
  }

  /// Feed occurrences of one calendar day, moved verbatim out of the
  /// agenda's day sections so the home card filters the shared feed cache
  /// exactly like the agenda does.
  static List<IcsOccurrence> onDay(WebcalFeed? feed, DateTime day) {
    if (feed == null) return const [];
    final seen = <String>{};
    final dayStart = DateTime(day.year, day.month, day.day);
    // calendar next-day (not +24h): the autumn DST day is 25 real hours
    final nextStart = DateTime(day.year, day.month, day.day + 1);

    return feed.occurrences
        .where((o) =>
            // include a lecture that started yesterday but still runs past
            // midnight: it belongs to today's list and the running hero
            (o.start.isBefore(nextStart) && o.end.isAfter(dayStart)) &&
            // one row per lecture; the room is part of the key so two
            // genuinely parallel groups of one family keep their own rows
            seen.add(
                "${o.title}|${o.start.toIso8601String()}|${o.room}"))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  /// The banner's candidate window: today + tomorrow through [onDay].
  static List<IcsOccurrence> heroWindow(WebcalFeed? feed, DateTime now) => [
        ...onDay(feed, now),
        ...onDay(feed, DateTime(now.year, now.month, now.day + 1)),
      ];

  static String _hm(DateTime d) =>
      "${d.hour.toString().padLeft(2, "0")}:"
      "${d.minute.toString().padLeft(2, "0")}";
}

/// The hero card. Without [onTap] the tree is byte-identical to what the
/// agenda rendered before the extraction (agenda keeps its look, R12);
/// the home variant only adds the InkWell tap surface.
class NextUpCard extends StatelessWidget {
  const NextUpCard({super.key, required this.up, this.onTap});

  final NextUp up;

  /// Home wires this to the agenda (scrollToToday); the agenda passes null.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hero = up.occ;
    final body = Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(up.running ? Icons.play_circle : Icons.directions_run,
              color: scheme.onPrimaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(up.detail,
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: scheme.onPrimaryContainer)),
                Text(hero.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 13, color: scheme.onPrimaryContainer)),
                if (hero.room.isNotEmpty)
                  Text(hero.room,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onPrimaryContainer)),
              ],
            ),
          ),
          Text(
              "${hero.start.hour.toString().padLeft(2, "0")}:"
              "${hero.start.minute.toString().padLeft(2, "0")}–"
              "${hero.end.hour.toString().padLeft(2, "0")}:"
              "${hero.end.minute.toString().padLeft(2, "0")}",
              style: TextStyle(
                  fontSize: 12,
                  color: scheme.onPrimaryContainer,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
    return Card(
      color: scheme.primaryContainer,
      child: onTap == null
          ? body
          : InkWell(
              onTap: onTap,
              borderRadius: const BorderRadius.all(Radius.circular(12)),
              child: body),
    );
  }
}
