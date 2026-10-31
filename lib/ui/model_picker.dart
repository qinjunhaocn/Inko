import 'package:flutter/material.dart';

import '../data/catalog.dart';

/// 机型选择器：按系列分组，点一下即返回。
Future<String?> showModelPicker({
  required BuildContext context,
  required WatermarkCatalog catalog,
  required String selectedId,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (BuildContext context) {
      final scheme = Theme.of(context).colorScheme;
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.82,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (BuildContext context, ScrollController controller) {
          final families = catalog.families;
          return ListView.builder(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            itemCount: families.length + 1,
            itemBuilder: (BuildContext context, int index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                  child: Text(
                    '选择机型',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                );
              }
              final family = families[index - 1];
              final models = catalog.models
                  .where((WatermarkModel m) => m.family == family)
                  .toList(growable: false);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
                    child: Text(
                      family,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  ...models.map((WatermarkModel model) {
                    final selected = model.id == selectedId;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Material(
                        color: selected
                            ? scheme.primaryContainer
                            : scheme.surfaceContainerHighest.withValues(
                                alpha: 0.55,
                              ),
                        borderRadius: BorderRadius.circular(14),
                        child: ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          title: Text(
                            model.name,
                            style: TextStyle(
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            model.styles
                                .map((WatermarkStyle s) => s.label)
                                .take(3)
                                .join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: selected
                              ? Icon(
                                  Icons.check_circle,
                                  color: scheme.onPrimaryContainer,
                                )
                              : const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).pop(model.id),
                        ),
                      ),
                    );
                  }),
                ],
              );
            },
          );
        },
      );
    },
  );
}
