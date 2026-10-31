import 'dart:ui';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:kit_mobile/common_ui/kit_progress_indicator.dart';
import 'package:kit_mobile/credentials/models/auth_result.dart';
import 'package:kit_mobile/credentials/data/credentials_provider.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/local_files_storage/files_manager.dart';
import 'package:kit_mobile/settings/providers/settings_provider.dart';
import 'notifications/mei_notifications.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/toasts/models/toasts_provider.dart';
import 'package:kit_mobile/toasts/views/toasts_overlay.dart';
import 'package:kit_mobile/tutorials/data/tutorial_manager.dart';
import 'package:liquid_glass_widgets/liquid_glass_setup.dart';
import 'package:provider/provider.dart';

import 'constants/view_constants.dart';
import 'credentials/views/login_view.dart';
import 'navigation/views/kit_nav_container.dart';

const isAlpha = true;

void main() async {
  // Plugin channels below need the binding before any platform call.
  WidgetsFlutterBinding.ensureInitialized();
  L10n.setSystemLanguage(
      PlatformDispatcher.instance.locale.languageCode == "en" ? "en" : "de");
  await L10n.reload();
  await LiquidGlassWidgets.initialize();
  // notifications/WorkManager are optional: a PlatformException here (custom
  // ROM, denied alarm permission, misbehaving provider) used to abort main()
  // BEFORE runApp - a blank window instead of an app with no notifications
  try {
    await MeiNotifications.init();
    await registerBackgroundPolling();
    await registerTestPollOnce();
  } catch (e) {
    if (kDebugMode) print("notifications bootstrap failed: $e");
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    var themeData = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: mainColor,
      ),
      useMaterial3: true,
      scaffoldBackgroundColor: appleGrey,
      cardColor: Colors.white,
      canvasColor: Colors.white,
    );

    var textTheme = themeData.textTheme.copyWith(
      titleLarge:
          themeData.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
      titleMedium: themeData.textTheme.titleMedium
          ?.copyWith(fontWeight: FontWeight.bold),
      headlineSmall: themeData.textTheme.headlineSmall
          ?.copyWith(fontWeight: FontWeight.bold),
      headlineMedium: themeData.textTheme.headlineMedium
          ?.copyWith(fontWeight: FontWeight.bold),
    );

    final bottomSheetThemeData = themeData.bottomSheetTheme
        .copyWith(backgroundColor: Color.fromRGBO(0, 0, 0, 0));

    themeData = themeData.copyWith(
        textTheme: textTheme, bottomSheetTheme: bottomSheetThemeData);
    themeData = themeData.copyWith(
      appBarTheme: themeData.appBarTheme.copyWith(
        backgroundColor: appleGrey,
        surfaceTintColor: appleGrey,
        shadowColor: Colors.black38,
        // titleTextStyle: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.normal)
      ),
    );

    var darkThemeData = ThemeData.dark();

    darkThemeData = darkThemeData.copyWith(
      colorScheme: ColorScheme.fromSeed(
          seedColor: mainColor,
          brightness: Brightness
              .dark), //, onBackground: Colors.red, background: Colors.red),
      textTheme: darkThemeData.textTheme.copyWith(
        titleLarge: darkThemeData.textTheme.titleLarge
            ?.copyWith(fontWeight: FontWeight.bold),
        titleMedium: darkThemeData.textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.bold),
        headlineSmall: darkThemeData.textTheme.headlineSmall
            ?.copyWith(fontWeight: FontWeight.bold),
        headlineMedium: darkThemeData.textTheme.headlineMedium
            ?.copyWith(fontWeight: FontWeight.bold),
      ),
      scaffoldBackgroundColor: Colors.black,
      appBarTheme: darkThemeData.appBarTheme.copyWith(
        backgroundColor: Colors.black,
        surfaceTintColor: Colors.black,
      ),
      cardColor: appleDarkGrey,
      bottomSheetTheme: bottomSheetThemeData,
      // white canvas in a dark theme painted white popups on black
      canvasColor: appleDarkGrey,
    );

    final settingsProvider = SettingsProvider(context: context);

    return MultiProvider(
      providers: [
        ChangeNotifierProvider<KITProvider>(create: (ctx) => KITProvider()),
        ChangeNotifierProvider<CredentialsProvider>(
          create: (ctx) => CredentialsProvider(),
        ),
        ChangeNotifierProvider<ToastsProvider>(
          create: (ctx) => ToastsProvider(),
        ),
        ChangeNotifierProvider<SettingsProvider>.value(
          value: settingsProvider,
        ),
        ChangeNotifierProvider<IliasFilesProvider>(
          create: (ctx) => IliasFilesProvider(),
        ),
        ChangeNotifierProvider<TutorialManager>(
          create: (ctx) => TutorialManager(),
        ),
      ],
      child: Consumer<SettingsProvider>(
          // language switch -> notifyListeners -> rebuild MaterialApp with
          // the new locale AND a new home key so every static L10n.t string
          // in the widget tree is re-evaluated
          builder: (context, settings, child) => MaterialApp(
              title: "KA.Uni",
              theme: themeData,
              darkTheme: darkThemeData,
              locale: L10n.locale,
              supportedLocales: const [Locale("de"), Locale("en")],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              builder: (context, child) {
                return Stack(
                  children: [
                    child ?? SizedBox(),
                    ToastsOverlay(
                      extraPadding: EdgeInsets.only(bottom: 40),
                    )
                  ],
                );
              },
              // No locale key on home: Navigator.changedExternalState already
              // rebuilds every route on locale change; remounting would
              // re-trigger the login/preload flow in initState.
              home: KITApp())),
    );
  }
}

