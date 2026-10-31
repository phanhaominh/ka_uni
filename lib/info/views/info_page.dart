import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:kit_mobile/common_ui/kit_logo.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../common_ui/block_container.dart';
import '../../l10n/l10n.dart';

class InfoPage extends StatefulWidget {
  const InfoPage({super.key});

  @override
  State<StatefulWidget> createState() {
    return _InfoPageState();
  }
}

class _InfoPageState extends State<InfoPage> {
  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<KITProvider>(context);
    final mq = MediaQuery.of(context);
    final theme = Theme.of(context);

    bool isPersonalized = vm.profileReady;

    final greeting =
        isPersonalized ? "Hi, ${vm.student.name.repr}!" : L10n.t("settings.hello");

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Text("Was ist"),
            KITLogo()
          ],
        ),
        actions: [
          CupertinoButton(
            child: SizedBox(
              width: 20,
              height: 20,
              child: SvgPicture.asset(
                "assets/images/GitHub.svg",
                colorFilter: ColorFilter.mode(
                    theme.colorScheme.primary, BlendMode.srcIn),
              ),
            ),
            onPressed: () =>
                launchUrl(Uri.parse("https://github.com/DEMIDOB/ka_uni")),
          )
        ],
        centerTitle: true,
      ),
      body: ListView(
        children: [
          Container(
            width: mq.size.width,
            padding: const EdgeInsets.only(top: 10.0, left: 25, right: 25),
            child: Hero(
              tag: "greeting",
              child: Text(
                greeting,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
                maxLines: 2,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(10.0),
            child: Column(
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: mq.size.width - 30,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 15, vertical: 10),
                        child: Text(
                          L10n.t("settings.aboutIntro"),
                          maxLines: 10,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ],
                ),

                CupertinoButton(
                    child: Text(L10n.t("info.privacyPolicy")),
                    onPressed: () {
                      launchUrlString("https://dandemidov.com/ka_uni/privacy_policy/");
                    }),

                InfoViewFaqSection(
                    title: L10n.t("settings.faqSecurityTitle"),
                    body: L10n.t("settings.faqSecurityBody")),

                // !isAlpha ? Text("") : Container(
                //   padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 10),
                //   decoration: BoxDecoration(
                //     borderRadius: BorderRadius.all(Radius.circular(5)),
                //     border: Border.all(color: Colors.red)
                //   ),
                //   child: Row(
                //     mainAxisAlignment: MainAxisAlignment.spaceBetween,
                //     children: [
                //       Text("α", style: theme.textTheme.bodyMedium?.copyWith(color: Colors.red, fontWeight: FontWeight.bold)),
                //       Text("Die App ist noch in alpha!", style: theme.textTheme.bodyMedium?.copyWith(color: Colors.red, fontWeight: FontWeight.bold),),
                //       Text("α", style: theme.textTheme.bodyMedium?.copyWith(color: Colors.red, fontWeight: FontWeight.bold)),
                //     ],
                //   ),
                // ),

                InfoViewFaqSection(
                    title: L10n.t("settings.faqContributeTitle"),
                    body: L10n.t("settings.faqContributeBody")),

                InfoViewFaqSection(
                    title: L10n.t("settings.faqRoadmapTitle"),
                    body: L10n.t("settings.faqRoadmapBody")),
              ],
            ),
          )
        ],
      ),
    );
  }
}

class InfoViewFaqSection extends StatelessWidget {
  final String title, body;

  const InfoViewFaqSection(
      {super.key, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mq = MediaQuery.of(context);

    return BlockContainer(
      padding: EdgeInsets.symmetric(vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium,
          ),
          SizedBox(
            width: mq.size.width - 20,
            child: Text(
              body,
              maxLines: 10,
            ),
          )
        ],
      ),
    );
  }
}
