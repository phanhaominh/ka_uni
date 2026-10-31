import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:kit_mobile/common_ui/alpha_badge.dart';
import 'package:kit_mobile/credentials/data/credentials_provider.dart';
import 'package:kit_mobile/credentials/models/auth_result.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
// import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';
import 'package:provider/provider.dart';

import '../../../common_ui/kit_progress_indicator.dart';
import '../../constants/view_constants.dart';
import '../../info/views/info_page.dart';
import '../../l10n/l10n.dart';
import '../../toasts/models/toasts_provider.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<StatefulWidget> createState() {
    return LoginPageState();
  }
}

class LoginPageState extends State<LoginPage> {
  final _usernameInputController = TextEditingController();
  final _passwordInputController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final credsVM = Provider.of<CredentialsProvider>(context);
    final vm = Provider.of<KITProvider>(context);

    final theme = Theme.of(context);
    final mq = MediaQuery.of(context);

    final myCupertinoInputDecoration = BoxDecoration(
        color: CupertinoDynamicColor.withBrightness(
          color: CupertinoColors.white,
          darkColor: CupertinoColors.darkBackgroundGray,
        ),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
        borderRadius: BorderRadius.all(cupertinoInputBorderRadius));

    if (credsVM.credentialsLoaded && _usernameInputController.text.isEmpty) {
      // username only: the real KIT password must never appear in an
      // editable, copyable field - automatic auth uses the stored value
      // programmatically via credsVM.login(), not this text field
      _usernameInputController.text = credsVM.credentials.username;
    }

