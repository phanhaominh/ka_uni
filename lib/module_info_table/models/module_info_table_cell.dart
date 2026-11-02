import 'package:html/dom.dart';
import 'package:kit_mobile/parsing/util/remove_html_children.dart';

class ModuleInfoTableCell {
  String body = "";
  String link = "";
  final Element? node;

  String dateStr = "";
  String timeStr = "";

  bool doesToggleFavorite = false;
  bool isFavorite = false;

  // technical string encoding the corresponding action, for example
  // 0x961185545DD745ADB71707170D9472E1 as "remove that subject from favorites"
  String objectValue = "";

  ModuleInfoTableCell({this.node});

  static ModuleInfoTableCell parseFromHtml(Element node) {
    ModuleInfoTableCell cell = ModuleInfoTableCell(node: node.clone(true));
    
    final spans = node.getElementsByTagName("span");
    final links = node.getElementsByTagName("a");
    final buttons = node.getElementsByTagName("button");
    
    for (final spanElement in spans) {
      if (spanElement.classes.contains("date")) {
        removeHtmlChildren(spanElement);
        cell.dateStr = spanElement.innerHtml.trim();
      } else if (spanElement.classes.contains("time")) {
        removeHtmlChildren(spanElement);
        cell.timeStr = spanElement.innerHtml.trim();
      }
    }

    for (final buttonNode in buttons) {
      if (buttonNode.attributes.containsKey("name") && buttonNode.attributes["name"]!.toLowerCase().contains("eventfavorite")) {
        cell.markMeAsAddToFavorites();
      }
    }

    // if (cell.dateStr.isNotEmpty) {
    //   if (kDebugMode) {
    //     print(cell.dateStr);
    //     print(cell.timeStr);
    //   }
    // }

    if (links.isEmpty) {
      removeHtmlChildren(node);
      cell.body = node.innerHtml;
      return cell;
    } else {
      final link = links.first;
      cell.link = link.attributes["href"] ?? "";
      removeHtmlChildren(link);
      cell.body = link.innerHtml;
    }

    removeHtmlChildren(node);
    cell.body += " ${node.innerHtml}";
    return cell;
  }

  void markMeAsAddToFavorites() {
    if (node == null) {
      return;
    }

    final button = node!.getElementsByTagName("button").firstOrNull;
    if (button == null) {
      return;
    }

    final buttonName = button.attributes["name"];
    if (buttonName == null) {
      return;
    }

    final buttonValue = button.attributes["value"];
    if (buttonValue == null) {
      return;
    }

    isFavorite = buttonName.contains("remove");
    doesToggleFavorite = true;
    objectValue = buttonValue;
  }

  bool get isAppointment {
    return dateStr.isNotEmpty && timeStr.isNotEmpty;
  }

  /// Only a real https ILIAS URL may be hoisted as the course's ILIAS
  /// link: mirrors the host gate of CampusManager's manual-attach
  /// validator (_requireIliasUrl is private, so the check is duplicated
  /// deliberately). Before this, ANY href merely containing "ilias" -
  /// e.g. a CampusKIT link with ilias in a query param - became the
  /// module page's ILIAS button target: an open redirect that opens
  /// inside the session-carrying ILIAS webview.
  bool get hasIliasLink {
    const host = "ilias.studium.kit.edu";
    final uri = Uri.tryParse(link);
    if (uri == null) return false;
    final lowerHost = uri.host.toLowerCase();
    return uri.scheme == "https" &&
        (lowerHost == host || lowerHost.endsWith(".$host"));
  }

  static ModuleInfoTableCell get empty {
    return ModuleInfoTableCell();
  }

}