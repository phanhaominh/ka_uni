import 'package:html/dom.dart';
import 'package:html/parser.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/module/models/module.dart';
import 'package:kit_mobile/module_info_table/models/module_info_table_cell.dart';
import 'package:kit_mobile/module_info_table/models/module_info_table_type.dart';

import '../../parsing/util/remove_html_children.dart';
import 'module_info_table_row.dart';

class ModuleInfoTable {
  int numCols = 0;
  int numRows = 0;

  ModuleInfoTableType _type = ModuleInfoTableType.common;
  ModuleInfoTableType get type => _type;

  String _caption = "";
  set caption(newValue) {
    _caption = newValue;
    _type = ModuleInfoTableType.fromCaption(_caption);
  }

  String get caption => _caption;

  int get termCellIndex => colTitles.indexOf("Semester");
  int get titleCellIndex => colTitles.indexOf("Titel");

  /// Render-time caption: CampusKIT captions are German-only regardless of
  /// app language, which put 'Prüfungen (WS 26/27)' and 'Veranstaltungen'
  /// on the module page of an English UI. Map the fixed set of CampusKIT
  /// section captions onto L10n (semester suffix preserved: "Exams
  /// (WS 26/27)"); anything module-specific passes through verbatim. The
  /// data side (favorite toggles match against the live CampusKIT caption)
  /// keeps reading [caption].
  String get localisedCaption {
    final trimmed = _caption.trim();
    // every CampusKIT caption occurs BOTH bare and with a semester
    // suffix - the device showed "Veranstaltungen (WS 26/27)" while an
    // earlier capture had the bare form: the optional "(TERM)" tail must
    // be split off for ALL captions, not just Prüfungen, or the
    // German-in-English leak returns the moment KIT adds the suffix
    final m = _captionWithTerm.firstMatch(trimmed);
    final base = m?.group(1)?.trim() ?? trimmed;
    final term = m?.group(2)?.trim();
    final withTerm = term != null && term.isNotEmpty;
    switch (base) {
      case "Prüfungen":
        return withTerm
            ? L10n.t("module.sectionExamsTerm", [term])
            : L10n.t("module.sectionExams");
      case "Veranstaltungen":
        return withTerm
            ? L10n.t("module.sectionCoursesTerm", [term])
            : L10n.t("module.sectionCourses");
      case "Teilleistungen":
        return L10n.t("module.sectionMilestones");
      case "Leistungsnachweise":
        return L10n.t("module.sectionRequirements");
      case "Module":
        return L10n.t("module.sectionModules");
    }
    return trimmed;
  }

  static final _captionWithTerm = RegExp(r"^(.*?)\s*\(([^()]*)\)\s*$");

  List<String> colTitles = [];
  List<ModuleInfoTableRow> rows = [];

  bool show = true;

  late KITModule parentModule;

  String? iliasLink;
  bool hasFavoriteChild = false;

  static ModuleInfoTable? parseFromHtml(String src) {
    final document = parse(src.replaceAll("&nbsp;", " "));

    final tableNodes = document.getElementsByTagName("table");
    if (tableNodes.isEmpty) {
      return null;
    }

    final tableNode = tableNodes.first;

    final headTr = tableNode
        .getElementsByClassName("tablehead")
        .firstOrNull
        ?.getElementsByTagName("tr")
        .firstOrNull;
    if (headTr == null) {
      return null;
    }

    var table = ModuleInfoTable();

    headTr.getElementsByTagName("th").forEach((tableColTitleNode) {
      // removeHtmlChildren(tableColTitleNode);
      String text = "";
      for (var child in tableColTitleNode.children) {
        removeHtmlChildren(child);
        text += child.innerHtml;
        child.remove();
      }
      text += tableColTitleNode.innerHtml;
      text = _clearTitle(text);
      table.colTitles.add(text);
    });

    tableNode
        .getElementsByClassName("tablecontent")
        .firstOrNull
        ?.getElementsByTagName("tr")
        .forEach((trNode) {
      final row = ModuleInfoTableRow.parseFromHtml(trNode);
      // if (row.cells.length - table.colTitles.length == 1) {
      //   final lastCell = row.cells.removeAt(row.cells.length - 1);
      //   lastCell.markMeAsAddToFavorites();
      //   row.favoriteToggleCell = lastCell;
      // }
      for (int i = row.cells.length; i < table.colTitles.length; ++i) {
        row.cells.add(ModuleInfoTableCell.empty);
      }

      if (row.cells.length != table.colTitles.length) {
        return;
      }

      table._preprocessRow(row);
      table.rows.add(row);
    });

    return table;
  }