class KITApp extends StatefulWidget {
  const KITApp({super.key});

  @override
  State<KITApp> createState() => _KITAppState();
}

class _KITAppState extends State<KITApp> {
  late Future<bool> _credentialsFuture;

  @override
  void initState() {
    super.initState();

    final vm = Provider.of<KITProvider>(context, listen: false);
    final credsVM = Provider.of<CredentialsProvider>(context, listen: false);
    final toastsProvider = Provider.of<ToastsProvider>(context, listen: false);

    _credentialsFuture = credsVM.loadCredentials(notify: false);
    // never leave this future's rejection unhandled: login rethrows after its
    // finally when the network dies, and an unawaited whenComplete would drop
    // it into the zone as an unhandled error (offline launch crash-noise)
    unawaited(_credentialsFuture.then((_) async {
      if (!credsVM.credentials.valid) return;
      final preloadResult = await vm.tryPreloadCache(credsVM.credentials);

      if (!preloadResult) {
        // should never happen but just in case
        toastsProvider.showTextToast(L10n.t("auth.invalidCredentials"));
        return;
      }

      final loginOk = await credsVM.login(vm);
      if (loginOk == AuthResult.ok) {
        // shared with the manual login form: ilias SSO, timetable, exams,
        // modules - sequentially on the fresh cascampus session, all
        // errors contained
        unawaited(credsVM.loginPostSteps(vm));
      } else {
        // Preload optimistically set ready=true; a failed re-login MUST
        // tear it down, otherwise the dead session's cached home stays on
        // screen forever and the user is never sent back to the login form.
        vm.campusManager.ready = false;
        vm.campusManager.notificationCallback();
        toastsProvider.showTextToast(L10n.t("auth.invalidCredentials"));
      }
    }).catchError((Object e) {
      if (kDebugMode) print("bootstrap login failed: $e");
    }));
  }

  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<KITProvider>(context);

    return FutureBuilder(
        future: _credentialsFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: KITProgressIndicator());
          }

          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: vm.profileReady ? KITNavContainer() : LoginPage(),
          );
        });
  }
}
