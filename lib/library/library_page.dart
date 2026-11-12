import 'dart:async';

// Main's directive for W4: the AnnyHttp surface is public for widget-local
// helpers (fetchIntervals/fetchBookableDays/childSeats) — the seam
// annotation exists to keep the MANAGER's own calls disciplined, not to
// lock the UI out of the read-only endpoints.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common_ui/block_container.dart';
import '../common_ui/kit_progress_indicator.dart';
import '../common_ui/max_width_body.dart';
import '../constants/view_constants.dart';
import '../home/views/padded_title.dart';
import '../l10n/l10n.dart';
import 'anny_api.dart';
import 'anny_manager.dart';
import '../state_management/kit_provider.dart';
import '../toasts/models/toasts_provider.dart';

/// Full library seat-reservation page: room list (individual seats /
/// group rooms), the book flow (day strip -> start times -> duration ->
/// confirm sheet) and "My bookings" with cancel. All legality comes from
/// the server (start-dates + intervals), nothing is re-implemented here.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  /// route identity for the notification deep link router
  static const String routeName = '/library';

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final anny = context.read<KITProvider>().anny;
      if (!anny.hasData) unawaited(anny.refreshAnon());
      if (anny.signedIn) unawaited(anny.refreshBookings());
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vm = context.watch<KITProvider>();
    final AnnyManager anny = vm.anny;
    final toasts = context.read<ToastsProvider>();

    final seats =
        anny.rooms.where((AnnyRoom r) => r.section == "seats").toList();
    final groups =
        anny.rooms.where((AnnyRoom r) => r.section != "seats").toList();

    return Scaffold(
      appBar: AppBar(title: Text(L10n.t("library.title"))),
      body: MaxWidthBody(
        child: ListView(
          padding: defaultPagePaddingEdgeInsetsAll.copyWith(bottom: 120),
          children: [
            _accountSection(theme, anny, toasts),
            const SizedBox(height: spaceLg),
            if (anny.rooms.isEmpty && anny.isFetching)
              Padding(
                padding: const EdgeInsets.all(spaceMd),
                child: KITProgressIndicator(
                    semanticsLabel: L10n.t("library.title")),
              )
            else if (anny.rooms.isEmpty)
              BlockContainer(
                child: Padding(
                  padding: const EdgeInsets.all(spaceMd),
                  child: Column(
                    children: [
                      Icon(Icons.cloud_off,
                          size: 32, color: theme.colorScheme.outline),
                      const SizedBox(height: spaceSm),
                      Text(L10n.t("library.loadFailed")),
                      const SizedBox(height: spaceMd),
                      FilledButton.tonal(
                        onPressed: () => anny.refreshAnon(force: true),
                        child: Text(L10n.t("library.retry")),
                      ),
                    ],
                  ),
                ),
              )
            else ...[
              if (seats.isNotEmpty) ...[
                PaddedTitle(title: L10n.t("library.roomsIndividual")),
                BlockContainer(
                    child: Column(children: [
                  for (final AnnyRoom r in seats) _roomRow(theme, anny, r),
                ])),
                const SizedBox(height: spaceLg),
              ],
              if (groups.isNotEmpty) ...[
                PaddedTitle(title: L10n.t("library.roomsGroups")),
                BlockContainer(
                    child: Column(children: [
                  for (final AnnyRoom r in groups) _roomRow(theme, anny, r),
                ])),
                const SizedBox(height: spaceLg),
              ],
            ],
            if (anny.signedIn) ...[
              PaddedTitle(
                  title: L10n.t("library.myBookings"),
                  trailing: Tooltip(
                    message: L10n.t("library.refresh"),
                    child: CupertinoButton(
                      padding: const EdgeInsets.all(10),
                      onPressed: () => anny.refreshBookings(),
                      child: const Icon(CupertinoIcons.arrow_clockwise),
                    ),
                  )),
              _bookingsSection(theme, anny, toasts),
            ],
          ],
        ),
      ),
    );
  }

  Widget _accountSection(
      ThemeData theme, AnnyManager anny, ToastsProvider toasts) {
    if (!anny.signedIn) {
      return BlockContainer(
        child: Padding(
          padding: const EdgeInsets.all(spaceMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(L10n.t("library.neverBooked"),
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.outline)),
              const SizedBox(height: spaceSm),
              FilledButton.tonal(
                onPressed: () => showLibrarySignInDialog(context),
                child: Text(L10n.t("library.loginKit")),
              ),
            ],
          ),
        ),
      );
    }
    return BlockContainer(
      child: Padding(
        padding: const EdgeInsets.all(spaceMd),
        child: Row(
          children: [
            Expanded(child: _IdentityLine(anny: anny)),
            CupertinoButton(
              onPressed: () => anny.signOut(),
              child: Text(L10n.t("library.signOut"),
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.error)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roomRow(ThemeData theme, AnnyManager anny, AnnyRoom r) {
    final int? free = anny.freeCounts[r.slug];
    final bool fav = anny.favSlug == r.slug;
    return InkWell(
      onTap: () => _openRoomSheet(anny, context.read<ToastsProvider>(), r),
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: spaceMd, vertical: spaceSm),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.name, style: theme.textTheme.bodyMedium),
                  if (r.openFrom.isNotEmpty && r.openTo.isNotEmpty)
                    Text(
                      "${_hmRaw(r.openFrom)} – ${_hmRaw(r.openTo)}",
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                ],
              ),
            ),
            const SizedBox(width: spaceSm),
            Text(
              free == null ? "${r.quantity}" : "$free/${r.quantity}",
              style: theme.textTheme.titleSmall?.copyWith(
                  color: free != null && free == 0
                      ? theme.colorScheme.outline
                      : null),
            ),
            // tooltip + 44pt-ish target: an unlabeled 20px star is
            // undiscoverable and hard to hit (R21)
            Tooltip(
              message: L10n.t("library.fav"),
              child: CupertinoButton(
                padding: const EdgeInsets.all(spaceSm),
                onPressed: () => anny.setFav(r.slug),
                child: Icon(
                  fav ? CupertinoIcons.star_fill : CupertinoIcons.star,
                  size: 20,
                  color: fav
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                ),
              ),
            ),
            Icon(CupertinoIcons.chevron_right,
                size: 16, color: theme.colorScheme.outline),
          ],
        ),
      ),
    );
  }

  Widget _bookingsSection(
      ThemeData theme, AnnyManager anny, ToastsProvider toasts) {
    if (anny.isLoadingBookings && anny.bookings.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(spaceMd),
        child:
            KITProgressIndicator(semanticsLabel: L10n.t("library.myBookings")),
      );
    }
    if (anny.bookings.isEmpty) {
      return BlockContainer(
        child: Padding(
          padding: const EdgeInsets.all(spaceMd),
          child: Text(L10n.t("library.noBookings"),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.outline)),
        ),
      );
    }
    return BlockContainer(
      child: Column(
        children: [
          for (final AnnyBooking b in anny.bookings)
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: spaceMd, vertical: spaceSm),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(b.resource.isEmpty ? b.number : b.resource,
                            style: theme.textTheme.bodyMedium),
                        Text(
                          "${L10n.stamp(b.start)} – ${_hm(_hhmm(b.end))} · "
                          "${b.number}",
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.outline),
                        ),
                      ],
                    ),
                  ),
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(
                        horizontal: spaceSm, vertical: spaceXs),
                    onPressed: () => _confirmCancel(theme, anny, toasts, b),
                    child: Text(L10n.t("library.cancel"),
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.error)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmCancel(ThemeData theme, AnnyManager anny,
      ToastsProvider toasts, AnnyBooking b) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => CupertinoAlertDialog(
        title: Text(L10n.t("library.cancelConfirm",
            [b.resource.isEmpty ? b.number : b.resource])),
        actions: [
          CupertinoDialogAction(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: Text(L10n.t("settings.cancel"))),
          CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: Text(L10n.t("library.cancel"))),
        ],
      ),
    );
    if (yes != true) return;
    final ok = await anny.cancel(b);
    toasts.showTextToast(
        L10n.t(ok ? "library.canceledOk" : "library.canceledFailed"));
  }

  Future<void> _openRoomSheet(
      AnnyManager anny, ToastsProvider toasts, AnnyRoom room) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _RoomSheet(anny: anny, toasts: toasts, room: room),
    );
  }

  static String _hm((int, int) t) =>
      "${t.$1.toString().padLeft(2, "0")}:${t.$2.toString().padLeft(2, "0")}";

  static (int, int) _hhmm(DateTime d) => (d.hour, d.minute);

  /// "HH:mm:ss" → "HH:mm"
  static String _hmRaw(String s) => s.length >= 5 ? s.substring(0, 5) : s;
}

