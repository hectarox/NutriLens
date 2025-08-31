part of '../main.dart';

class _ExpandableDaySection extends StatefulWidget {
  final String title;
  final int totalKcal;
  final int? totalCarbs;
  final int? totalProtein;
  final int? totalFat;
  final List<Widget> children;
  const _ExpandableDaySection({
    required this.title,
    required this.totalKcal,
    this.totalCarbs,
    this.totalProtein,
    this.totalFat,
    required this.children,
  });

  @override
  State<_ExpandableDaySection> createState() => _ExpandableDaySectionState();
}

class _ExpandableDaySectionState extends State<_ExpandableDaySection> {
  bool _expanded = true;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final kcal = widget.totalKcal;
    final color = kcal < 1400
        ? Colors.green
        : (kcal < 2000 ? Colors.orange : Colors.red);
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: _expanded,
          onExpansionChanged: (v) => setState(() => _expanded = v),
          title: Text(
            widget.title,
            style: Theme.of(context).textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 8.0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                  child: Row(children: [
                    Icon(Icons.local_fire_department, size: 16, color: color),
                    const SizedBox(width: 6),
                    Text('$kcal ${s.kcalSuffix}', style: TextStyle(color: color)),
                  ]),
                ),
                if (widget.totalCarbs != null)
                  Builder(builder: (ctx) {
                    final c = _carbsColor(ctx);
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: c.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                      child: Row(children: [
                        Icon(Icons.grain, size: 16, color: c),
                        const SizedBox(width: 6),
                        Text('${widget.totalCarbs} ${s.carbsSuffix}', style: TextStyle(color: c)),
                      ]),
                    );
                  }),
                if (widget.totalProtein != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: Colors.teal.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                    child: Row(children: [
                      const Icon(Icons.egg_alt, size: 16, color: Colors.teal),
                      const SizedBox(width: 6),
                      Text('${widget.totalProtein} ${s.proteinSuffix}', style: const TextStyle(color: Colors.teal)),
                    ]),
                  ),
                if (widget.totalFat != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: Colors.purple.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                    child: Row(children: [
                      const Icon(Icons.blur_on, size: 16, color: Colors.purple),
                      const SizedBox(width: 6),
                      Text('${widget.totalFat} ${s.fatSuffix}', style: const TextStyle(color: Colors.purple)),
                    ]),
                  ),
              ],
            ),
          ),
          children: widget.children,
        ),
      ),
    );
  }
}
