import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// R35.6 SCRAPE-REFUSAL TEST (doctrine, not decoration): every host the
/// binary can *name* lives on this list. The fork's privacy line is "the
/// app scrapes KIT, it does not browse the web for you" - a new host must
/// be a conscious act: fenced parser, a RUNBOOK won't-list justification,
/// and proof no existing join already answers the need (brief R35.6).
///
/// The test greps the shipped source itself (tests run from the package
/// root), so a URL hiding in a string interpolation prefix still trips
/// it: only fully-qualified https?:// literals are considered.
void main() {
  const allowed = {
    // KIT campus stack (scraped)
    "campus.studium.kit.edu",
    "cascampus.studium.kit.edu",
    "plus.campus.kit.edu",
    "campus.kit.edu",
    "idp.scc.kit.edu", // SSO IdP (login flow only)
    "ilias.studium.kit.edu",
    // student services (scraped: mensa; tap-through: library, SW)
    "www.sw-ka.de",
    "katalog.bibliothek.kit.edu",
    // Anny (open data API, own host allowlist in anny_auth.dart)
    "anny.eu",
    "auth.anny.eu",
    "b.anny.eu",
    // maps (tile + attribution links)
    "tile.openstreetmap.org",
    "openstreetmap.org",
    // app info page external links (tap-through, never scraped)
    "www.kit.edu",
    "dandemidov.com",
    "github.com",
    // starter-pack editorial rows (assets/starter_pack.json + handbook
    // citation — tap through, every URL verified 2026-11-13, stand: stamp
    // shipped)
    "www.make-it-in-germany.com",
    "web1.karlsruhe.de",
    "www1.karlsruhe.de",
    "www.intl.kit.edu",
    "www.sle.kit.edu",
    "www.gesetze-im-internet.de",
    "www.mach.kit.edu",
  };

  List<File> scannedFiles() => Directory("lib")
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith(".dart"))
      .toList()
    ..addAll(Directory("assets")
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith(".json")));

  test("every literal host in lib/ and assets/ is on the allowlist", () {
    final pattern = RegExp(r"https?://([a-zA-Z0-9.-]+)");
    final found = <String, List<String>>{};
    for (final entry in scannedFiles()) {
      final text = entry.readAsStringSync();
      for (final m in pattern.allMatches(text)) {
        final host = m.group(1)!.toLowerCase();
        // not a real host: scheme example inside docs/regex ("https://ilias"
        // in a matcher comment) - FQDNs need a dot
        if (!host.contains(".")) continue;
        (found[host] ??= []).add(entry.path);
      }
    }
    final strangers =
        found.keys.where((h) => !allowed.contains(h)).toSet();
    expect(
        strangers,
        isEmpty,
        reason: "new host(s) $strangers referenced in "
            "${strangers.map((h) => found[h]?.first).toSet().join(", ")} - "
            "add deliberately: fenced parser + RUNBOOK won't-list entry + "
            "no existing join answers it (R35.6)");
  });

  test("allowlist entries all still exist in the source", () {
    // a stale allowlist is a lying allowlist: dead hosts must be removed
    final text =
        scannedFiles().map((f) => f.readAsStringSync()).join("\n");
    final dead = allowed
        .where((h) => !text.contains("://$h"))
        .toSet();
    expect(dead, isEmpty,
        reason: "hosts on the allowlist no longer present in lib/ - "
            "delete them from the allowlist or restore the caller");
  });
}
