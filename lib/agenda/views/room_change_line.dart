import 'package:flutter/material.dart';
import 'package:kit_mobile/constants/view_constants.dart';

import '../../timetable/models/webcal.dart';

/// Feed-trust window of the hero room-change line: the exact 30 h rule the
/// home card's `_feedFresh` applies to the same [WebcalKeys.fetchedAt] stamp
/// (R24: ~60 consecutive failed polls). A struck-through room is a claim
/// about the CURRENT feed — it may only speak while the poll proves itself
/// alive; older than this, the heroes render exactly as before R32.6.
const Duration heroRoomFeedFreshness = Duration(hours: 30);

/// The R32.6 room delta that entitles the hero [RoomChangeLine], or null
/// when the hero must stay untouched.
///
/// A delta only qualifies when it is a pure LOCATION swap
/// ([IcsChangeKind.changed] with `oldRoom` ≠ `room`, both non-empty): a
/// lecture that merely GAINS its first room has nothing to strike through
/// (same dangling-arrow guard as the agenda row delta), and a `moved` delta
/// is a time change whose new slot the hero only reached by moving.
///
/// Matching is strict — the delta must name the hero's very occurrence:
/// title identity ([IcsChange.titleKey]) AND the occurrence start AND the
/// room the hero ACTUALLY displays (`c.room == occ.room`). The last guard
/// is what keeps a delta that no longer matches the parsed feed (a re-read
/// caught the store ahead of the cache, or the room was reverted later)
/// from advertising a move the displayed room never made. Successive edits
/// of one session share the same `when` (the occurrence start), so ties
/// resolve in stored (oldest-first) order: the LAST matching delta wins —
/// the same tie rule as the agenda row picker and `IcsChangeIndex.blockKeys`.
IcsChange? heroRoomDelta(
    {required IcsOccurrence occ,
    required List<IcsChange> changes,
    required bool feedFresh}) {
  if (!feedFresh || occ.room.isEmpty || changes.isEmpty) return null;
  final occKey = IcsChange.titleKey(occ.title);
  IcsChange? delta;
  for (final c in changes) {
    if (c.kind != IcsChangeKind.changed) continue;
    final oldRoom = c.oldRoom;
    if (oldRoom == null || oldRoom.isEmpty || oldRoom == c.room) continue;
    if (c.room.isEmpty || c.room != occ.room) continue;
    if (IcsChange.titleKey(c.title) != occKey) continue;
    if (!c.when.isAtSameMomentAs(occ.start)) continue;
    if (delta == null || !c.when.isBefore(delta.when)) delta = c;
  }
  return delta;
}

/// The struck-room caption rendered under BOTH NextUp hero sites (agenda
/// banner + home card) — ONE widget, because a hero message that exists
/// twice drifts twice (R12 doctrine). Struck-through old room → bold new
/// room in the tertiary caption token the agenda row room-diff already
/// uses; the card itself keeps showing the new room untouched, so a stale
/// or unrelated store never mutates the hero, it only adds this line.
class RoomChangeLine extends StatelessWidget {
  const RoomChangeLine({super.key, required this.delta});

  final IcsChange delta;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // align under the hero's text column: card gutter + card padding +
    // the countdown icon (default 24) + the icon gap of NextUpCard's Row
    return Padding(
      padding: EdgeInsets.fromLTRB(cardGutter + 46, 0, cardGutter + 12, 2),
      child: Row(
        children: [
          Icon(Icons.compare_arrows, size: 14, color: scheme.tertiary),
          const SizedBox(width: 6),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: TextStyle(fontSize: 12, color: scheme.tertiary),
                children: [
                  TextSpan(
                      text: delta.oldRoom,
                      style: const TextStyle(
                          decoration: TextDecoration.lineThrough)),
                  const TextSpan(text: " → "),
                  TextSpan(
                      text: delta.room,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
