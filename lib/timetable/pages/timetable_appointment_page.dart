import 'package:kit_mobile/constants/view_constants.dart';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
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
        (place.dataUrl.isNotEmpty
            ? await widget.appointment.placeData
            : null);
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mq = MediaQuery.of(context);

    return Scaffold(
      appBar: AppBar(),
      // an online lecture has no place to walk to: no button
      floatingActionButton: widget.appointment.displayPlace.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openDirections(),
              icon: const Icon(Icons.directions),
              label: Text(L10n.t("timetable.directions")),
            ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: Stack(
        children: [
          Center(
              child: SizedBox(
            width: mq.size.width,
            height: mq.size.height,
            child: FutureBuilder(
              future: widget.appointment.placeData,
              builder: (context, snapshot) {
                if (!snapshot.hasData || snapshot.data == null) {
                  return KITProgressIndicator();
                }

                final data = snapshot.data!;

                // "Geb. 10.21, Raum 0.21" -> prefer the short room/building
                // code for the chip above the pin; fall back to the full
                // place string (ellipsis-capped) when it holds no code
                final placeText = widget.appointment.displayPlace;
                final roomLabel = _roomPattern.firstMatch(placeText)?.group(0) ??
                    placeText;

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
                                        ?.copyWith(
                                            fontWeight: FontWeight.bold),
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
                          onTap: () => print(
                              Uri.parse('https://openstreetmap.org/copyright')),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          )),
          DraggableScrollableSheet(
              minChildSize: 0.15,
              initialChildSize: 0.2,
              maxChildSize: 0.4,
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

                return Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: 15 * max(0, 1 - _draggableSheetOffset / 100)),
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
                          color:
                              theme.colorScheme.surface.withValues(alpha: 0.5),
                          child: ListView(
                            controller: controller,
                            // last row must never sit flush on the panel
                            // edge - and the system bar is below it
                            padding: EdgeInsets.only(
                                bottom: spaceXl +
                                    MediaQuery.paddingOf(context).bottom),
                            children: [
                              // Text("data"),
                              Padding(
                                padding: EdgeInsets.symmetric(horizontal: 15),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(height: 15,),
                                    Hero(
                                        tag:
                                            "appointmentTitle_${widget.appointment.title}_${widget.appointment.id}${widget.heroSuffix}",
                                        child: Text(
                                          widget.appointment.displayTitle,
                                          style: theme.textTheme.titleLarge
                                              ?.copyWith(
                                                  fontWeight: FontWeight.bold),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        )),
                                    SizedBox(height: spaceLg),
                                    // empty values (lunch has no room, feed
                                    // rows often no id) would leave orphan
                                    // labels eating the column's rhythm
                                    ...(() {
                                      final details = <(String, String)>[
                                        (L10n.t("timetable.idLabel"),
                                            widget.appointment.id),
                                        (L10n.t("timetable.placeLabel"),
                                            widget.appointment.displayPlace),
                                        (L10n.t("timetable.timeLabel"),
                                            _timeRangeLabel()),
                                        if (widget.appointment.place.aliasList
                                            .isNotEmpty)
                                          (L10n.t("timetable.aliasesLabel"),
                                              widget
                                                  .appointment.place.aliasList
                                                  .join(", ")),
                                      ];
                                      final widgets = <Widget>[];
                                      for (final (label, value) in details) {
                                        if (value.isEmpty) continue;
                                        if (widgets.isNotEmpty) {
                                          widgets.add(
                                              const SizedBox(height: spaceSm));
                                        }
                                        widgets.add(
                                            placeDetail(label, value, theme));
                                      }
                                      return widgets;
                                    })(),
                                    SizedBox(height: spaceXl),
                                    // the real payload of the expanded state:
                                    // a jump to the KIT campus-map / room
                                    // page. The old trailing 500px spacer is
                                    // gone - it scrolled the title and the
                                    // ID/Ort rows off-screen and left an
                                    // empty blur panel; minChildSize already
                                    // provides the drag handle.
                                    if (_placePageUrl != null)
                                      InkWell(
                                        onTap: _openPlacePage,
                                        borderRadius: const BorderRadius.all(
                                            Radius.circular(12)),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: spaceMd),
                                          child: Row(
                                            children: [
                                              Icon(
                                                Icons.map_outlined,
                                                color:
                                                    theme.colorScheme.primary,
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
                                        borderRadius: const BorderRadius.all(
                                            Radius.circular(12)),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 10),
                                          child: Row(
                                            children: [
                                              Icon(
                                                Icons.school_outlined,
                                                color:
                                                    theme.colorScheme.primary,
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
                              )
                            ],
                          ),
                        )),
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
