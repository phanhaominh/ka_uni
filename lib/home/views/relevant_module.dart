import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:kit_mobile/common_ui/block_container.dart';
import 'package:kit_mobile/ilias/views/ilias_page_view.dart';
import 'package:kit_mobile/module/models/module.dart';
import 'package:kit_mobile/parsing/models/hierarchic_table_row.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:provider/provider.dart';

import '../../module/views/module_page.dart';
import '../../utils/string_prettifiers.dart';

class RelevantModuleView extends StatelessWidget {
  final KITModule module;

  const RelevantModuleView({super.key, required this.module});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vm = Provider.of<KITProvider>(context);

    return Stack(
      children: [
        BlockContainer(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                SizedBox(
                  width: 110,
                  child: Text(sanitizeModuleTitle(module.title), maxLines: 3, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),),
                ),


                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    CupertinoButton(
                        padding: EdgeInsets.zero,
                        child: Icon(CupertinoIcons.info_circle),
                        onPressed: () async {
                          final moduleToShow = _getModuleToShow(vm);
                          Navigator.of(context).push(MaterialPageRoute(builder: (BuildContext context) => ModuleView(module: moduleToShow)));
                        }
                    ),

                    // feed-admitted modules may legitimately have no
                    // ILIAS course ("Advanced Mathematics I"): hide the
                    // button instead of opening a dashboard detour
                    // (module_page.dart gates identically; IliasPageView
                    // itself would only fall back to the dashboard)
                    (module.iliasLink == null || module.iliasLink!.isEmpty)
                        ? Text("")
                        : CupertinoButton(
                      padding: EdgeInsets.zero,
                      child: Text("ILIAS"),
                      onPressed: () async {
                        // await vm.iliasManager.authorize();
                        final moduleToShow = await _getModuleToShow(vm);
                        // module lookup is a network round-trip; the card
                        // can be gone (tab switch rebuild) by the time it
                        // completes -> pushing on a dead context throws
                        if (!context.mounted) return;
                        Navigator.of(context).push(MaterialPageRoute(builder: (BuildContext context) => IliasPageView(moduleToShow, PHPSESSID_Future: vm.iliasManager.getPHPSESSID())));
                      },

                    ),

                  ],
                )


              ],
            )
        ),

        Opacity(
          opacity: 1,
          child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                module.hasFavoriteChild ? Padding(
                  padding: EdgeInsets.all(3),
                  // width: 20,
                  // height: 20,
                  child: BlockContainer(
                    padding: EdgeInsets.zero,
                    opacity: 0.8,
                    child: Padding(padding: EdgeInsets.all(0), child: Icon(Icons.star, color: theme.colorScheme.primary, size: 15,),) ,
                  )
                ) : Text("")
              ],
            )
        )
      ],
    );
  }

  Future<KITModule> _getModuleToShow(KITProvider vm) async {
    Future<KITModule> moduleToShow = Future.value(module);
    // placeholder card (row not fetched yet, no row data): resolve it by
    // the stored row id with an EXACT match - the prettified title is not
    // a substring of the raw "level_title_year" id, and a contains() test
    // on short titles could bind a different row's module
    if (module.row == null) {
      HierarchicTableRow? rowToShow;
      for (final row in vm.campusManager.moduleRows) {
        if (module.hierarchicalTableRowId.isNotEmpty
            ? row.id == module.hierarchicalTableRowId
            : row.id.contains(module.title)) {
          rowToShow = row;
          break;
        }
      }
      if (rowToShow == null) {
        return moduleToShow;
      }
      moduleToShow = vm.getOrFetchModuleForRow(rowToShow);
    }

    return moduleToShow;
  }



}