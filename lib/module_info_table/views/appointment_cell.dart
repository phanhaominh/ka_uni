import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:kit_mobile/module_info_table/models/module_info_table_cell.dart';

class AppointmentCell extends StatelessWidget {
  final ModuleInfoTableCell cellData;

  const AppointmentCell({super.key, required this.cellData});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(5),
          child: Icon(
            CupertinoIcons.arrow_turn_down_right,
            size: 15,
            color: theme.colorScheme.primary,
          ),
        ),
        // dateStr/timeStr are scraped verbatim and can be long multi-date
        // lists ("20.04.2026, 27.04.2026, …"): side by side they overflowed
        // the row. One Expanded with the time under the date; what still
        // does not fit ellipsizes instead of painting off-screen
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // scraped verbatim; the cell translates the German words
              // ("Do, wöchentlich" -> "Thu, weekly") in an English UI
              Text(cellData.localisedDateLabel,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              Text(cellData.timeStr,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ],
    );
  }
}
