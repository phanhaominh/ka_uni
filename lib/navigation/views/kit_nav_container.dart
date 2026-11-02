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
import '../notification_deep_links.dart';
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

  /// the pushed ILIAS page while it is on the stack; one-page rule for the
  /// paperclip, mirroring NotificationDeepLinkRouter.drain
  Route<dynamic>? _iliasRoute;

  @override
  void initState() {
    super.initState();
    // deep-link queue: taps that arrived during cold start or while the
    // login gate was still closed wait in the router; this shell being on
    // screen IS the lifecycle signal to consume them (post-frame, because
    // the Navigator must have its first attached frame before pushes)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) NotificationDeepLinkRouter.instance.shellAppeared();
    });
  }

  @override
  void dispose() {
    // logout tears this scaffold down: later taps must queue again instead
    // of pushing onto a Navigator that drops back to the login form
    NotificationDeepLinkRouter.instance.shellGone();
    super.dispose();
  }

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
                        2, null,
                        // the real ILIAS brand tile: a generic glyph
                        // (first a paperclip) never read as "ILIAS"
                        assetIcon: "assets/images/ilias_icon.png",
                        title: "ILIAS",
                        customAction: () {
                          // one-page rule: ILIAS is a heavy SSO page holding
                          // its own WebView - burst clip taps must not stack
                          // copies of it; a tap while one is already on the
                          // stack is a no-op, mirroring the deep-link router
                          final open = _iliasRoute;
                          if (open != null && open.navigator != null) return;
                          final route = MaterialPageRoute(
                              settings: RouteSettings(
                                  name: IliasPageView.routeName),
                              builder: (BuildContext context) => IliasPageView(
                                  KITModule(),
                                  PHPSESSID_Future:
                                      vm.iliasManager.getPHPSESSID()));
                          Navigator.of(context).push(route);
                          _iliasRoute = route;
                          // popping frees the slot: the next tap pushes fresh
                          route.popped.whenComplete(() {
                            if (_iliasRoute == route) _iliasRoute = null;
                          });
                        })
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      body: IndexedStack(
        // not the old list-index swap: IndexedStack keeps the unselected
        // tab's State alive - the Dashboard carousel page and its scroll
        // positions survive a Settings round-trip. C13 audited: nothing
        // under lib/settings runs a periodic timer (the only dispose there
        // tears down a TextEditingController), so the alive-but-hidden tab
        // nags nothing; its initState work (_OwnIcsSection one-shot
        // personal-ICS load, _CacheSizeText single directory walk) now also
        // runs at startup while Dashboard shows - bounded one-shots, an
        // accepted behavior change; an AppLifecycle pause observer would
        // have nothing to stop
        index: _selectedPage,
        children: const [SettingsPage(), KITHomePage()],
      ),
    );
  }

  Widget customBottomNavBarButton(int targetIdx, IconData? icon,
      {String title = "", String assetIcon = "", Function? customAction}) {
    return Tooltip(
      // sighted users get the name on long-press; the paperclip glyph
      // alone never announced ILIAS
      message: title,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        // dock icons are bare glyphs; without a label a screen reader
        // announces nothing on the app's primary navigation
        child: Semantics(
          button: true,
          label: title,
          child: assetIcon.isNotEmpty
              // brand tiles keep their own colors: the grey "unselected"
              // treatment only applies to template glyphs
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.asset(assetIcon, height: 26, width: 26),
                )
              : Row(
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
        }),
    );
  }
}
