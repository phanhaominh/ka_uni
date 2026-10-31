import 'package:flutter/material.dart';

import '../main.dart';

class AlphaBadge extends StatelessWidget {
  const AlphaBadge({super.key});

  @override
  Widget build(BuildContext context) {
    if (!isAlpha) {
      return const SizedBox(width: 0, height: 0);
    }
    // the badge body was gutted during the alpha->release transition;
    // everything after the old `return SizedBox()` was dead code
    return const SizedBox(width: 0, height: 0);
  }

}