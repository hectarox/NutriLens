part of '../main.dart';

class _HistoryMealCard extends StatelessWidget {
  final Map<String, dynamic> meal;
  final VoidCallback onDelete;
  final VoidCallback? onTap;
  final void Function(Map<String, dynamic> source)? onDrop;
  const _HistoryMealCard({required this.meal, required this.onDelete, this.onTap, this.onDrop});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = S.of(context);
    final kcal = meal['kcal'] as int?;
    final kcalColor = kcal == null
        ? scheme.onSurfaceVariant
        : (kcal < 700 ? Colors.green : (kcal < 1000 ? Colors.orange : Colors.red));
    final carbs = meal['carbs'] as int?;
    final protein = meal['protein'] as int?;
    final fat = meal['fat'] as int?;

    final Widget cardContent = Padding(
      padding: const EdgeInsets.all(12.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (meal['image'] != null || (meal['imagePath'] is String && (meal['imagePath'] as String).isNotEmpty))
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _buildImageWidget(
                meal['image'] != null ? meal['image'] : (meal['imagePath'] as String),
                width: 72,
                height: 72,
                fit: BoxFit.cover,
              ),
            )
          else
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.fastfood, color: scheme.onSurfaceVariant),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        meal['name'] ?? meal['description'] ?? s.noDescription,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Builder(builder: (ctx) {
                      final state = context.findAncestorStateOfType<_MainScreenState>();
                      final dt = state?.asDateTime(meal['time']);
                      return dt == null
                          ? const SizedBox.shrink()
                          : Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                state!.formatTimeShort(dt),
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            );
                    }),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (kcal != null)
                      _Pill(
                        icon: Icons.local_fire_department,
                        label: '$kcal ${s.kcalSuffix}',
                        color: kcalColor,
                      ),
                    if (carbs != null) const SizedBox(height: 4),
                    if (carbs != null)
                      _Pill(
                        icon: Icons.grain,
                        label: '$carbs ${s.carbsSuffix}',
                        color: _carbsColor(context),
                      ),
                    if (protein != null)
                      _Pill(
                        icon: Icons.egg_alt,
                        label: '$protein ${s.proteinSuffix}',
                        color: Colors.teal,
                      ),
                    if (fat != null)
                      _Pill(
                        icon: Icons.blur_on,
                        label: '$fat ${s.fatSuffix}',
                        color: Colors.purple,
                      ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            onSelected: (val) async {
              if (val == 'edit') {
                final updated = await showDialog<Map<String, dynamic>>(
                  context: context,
                  builder: (ctx) {
                    final nameCtrl = TextEditingController(text: meal['name']?.toString() ?? '');
                    final kcalCtrl = TextEditingController(text: meal['kcal']?.toString() ?? '');
                    final carbsCtrl = TextEditingController(text: meal['carbs']?.toString() ?? '');
                    final proteinCtrl = TextEditingController(text: meal['protein']?.toString() ?? '');
                    final fatCtrl = TextEditingController(text: meal['fat']?.toString() ?? '');
                    // Prefill grams with AI-provided value or, for groups, the combined sum of children
                    int? defaultG = meal['grams'] as int?;
                    if (defaultG == null && meal['isGroup'] == true && meal['children'] is List) {
                      int sum = 0;
                      int count = 0;
                      for (final c in (meal['children'] as List)) {
                        if (c is Map && c['grams'] is int) { sum += c['grams'] as int; count++; }
                      }
                      if (count > 0 && sum > 0) defaultG = sum;
                    }
                    final gramsCtrl = TextEditingController(text: (defaultG?.toString() ?? ''));
                    bool linkValues = true;
                    final oldK = meal['kcal'] as int?;
                    final oldC = meal['carbs'] as int?;
                    final oldP = meal['protein'] as int?;
                    final oldF = meal['fat'] as int?;
                    // Use AI/default grams or combined group grams as baseline when linking
                    final int? oldG = defaultG;
                    return StatefulBuilder(
                      builder: (context, setSB) => AlertDialog(
                        title: Text(S.of(context).editMeal),
                        content: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextField(controller: nameCtrl, decoration: InputDecoration(labelText: S.of(context).name)),
                              const SizedBox(height: 8),
                              TextField(controller: gramsCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: S.of(context).weightLabel)),
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                value: linkValues,
                                onChanged: (v) => setSB(() => linkValues = v ?? true),
                                title: Text(S.of(context).linkValues),
                              ),
                              TextField(controller: kcalCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: S.of(context).kcalLabel)),
                              const SizedBox(height: 8),
                              TextField(controller: carbsCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: S.of(context).carbsLabel)),
                              const SizedBox(height: 8),
                              TextField(controller: proteinCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: S.of(context).proteinLabel)),
                              const SizedBox(height: 8),
                              TextField(controller: fatCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: S.of(context).fatLabel)),
                            ],
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () {
                              setSB(() {
                                nameCtrl.text = meal['name']?.toString() ?? '';
                                gramsCtrl.text = (defaultG?.toString() ?? '');
                                kcalCtrl.text = (meal['kcal']?.toString() ?? '');
                                carbsCtrl.text = (meal['carbs']?.toString() ?? '');
                                proteinCtrl.text = (meal['protein']?.toString() ?? '');
                                fatCtrl.text = (meal['fat']?.toString() ?? '');
                              });
                            },
                            child: Text(S.of(context).restoreDefaults),
                          ),
                          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(S.of(context).cancel)),
                          FilledButton(
                            onPressed: () {
                              int? newG = int.tryParse(gramsCtrl.text.trim());
                              int? newK = int.tryParse(kcalCtrl.text.trim());
                              int? newC = int.tryParse(carbsCtrl.text.trim());
                              int? newP = int.tryParse(proteinCtrl.text.trim());
                              int? newF = int.tryParse(fatCtrl.text.trim());
                              if (linkValues) {
                                double? factor;
                                if (oldC != null && newC != null && oldC > 0 && newC != oldC) {
                                  factor = newC / oldC;
                                } else if (oldP != null && newP != null && oldP > 0 && newP != oldP) {
                                  factor = newP / oldP;
                                } else if (oldF != null && newF != null && oldF > 0 && newF != oldF) {
                                  factor = newF / oldF;
                                } else if (oldK != null && newK != null && oldK > 0 && newK != oldK) {
                                  factor = newK / oldK;
                                } else if (newG != null && oldG != null && oldG > 0 && newG != oldG) {
                                  factor = newG / oldG;
                                }
                                if (factor != null) {
                                  if ((newG == null || newG == oldG) && oldG != null) newG = (oldG * factor).round();
                                  if (newK == null || newK == oldK) newK = oldK != null ? (oldK * factor).round() : null;
                                  if (newC == null || newC == oldC) newC = oldC != null ? (oldC * factor).round() : null;
                                  if (newP == null || newP == oldP) newP = oldP != null ? (oldP * factor).round() : null;
                                  if (newF == null || newF == oldF) newF = oldF != null ? (oldF * factor).round() : null;
                                }
                              }
                              Navigator.pop(ctx, {
                                'name': nameCtrl.text.trim().isEmpty ? null : nameCtrl.text.trim(),
                                'grams': newG,
                                'kcal': newK,
                                'carbs': newC,
                                'protein': newP,
                                'fat': newF,
                              });
                            },
                            child: Text(S.of(context).save),
                          ),
                        ],
                      ),
                    );
                  },
                );
                if (updated != null) {
                  meal['name'] = updated['name'] ?? meal['name'];
                  meal['grams'] = updated['grams'] ?? meal['grams'];
                  meal['kcal'] = updated['kcal'] ?? meal['kcal'];
                  meal['carbs'] = updated['carbs'] ?? meal['carbs'];
                  meal['protein'] = updated['protein'] ?? meal['protein'];
                  meal['fat'] = updated['fat'] ?? meal['fat'];
                  // ignore: use_build_context_synchronously
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.of(context).mealUpdated)));
                  final state = context.findAncestorStateOfType<_MainScreenState>();
                  await state?._saveHistory();
                }
              } else if (val == 'delete') {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(S.of(context).deleteItem),
                    content: Text(S.of(context).deleteConfirm),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(S.of(context).cancel)),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(S.of(context).delete)),
                    ],
                  ),
                );
                if (ok == true) onDelete();
              }
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(value: 'edit', child: ListTile(leading: const Icon(Icons.edit_outlined), title: Text(S.of(context).edit))),
              PopupMenuItem(value: 'delete', child: ListTile(leading: const Icon(Icons.delete_outline), title: Text(S.of(context).delete))),
            ],
          ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: DragTarget<Map<String, dynamic>>(
        onWillAccept: (data) => data != null && !identical(data, meal),
        onAccept: (data) => onDrop?.call(data),
        builder: (context, candidates, rejected) {
          final highlight = candidates.isNotEmpty;
          return LongPressDraggable<Map<String, dynamic>>(
            data: meal,
            feedback: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Card(child: cardContent),
              ),
            ),
            child: Card(
              color: highlight ? Theme.of(context).colorScheme.secondaryContainer : null,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: onTap,
                child: cardContent,
              ),
            ),
          );
        },
      ),
    );
  }
}
