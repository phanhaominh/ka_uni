import 'package:flutter/material.dart';
import 'package:kit_mobile/common_ui/block_container.dart';
import 'package:provider/provider.dart';

import '../models/toasts_provider.dart';

class ToastsOverlay extends StatelessWidget {
  final EdgeInsets? extraPadding;

  const ToastsOverlay({super.key, this.extraPadding});

  @override
  Widget build(BuildContext context) {
    final toastsProvider = Provider.of<ToastsProvider>(context);
    final theme = Theme.of(context);

    return SafeArea(
        child: Column(
      children: [
        Spacer(),
        Container(
          padding: extraPadding,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedOpacity(
                opacity: toastsProvider.isShowing ? 1 : 0,
                duration: ToastsProvider.defaultAnimationDuration,
                child: IgnorePointer(
                  ignoring: !toastsProvider.isShowing,
                  child: BlockContainer(
                    withShadow: true,
                    // honor an explicit caller color; the dark theme maps
                    // cardColor to appleDarkGrey - the old Colors.black
                    // vanished on the black scaffold
                    backgroundColor:
                        toastsProvider.backgroundColor ?? theme.cardColor,
                    child: Text(
                      toastsProvider.message,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: toastsProvider.foregroundColor),
                    ),
                  ),
                ),
              )
            ],
          ),
        ),
      ],
    ));
  }
}
