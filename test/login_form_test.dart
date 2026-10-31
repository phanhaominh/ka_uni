import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/common_ui/kit_progress_indicator.dart';
import 'package:kit_mobile/credentials/data/credentials_provider.dart';
import 'package:kit_mobile/credentials/models/auth_result.dart';
import 'package:kit_mobile/credentials/models/kit_credentials.dart';
import 'package:kit_mobile/credentials/views/login_view.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:provider/provider.dart';

// L10n._language defaults to "de" in tests (no prefs loaded), so the submit
// button renders the German label.
// The two CupertinoTextFields in document order: username, password.
Finder fieldFinder(int index) => find
    .descendant(of: find.byType(LoginPage), matching: find.byType(EditableText))
    .at(index);

Finder submitFinder() => find.widgetWithText(CupertinoButton, 'Einloggen');

/// Stands in for the real provider: the submit button's whole job is handing
/// the two controller texts to submit(), so capturing them there proves the
/// form wiring without any KITProvider/network construction.
class ProbeProvider extends CredentialsProvider {
  ProbeProvider(this.onSubmitted);

  final void Function(String user, String pass) onSubmitted;

  @override
  Future<AuthResult> submit(
      String typedUsername, String typedPassword, KITProvider vm) async {
    onSubmitted(typedUsername, typedPassword);
    return AuthResult.wrongUsernameFormat; // stop before any network work
  }
}

Future<void> pumpLogin(WidgetTester tester, CredentialsProvider creds) async {
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<CredentialsProvider>.value(value: creds),
      ChangeNotifierProvider<KITProvider>.value(value: KITProvider()),
    ],
    child: const MaterialApp(home: LoginPage()),
  ));
  // pump, never pumpAndSettle: the focused CupertinoTextField cursor blinks
  // forever and settle would time out
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets('typed credentials reach submit verbatim (incl. \$ and ?)',
      (tester) async {
    const typedUser = "uxtest";
    const typedPass = r"pAssw0rd?$x9";
    late List<String> got;

    final creds = ProbeProvider((u, p) => got = [u, p])
      ..credentials = KITCredentials(username: "uxfake", password: "old-pass")
      ..credentialsLoaded = true;

    await pumpLogin(tester, creds);
    expect(find.text("uxfake"), findsOneWidget); // stored username prefills

    await tester.enterText(fieldFinder(0), typedUser);
    await tester.enterText(fieldFinder(1), typedPass);
    await tester.tap(submitFinder());
    await tester.pump(const Duration(milliseconds: 600)); // opacity + submit

    expect(got[0], typedUser);
    expect(got[1], typedPass);
  });

  testWidgets('password is never auto-filled from storage', (tester) async {
    late List<String> got;
    final creds = ProbeProvider((u, p) => got = [u, p])
      ..credentials =
          KITCredentials(username: "uxfake", password: "stored-secret")
      ..credentialsLoaded = true;

    await pumpLogin(tester, creds);
    await tester.tap(submitFinder());
    await tester.pump(const Duration(milliseconds: 600));

    expect(got[0], "uxfake"); // prefilled username is submitted
    expect(got[1], isEmpty); // but the stored secret never enters the field
  });

  testWidgets('logging-in overlay stays readable in light theme', (tester) async {
    final creds = ProbeProvider((u, p) {})
      ..credentials = KITCredentials(username: "uxfake", password: "stored-secret")
      ..credentialsLoaded = true
      ..displayName = "Testo"
      ..loggingIn = true;

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<CredentialsProvider>.value(value: creds),
        ChangeNotifierProvider<KITProvider>.value(value: KITProvider()),
      ],
      child: MaterialApp(theme: ThemeData.light(), home: const LoginPage()),
    ));
    await tester.pump(const Duration(milliseconds: 600));

    // the overlay greeting + spinner sat on the light scaffold with
    // hardcoded white: invisible in light mode
    final greeting = tester.widget<Text>(find.text("Hallo, Testo"));
    expect(greeting.style?.color, isNot(Colors.white));
    final spinner = tester.widgetList<KITProgressIndicator>(
            find.descendant(
                of: find.byType(LoginPage),
                matching: find.byType(KITProgressIndicator)))
        .last;
    expect(spinner.color, isNot(Colors.white));
  });
}
