import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:kit_mobile/common_ui/block_container.dart';
import 'package:kit_mobile/common_ui/kit_progress_indicator.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/module_info_table/views/module_info_table_view.dart';
import 'package:kit_mobile/utils/date_time_utils.dart';
import 'package:provider/provider.dart';

import '../../ilias/views/ilias_page_view.dart';
import '../../state_management/kit_provider.dart';
import '../../toasts/models/toasts_provider.dart';
import '../models/module.dart';

class ModuleView extends StatefulWidget {
  final Future<KITModule> module;

  const ModuleView({super.key, required this.module});

  @override
  State<StatefulWidget> createState() {
    return _ModuleViewState();
  }

}

class _ModuleViewState extends State<ModuleView> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vm = Provider.of<KITProvider>(context);

    return FutureBuilder(
      future: widget.module,
      builder: (BuildContext context, AsyncSnapshot<KITModule> moduleSnapshot) {
        if (moduleSnapshot.hasError) {
          // the info button hands the fetch future straight to this page
          // without awaiting it: without an error branch a dead network
          // left the spinner turning forever and the rejection surfaced
          // nowhere (the ILIAS button beside it mounted-guards for years)
          return Scaffold(
            appBar: AppBar(
              title: Text(L10n.t("module.title"), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.normal),),
            ),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(L10n.t("module.loadError"), textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),),
              ),
            ),
          );
        }

        if (!moduleSnapshot.hasData || moduleSnapshot.data == null) {
          return Scaffold(
            appBar: AppBar(
              title: Text(L10n.t("module.title"), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.normal),),
            ),
            body: const Center(
              child: KITProgressIndicator(),
            ),
          );
        }

        final module = moduleSnapshot.data!;

        final double iconDescriptionPadding = 2;

        final moduleFormattedGrade = _formatGrade(module.grade);

        return Scaffold(
          appBar: AppBar(
            title: Text(L10n.t("module.title"), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.normal),),
            actions: [
              (module.iliasLink != null && module.iliasLink!.isNotEmpty) ? CupertinoButton(child: Text("ILIAS"), onPressed: () {
                Navigator.of(context).push(MaterialPageRoute(builder: (BuildContext context) => IliasPageView(module, PHPSESSID_Future: vm.iliasManager.getPHPSESSID())));
                // print(module.iliasLink);
                // Navigator.of(context).push(MaterialPageRoute(builder: (BuildContext context) => IliasPageView(module)));
                // FlutterWebBrowser.openWebPage(url: module.iliasLink!);
              } ) : CupertinoButton(
                  child: Text(L10n.t("settings.moduleAttachIlias")),
                  onPressed: () => _attachIliasLink(module),
              )
            ],
          ),
          body: Padding(
            padding: EdgeInsets.symmetric(horizontal: 15),
            child: ListView(
              // crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Padding(padding: EdgeInsets.only(top: 15),),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: MediaQuery.of(context).size.width * 0.85,
                      child: Text(module.title, style: theme.textTheme.headlineMedium, maxLines: 5,),
                    ),
                    // Icon(CupertinoIcons.star)
                  ],
                ),

                Padding(padding: EdgeInsets.only(top: 20)),

                Container(
                  padding: EdgeInsets.only(left: 15),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(module.id),
                      if (module.lastUpdated.millisecondsSinceEpoch > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            L10n.t("module.lastUpdated", [formatHumanReadableTimestamp(module.lastUpdated)]),
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.outline),
                          ),
                        ),
                    ],
                  ),
                ),

                BlockContainer(
                  child: Column(
                    children: [

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.start,
                            children: [
                              Icon(module.isUpcoming ? CupertinoIcons.clock : (module.examDateKnown ? CupertinoIcons.check_mark_circled : CupertinoIcons.question_circle), color: module.examDateKnown ? theme.colorScheme.primary : theme.disabledColor,),
                              Padding(padding: EdgeInsets.all(iconDescriptionPadding),),
                              Text(module.timeAxisPositionString,) // style: theme.textTheme.bodyMedium?.copyWith(color: module.examDateKnown ? theme.colorScheme.primary : theme.disabledColor),)
                            ],
                          ),

                          !module.examDateKnown ? Text("") : Row(
                            mainAxisAlignment: MainAxisAlignment.start,
                            children: [
                              Icon(CupertinoIcons.calendar_circle, color: module.examDateKnown ? theme.colorScheme.primary : theme.disabledColor,),
                              Padding(padding: EdgeInsets.all(iconDescriptionPadding),),
                              Text(module.examDateStr,) // style: theme.textTheme.bodyMedium?.copyWith(color: module.examDateKnown ? theme.colorScheme.primary : theme.disabledColor),)
                            ],
                          )
                        ],
                      ),

                      // Padding(
                      //   padding: EdgeInsets.only(top: 5),
                      // ),

                      Divider(),

                      // Padding(
                      //   padding: EdgeInsets.only(top: 5),
                      // ),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.start,
                            children: [
                              Icon(CupertinoIcons.pencil_outline, color: theme.colorScheme.primary,),
                              Padding(padding: EdgeInsets.all(iconDescriptionPadding),),
                              Text(moduleFormattedGrade.isNotEmpty ? moduleFormattedGrade : "0,0",)
                            ],
                          ),

                          VerticalDivider(color: Colors.black,),

                          Row(
                            mainAxisAlignment: MainAxisAlignment.start,
                            children: [
                              Icon(CupertinoIcons.book_circle, color: theme.colorScheme.primary,),
                              Padding(padding: EdgeInsets.all(iconDescriptionPadding),),
                              Text(L10n.t("module.credits", [module.pointsAcquired, module.pointsAvailable]),)
                            ],
                          )
                        ],
                      ),
                    ],
                  ),
                ),

                Column(
                  children: module.tables.map((table) => BlockContainer(
                    padding: EdgeInsets.only(top: 20, left: 4, right: 4),
                    child: ModuleInfoTableView(table: table),)
                  ).toList(),
                )

              ],
            ),
          ),
        );
      }
    );
  }

  /// CampusKIT never links some ILIAS courses ("Advanced Mathematics I"
  /// is the live case): ask for the course URL and store it as the
  /// module's manual fallback via the manager. The manager patches the
  /// live module instance, so after setState the header action flips to
  /// the regular ILIAS button; a rejected URL surfaces as a toast.
  Future<void> _attachIliasLink(KITModule module) async {
    // providers grabbed before the dialog await: no BuildContext use
    // across an async gap, and they are stable (listen: false) anyway
    final vm = Provider.of<KITProvider>(context, listen: false);
    final toastsProvider =
        Provider.of<ToastsProvider>(context, listen: false);
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(L10n.t("settings.moduleAttachIlias")),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: CupertinoTextField(
            controller: controller,
            placeholder: L10n.t("settings.moduleAttachIliasHint"),
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
        ),
        actions: [
          CupertinoDialogAction(
            child: Text(L10n.t("files.cancel")),
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
          CupertinoDialogAction(
            child: Text(L10n.t("settings.ownIcsSave")),
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) {
      controller.dispose();
      return;
    }
    try {
      await vm.campusManager.setManualIliasUrl(module.title, url);
      toastsProvider.showTextToast(L10n.t("settings.moduleAttachIliasSaved"));
      if (mounted) setState(() {});
    } on ArgumentError {
      toastsProvider
          .showTextToast(L10n.t("settings.moduleAttachIliasInvalid"));
    } finally {
      controller.dispose();
    }
  }

  /// Campus grade cells arrive as HTML fragments ("sehr gut &nbsp;", named
  /// entities, the occasional tag). Decode them with the same parser the
  /// scrapers use: unlike the old hand-rolled stripper it decodes entities
  /// properly, drops tags, and passes a stray '&' through untouched.
  String _formatGrade(String grade) =>
      (html_parser.parseFragment(grade).text ?? "").trim();

}
