part of '../main.dart';

class _FormattedResultCard extends StatelessWidget {
  final String resultText;
  const _FormattedResultCard({required this.resultText});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Map<String, dynamic>? jsonMap;
    try {
      final decoded = json.decode(resultText);
      if (decoded is Map<String, dynamic>) jsonMap = decoded;
    } catch (_) {}

    Widget content;
    if (jsonMap != null) {
      final entries = jsonMap.entries.toList();
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [scheme.primary.withOpacity(0.1), scheme.primary.withOpacity(0.05)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: scheme.primary.withOpacity(0.2)),
                    ),
                    child: Text(
                      e.key, 
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      e.value is Map || e.value is List
                          ? const JsonEncoder.withIndent('  ').convert(e.value)
                          : e.value.toString(),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    } else {
      // Try to parse simple key: value lines
      final lines = resultText.trim().split('\n');
      final kvRegex = RegExp(r'^\s*([^:]{2,})\s*:\s*(.+)$');
      final kvs = <MapEntry<String, String>>[];
      for (final l in lines) {
        final m = kvRegex.firstMatch(l);
        if (m != null) kvs.add(MapEntry(m.group(1)!, m.group(2)!));
      }
      if (kvs.isNotEmpty) {
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final e in kvs)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [scheme.secondary.withOpacity(0.1), scheme.secondary.withOpacity(0.05)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: scheme.secondary.withOpacity(0.2)),
                      ),
                      child: Text(
                        e.key, 
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.secondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(e.value)),
                  ],
                ),
              ),
          ],
        );
      } else {
        content = Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(resultText, style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace')),
        );
      }
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withOpacity(0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.primary.withOpacity(0.2),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.restaurant_menu,
                  color: scheme.onPrimary,
                  size: 16,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  S.of(context).result,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: IconButton(
                  tooltip: S.of(context).copy,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: resultText));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(S.of(context).copied)),
                    );
                  },
                  icon: Icon(
                    Icons.copy_all_outlined,
                    color: scheme.primary,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: content,
            ),
          ],
        ),
      ),
    );
  }
}
