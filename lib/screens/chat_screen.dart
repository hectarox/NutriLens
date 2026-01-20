import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/gemini_service.dart';
import '../models/a2ui_models.dart';

import '../main.dart'; // For S

class ChatMessage {
  final bool isUser;
  final List<A2UIComponent> components;
  ChatMessage({required this.isUser, required this.components});
}

class ChatScreen extends StatefulWidget {
  final Function(Map<String, dynamic>)? onAddToHistory;
  final List<Map<String, dynamic>> history;
  final int dailyLimit;

  const ChatScreen({
    super.key, 
    this.onAddToHistory,
    this.history = const [],
    this.dailyLimit = 2000,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with AutomaticKeepAliveClientMixin {
  late GeminiService _geminiService;
  final TextEditingController _controller = TextEditingController();
  final List<ChatMessage> _messages = [];
  final ScrollController _scrollController = ScrollController();
  
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _initGemini();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_messages.isEmpty) {
      final s = S.of(context);
      final hour = DateTime.now().hour;
      
      List<String> suggestions;
      if (hour >= 5 && hour < 11) {
        // Breakfast time
        suggestions = [s.suggestBreakfast, s.analyzeBreakfast, s.quickBreakfast];
      } else if (hour >= 11 && hour < 15) {
        // Lunch time
        suggestions = [s.suggestLunch, s.analyzeLunch, s.quickLunch];
      } else if (hour >= 15 && hour < 18) {
        // Afternoon snack
        suggestions = [s.suggestSnack, s.analyzeSnack, s.lowCarb];
      } else if (hour >= 18 && hour < 22) {
        // Dinner time
        suggestions = [s.suggestDinner, s.analyzeDinner, s.lightDinner];
      } else {
        // Late night / Early morning
        suggestions = [s.suggestSnack, s.lowCarb, s.suggestBreakfast];
      }

      _messages.add(ChatMessage(
        isUser: false,
        components: [
          TextComponent(text: s.chatWelcome),
          SuggestionsComponent(suggestions: suggestions)
        ]
      ));
    }
  }

  void _initGemini() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final weekStart = today.subtract(const Duration(days: 7));
    
    int todayKcal = 0;
    final recentMeals = <String>[];
    
    // Simple heuristic: assume history is sorted or just iterate all
    // Note: widget.history might be large, but usually manageable for a text prompt
    for (final meal in widget.history) {
      DateTime? time;
      if (meal['time'] is DateTime) {
        time = meal['time'];
      } else if (meal['time'] is String) {
        time = DateTime.tryParse(meal['time']);
      }
      
      if (time == null) continue;
      
      if (time.isAfter(today)) {
        todayKcal += (meal['kcal'] as num? ?? 0).toInt();
      }
      
      if (time.isAfter(weekStart)) {
         recentMeals.add("- ${meal['name']} (${meal['kcal']} kcal)");
      }
    }
    
    final contextString = "Daily Limit: ${widget.dailyLimit} kcal\n"
        "Consumed Today: $todayKcal kcal\n"
        "Recent Meals (Last 7 days):\n${recentMeals.take(50).join('\n')}";
        
    _geminiService = GeminiService(nutritionContext: contextString);
  }

  @override
  bool get wantKeepAlive => true;

