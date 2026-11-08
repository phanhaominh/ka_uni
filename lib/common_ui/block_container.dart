import 'package:flutter/material.dart';
import 'package:kit_mobile/constants/view_constants.dart';
import 'package:kit_mobile/settings/providers/settings_provider.dart';
import 'package:liquid_glass_widgets/widgets/containers/glass_container.dart';
import 'package:provider/provider.dart';

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
    final settingsVM = Provider.of<SettingsProvider>(context);
    final theme = Theme.of(context);

    if (settingsVM.liquidAssEverywhere.value) {
      return Opacity(
        // the param was dead until the home favorite-star chip started
        // requesting 0.8
        opacity: opacity,
        child: Padding(
          padding: padding ?? const EdgeInsets.all(cardGutter),
          child: GlassContainer(
            child: Padding(
              padding: innerPadding ??
                  const EdgeInsets.only(top: 10, bottom: 10, left: 15, right: 15),
              child: child,
            ),
          ),
        ),
      );
    }

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