  // Clears column titles as well as table titles (captions)
  static String _clearTitle(String colTitle) {
    return colTitle.replaceAll("&nbsp;", " ").trim();
  }

  static List<ModuleInfoTable> extractAllFromHtml(String src) {
    final document = parse(src);

    List<ModuleInfoTable> tables = [];

    // Captions attach by document position: each .table-caption belongs to
    // the .table-container that follows it (cascampus templatecomponents
    // print "<h2 class=table-caption>...</h2><div class=table-container>").
    // The old length-equality pairing deserted EVERY caption as soon as one
    // container failed to parse - caption-less tables lose their exam /
    // milestone / appointment type detection and the caption-gated favorite
    // stars die on the whole module page.
    Element? pendingCaption;
    document
        .querySelectorAll(".table-caption, .table-container")
        .forEach((node) {
      if (node.classes.contains("table-caption")) {
        pendingCaption = node;
        return;
      }
      final table = parseFromHtml(node.innerHtml);
      if (table != null) {
        final caption = pendingCaption;
        if (caption != null) {
          removeHtmlChildren(caption);
          table.caption = _clearTitle(caption.innerHtml);
        }
        tables.add(table);
      }
      pendingCaption = null;
    });

    return tables;
  }

  bool removeCol({String? name, int? idx}) {
    if (idx == null) {
      if (name == null) {
        return false;
      }

      int idx0 = 0;
      for (final colTitle in colTitles) {
        if (name.toLowerCase().trim() == colTitle.toLowerCase().trim()) {
          break;
        }
        ++idx0;
      }

      idx = idx0;
    }

    if (idx < 0 || idx >= colTitles.length) {
      return false;
    }

    colTitles.removeAt(idx);
    for (var row in rows) {
      try {
        row.cells.removeAt(idx);
      } catch (exc) {}
    }

    return true;
  }

  void prepare(KITModule parentModule) {
    show = true;
    this.parentModule = parentModule;

    while (removeCol(name: "")) {
      {}
    }

    switch (caption.trim()) {
      case "Teilleistungen":
        removeCol(name: "kennung");
        removeCol(name: "status");
        show = true;
        break;
      case "Leistungsnachweise":
        removeCol(name: "");
        removeCol(name: "prüfung");
        show = true;
        break;
      case "Module":
        removeCol(name: "kennung");
        removeCol(name: "status");
        removeCol(name: "art");
        removeCol(name: "datum");
        show = true;
        break;
    }

    // CampusKIT lists every recurring lecture TWICE in the "Veranstaltungen"
    // table: once as the weekly rule line ("Do, wöchentlich 16:00 - 18:00")
    // and once per expanded single date ("Do, 05.11.2026 ...", "Do,
    // 12.11.2026 ...") - the audit saw both rows for one lecture. The
    // scraped spans carry no machine rrule/override tag (unlike the webcal
    // feed's IcsOccurrence), so group on day-of-week + time via the cell's
    // isWeeklyRule/appointmentWeekday parse: drop every dated row a rule
    // line covers, keep one-off Einzeltermine (different day or time).
    if (_type == ModuleInfoTableType.appointments) {
      final ruleKeys = <String>{};
      for (final row in rows) {
        final cell = row.appointmentCell;
        final weekday = cell?.appointmentWeekday;
        if (cell != null && cell.isWeeklyRule && weekday != null) {
          ruleKeys.add("$weekday|${_timeKey(cell.timeStr)}");
        }
      }
      if (ruleKeys.isNotEmpty) {
        rows.removeWhere((row) {
          final cell = row.appointmentCell;
          final weekday = cell?.appointmentWeekday;
          return cell != null &&
              !cell.isWeeklyRule &&
              weekday != null &&
              ruleKeys.contains("$weekday|${_timeKey(cell.timeStr)}");
        });
      }
    }
  }

  static String _timeKey(String timeStr) =>
      timeStr.replaceAll(RegExp(r"\s+"), " ").trim().toLowerCase();

  // called after the row is parsed and has finished all its internal processing
  // before adding it to the rows list of the table
  void _preprocessRow(ModuleInfoTableRow row) {
    iliasLink ??= row.iliasLink;
    hasFavoriteChild |= row.hasFavoriteChild;
  }
}
