import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:kit_mobile/common_ui/kit_progress_indicator.dart';
import 'package:kit_mobile/timetable/models/timetable_appointment.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:url_launcher/url_launcher.dart';

class TimetableAppointmentPage extends StatefulWidget {
  final TimetableAppointment appointment;

  const TimetableAppointmentPage({super.key, required this.appointment});

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
                                    borderRadius: BorderRadius.circular(9),
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
                                            "appointmentTitle_${widget.appointment.title}_${widget.appointment.id}",
                                        child: Text(
                                          widget.appointment.displayTitle,
                                          style: theme.textTheme.titleLarge
                                              ?.copyWith(
                                                  fontWeight: FontWeight.bold),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        )),
                                    SizedBox(height: 20),
                                    placeDetail(
                                        "ID:", widget.appointment.id, theme),
                                    placeDetail("Ort:",
                                        widget.appointment.displayPlace, theme),
                                    placeDetail(L10n.t("timetable.timeLabel"),
                                        _timeRangeLabel(), theme),
                                    if (widget
                                        .appointment.place.aliasList.isNotEmpty)
                                      placeDetail(
                                          L10n.t("timetable.aliasesLabel"),
                                          widget
                                              .appointment.place.aliasList
                                              .join(", "),
                                          theme),
                                    SizedBox(height: 20),
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
                                              vertical: 10),
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
          // ClipRRect(
          //   child: BackdropFilter(
          //     filter: ImageFilter.blur(
          //       sigmaX: 10,
          //       sigmaY: 10,
          //     ),
          //     child: Container(
          //       color: theme.colorScheme.surface.withValues(alpha: 0.5),
          //       child: SafeArea(
          //         bottom: false,
          //         child:
          //         Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          //           CupertinoButton(
          //             padding: EdgeInsets.zero,
          //             // color: Colors.amber,
          //             child: Icon(Icons.arrow_back_ios_rounded),
          //             onPressed: () {
          //               Navigator.of(context).maybePop();
          //             },
          //           )
          //         ]),
          //       ),
          //     ),
          //   ),
          // )
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
          width: 5,
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
