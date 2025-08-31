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
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(e.key, style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSecondaryContainer)),
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
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: scheme.tertiaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(e.key, style: theme.textTheme.labelMedium?.copyWith(color: scheme.onTertiaryContainer)),
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

    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,
          title: Row(
            children: [
              Expanded(child: Text(S.of(context).result, style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis)),
              IconButton(
                tooltip: S.of(context).copy,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: resultText));
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.of(context).copied)));
                },
                icon: const Icon(Icons.copy_all_outlined),
              ),
            ],
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Align(
              alignment: Alignment.center,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: content,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