    return Scaffold(
        body: Stack(
      children: [
        Scaffold(
            body: Stack(
          children: [
            AnimatedOpacity(
                opacity: !credsVM.loggingIn ? 1 : 0,
                duration: Duration(milliseconds: 250),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Column(
                      children: [
                        GestureDetector(
                          onTap: !kDebugMode
                              ? null
                              : () async {
                                  await credsVM.loadCredentials();
                                },
                          child: Text(L10n.t("settings.hello"),
                              style: theme.textTheme.headlineLarge
                                  ?.copyWith(fontWeight: FontWeight.bold)),
                        ),
                        Text(
                          L10n.t("settings.welcomeKarlsruhe"),
                          style: theme.textTheme.headlineSmall
                              ?.copyWith(color: theme.colorScheme.primary),
                        ),
                        // Text("Wilkommen im KIT", style: theme.textTheme.headlineSmall?.copyWith(color: theme.primaryColor),),
                      ],
                    ),
                    // (!credsVM.credentialsLoaded || credsVM.loggingIn) ? const KITProgressIndicator() :
                    Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          child: CupertinoTextField(
                            controller: _usernameInputController,
                            placeholder: "Username (uxxxx)",
                            enabled: (credsVM.credentialsLoaded &&
                                !credsVM.loggingIn),
                            autocorrect: false,
                            style: theme.textTheme.bodyMedium,
                            decoration: myCupertinoInputDecoration,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(10),
                          child: CupertinoTextField(
                            controller: _passwordInputController,
                            // onChanged: (val) => _passwordInputController.text,
                            placeholder: L10n.t("settings.password"),
                            enabled: (credsVM.credentialsLoaded &&
                                !credsVM.loggingIn),
                            keyboardType: TextInputType.visiblePassword,
                            obscureText: true,
                            style: theme.textTheme.bodyMedium,
                            decoration: myCupertinoInputDecoration,
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            CupertinoButton(
                                child: Icon(CupertinoIcons.info),
                                onPressed: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                        builder: (context) => InfoPage()))),
                            CupertinoButton(
                                child: Text(L10n.t("settings.login")),
                                onPressed: () => _submitLogin(credsVM, vm))
                          ],
                        )
                      ],
                    )
                  ],
                )),
            AnimatedPositioned(
                top: _awaitingAuthentication
                    ? -mq.size.height * 0.5
                    : mq.size.height * 0.3,
                curve: Curves.ease,
                duration: const Duration(milliseconds: 750),
                child: IgnorePointer(
                  // Decorative glow: its 7Wx7W bounds previously swallowed
                  // every tap below 30% of the screen (untappable form).
                  child: AnimatedOpacity(
                    curve: Curves.ease,
                    duration: const Duration(milliseconds: 750),
                    opacity: _awaitingAuthentication ? 1 : 0.5,
                    child: Container(
                        decoration: BoxDecoration(
                            boxShadow: [
                              BoxShadow(
                                color: theme.colorScheme.primary.withValues(
                                    alpha: theme.brightness ==
                                            Brightness.light
                                        ? 0.8
                                        : 0.5),
                                blurRadius: 50,
                                spreadRadius: 20,
                              )
                            ],
                            color: theme.colorScheme.primary,
                            borderRadius: BorderRadius.all(Radius.circular(
                                mq.size.width * 7))),
                        width: mq.size.width * 7,
                        height: mq.size.width * 7),
                  ),
                )),
            AnimatedOpacity(
              opacity: _awaitingAuthentication ? 1 : 0,
              duration: Duration(milliseconds: 250),
              child: SafeArea(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: mq.size.width * 0.3,
                      child: const AlphaBadge(),
                    ),
                    Column(
                      children: [
                        SizedBox(
                          width: mq.size.width,
                          // height: 125,
                          child: Center(
                            child: GlassContainer(
                              useOwnLayer: true,
                              quality: GlassQuality.premium,
                              settings: LiquidGlassSettings(blur: 0),
                              child: Container(
                                padding: EdgeInsets.all(defaultPagePadding),
                                child: Hero(
                                  tag: "greeting",
                                  child: Text(
                                    L10n.t("settings.helloName", [credsVM.displayName]),
                                    // theme default (dark ink on light, white
                                    // on dark): the glass has blur 0, so a
                                    // hardcoded white vanished in light mode
                                    style: theme.textTheme.headlineLarge
                                        ?.copyWith(
                                            fontWeight: FontWeight.bold),
                                    maxLines: 2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          height: 25,
                        ),
                        KITProgressIndicator(
                          color: theme.colorScheme.primary,
                        ),
                      ],
                    ),
                    SizedBox(
                      width: mq.size.width,
                      height: 0,
                    )
                  ],
                ),
              ),
            )
          ],
        )),
        vm.overlayHtmlData.isNotEmpty
            ? BackdropFilter(
                // color: Colors.black12,
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: ListView(
                  children: [
                    CupertinoButton(
                        onPressed: vm.dismissOverlayHtml,
                        child: Text(L10n.t("common.dismiss"))),
                    HtmlWidget(vm.overlayHtmlData)
                  ],
                ),
              )
            : const Text("")
      ],
    ));
  }

  bool _awaitingAuthentication = false;

  void _submitLogin(CredentialsProvider credsVM, KITProvider vm) {
    if (kDebugMode) {
      print("Submitted Login");
    }
    if (_awaitingAuthentication) {
      return;
    }

    setState(() {
      _awaitingAuthentication = true;
    });

    credsVM
        .submit(
            _usernameInputController.text, _passwordInputController.text, vm)
        .then((result) {
      if (!mounted) return;
      if (result != AuthResult.ok) {
        if (kDebugMode) {
          print("Authentication failed: $result");
        }
        setState(() {
          _awaitingAuthentication = false;
        });
        return;
      }

      if (kDebugMode) {
        print("Successfully authenticated");
      }

      // fetches run in the background; a throw must NEVER leave the form
      // disabled (the historical frozen-form dead end)
      unawaited(credsVM.loginPostSteps(vm));
      _onSuccessfulLogin(credsVM, vm);
    }).catchError((Object e) {
      if (kDebugMode) print("Login threw: $e");
      if (!mounted) return;
      setState(() {
        _awaitingAuthentication = false;
      });
      context.read<ToastsProvider>().showTextToast(L10n.t("auth.fail"));
    });
  }

  // TODO: probably delete
  void _onSuccessfulLogin(CredentialsProvider credsVM, KITProvider vm) {
    credsVM.setDisplayName(vm.student.name.repr);
  }
}
