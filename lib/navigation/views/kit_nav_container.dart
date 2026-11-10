import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:kit_mobile/constants/view_constants.dart';
import 'package:kit_mobile/extensions/theme_data_extension.dart';
import 'package:kit_mobile/home/views/home_page.dart';
import 'package:kit_mobile/ilias/views/ilias_page_view.dart';
import 'package:kit_mobile/l10n/l10n.dart';
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

  /// the router appearance token of THIS shell instance, taken when it
  /// reports in; dispose hands it back so a superseded shell (fast
  /// false→true profileReady flap: the new shell's first frame can beat
  /// this one's AnimatedSwitcher exit) cannot kill the live shell's
  /// ready flag and strand the deep-link queue forever
  int? _shellToken;

  @override
  void initState() {
    super.initState();
    // deep-link queue: taps that arrived during cold start or while the
    // login gate was still closed wait in the router; this shell being on
    // screen IS the lifecycle signal to consume them (post-frame, because
    // the Navigator must have its first attached frame before pushes)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted)
        _shellToken = NotificationDeepLinkRouter.instance.shellAppeared();
    });
  }

  @override
  void dispose() {
    // logout tears this scaffold down: later taps must queue again instead
    // of pushing onto a Navigator that drops back to the login form, and
    // session-dead pages get popped off (router-side, idempotent). A shell
    // that never reported in has nothing to revoke — skip, a token-less
    // shellGone would be the always-runs flavor and could kill a live
    // sibling's flag during a flap.
    final token = _shellToken;
    if (token != null) {
      NotificationDeepLinkRouter.instance.shellGone(appearedToken: token);
    }
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
          // wide-screen cap: at 1280 dp the pill stretched to ~1180 dp and
          // the three icons floated apart; a phone (<480 dp inner) is
          // untouched
          // Row, NOT Center: the bottomSheet slot hands out tight-WIDE,
          // loose-TALL-to-full-height constraints; Center expands to the
          // full height and floats its child dead-center of the screen -
          // on every phone the dock "detached" from the bottom edge (b46
          // regression, reported as the floating pill).
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: ClipRRect(
                    borderRadius: bottomNavigationBorderRadius,
                    child: BackdropFilter(
                      // sigma 14 was too weak under the pill: menu text behind
                      // the dock stayed readable and read as ghosting
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
                                title: L10n.t("nav.settings")),
                            customBottomNavBarButton(1, CupertinoIcons.home,
                                title: L10n.t("nav.dashboard")),
                            customBottomNavBarButton(2, null,
                                // the real ILIAS brand tile: a generic glyph
                                // (first a paperclip) never read as "ILIAS"
                                assetIcon: "assets/images/ilias_icon.png",
                                title: "ILIAS", customAction: () {
                              // one-page rule: ILIAS is a heavy SSO page
                              // holding its own WebView - burst clip taps
                              // must not stack copies of it; a tap while one
                              // is already on the stack is a no-op,
                              // mirroring the deep-link router
                              final open = _iliasRoute;
                              if (open != null && open.navigator != null) {
                                return;
                              }
                              final route = MaterialPageRoute(
                                  settings: RouteSettings(
                                      name: IliasPageView.routeName),
                                  builder: (BuildContext context) =>
                                      IliasPageView(KITModule(),
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
            ],
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
            // TalkBack: announce which tab is active, not just that there is one
            selected: targetIdx == _selectedPage,
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