/// day strip -> start times -> duration chips for one room
class _RoomSheet extends StatefulWidget {
  const _RoomSheet(
      {required this.anny, required this.toasts, required this.room});
  final AnnyManager anny;
  final ToastsProvider toasts;
  final AnnyRoom room;

  @override
  State<_RoomSheet> createState() => _RoomSheetState();
}

class _RoomSheetState extends State<_RoomSheet> {
  Map<DateTime, int>? _days;
  List<AnnySlot>? _slots;
  DateTime? _day;
  AnnySlot? _slot;
  int? _minutes;
  bool _error = false;
  bool _slotsError = false;
  int _slotsGen = 0;

  @override
  void initState() {
    super.initState();
    _loadDays();
  }

  int get _min => widget.room.minDuration > 0 ? widget.room.minDuration : 30;
  int get _max => widget.room.maxDuration > 0 ? widget.room.maxDuration : 300;
  int get _step => widget.room.interval > 0 ? widget.room.interval : 30;

  Future<void> _loadDays() async {
    setState(() => _error = false);
    try {
      final days = await fetchBookableDays(
          widget.anny.http, widget.room.slug, widget.room.serviceId);
      final first = days.entries
          .where((e) => e.value != 0)
          .map((e) => e.key)
          .fold<DateTime?>(null, (a, b) => a == null || b.isBefore(a) ? b : a);
      if (!mounted) return;
      setState(() {
        _days = days;
        _day = first;
        // EMPTY is a result, not a fetch failure: the grid's retry row
        // used to swallow "no bookable days" into a bare load error
        _error = false;
      });
      if (_day != null) _loadSlots(_day!);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = true);
    }
  }

  Future<void> _loadSlots(DateTime day) async {
    final int gen = ++_slotsGen; // generation guard: two quick day taps
    setState(() {
      _slots = null;
      _slot = null;
      _slotsError = false;
    });
    try {
      final slots = await fetchIntervals(
          widget.anny.http, widget.room.slug, widget.room.serviceId, day);
      if (!mounted || gen != _slotsGen) return; // reply for a discarded day
      setState(() => _slots = slots);
    } catch (_) {
      if (!mounted || gen != _slotsGen) return;
      // an EMPTY list that is really a FETCH failure used to render as
      // "Closed · —": the user could not retry a network hiccup (R21)
      setState(() {
        _slots = const [];
        _slotsError = true;
      });
    }
  }

  void _pickDay(DateTime d) {
    setState(() => _day = d);
    _loadSlots(d);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = _days?.keys.toList() ?? const [];
    days.sort();
    final slots = _slots;
    final mins = [
      for (var m = _min; m <= _max; m += _step) m,
    ];

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(pageGutter, 0, pageGutter,
            MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(L10n.t("library.roomBook", [widget.room.name]),
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: spaceXs),
              Text(
                [
                  L10n.t("library.capacity", [widget.room.quantity]),
                  if (widget.room.advanceDays > 0)
                    L10n.t("library.advanceDays", [widget.room.advanceDays]),
                ].join(" · "),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              const SizedBox(height: spaceMd),
              if (_error && _days == null)
                Row(children: [
                  Icon(Icons.cloud_off,
                      size: 20, color: theme.colorScheme.outline),
                  const SizedBox(width: spaceSm),
                  Text(L10n.t("library.loadFailed"),
                      style: theme.textTheme.bodyMedium),
                  const SizedBox(width: spaceSm),
                  CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: _loadDays,
                      child: Text(L10n.t("library.retry"))),
                ])
              else if (_days == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: spaceMd),
                  child: KITProgressIndicator(
                      semanticsLabel: L10n.t("library.title")),
                )
              else ...[
                // day strip: 1 = bookable, 0 = closed (grey, untappable)
                SizedBox(
                  height: 56,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final d in days)
                        Padding(
                          padding: const EdgeInsets.only(right: spaceSm),
                          child: ChoiceChip(
                            label: Text("${L10n.weekday(d.weekday)} "
                                "${d.day}.${d.month}"),
                            selected: _day != null &&
                                _day!.year == d.year &&
                                _day!.month == d.month &&
                                _day!.day == d.day,
                            onSelected: (_days![d] ?? 0) != 0
                                ? (_) => _pickDay(d)
                                : null,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: spaceSm),
                if (_days != null && _days!.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: spaceSm),
                    child: Text(L10n.t("library.noBookableDays"),
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.outline)),
                  )
                else if (slots == null)
                  KITProgressIndicator(semanticsLabel: L10n.t("library.title"))
                else if (slots.isEmpty && _slotsError)
                  Row(
                    children: [
                      Expanded(
                        child: Text(L10n.t("library.loadFailed"),
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.outline)),
                      ),
                      CupertinoButton(
                        padding: const EdgeInsets.all(10),
                        onPressed:
                            _day == null ? null : () => _loadSlots(_day!),
                        child: Text(L10n.t("library.retry")),
                      ),
                    ],
                  )
                else if (slots.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: spaceSm),
                    child: Text(L10n.t("library.closedOpens", ["—"]),
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.outline)),
                  )
                else
                  Wrap(
                    spacing: spaceSm,
                    runSpacing: spaceXs,
                    children: [
                      for (final AnnySlot s in slots)
                        if (s.available)
                          ChoiceChip(
                            label: Text(_hh(s.start)),
                            selected: _slot == s,
                            onSelected: (_) => setState(() => _slot = s),
                          )
                        else
                          // unavailable starts stay visible, greyed
                          Chip(
                            label: Text(_hh(s.start),
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.outline)),
                            backgroundColor:
                                theme.colorScheme.surfaceContainerHigh,
                          ),
                    ],
                  ),
                const SizedBox(height: spaceMd),
                Text(L10n.t("library.duration"),
                    style: theme.textTheme.labelLarge),
                const SizedBox(height: spaceXs),
                Wrap(
                  spacing: spaceSm,
                  runSpacing: spaceXs,
                  children: [
                    for (final m in mins)
                      ChoiceChip(
                        label: Text(m % 60 == 0 && m >= 60
                            ? L10n.t("library.durH", [m ~/ 60])
                            : L10n.t("library.durMin", [m])),
                        selected: _minutes == m,
                        onSelected: (_) => setState(() => _minutes = m),
                      ),
                  ],
                ),
                const SizedBox(height: spaceMd),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _day == null || _slot == null || _minutes == null
                        ? null
                        : _confirm,
                    child: Text(L10n.t("library.book")),
                  ),
                ),
                const SizedBox(height: spaceMd),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _hh(DateTime d) => "${d.hour.toString().padLeft(2, "0")}:"
      "${d.minute.toString().padLeft(2, "0")}";

  /// the confirm sheet: window, check-in rule, cancel deadline, names
  Future<void> _confirm() async {
    final AnnyRoom room = widget.room;
    final DateTime start = DateTime(_day!.year, _day!.month, _day!.day,
        _slot!.start.hour, _slot!.start.minute);
    final int minutes = _minutes!;
    final bool? go = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ConfirmSheet(
          anny: widget.anny,
          toasts: widget.toasts,
          room: room,
          start: start,
          minutes: minutes),
    );
    if (go == true && mounted) {
      Navigator.of(context).pop();
    } else if (go == false && mounted && _day != null) {
      // "just taken" - refetch: the slot we advertised no longer exists
      _loadSlots(_day!);
    }
  }
}

