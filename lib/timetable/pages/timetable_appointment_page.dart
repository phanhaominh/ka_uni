import 'package:kit_mobile/constants/view_constants.dart';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:kit_mobile/common_ui/kit_progress_indicator.dart';
import 'package:kit_mobile/timetable/models/timetable_appointment.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:kit_mobile/geo/logic/maps_url.dart';

class TimetableAppointmentPage extends StatefulWidget {
  final TimetableAppointment appointment;

  /// Disambiguator appended to the title Hero tag: the weekly carousel
  /// renders five pages from one weekday template, so identical lunch
  /// rows share title AND id across pages and their Heroes must not fly
  /// into each other (W1 appends "_<weekday.index>" at its push site).
  final String heroSuffix;

  const TimetableAppointmentPage(
      {super.key, required this.appointment, this.heroSuffix = ""});

  @override
  State<StatefulWidget> createState() {
    return _TimetableAppointmentPageState();
  }
}

class _TimetableAppointmentPageState extends State<TimetableAppointmentPage> {
  double _draggableSheetOffset = 0;

  /// The sheet's scroll controller and its offset listener, kept as
  /// fields: the builder runs on EVERY rebuild, so a listener added
  /// there must be attached only once and removed in dispose, else one
  /// new listener accumulates per rebuild and every scroll frame fires
  /// all of them.
  ScrollController? _sheetController;
  VoidCallback? _sheetOffsetListener;

  /// R22: placeData is an ASYNC GETTER (HTTP GET of the room dataUrl +
  /// HTML parse). Passing widget.appointment.placeData inline into the
  /// FutureBuilder gave every rebuild a NEW future - and the sheet's
  /// offset listener setState fires on EVERY scroll frame, so dragging
  /// re-fetched the room page per frame and reset the map to spinner +
  /// initial camera each time. Resolve exactly once per page instance.
  late final Future<LatLng> _placeFuture = widget.appointment.placeData;

  /// The panel opens EXPANDED (details readable on arrival, no drag tax)
  /// and collapses to a peek via the header chevron or a drag. min==peek,
  /// max==initial so there is exactly one meaningful "open" height.
  static const _peekExtent = 0.28;
  static const _openExtent = 0.55;
  final DraggableScrollableController _dragCtrl =
      DraggableScrollableController();
  bool _expanded = true;

