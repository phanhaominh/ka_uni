import 'package:flutter/material.dart';

import '../common_ui/max_width_body.dart';
import '../l10n/l10n.dart';
import '../state_management/campus/campus_manager.dart';
import 'fristenbuch.dart';

/// R34.1 FRISTENBUCH editor: the full-screen page behind
/// Settings → Setup → "Fristenbuch". List + add + delete — deliberately
/// NO edit affordance: delete + re-add keeps the state machine at two
/// shapes (present/absent) and the deterministic emitter handles the rest
/// (an edit would only re-derive what re-add derives, at twice the states).
///
/// The page is the layer's OWNER: every commit writes the store
/// (DATA_fristenbuch, logout-swept) and runs the owner re-apply into the
/// merged ICS cache ([CampusManager.reapplyFrB]) — so agenda rows, the
/// cockpit countdown, morning digest, T−30 reminders and the ICS export
/// all see a hand-noted deadline the instant it is noted, through the
/// same pipeline a scraped one takes.
///
/// Provenance: the coverage header and every row's "noted by me" chip
/// carry the honesty line — these are the student's own notes, never
/// scraped KIT truth, and the UI never lets them look otherwise.
class FristenbuchPage extends StatefulWidget {
  const FristenbuchPage({super.key, required this.manager});

  static const routeName = "/fristenbuch";

  /// the live manager whose [CampusManager.reapplyFrB] projects the block
  /// into the merged cache (settings passes its `vm.campusManager`)
  final CampusManager manager;

  @override
  State<FristenbuchPage> createState() => _FristenbuchPageState();
}

class _FristenbuchPageState extends State<FristenbuchPage> {
  List<FristenbuchEntry> _entries = const [];
  bool _loading = true;

  // One load on init, no re-reads: the editor page is the ONLY writer of
  // the store (the poll carries the derived block, never the book), and
  // logout - the one event that empties it under the page - tears the
  // whole navigator shell down to the login form anyway.
  @override
  void initState() {
    super.initState();
    loadFristenbuchEntries().then((e) {
      if (!mounted) return;
      setState(() {
        _entries = e;
        _loading = false;
      });
    });
  }

  /// the one commit path: store first, then the owner re-apply. Ordering
  /// matters — the cache may never carry a block the store did not
  /// survive (a crash between the two writes rebuilds from the store on
  /// next fetch, the F-2 projection union keeps the cache's copy visible
  /// until then; never the other way round).
  Future<void> _persist(List<FristenbuchEntry> next) async {
    await saveFristenbuchEntries(next);
    await widget.manager.reapplyFrB(buildFristenbuchBlock(next));
    if (!mounted) return;
    setState(() => _entries = next);
  }

  Future<void> _add() async {
    final draft = await showDialog<_FristenbuchDraft>(
        context: context, builder: (_) => const _FristenbuchDialog());
    if (draft == null) return;
    await _persist([..._entries,
      FristenbuchEntry(
          id: fristenbuchNextId(_entries),
          label: draft.label,
          due: draft.due,
          note: draft.note.isEmpty ? null : draft.note)
    ]);
  }

  Future<void> _delete(FristenbuchEntry e) =>
      _persist(_entries.where((o) => o.id != e.id).toList());

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sorted = [..._entries]
      ..sort((a, b) {
        final d = DateTime(a.due.year, a.due.month, a.due.day)
            .compareTo(DateTime(b.due.year, b.due.month, b.due.day));
        return d != 0 ? d : a.id.compareTo(b.id);
      });
    return Scaffold(
      appBar: AppBar(title: Text(L10n.t("timetable.frbTitle"))),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey("frbAdd"),
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: Text(L10n.t("timetable.frbAdd")),
      ),
      body: MaxWidthBody(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Icon(Icons.info_outline, size: 16, color: scheme.outline),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(L10n.t("timetable.frbCoverage"),
                        style:
                            TextStyle(fontSize: 12, color: scheme.outline)),
                  ),
                ]),
              ),
            ),
            if (_loading)
              const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()))
            else if (sorted.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(L10n.t("timetable.frbEmpty"),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.outline)),
              )
            else
              for (final e in sorted) _tile(context, e),
          ],
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, FristenbuchEntry e) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        leading: Text(_date(e.due),
            style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w600)),
        title: Text(e.label),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (e.note != null) Text(e.note!),
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8)),
              child: Text(L10n.t("timetable.frbYou"),
                  style: TextStyle(
                      fontSize: 10, color: scheme.onSurfaceVariant)),
            ),
          ],
        ),
        isThreeLine: e.note != null,
        trailing: IconButton(
          key: ValueKey("frbDelete-${e.id}"),
          icon: const Icon(Icons.delete_outline),
          tooltip: L10n.t("timetable.frbDelete"),
          onPressed: () => _delete(e),
        ),
      ),
    );
  }

  static String _date(DateTime d) =>
      "${d.day.toString().padLeft(2, "0")}."
      "${d.month.toString().padLeft(2, "0")}."
      "${d.year}";
}

class _FristenbuchDraft {
  final String label;
  final DateTime due;
  final String note;
  const _FristenbuchDraft(this.label, this.due, this.note);
}

class _FristenbuchDialog extends StatefulWidget {
  const _FristenbuchDialog();

  @override
  State<_FristenbuchDialog> createState() => _FristenbuchDialogState();
}

class _FristenbuchDialogState extends State<_FristenbuchDialog> {
  final _label = TextEditingController();
  final _note = TextEditingController();
  DateTime? _due;

  @override
  void dispose() {
    _label.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      // a noted deadline is nearly always future; pre-selecting today+14
      // saves taps without ever FORBIDING a past or far date
      initialDate: _due ?? DateTime(now.year, now.month, now.day + 14),
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 6),
    );
    if (picked != null) setState(() => _due = picked);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(L10n.t("timetable.frbNew")),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey("frbLabel"),
            controller: _label,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration:
                InputDecoration(hintText: L10n.t("timetable.frbLabelHint")),
            onChanged: (_) => setState(() {}),
          ),
          Row(
            children: [
              Text(L10n.t("timetable.frbDate")),
              const SizedBox(width: 12),
              TextButton(
                key: const ValueKey("frbDate"),
                onPressed: _pickDate,
                child: Text(_due == null
                    ? "—"
                    : "${_due!.day.toString().padLeft(2, "0")}."
                        "${_due!.month.toString().padLeft(2, "0")}."
                        "${_due!.year}"),
              ),
            ],
          ),
          TextField(
            key: const ValueKey("frbNote"),
            controller: _note,
            textCapitalization: TextCapitalization.sentences,
            decoration:
                InputDecoration(hintText: L10n.t("timetable.frbNoteHint")),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(L10n.t("settings.cancel"))),
        TextButton(
          key: const ValueKey("frbSave"),
          onPressed: _label.text.trim().isEmpty || _due == null
              ? null
              : () => Navigator.of(context).pop(
                  _FristenbuchDraft(
                      _label.text.trim(), _due!, _note.text.trim())),
          child: Text(L10n.t("timetable.frbSave")),
        ),
      ],
    );
  }
}
