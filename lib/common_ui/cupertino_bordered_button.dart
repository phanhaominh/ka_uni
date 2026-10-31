import 'package:flutter/cupertino.dart';

class CupertinoBorderedButton extends StatelessWidget {
  final String title;
  final IconData? icon;
  final Function? onPressed;

  const CupertinoBorderedButton(
      {super.key, required this.title, this.icon, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        sizeStyle: CupertinoButtonSize.small,
        onPressed: () {
          if (onPressed != null) {
            onPressed!();
          }
        },
        child: Row(
          children: [
            Text(title),
            SizedBox(
              width: 5,
            ),
            Icon(icon)
          ],
        ),
    );
  }
}