  void _toggleSheet() {
    if (!_dragCtrl.isAttached) return;
    _dragCtrl.animateTo(
      _expanded ? _peekExtent : _openExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  /// Room/building code embedded in the place string ("10.91", "30.30").
  static final _roomPattern = RegExp(r"\d{1,2}\.\d{2,4}");

  String _timeRangeLabel() {
    String two(int v) => v.toString().padLeft(2, "0");
    final b = widget.appointment.begin;
    final e = widget.appointment.end;
    return "${two(b.hour)}:${two(b.minute)} – ${two(e.hour)}:${two(e.minute)}";
  }

  /// Campus-map / room page for the appointment's place: the KIT place
  /// page the coordinates were scraped from first, the institution's own
  /// site as fallback; null when neither is known.
  String? get _placePageUrl {
    final place = widget.appointment.place;
    if (place.dataUrl.isNotEmpty) return place.dataUrl;
    if (place.url.isNotEmpty) return place.url;
    return null;
  }

  void _openPlacePage() {
    final url = _placePageUrl;
    if (url == null) return;
    launchUrl(Uri.parse(url));
  }

  /// "Route here" - hands off to Google Maps with NO origin set, so Maps
  /// starts navigation from the device's current location. Destination
  /// preference: coordinates the place already carries locally, then the
  /// same resolved point the in-app map pins; a place the map can only
  /// approximate (the dataUrl-less fallback drops the pin on the main
  /// building) must NOT be offered as a precise destination - Maps gets
  /// the search string instead and geocodes it itself.
  Future<void> _openDirections() async {
    final place = widget.appointment.place;
    final exact = place.latLngFromList ??
        (place.dataUrl.isNotEmpty ? await widget.appointment.placeData : null);
    final url = exact != null
        ? mapsDirectionsUrl(exact)
        : mapsSearchUrl(
            "${widget.appointment.displayPlace} KIT Karlsruhe".trim());
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } on Object catch (_) {
      // same posture as the course-page launcher: no Maps/browser on the
      // device is not worth interrupting the schedule view for
    }
  }

  /// The feed's URL property (W3: parsed from the VEVENT URL line, the
  /// KIT campus course page). The value arrives with the feed, so it is
  /// gated https + exact KIT host before a tap target is offered at all -
  /// the agenda's F12 launcher posture: a tampered or malformed URL must
  /// never reach the external launcher.
  Uri? get _coursePageUri {
    final raw = widget.appointment.url;
    if (raw == null || raw.isEmpty) return null;
    try {
      final uri = Uri.parse(raw);
      return uri.scheme == "https" && uri.host == "campus.studium.kit.edu"
          ? uri
          : null;
    } on Object catch (_) {
      return null;
    }
  }

  /// Error-handled launch through the gate (agenda's _launchExternal
  /// idiom): a missing or refusing browser stays a silent no-op instead
  /// of throwing inside the tap.
  void _openCoursePage() {
    final uri = _coursePageUri;
    if (uri == null) return;
    try {
      launchUrl(uri, mode: LaunchMode.externalApplication)
          .catchError((_) => false);
    } on Object catch (_) {}
  }

  @override
  void dispose() {
    final listener = _sheetOffsetListener;
    if (listener != null) {
      _sheetController?.removeListener(listener);
    }
    _dragCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mq = MediaQuery.of(context);

    return Scaffold(
      appBar: AppBar(),
      body: Stack(
        children: [
          Center(
              child: SizedBox(
            width: mq.size.width,
            height: mq.size.height,
            child: FutureBuilder(
              future: _placeFuture,
              builder: (context, snapshot) {
                if (!snapshot.hasData || snapshot.data == null) {
                  return KITProgressIndicator();
                }

                final data = snapshot.data!;

                // "Geb. 10.21, Raum 0.21" -> prefer the short room/building
                // code for the chip above the pin; fall back to the full
                // place string (ellipsis-capped) when it holds no code
                final placeText = widget.appointment.displayPlace;
                final roomLabel =
                    _roomPattern.firstMatch(placeText)?.group(0) ?? placeText;

                return FlutterMap(
                  options: MapOptions(
                    initialCenter: data,
                    initialZoom: 17,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.demidov.kaUni',
                    ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: data,
                          width: 160,
                          height: 84,
                          // topCenter parks the bottom edge (the pin tip)
                          // exactly on the location; the old 25dp shadow
                          // blob rendered ~3x larger and buried the whole
                          // building footprint
                          alignment: Alignment.topCenter,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            // the marker box is tightly 84px tall, so pack
                            // from the bottom: the pin tip then sits on the
                            // topCenter anchor point itself
                            mainAxisAlignment: MainAxisAlignment.end,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              if (roomLabel.isNotEmpty)
                                Container(
                                  constraints:
                                      const BoxConstraints(maxWidth: 150),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.surface
                                        .withValues(alpha: 0.92),
                                    borderRadius:
                                        BorderRadius.circular(chipRadiusDouble),
                                    boxShadow: const [
                                      BoxShadow(
                                          color: Colors.black26,
                                          blurRadius: 4,
                                          offset: Offset(0, 1)),
                                    ],
                                  ),
                                  child: Text(
                                    roomLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(fontWeight: FontWeight.bold),
                                  ),
                                ),
                              SizedBox(height: 2),
                              Icon(
                                Icons.location_on,
                                size: 34,
                                color: Colors.red,
                                shadows: [
                                  BoxShadow(
                                      color:
                                          Colors.black.withValues(alpha: 0.3),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    RichAttributionWidget(
                      attributions: [
                        TextSourceAttribution(
                          'OpenStreetMap contributors',
                          // R22: the legally-requested attribution tap only
                          // printed the URL to the console (analyzer even
                          // flagged the avoid_print) - open it for real
                          onTap: () => launchUrl(
                              Uri.parse('https://openstreetmap.org/copyright'),
                              mode: LaunchMode.externalApplication),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          )),
          DraggableScrollableSheet(
              controller: _dragCtrl,
              minChildSize: _peekExtent,
              initialChildSize: _openExtent,
              maxChildSize: _openExtent,
              builder: (context, controller) {
                if (_sheetOffsetListener == null) {
                  _sheetController = controller;
                  _sheetOffsetListener = () {
                    setState(() {
                      _draggableSheetOffset = controller.offset;
                    });
                  };
                  controller.addListener(_sheetOffsetListener!);
                }

                return NotificationListener<DraggableScrollableNotification>(
                  // manual drags must keep the chevron honest; the exact
                  // extent only matters as "nearer to open than to peek"
                  onNotification: (n) {
                    final open = n.extent > (_peekExtent + _openExtent) / 2;
                    if (open != _expanded) {
                      setState(() => _expanded = open);
                    }
                    return false;
                  },
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal:
                            15 * max(0, 1 - _draggableSheetOffset / 100)),
                    child: ClipRRect(
                      borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(20) *
                              max(0, 1 - _draggableSheetOffset / 100),
                          topRight: Radius.circular(20) *
                              max(0, 1 - _draggableSheetOffset / 100)),
                      child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                          child: Container(
                            // padding: EdgeInsets.all(15),
                            color: theme.colorScheme.surface
                                .withValues(alpha: 0.5),
                            child: Column(
                              children: [
                                // visible grab bar: the rounded top corner was
                                // the entire drag affordance before
                                Align(
                                  alignment: Alignment.topCenter,
                                  child: Container(
                                    width: 36,
                                    height: 4,
                                    margin: const EdgeInsets.only(top: 10),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.outlineVariant,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: ListView(
                                    controller: controller,
                                    // last row must never sit flush on the panel
                                    // edge - and the system bar is below it
                                    padding: EdgeInsets.only(
                                        bottom: spaceXl +
                                            MediaQuery.paddingOf(context)
                                                .bottom),
                                    children: [
                                      // Text("data"),
                                      Padding(
                                        padding: EdgeInsets.symmetric(
                                            horizontal: 15),
                                        child: Align(
                                          // on landscape tablets the full-width
                                          // frosted panel read as a stretched
                                          // column over dead blur; cap the content
                                          alignment: Alignment.topCenter,
                                          child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                                maxWidth: 560),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                SizedBox(height: 12),
                                                Row(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Expanded(
                                                      child: Hero(
                                                          tag:
                                                              "appointmentTitle_${widget.appointment.title}_${widget.appointment.id}${widget.heroSuffix}",
                                                          child: Text(
                                                            widget.appointment
                                                                .displayTitle,
                                                            style: theme
                                                                .textTheme
                                                                .titleLarge
                                                                ?.copyWith(
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .bold),
                                                            maxLines: 2,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          )),
                                                    ),
                                                    IconButton(
                                                      onPressed: _toggleSheet,
                                                      tooltip: L10n.t(_expanded
                                                          ? "timetable.collapseDetails"
                                                          : "timetable.expandDetails"),
                                                      icon: Icon(_expanded
                                                          ? Icons.expand_more
                                                          : Icons.expand_less),
                                                    ),
                                                  ],
                                                ),
                                                SizedBox(height: spaceLg),
                                                // WHERE first: the room and the way
                                                // there sit above the collapsed peek,
                                                // so "hide details" never hides them
                                                if (widget
                                                    .appointment
                                                    .displayPlace
                                                    .isNotEmpty) ...[
                                                  placeDetail(
                                                      L10n.t(
                                                          "timetable.placeLabel"),
                                                      widget.appointment
                                                          .displayPlace,
                                                      theme),
                                                  SizedBox(height: spaceMd),
                                                  // the CTA attaches to the room it
                                                  // routes to; the old FAB at endFloat
                                                  // ate the sheet's title instead
                                                  FilledButton.icon(
                                                    onPressed: _openDirections,
                                                    style:
                                                        FilledButton.styleFrom(
                                                      minimumSize:
                                                          const Size.fromHeight(
                                                              48),
                                                    ),
                                                    icon: const Icon(
                                                        Icons.directions),
                                                    label: Text(L10n.t(
                                                        "timetable.directions")),
                                                  ),
                                                  SizedBox(height: spaceLg),
                                                ],
                                                // empty values (lunch has no room, feed
                                                // rows often no id) would leave orphan
                                                // labels eating the column's rhythm
                                                ...(() {
                                                  final details =
                                                      <(String, String)>[
                                                    (
                                                      L10n.t(
                                                          "timetable.idLabel"),
                                                      widget.appointment.id
                                                    ),
                                                    (
                                                      L10n.t(
                                                          "timetable.timeLabel"),
                                                      _timeRangeLabel()
                                                    ),
                                                    if (widget.appointment.place
                                                        .aliasList.isNotEmpty)
                                                      (
                                                        L10n.t(
                                                            "timetable.aliasesLabel"),
                                                        widget.appointment.place
                                                            .aliasList
                                                            .join(", ")
                                                      ),
                                                  ];
                                                  final widgets = <Widget>[];
                                                  for (final (label, value)
                                                      in details) {
                                                    if (value.isEmpty) continue;
                                                    if (widgets.isNotEmpty) {
                                                      widgets.add(
                                                          const SizedBox(
                                                              height: spaceSm));
                                                    }
                                                    widgets.add(placeDetail(
                                                        label, value, theme));
                                                  }
                                                  return widgets;
                                                })(),
                                                // secondary payload, below the peek's
                                                // fold: campus-map page + course page
                                                if (_placePageUrl != null)
                                                  InkWell(
                                                    onTap: _openPlacePage,
                                                    borderRadius:
                                                        const BorderRadius.all(
                                                            Radius.circular(
                                                                12)),
                                                    child: Padding(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                          vertical: spaceMd),
                                                      child: Row(
                                                        children: [
                                                          Icon(
                                                            Icons.map_outlined,
                                                            color: theme
                                                                .colorScheme
                                                                .primary,
                                                          ),
                                                          SizedBox(width: 8),
                                                          Expanded(
                                                            child: Text(
                                                              L10n.t(
                                                                  "timetable.openCampusMap"),
                                                              style: theme
                                                                  .textTheme
                                                                  .bodyMedium
                                                                  ?.copyWith(
                                                                      color: theme
                                                                          .colorScheme
                                                                          .primary),
                                                            ),
                                                          ),
                                                          Icon(
                                                            Icons.chevron_right,
                                                            color: theme
                                                                .colorScheme
                                                                .outline,
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                if (_coursePageUri != null)
                                                  InkWell(
                                                    onTap: _openCoursePage,
                                                    borderRadius:
                                                        const BorderRadius.all(
                                                            Radius.circular(
                                                                12)),
                                                    child: Padding(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                          vertical: 10),
                                                      child: Row(
                                                        children: [
                                                          Icon(
                                                            Icons
                                                                .school_outlined,
                                                            color: theme
                                                                .colorScheme
                                                                .primary,
                                                          ),
                                                          SizedBox(width: 8),
                                                          Expanded(
                                                            child: Text(
                                                              L10n.t(
                                                                  "timetable.openCoursePage"),
                                                              style: theme
                                                                  .textTheme
                                                                  .bodyMedium
                                                                  ?.copyWith(
                                                                      color: theme
                                                                          .colorScheme
                                                                          .primary),
                                                            ),
                                                          ),
                                                          Icon(
                                                            Icons.chevron_right,
                                                            color: theme
                                                                .colorScheme
                                                                .outline,
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                SizedBox(height: 20),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          )),
                    ),
                  ),
                );
              }),
        ],
      ),
    );
  }

  Widget placeDetail(String description, String detail, ThemeData theme) {
    return Row(
      children: [
        Text(
          description,
          style:
              theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        SizedBox(
          width: spaceXs,
        ),
        // Expanded: an unbounded long ID/place used to blow up the row;
        // the detail now truncates with an ellipsis instead of clipping
        Expanded(
          child: Text(
            detail,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
