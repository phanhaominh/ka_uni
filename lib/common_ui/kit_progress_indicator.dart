import 'package:flutter/cupertino.dart';

class KITProgressIndicator extends StatelessWidget {
  final bool animating;
  final Color? color;

  /// Optional screen-reader label. The bare activity indicator is reused
  /// all over the app and is otherwise indistinguishable; sites that know
  /// WHAT is loading (e.g. the app-bar profile spinner) can set this so
  /// TalkBack/VoiceOver announces it. Default null keeps every other
  /// call site byte-for-byte unchanged.
  final String? semanticsLabel;

  const KITProgressIndicator(
      {super.key, this.animating = true, this.color, this.semanticsLabel});

  @override
  Widget build(BuildContext context) {
    final indicator =
        CupertinoActivityIndicator(animating: animating, color: color);
    final label = semanticsLabel;
    if (label == null) {
      return indicator;
    }
    return Semantics(label: label, child: indicator);
  }
}
