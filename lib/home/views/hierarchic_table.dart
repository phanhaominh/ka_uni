import 'package:flutter/material.dart';
import 'package:kit_mobile/module/views/module_page.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:provider/provider.dart';

import '../../parsing/models/hierarchic_table_row.dart';

class HierarchicTableView extends StatefulWidget {
  final List<HierarchicTableRow> rows;

  const HierarchicTableView({super.key, required this.rows});
  final minLevelToShow = 3;

  @override
  State<HierarchicTableView> createState() => _HierarchicTableViewState();
}

class _HierarchicTableViewState extends State<HierarchicTableView> {
  // C12: while a module page for a given row is on the stack, further taps
  // on that row must not push a second identical page (each one runs a full
  // scrape). Tracks the live pushed route per row id and clears on pop.
  final Map<String, Route> _pushedModuleRoutes = {};

  void _openModule(HierarchicTableRow row) {
    final key = row.id;
    if (_pushedModuleRoutes.containsKey(key)) return; // already on the stack
    final vm = context.read<KITProvider>();
    final moduleFuture = vm.getOrFetchModuleForRow(row);
    final route = MaterialPageRoute(
        builder: (BuildContext context) => ModuleView(module: moduleFuture));
    _pushedModuleRoutes[key] = route;
    Navigator.of(context).push(route).whenComplete(() {
      if (mounted) _pushedModuleRoutes.remove(key);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final minLevelToShow = widget.minLevelToShow;

    return Column(
      children: widget.rows.map((row) {
        if (row.level < minLevelToShow) {
          return const SizedBox(width: 0, height: 0);
        }

        return GestureDetector(
          onTap: () => _openModule(row),
          child: Padding(
            padding: EdgeInsets.only(
                left: 10 + (row.level - minLevelToShow) * 20,
                top: row.level == minLevelToShow ? 8 : 6,
                bottom: row.level == minLevelToShow ? 8 : 0,
                right: 10),
            child: Column(
              children: [
                (row.level == minLevelToShow
                    ? const Divider()
                    : const SizedBox(height: 0)),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        row.title,
                        maxLines: 3,
                        style: row.level == minLevelToShow
                            ? theme.textTheme.titleMedium
                            : theme.textTheme.bodyMedium,
                      ),
                    ),
                    // C12: truncate, don't blank — the old `length < 6`
                    // gate silently hid any real grade string
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 120),
                      child: Text(
                        row.grade,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                )
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}
