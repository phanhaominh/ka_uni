import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:kit_mobile/constants/view_constants.dart';
import 'package:kit_mobile/extensions/theme_data_extension.dart';
import 'package:kit_mobile/home/views/home_page.dart';
import 'package:kit_mobile/ilias/views/ilias_page_view.dart';
import 'package:kit_mobile/settings/views/settings_page.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:provider/provider.dart';

import '../../module/models/module.dart';
class KITNavContainer extends StatefulWidget {
  const KITNavContainer({super.key});

  @override
  State<StatefulWidget> createState() {
    return _KITNavContainerState();
  }
}

const bottomNavigationBorderRadius = BorderRadius.all(appBorderRadius);

class _KITNavContainerState extends State<KITNavContainer> {
  int _selectedPage = 1;

  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<KITProvider>(context);
    final theme = Theme.of(context);

    return Scaffold(
      // Plain backdrop blur instead of liquid_glass_widgets: the dev-pin
      // premium shader layer ghosted stale content of the view behind it
      // through the dock on this device, while remaining visually
      // acceptable elsewhere.
      bottomSheet: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 50),
          child: ClipRRect(
            borderRadius: bottomNavigationBorderRadius,
            child: BackdropFilter(
              // sigma 14 was too weak under the pill: menu text behind the
              // dock stayed readable and read as ghosting
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                decoration: BoxDecoration(
                  color: theme.isLightMode
                      ? Colors.white.withValues(alpha: 0.8)
                      : Colors.black.withValues(alpha: 0.55),
                  border: Border.all(
                    color: Colors.grey.withValues(alpha: 0.15),
                  ),
                  borderRadius: bottomNavigationBorderRadius,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    customBottomNavBarButton(0, CupertinoIcons.settings,
                        title: "Settings"),
                    customBottomNavBarButton(1, CupertinoIcons.home,
                        title: "Dashboard"),
                    customBottomNavBarButton(
                        2, CupertinoIcons.rectangle_paperclip,
                        title: "ILIAS",
                        customAction: () {
                          Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (BuildContext context) =>
                                      IliasPageView(KITModule(),
                                          PHPSESSID_Future:
                                              vm.iliasManager.getPHPSESSID())));
                        })
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          [
            SettingsPage(),
            KITHomePage(),
            // IliasPageView(KITModule(),
            //     PHPSESSID: vm.iliasManager.getPHPSESSID()),
            IliasPageView(KITModule(), PHPSESSID_Future: Future.value("")),
          ][_selectedPage],
        ],
      ),
    );
  }

  Widget customBottomNavBarButton(int targetIdx, IconData icon,
      {String title = "", Function? customAction}) {
    return CupertinoButton(
        padding: EdgeInsets.zero,
        // dock icons are bare glyphs; without a label a screen reader
        // announces nothing on the app's primary navigation
        child: Semantics(
          button: true,
          label: title,
          child: Row(
            children: [
              Icon(
                icon,
                color: targetIdx == _selectedPage ? null : Colors.grey,
              ),
            ],
          ),
        ),
        onPressed: () {
          if (customAction != null) {
            customAction();
            return;
          }

          setState(() {
            _selectedPage = targetIdx;
          });
        });
  }
}
