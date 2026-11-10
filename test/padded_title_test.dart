import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/home/views/padded_title.dart';

// the home rows place trailing controls AFTER the PaddedTitle (spinner +
// refresh button next to "Aktuelle Module im WS 26/27", "Alle ansehen"
// next to "Angeheftete Dateien"); as a bare Text the title guaranteed
// RenderFlex overflow stripes at Pixel-3 width and >=1.3x text scale -
// and overflow is a captured exception in widget tests
void main() {
  testWidgets("long title + wide trailing ellipsizes instead of overflowing",
      (tester) async {
    // Pixel-3 class surface (393 logical px) with the font scale from the
    // bug report: tight enough that the title cannot fit next to the
    // trailing controls, so only the flexible ellipsis keeps the row legal
    tester.view.physicalSize = const Size(393, 851);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: Scaffold(
          body: PaddedTitle(
            title: "Aktuelle Module im WS 26/27",
            trailing: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 44, height: 44), // refresh button budget
              ],
            ),
          ),
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
    // the title is still laid out and shrunk, not dropped
    final box = tester
        .renderObject<RenderBox>(find.text("Aktuelle Module im WS 26/27"));
    expect(box.size.width, lessThan(393));
  });
}
