import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/local_files_storage/files_manager.dart';
import 'package:kit_mobile/local_files_storage/models/pinned_file.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pin identity: urlString when the reference has one, fileSystemPath
/// when it does not (the cache-page viewer synthesizes
/// `PinnedFile(urlString: "")` for files opened straight off the disk).
/// The old bare-urlString matching made ALL empty-url pins one file:
/// pinning file B silently deleted pin A, rename hit the first empty-url
/// entry (the wrong file), and unpinning one dropped every empty-url pin
/// of the semester. These are the regression scenarios.
PinnedFile pinned({
  String semester = "SS 2026",
  String url = "",
  String path = "/cache/a.pdf",
  String title = "Modul",
  String name = "",
}) =>
    PinnedFile(
      semesterString: semester,
      urlString: url,
      moduleTitle: title,
      addedAt: DateTime.utc(2026, 11, 13),
      customName: name,
      fileSystemPath: path,
    );

void main() {
  late IliasFilesProvider manager;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    manager = IliasFilesProvider();
  });

  test("pinning two empty-url files keeps BOTH pins", () async {
    await manager.addPinnedFile(pinned(path: "/cache/a.pdf", title: "A"));
    await manager.addPinnedFile(pinned(path: "/cache/b.pdf", title: "B"));

    final files = await manager.getFilesForSemester("SS 2026");
    expect(files.length, 2);
    expect(
      files.map((f) => f.fileSystemPath),
      containsAll(<String>["/cache/a.pdf", "/cache/b.pdf"]),
    );
  });

  test("re-pinning the same empty-url path replaces, not stacks", () async {
    await manager.addPinnedFile(pinned(path: "/cache/a.pdf", title: "A"));
    await manager.addPinnedFile(pinned(path: "/cache/a.pdf", title: "A neu"));

    final files = await manager.getFilesForSemester("SS 2026");
    expect(files.single.fileSystemPath, "/cache/a.pdf");
    expect(files.single.moduleTitle, "A neu");
  });

  test("url pins still dedupe on their URL", () async {
    await manager
        .addPinnedFile(pinned(url: "https://ilias/f", path: "/cache/a.pdf"));
    await manager.addPinnedFile(
        pinned(url: "https://ilias/f", path: "/cache/a-copy.pdf"));

    final files = await manager.getFilesForSemester("SS 2026");
    expect(files.single.urlString, "https://ilias/f");
    expect(files.single.fileSystemPath, "/cache/a-copy.pdf");
  });

  test("rename with empty url hits the entry with the matching path",
      () async {
    await manager.addPinnedFile(pinned(path: "/cache/a.pdf", title: "Alpha"));
    await manager.addPinnedFile(pinned(path: "/cache/b.pdf", title: "Beta"));

    await manager.updatePinnedFileCustomName(
      semesterString: "SS 2026",
      urlString: "",
      fileSystemPath: "/cache/b.pdf",
      customName: "Beta nachher",
    );

    final byPath = {
      for (final f in await manager.getFilesForSemester("SS 2026"))
        f.fileSystemPath: f,
    };
    // the old match renamed the FIRST empty-url entry: Alpha lost its name
    expect(byPath["/cache/b.pdf"]!.customName, "Beta nachher");
    expect(byPath["/cache/a.pdf"]!.customName, "Alpha");
  });

  test("unpinFile with empty url removes exactly the matching path", () async {
    await manager.addPinnedFile(pinned(path: "/cache/a.pdf", title: "A"));
    await manager.addPinnedFile(pinned(path: "/cache/b.pdf", title: "B"));

    await manager.unpinFile(
      semesterString: "SS 2026",
      urlString: "",
      fileSystemPath: "/cache/b.pdf",
    );

    final files = await manager.getFilesForSemester("SS 2026");
    expect(files.single.fileSystemPath, "/cache/a.pdf");
  });

  test("unpinFile with unknown identity removes nothing", () async {
    // empty url AND empty path: identity unknown, must not resolve into a
    // false claim on the one empty-url pin that exists
    await manager.addPinnedFile(pinned(path: "/cache/a.pdf", title: "A"));

    await manager.unpinFile(semesterString: "SS 2026", urlString: "");

    expect((await manager.getFilesForSemester("SS 2026")).length, 1);
  });

  test("unpinFilesByPaths drops exactly the path's entries, cross-semester",
      () async {
    await manager.addPinnedFile(pinned(
        semester: "SS 2026", url: "https://ilias/x", path: "/cache/x.pdf"));
    await manager.addPinnedFile(
        pinned(semester: "WS 25/26", path: "/cache/x.pdf", title: "X alt"));
    await manager.addPinnedFile(pinned(
        semester: "SS 2026", url: "https://ilias/y", path: "/cache/y.pdf"));

    await manager.unpinFilesByPaths({"/cache/x.pdf"});

    final current = await manager.getFilesForSemester("SS 2026");
    expect(current.single.fileSystemPath, "/cache/y.pdf");
    expect(await manager.getFilesForSemester("WS 25/26"), isEmpty);
  });
}
