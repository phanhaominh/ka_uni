import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:kit_mobile/common_ui/highlight_pulse.dart';

Color glowBorderColor(WidgetTester tester) {
  final decoration = tester
      .widget<DecoratedBox>(find.byKey(HighlightPulse.pulseKey))
      .decoration as BoxDecoration;
  return (decoration.border! as Border).top.color;
}

double glowBorderWidth(WidgetTester tester) {
  final decoration = tester
      .widget<DecoratedBox>(find.byKey(HighlightPulse.pulseKey))
      .decoration as BoxDecoration;
  return (decoration.border! as Border).top.width;
}

Future<void> pumpPulse(WidgetTester tester,
    {required bool armed,
    Duration duration = const Duration(seconds: 2)}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: HighlightPulse(
          armed: armed,
          color: const Color(0xFF00FF00),
          duration: duration,
          child: const SizedBox(width: 100, height: 50),
        ),
      ),
    ),
  ));
}

void main() {
  test("emphasis envelope sweeps 0 -> full -> 0 and leaves nothing", () {
    expect(HighlightPulse.emphasis(0), closeTo(0, 1e-9));
    expect(HighlightPulse.emphasis(0.5), closeTo(1, 1e-9));
    expect(HighlightPulse.emphasis(1), closeTo(0, 1e-9));
  });

  testWidgets("armed pulse blooms within the 2 s window, then extinguishes",
      (tester) async {
    await pumpPulse(tester, armed: true);
    // at rest before the first animation pump
    expect(glowBorderColor(tester).a, lessThan(0.01));
    final restingWidth = glowBorderWidth(tester);

    await tester.pump(); // start the tween
    await tester.pump(const Duration(milliseconds: 1000)); // peak
    expect(glowBorderColor(tester).a, greaterThan(0.8));
    // static border width across the whole sweep: only color/shadow
    // opacity animates, the child's layout never jitters (was: a 1->3
    // width lerp, pinned here with greaterThan(1))
    expect(glowBorderWidth(tester), restingWidth);
    await tester.pump(const Duration(milliseconds: 1000)); // window over
    expect(glowBorderColor(tester).a, lessThan(0.01));
    await tester.pumpAndSettle();
    expect(glowBorderColor(tester).a, lessThan(0.01));
  });

  testWidgets("unarmed pulse never renders the glow layer", (tester) async {
    await pumpPulse(tester, armed: false);
    expect(find.byKey(HighlightPulse.pulseKey), findsNothing);
    await tester.pumpAndSettle();
    expect(find.byKey(HighlightPulse.pulseKey), findsNothing);
  });
}
