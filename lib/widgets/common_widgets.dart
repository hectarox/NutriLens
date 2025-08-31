part of '../main.dart';

Color _carbsColor(BuildContext context) {
  // In light mode, use a distinct blue for carbs; in dark mode keep amber for legibility.
  // If daltonian mode is enabled, use high-contrast teal.
  final isLight = Theme.of(context).brightness == Brightness.light;
  if (appSettings.daltonian) return Colors.teal;
  return isLight ? Colors.blue : Colors.amber;
}

class _ProgressBar extends StatelessWidget {
  final double value; // 0.0 .. 1.5
  final Color color;
  const _ProgressBar({required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final capped = value.clamp(0.0, 1.0);
    final overflow = (value - 1.0).clamp(0.0, 0.5);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 18,
        color: scheme.surfaceContainerHighest,
        child: Stack(
          children: [
            FractionallySizedBox(
              widthFactor: capped,
              child: Container(color: color.withOpacity(0.85)),
            ),
            if (overflow > 0)
              Align(
                alignment: Alignment.centerRight,
                child: FractionallySizedBox(
                  widthFactor: overflow,
                  alignment: Alignment.centerRight,
                  child: Container(color: Colors.red.shade900.withOpacity(0.7)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _Pill({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    // Cap the pill width and ellipsize text to avoid bleeding over the card edge on low-DPI screens
    final w = MediaQuery.of(context).size.width;
    final maxW = w < 360
        ? 110.0
        : w < 420
            ? 140.0
            : 180.0;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxW),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                style: TextStyle(color: color, fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
