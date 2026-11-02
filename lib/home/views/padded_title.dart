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
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(width: spaceMd),
          ] +
          (trailing == null ? [] : [Spacer(), trailing!]),
    );
  }
}
