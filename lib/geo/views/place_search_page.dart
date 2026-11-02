import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../agenda/logic/walk_hint.dart';
import '../../l10n/l10n.dart';
import '../../state_management/kit_provider.dart';
import '../logic/place_search.dart';
import '../models/kit_place.dart';
import '../network/KITTopographyManager.dart';

/// Raum-Finder: Cupertino-styled search over the 824 live campus places
/// (data_de.js, 2026-11) the app already downloads for walk hints
/// (KITTopographyManager). Type
/// "20.30", "Audimax" or "Mensa" and see what/where it is - tapping a row
/// expands it in place, there is deliberately no second detail page, no
/// map and no location permission.
class PlaceSearchPage extends StatefulWidget {
  const PlaceSearchPage({super.key, this.initialQuery = "", this.fromRoom});

  /// Pre-filled query; the agenda pushes the room label here.
  final String initialQuery;

  /// Room string whose place anchors the "≈ x km von …" distance line;
  /// set when pushed from an agenda row. Null = no distance anywhere.
  final String? fromRoom;

  @override
  State<PlaceSearchPage> createState() => _PlaceSearchPageState();
}

class _PlaceSearchPageState extends State<PlaceSearchPage> {
  late final TextEditingController _controller;
  // F3: ranking costs 16-22 ms for multi-token rooms over the 824 live
  // places, so keystrokes arm this timer instead of ranking inline
  Timer? _debounce;
  // F10: false until the first load finished; gates the no-results view
  bool _loaded = false;
  List<KITPlace> _places = const [];
  KITPlace? _refPlace;
  List<PlaceMatch> _results = const [];
  // C92: true while the 200 ms settle timer for the newest keystroke is
  // still running - `_results` then belong to the PREVIOUS query and are
  // rendered dim instead of lingering looking current
  bool _staleResults = false;
  String? _expandedKey;

