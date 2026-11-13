// R34.6 — document expiry watch: store semantics, tier ladder, and the
// logout regression that pins the skeptic's veto condition: logout() MUST
// enumerate and delete every DOC_* keychain key, folding any failure into
// PartialLogoutException (reported, never skipped). Mocked secure storage
// per the existing precedent (live_submit_test.dart).
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/credentials/data/credentials_provider.dart';
import 'package:kit_mobile/docwatch/docwatch.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/tutorials/data/tutorial_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _pass = '{"id":"1","label":"Reisepass","expiry":"2030-01-01"}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group("DocWatchStore", () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test("add writes a DOC_* key, load returns it sorted by expiry", () async {
      final store = DocWatchStore();
      await store.add("  Aufenthaltstitel ", DateTime(2029, 5, 20, 13));
      await store.add("Reisepass", DateTime(2027, 1, 2));
      final raw = await const FlutterSecureStorage()
          .readAll(iOptions: DocWatchStore.iOptions);
      expect(raw.keys.where((k) => k.startsWith("DOC_")).length, 2);
      final docs = await store.load();
      expect(docs.map((e) => e.label), ["Reisepass", "Aufenthaltstitel"]);
      expect(docs.first.expiry, DateTime(2027, 1, 2));
      // date-only storage: time of day never survives the round trip
      expect(docs.last.expiry, DateTime(2029, 5, 20));
    });

    test("a corrupt DOC_* entry is dropped and self-heals, others load",
        () async {
      FlutterSecureStorage.setMockInitialValues(
          {"DOC_bad": "not json at all", "DOC_ok": _pass, "user": "keep"});
      final docs = await DocWatchStore().load();
      expect(docs.map((e) => e.label), ["Reisepass"]);
      final raw = await const FlutterSecureStorage()
          .readAll(iOptions: DocWatchStore.iOptions);
      expect(raw.containsKey("DOC_bad"), isFalse); // purged
      expect(raw["user"], "keep"); // non-family key untouched
    });

    test("remove deletes exactly its own key", () async {
      FlutterSecureStorage.setMockInitialValues(
          {"DOC_1": _pass, "DOC_2": _pass, "username": "u"});
      await DocWatchStore().remove("1");
      final raw = await const FlutterSecureStorage()
          .readAll(iOptions: DocWatchStore.iOptions);
      expect(raw.containsKey("DOC_1"), isFalse);
      expect(raw.containsKey("DOC_2"), isTrue);
      expect(raw["username"], "u");
    });
  });

  group("tier ladder", () {
    final now = DateTime(2026, 11, 13, 23, 30); // late evening: time ignored

    test("boundaries 90/30/7, expiry-today still seven, day past expired",
        () {
      expect(docDaysLeft(DateTime(2027, 2, 11), now), 90);
      expect(docTierFor(DateTime(2027, 2, 11), now), DocTier.ninety);
      expect(docTierFor(DateTime(2027, 2, 12), now), DocTier.none);
      expect(docTierFor(DateTime(2026, 12, 13), now), DocTier.thirty);
      expect(docTierFor(DateTime(2026, 12, 14), now), DocTier.ninety);
      expect(docTierFor(DateTime(2026, 11, 20), now), DocTier.seven);
      expect(docTierFor(DateTime(2026, 11, 21), now), DocTier.thirty);
      // today at midnight vs now 23:30 -> still "today", NOT expired
      expect(docTierFor(DateTime(2026, 11, 13), now), DocTier.seven);
      expect(docTierFor(DateTime(2026, 11, 12), now), DocTier.expired);
      expect(docDaysLeft(DateTime(2026, 11, 12), now), -1);
    });
  });

  group("logout purge", () {
    test("purgeAll deletes every DOC_* key and nothing else", () async {
      FlutterSecureStorage.setMockInitialValues({
        "DOC_a": _pass,
        "DOC_b": _pass,
        "username": "u",
        "password": "p",
        "ANNY_pass": "pw",
        "NOTDOC_keep": "x",
      });
      await DocWatchStore.purgeAll(const FlutterSecureStorage());
      final raw = await const FlutterSecureStorage()
          .readAll(iOptions: DocWatchStore.iOptions);
      expect(raw.keys.where((k) => k.startsWith("DOC_")), isEmpty);
      expect(raw["username"], "u"); // never deleteAll
      expect(raw["ANNY_pass"], "pw");
      expect(raw["NOTDOC_keep"], "x");
    });

    test("logout() kills every DOC_* keychain key (regression)", () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({
        "username": "uxxx",
        "password": "hunter2",
        "isLoggedIn": "1",
        "userDisplayName": "Test",
        "DOC_pass": _pass,
        "DOC_visum": '{"id":"2","label":"Visum","expiry":"2027-03-01"}',
        "NOTDOC_keep": "x",
      });
      final vm = KITProvider();
      final creds = CredentialsProvider();
      await creds.loadCredentials(notify: false);
      expect(creds.credentials.valid, isTrue); // seeded session is live

      Object? error;
      try {
        await creds.logout(vm, TutorialManager());
      } on Object catch (e) {
        error = e;
      }
      // platforms are mocked away in tests, so teardown steps CAN fail —
      // what must never happen is a raw exception escaping the partial
      // report contract: only PartialLogoutException may
      if (error != null) expect(error, isA<PartialLogoutException>());

      final raw = await const FlutterSecureStorage()
          .readAll(iOptions: DocWatchStore.iOptions);
      expect(raw.keys.where((k) => k.startsWith("DOC_")), isEmpty,
          reason: "DOC_* keys must die with logout()");
      expect(raw.containsKey("NOTDOC_keep"), isTrue,
          reason: "the purge must be a DOC_* enumeration, not deleteAll");
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
