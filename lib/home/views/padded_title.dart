import 'package:flutter/material.dart';
import 'package:kit_mobile/constants/view_constants.dart';

class PaddedTitle extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const PaddedTitle({super.key, required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
            const SizedBox(width: pageGutter),
            // every home section row puts controls AFTER this title
            // (spinner + refresh button, "Alle ansehen"): the long German
            // title at Pixel-3 width or >=1.3x font scale used to paint
            // RenderFlex overflow stripes; Flexible lets the Spacer
            // collapse first and the ellipsis actually render
            Flexible(
              child: Text(title,
                  style: theme.textTheme.titleLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: spaceMd),
          ] +
          (trailing == null ? [] : [Spacer(), trailing!]),
    );
  }
}
