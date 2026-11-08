import 'package:flutter/material.dart';

/// Caps body width on wide viewports (tablet landscape ~1280 dp) so text
/// lines stay readable and cards do not look like stretched phone
/// screenshots; phones (<900 dp) are untouched.
class MaxWidthBody extends StatelessWidget {
  const MaxWidthBody({super.key, required this.child, this.maxWidth = 840});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    if (w < 900) return child;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