  void _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _messages.add(ChatMessage(
        isUser: true, 
        components: [TextComponent(text: text)]
      ));
      _loading = true;
      _controller.clear();
    });
    _scrollToBottom();

    try {
      final response = await _geminiService.sendMessage(text);
      setState(() {
        _messages.add(ChatMessage(
          isUser: false,
          components: response
        ));
      });
      _scrollToBottom();
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    return Scaffold(
      // AppBar is handled by MainScreen usually, but if this is a tab, we might not need one.
      // However, MainScreen has an AppBar. 
      // If this is embedded in TabBarView, it shouldn't have its own Scaffold with AppBar if MainScreen already has one.
      // But MainScreen's AppBar title is static.
      // Let's assume this widget is a child of TabBarView.
      // MainScreen structure: Scaffold -> TabBarView -> Children.
      // So we don't need a Scaffold here, just the body content.
      // But wait, MainScreen's Scaffold wraps the TabBarView.
      // So we just return the content.
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                return Align(
                  alignment: msg.isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    padding: msg.isUser ? const EdgeInsets.all(12) : EdgeInsets.zero,
                    decoration: msg.isUser ? BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(16),
                    ) : null,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: msg.components.map((c) => _buildComponent(c, msg.isUser)).toList(),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller, 
                    decoration: InputDecoration(
                      hintText: S.of(context).askAboutDiets,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: const Icon(Icons.send), 
                  onPressed: _sendMessage
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComponent(A2UIComponent component, bool isUser) {
    if (component is RecipeComponent) {
      return RecipeCard(
        recipe: component,
        onAddToHistory: widget.onAddToHistory,
      );
    } else if (component is TipComponent) {
      return Card(
        color: Theme.of(context).colorScheme.tertiaryContainer,
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: Icon(Icons.lightbulb, color: Theme.of(context).colorScheme.onTertiaryContainer),
          title: Text(component.title, style: TextStyle(color: Theme.of(context).colorScheme.onTertiaryContainer, fontWeight: FontWeight.bold)),
          subtitle: Text(component.description, style: TextStyle(color: Theme.of(context).colorScheme.onTertiaryContainer)),
        ),
      );
    } else if (component is SuggestionsComponent) {
      return Padding(
        padding: const EdgeInsets.only(top: 8.0),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: component.suggestions.map((s) => ActionChip(
            label: Text(s),
            onPressed: () {
              _controller.text = s;
              _sendMessage();
            },
          )).toList(),
        ),
      );
    } else if (component is TextComponent) {
      return MarkdownBody(
        data: component.text,
        styleSheet: MarkdownStyleSheet(
          p: TextStyle(
            color: isUser 
              ? Theme.of(context).colorScheme.onPrimaryContainer 
              : Theme.of(context).colorScheme.onSurface,
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

class RecipeCard extends StatefulWidget {
  final RecipeComponent recipe;
  final Function(Map<String, dynamic>)? onAddToHistory;

  const RecipeCard({super.key, required this.recipe, this.onAddToHistory});

  @override
  State<RecipeCard> createState() => _RecipeCardState();
}

class _RecipeCardState extends State<RecipeCard> {
  double _portions = 1.0;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(widget.recipe.title, style: Theme.of(context).textTheme.titleLarge)),
                if (widget.onAddToHistory != null)
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: s.addToHistory,
                    onPressed: _addToHistory,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (widget.recipe.calories.isNotEmpty)
                  Chip(label: Text('${s.kcal}: ${_scaleValue(widget.recipe.calories)}')),
                if (widget.recipe.carbs.isNotEmpty)
                  Chip(label: Text('${s.carbs}: ${_scaleValue(widget.recipe.carbs)}')),
                if (widget.recipe.protein.isNotEmpty)
                  Chip(label: Text('${s.protein}: ${_scaleValue(widget.recipe.protein)}')),
                if (widget.recipe.fat.isNotEmpty)
                  Chip(label: Text('${s.fat}: ${_scaleValue(widget.recipe.fat)}')),
                if (widget.recipe.weight.isNotEmpty)
                  Chip(label: Text('${s.weight}: ${_scaleValue(widget.recipe.weight)}')),
              ],
            ),
            const Divider(),
            Row(
              children: [
                Text('${s.portions}: '),
                Expanded(
                  child: Slider(
                    value: _portions,
                    min: 1,
                    max: 10,
                    divisions: 9,
                    label: _portions.round().toString(),
                    onChanged: (v) => setState(() => _portions = v),
                  ),
                ),
                Text('${_portions.round()}'),
              ],
            ),
            Text('${s.ingredients}:', style: const TextStyle(fontWeight: FontWeight.bold)),
            ...widget.recipe.ingredients.map((e) => Text('• ${_scaleIngredient(e)}')),
            const SizedBox(height: 8),
            Text('${s.instructions}:', style: const TextStyle(fontWeight: FontWeight.bold)),
            ...widget.recipe.instructions.map((e) => Text('• $e')),
            if (widget.recipe.sourceUrl.isNotEmpty) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                icon: const Icon(Icons.link),
                label: Text(s.viewSource),
                onPressed: () async {
                  final uri = Uri.tryParse(widget.recipe.sourceUrl);
                  if (uri != null) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _scaleValue(String valStr) {
    final match = RegExp(r'(\d+(\.\d+)?)').firstMatch(valStr);
    if (match != null) {
      final val = double.tryParse(match.group(1)!);
      if (val != null) {
        final scaled = val * _portions;
        final numStr = scaled.toStringAsFixed(scaled.truncateToDouble() == scaled ? 0 : 1);
        return valStr.replaceFirst(match.group(1)!, numStr);
      }
    }
    return valStr;
  }

  String _scaleIngredient(String ingredient) {
    // Simple regex to find numbers and scale them
    // This is a heuristic and might not work for all formats
    return ingredient.replaceAllMapped(RegExp(r'(\d+(\.\d+)?)'), (match) {
      final val = double.tryParse(match.group(1)!);
      if (val != null) {
        final scaled = val * _portions;
        // Format to remove trailing zeros
        return scaled.toStringAsFixed(scaled.truncateToDouble() == scaled ? 0 : 1);
      }
      return match.group(0)!;
    });
  }

  void _addToHistory() {
    if (widget.onAddToHistory == null) return;
    
    double? parseAndScale(String s) {
      final m = RegExp(r'(\d+(\.\d+)?)').firstMatch(s);
      if (m != null) {
        final v = double.tryParse(m.group(1)!);
        if (v != null) return v * _portions;
      }
      return null;
    }

    final kcal = parseAndScale(widget.recipe.calories);
    final carbs = parseAndScale(widget.recipe.carbs);
    final protein = parseAndScale(widget.recipe.protein);
    final fat = parseAndScale(widget.recipe.fat);
    final weight = parseAndScale(widget.recipe.weight);

    final meal = {
      'isGroup': false,
      'name': widget.recipe.title,
      'description': S.of(context).recipeFromAiChat,
      'kcal': kcal?.round(), // Ensure int if needed, or keep double if supported. HistoryMealCard casts to int? for kcal.
      'carbs': carbs?.round(),
      'protein': protein?.round(),
      'fat': fat?.round(),
      'grams': weight?.round(),
      'time': DateTime.now(),
      'result': widget.recipe.ingredients.join('\n'),
    };
    
    widget.onAddToHistory!(meal);
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(S.of(context).addedToHistory)),
    );
  }
}
