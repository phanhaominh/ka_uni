import 'package:flutter/material.dart';
import 'package:kit_mobile/constants/view_constants.dart';

class BlockContainer extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;
  final EdgeInsets? innerPadding;
  final double opacity;
  final bool withShadow;
  final Color? backgroundColor;

  const BlockContainer(
      {super.key,
      required this.child,
      this.padding,
      this.innerPadding,
      this.opacity = 1,
      this.withShadow = false,
      this.backgroundColor});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // the liquidAssEverywhere glass variant was removed with its setting:
    // the only UI writer had been commented out, so the flag was
    // permanently false and every card paid a dead branch + subscription
    return Opacity(
      opacity: opacity,
      child: Padding(
        padding: padding ?? const EdgeInsets.all(cardGutter),
        child: Container(
          decoration: BoxDecoration(
              borderRadius: BorderRadius.all(appBorderRadius),
              color: backgroundColor ?? theme.cardColor,
              boxShadow: withShadow
                  ? [BoxShadow(blurRadius: 5, color: Colors.black12)]
                  : []),
          padding: innerPadding ??
              const EdgeInsets.only(top: 10, bottom: 10, left: 15, right: 15),
          child: child,
        ),
      ),
    );
  }
}