class _ConfirmSheet extends StatefulWidget {
  const _ConfirmSheet(
      {required this.anny,
      required this.toasts,
      required this.room,
      required this.start,
      required this.minutes});
  final AnnyManager anny;
  final ToastsProvider toasts;
  final AnnyRoom room;
  final DateTime start;
  final int minutes;

  @override
  State<_ConfirmSheet> createState() => _ConfirmSheetState();
}

class _ConfirmSheetState extends State<_ConfirmSheet> {
  final TextEditingController _first = TextEditingController();
  final TextEditingController _last = TextEditingController();
  String _email = "";
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.anny.checkoutIdentity().then((id) {
      if (!mounted) return;
      setState(() {
        _first.text = id.first;
        _last.text = id.last;
        _email = id.email;
      });
    });
  }

  @override
  void dispose() {
    _first.dispose();
    _last.dispose();
    super.dispose();
  }

  Future<void> _book() async {
    if (_busy) return;
    // an empty name used to reach book(), get killed by its identity
    // guard, and surface as a generic "Booking failed" (audit R21: the
    // first booking ALWAYS fails until the user guesses that the empty
    // "Nachname" field is fatal) - validate here and say so
    if (_first.text.trim().isEmpty || _last.text.trim().isEmpty) {
      widget.toasts.showTextToast(L10n.t("library.identityMissing"));
      return;
    }
    setState(() => _busy = true);
    await widget.anny.setCheckoutNames(_first.text.trim(), _last.text.trim());
    final b = await widget.anny.book(widget.room, widget.start, widget.minutes);
    if (!mounted) return;
    if (b != null) {
      Navigator.of(context).pop(true); // closes the room sheet too
      widget.toasts.showTextToast(L10n.t("library.bookedOk", [b.number]));
    } else if (widget.anny.error == AnnyErrorKind.none) {
      // just taken: this slot is gone, the sheet may not retry it — the
      // room sheet behind re-pulls the day so the grid tells the truth
      // instead of keeping a dead chip tappable (R21)
      Navigator.of(context).pop(false);
      widget.toasts.showTextToast(L10n.t("library.justTaken"));
    } else if (widget.anny.error == AnnyErrorKind.auth) {
      // the session died mid-booking; "signedIn" is false again, so the
      // page behind will show the sign-in CTA once this sheet closes
      setState(() => _busy = false);
      Navigator.of(context).pop(false);
      widget.toasts.showTextToast(L10n.t("library.signInFailed"));
    } else {
      // keep the sheet open - the user can fix the identity or retry
      setState(() => _busy = false);
      widget.toasts.showTextToast(L10n.t("library.bookingFailed"));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final end = widget.start.add(Duration(minutes: widget.minutes));
    String hh(DateTime d) => "${d.hour.toString().padLeft(2, "0")}:"
        "${d.minute.toString().padLeft(2, "0")}";
    final until = widget.room.cancelMinutesBefore > 0
        ? widget.start
            .subtract(Duration(minutes: widget.room.cancelMinutesBefore))
        : null;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(pageGutter, 0, pageGutter,
            MediaQuery.of(context).viewInsets.bottom + spaceMd),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(L10n.t("library.confirmBooking"),
                style: theme.textTheme.titleMedium),
            const SizedBox(height: spaceSm),
            Text(
                "${L10n.weekday(widget.start.weekday)}, "
                "${widget.start.day.toString().padLeft(2, "0")}."
                "${widget.start.month.toString().padLeft(2, "0")}."
                " · ${hh(widget.start)}–"
                "${hh(end)} · "
                "${widget.minutes % 60 == 0 && widget.minutes >= 60 ? L10n.t("library.durH", [widget.minutes ~/ 60]) : L10n.t("library.durMin", [widget.minutes])}",
                style: theme.textTheme.bodyMedium),
            const SizedBox(height: spaceXs),
            Text(L10n.t("library.checkinHint"),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            if (until != null) ...[
              const SizedBox(height: spaceXs),
              Text(L10n.t("library.cancelUntil", [L10n.stamp(until)]),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ],
            const SizedBox(height: spaceMd),
            Row(children: [
              Expanded(
                child: CupertinoTextField(
                  controller: _first,
                  placeholder: L10n.t("library.firstName"),
                  autocorrect: false,
                ),
              ),
              const SizedBox(width: spaceSm),
              Expanded(
                child: CupertinoTextField(
                  controller: _last,
                  placeholder: L10n.t("library.lastName"),
                  autocorrect: false,
                ),
              ),
            ]),
            if (_email.isNotEmpty) ...[
              const SizedBox(height: spaceSm),
              Text("${L10n.t("library.email")}: $_email",
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ],
            const SizedBox(height: spaceMd),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _book,
                child: _busy
                    ? KITProgressIndicator(
                        semanticsLabel: L10n.t("library.confirm"))
                    : Text(L10n.t("library.confirm")),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Signed in as …" — reads the persisted checkout identity ONCE per
/// mount (a future rebuilt every frame would re-read prefs endlessly).
class _IdentityLine extends StatefulWidget {
  const _IdentityLine({required this.anny});
  final AnnyManager anny;

  @override
  State<_IdentityLine> createState() => _IdentityLineState();
}

class _IdentityLineState extends State<_IdentityLine> {
  late final Future<({String first, String last, String email})> _id =
      widget.anny.checkoutIdentity();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
        future: _id,
        builder: (context, snap) => Text(
              L10n.t("library.signedInAs", [
                (snap.data?.first.isNotEmpty ?? false)
                    ? snap.data!.first
                    : (snap.data?.email ?? ""),
              ]),
              style: Theme.of(context).textTheme.bodyMedium,
            ));
  }
}

/// Two-field KIT sign-in dialog (same username/password layout as the
/// campus login form). The password goes only into [AnnyManager.signIn];
/// nothing about it is ever printed or stored outside the keychain.
Future<void> showLibrarySignInDialog(BuildContext context) async {
  final AnnyManager anny = context.read<KITProvider>().anny;
  final ToastsProvider toasts = context.read<ToastsProvider>();
  final theme = Theme.of(context);

  final TextEditingController user = TextEditingController();
  final TextEditingController pass = TextEditingController();

  final bool? go;
  String kitUser = "";
  String password = "";
  try {
    go = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => CupertinoAlertDialog(
        title: Text(L10n.t("library.signInTitle")),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoTextField(
              controller: user,
              placeholder: L10n.t("settings.usernamePlaceholder"),
              autocorrect: false,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: spaceSm),
            CupertinoTextField(
              controller: pass,
              placeholder: L10n.t("settings.password"),
              obscureText: true,
              keyboardType: TextInputType.visiblePassword,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
        actions: [
          CupertinoDialogAction(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: Text(L10n.t("settings.cancel"))),
          CupertinoDialogAction(
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: Text(L10n.t("settings.login"))),
        ],
      ),
    );
    kitUser = user.text.trim();
    password = pass.text;
  } finally {
    // R21: the plaintext password must not outlive the dialog inside a
    // controller the frame dropped (values are captured above first)
    pass.clear();
    user.dispose();
    pass.dispose();
  }
  if (go != true) return;
  if (kitUser.isEmpty) {
    toasts.showTextToast(L10n.t("library.userMissing"));
    return;
  }
  final bool ok = await anny.signIn(kitUser, password);
  if (!ok) toasts.showTextToast(L10n.t("library.signInFailed"));
}
