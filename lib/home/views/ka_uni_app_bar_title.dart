import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../common_ui/kit_logo.dart';
import '../../l10n/l10n.dart';
import '../../settings/providers/settings_provider.dart';
import '../../state_management/kit_provider.dart';

class KaUniAppBarTitle extends StatelessWidget {
  const KaUniAppBarTitle({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<KITProvider>(context);
    final settingsVM = Provider.of<SettingsProvider>(context);
    final theme = Theme.of(context);

    // split the localized template around the name so the name keeps its
    // primary-color tint in every locale
    final greetingParts = L10n.t("settings.helloName").split("{0}");

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: settingsVM.showingProfile.value
              ? const KITLogo()
              : Text.rich(
                  TextSpan(
                    style: theme.textTheme.titleLarge,
                    children: [
                      TextSpan(text: greetingParts.first),
                      TextSpan(
                        text: vm.student.name.firstName,
                        style: TextStyle(color: theme.colorScheme.primary),
                      ),
                      if (greetingParts.length > 1)
                        TextSpan(text: greetingParts[1]),
                    ],
                  ),
                ),
        )
      ],
    );
  }
}
