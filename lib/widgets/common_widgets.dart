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
    // Responsive design based on screen width and text scale factor
    final mediaQuery = MediaQuery.of(context);
    final screenWidth = mediaQuery.size.width;
    final textScaleFactor = mediaQuery.textScaleFactor;
    
    // Calculate responsive dimensions
    final double maxWidth;
    final double iconSize;
    final double fontSize;
    final EdgeInsets padding;
    final double spacing;
    
    if (screenWidth < 320) {
      // Very small screens (old phones)
      maxWidth = 85.0;
      iconSize = 11.0;
      fontSize = 9.0;
      padding = const EdgeInsets.symmetric(horizontal: 5, vertical: 2);
      spacing = 3.0;
    } else if (screenWidth < 360) {
      // Small screens
      maxWidth = 110.0;
      iconSize = 12.0;
      fontSize = 10.0;
      padding = const EdgeInsets.symmetric(horizontal: 6, vertical: 3);
      spacing = 4.0;
    } else if (screenWidth < 420) {
      // Medium screens
      maxWidth = 140.0;
      iconSize = 14.0;
      fontSize = 11.0;
      padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4);
      spacing = 6.0;
    } else if (screenWidth < 600) {
      // Large screens
      maxWidth = 180.0;
      iconSize = 15.0;
      fontSize = 12.0;
      padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 5);
      spacing = 6.0;
    } else {
      // Extra large screens (tablets)
      maxWidth = 220.0;
      iconSize = 16.0;
      fontSize = 13.0;
      padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 6);
      spacing = 8.0;
    }
    
    // Adjust for accessibility text scaling
    final adjustedFontSize = fontSize * textScaleFactor.clamp(0.8, 1.3);
    final adjustedIconSize = iconSize * textScaleFactor.clamp(0.8, 1.2);
    
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: adjustedIconSize, color: color),
            SizedBox(width: spacing),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: color, 
                  fontSize: adjustedFontSize,
                  fontWeight: FontWeight.w500,
                ),
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


// Compact pill widget for total nutrition bar
class _CompactPill extends StatelessWidget {
  final String label;
  final Color color;

  const _CompactPill({
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.4), width: 0.5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
