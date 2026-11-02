import 'package:flutter/cupertino.dart';

// Layout
const defaultPagePaddingEdgeInsetsAll = EdgeInsets.all(15.0);
const defaultPagePadding = 15.0;

// Spacing rhythm - the only vertical/horizontal steps the app uses.
const double spaceXs = 4, spaceSm = 8, spaceMd = 12, spaceLg = 16, spaceXl = 24;

// Page gutter: section titles, date band and trailing buttons share it.
const double pageGutter = 16;

// Outer margin of every inline card (BlockContainer default, Card margin).
const double cardGutter = 4;

// "not the living present": past days AND cancelled ghosts dim alike.
const double deadContentOpacity = 0.45;

// Shapes
const double appBorderRadiusDouble = 20;
const appBorderRadius = Radius.circular(appBorderRadiusDouble);
const cupertinoInputBorderRadius = Radius.circular(5);
const double chipRadiusDouble = 8;
const chipRadius = Radius.circular(chipRadiusDouble);

// Colors
const mainColor = Color.fromRGBO(0, 150, 130, 1);
const appleGrey = Color.fromRGBO(243, 242, 248, 1);
const appleDarkGrey = Color.fromRGBO(28, 28, 30, 1);

const navigationLightBackground = Color.fromRGBO(240, 240, 240, 0.7);

const defaultChevronRotationAnimationCurve = Curves.ease;
const defaultChevronRotationAnimationDuration = Duration(milliseconds: 200);