  // (localized label key, German query): the directory itself is German
  // (data_de.js), so an English "Library" chip still searches "Bibliothek"
  static const _quickChips = [
    ("places.quickAudimax", "Audimax"),
    ("places.quickMensa", "Mensa"),
    ("places.quickLibrary", "Bibliothek"),
    ("places.quickSport", "Sport"),
  ];

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
    // F3: the prefs read, the initial rank and resolveRoomPlace
    // (6-8 ms together) must not block the route push - run them after
    // the first frame
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPlaces());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadPlaces() async {
    final manager = context.read<KITProvider>().topographyManager;
    var places = manager.places;
    if (places.isEmpty) {
      // cold start: the live fetch is still in flight or the device is
      // offline - stale-OK results beat an empty page, data_de.js changes
      // rarely (KIT restructures the campus directory about as often as
      // buildings get demolished)
      places = (await KITTopographyManager.loadSnapshot()) ?? const [];
    }
    if (!mounted) return;
    setState(() {
      _places = places;
      _refPlace = widget.fromRoom == null
          ? null
          : resolveRoomPlace(places, widget.fromRoom!);
      _loaded = true;
      _search();
    });
  }

  /// Recompute results from the current field text; relevance only, never
  /// distance-sorted.
  void _search() {
    _results = rankPlaces(_places, _controller.text, from: _refPlace);
    _staleResults = false;
  }

  /// Keystrokes only cancel/restart a 200 ms settle timer around the
  /// rank (F3: 16-22 ms per full rank > frame budget), so rapid typing
  /// triggers exactly ONE ranking. Everything the user touches directly
  /// stays instant: the field text is controller-driven, and this
  /// immediate setState keeps the clear button and the empty-query view
  /// live; quick chips seed the field through the very same path.
  void _onChanged() {
    _debounce?.cancel();
    setState(() {
      _expandedKey = null;
      _staleResults = true;
    });
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(_search);
    });
  }

  void _useChipQuery(String query) {
    _controller.text = query;
    _onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L10n.t("places.title"))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: CupertinoTextField(
              controller: _controller,
              placeholder: L10n.t("places.searchPlaceholder"),
              autofocus: true,
              clearButtonMode: OverlayVisibilityMode.editing,
              prefix: const Padding(
                padding: EdgeInsets.only(left: 8, right: 4),
                child: Icon(CupertinoIcons.search, size: 17),
              ),
              onChanged: (_) => _onChanged(),
            ),
          ),
          Expanded(
            child: _controller.text.trim().isEmpty
                ? _emptyQuery(context)
                : !_loaded
                    // F10: the snapshot prefs read is still pending;
                    // rendering the (still empty) _results here flashed
                    // "Keine Treffer" for 1-3 frames on a cold start
                    ? const SizedBox.shrink()
                    : _results.isEmpty
                        ? _noResults(context)
                        : AnimatedOpacity(
                            // C92: previous-keystroke results stay
                            // readable but visibly dim while the new rank
                            // debounces - never a blank flash, and a tap
                            // on them is still a valid (slightly old) hit
                            duration: const Duration(milliseconds: 120),
                            opacity: _staleResults ? 0.45 : 1,
                            child: ListView.builder(
                              itemCount: _results.length,
                              itemBuilder: (context, i) =>
                                  _resultRow(_results[i]),
                            ),
                          ),
          ),
        ],
      ),
    );
  }

  Widget _emptyQuery(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              L10n.t("places.emptyHint"),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.outline),
            ),
            const SizedBox(height: 20),
            Text(L10n.t("places.quick"),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: scheme.outline)),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (labelKey, query) in _quickChips)
                  _chip(context, L10n.t(labelKey), query),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, String label, String query) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _useChipQuery(query),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(label,
              style: TextStyle(
                  fontSize: 13, color: scheme.onSecondaryContainer)),
        ),
      ),
    );
  }

  Widget _noResults(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(L10n.t("places.noResults"),
              style: TextStyle(fontSize: 13, color: scheme.outline)),
          const SizedBox(height: 6),
          // F8: a dead end should point at the next step, and the single
          // most common miss is typing a whole room label for a place
          // the directory only knows by building number
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(L10n.t("places.noResultsHint"),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: scheme.outline)),
          ),
        ],
      ),
    );
  }

  String _keyOf(KITPlace p) => p.id.isNotEmpty ? p.id : p.title;

  /// The live directory (data_de.js, 2026-11) ships exactly these four
  /// category codes; anything else (legacy exports' "Mensa & Cafeteria")
  /// renders raw, an empty code renders nothing (F6).
  static const _categoryL10nKeys = {
    "building": "places.categoryBuilding",
    "institute": "places.categoryInstitute",
    "facility": "places.categoryFacility",
    "lecturehall": "places.categoryLecturehall",
  };

  String _categoryLabel(String code) {
    final key = _categoryL10nKeys[code.toLowerCase()];
    return key == null ? code : L10n.t(key);
  }

  Widget _resultRow(PlaceMatch m) {
    final p = m.place;
    final scheme = Theme.of(context).colorScheme;
    final expanded = _expandedKey == _keyOf(p);
    // "auch: …" hint only when an alias - not the title itself - matched
    final aliasHint = m.matchedAlias != null && m.matchedAlias != p.title;
    final distance = m.distanceMeters == null
        ? null
        : L10n.t("places.distanceFrom", [
            formatCampusDistance(m.distanceMeters!),
            _refPlace!.title,
          ]);
    final website = _launchableUrl(p);
    return InkWell(
      // expand-in-place; the alternative (a second detail page) was
      // explicitly dropped
      onTap: () =>
          setState(() => _expandedKey = expanded ? null : _keyOf(p)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(p.title, style: const TextStyle(fontSize: 15)),
            if (p.category.isNotEmpty)
              Text(_categoryLabel(p.category),
                  style: TextStyle(fontSize: 12, color: scheme.outline)),
            if (aliasHint)
              Text(L10n.t("places.aliasPrefix", [m.matchedAlias!]),
                  style: TextStyle(fontSize: 12, color: scheme.outline)),
            if (distance != null)
              Text(distance,
                  style: TextStyle(fontSize: 12, color: scheme.outline)),
            if (expanded) ...[
              const SizedBox(height: 4),
              // the collapsed row already shows category + distance; the
              // details add the full alias list and the institution link
              if (p.aliasList.isNotEmpty)
                Text(
                    "${L10n.t("places.aliases")}: ${p.aliasList.join(", ")}",
                    style: TextStyle(fontSize: 12, color: scheme.outline)),
              if (website != null) _websiteRow(website, scheme),
            ],
          ],
        ),
      ),
    );
  }

  /// Parses the payload URL EXACTLY ONCE and only accepts a URL that
  /// can actually be launched (F12): the old code kept the button even
  /// when the host failed to parse, then re-parsed inside onPressed -
  /// where the same throw (or a non-http scheme like mailto:/javascript:
  /// sneaking into the payload) left a permanently dead button.
  Uri? _launchableUrl(KITPlace p) {
    if (p.url.isEmpty) return null;
    try {
      final uri = Uri.parse(p.url);
      return uri.host.isNotEmpty &&
              (uri.scheme == "http" || uri.scheme == "https")
          ? uri
          : null;
    } on Object catch (_) {
      // unparsable url in the KIT payload: render nothing, not a dead end
      return null;
    }
  }

  Widget _websiteRow(Uri uri, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(uri.host,
            style: TextStyle(fontSize: 12, color: scheme.outline)),
        CupertinoButton(
          padding: const EdgeInsets.only(top: 2),
          minimumSize: Size.zero,
          onPressed: () =>
              launchUrl(uri, mode: LaunchMode.externalApplication),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(CupertinoIcons.link, size: 14, color: scheme.primary),
              const SizedBox(width: 6),
              Text(L10n.t("places.website"),
                  style: TextStyle(fontSize: 13, color: scheme.primary)),
            ],
          ),
        ),
      ],
    );
  }
}
