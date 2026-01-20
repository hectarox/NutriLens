abstract class A2UIComponent {
  final String type;
  A2UIComponent(this.type);

  Map<String, dynamic> toJson();
  
  static A2UIComponent fromJson(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'recipe':
        return RecipeComponent.fromJson(json);
      case 'tip':
        return TipComponent.fromJson(json);
      case 'quickReplies':
      case 'suggestions': // Fallback for old messages
        return SuggestionsComponent.fromJson(json);
      case 'message':
      default:
        return TextComponent.fromJson(json);
    }
  }
}

class TextComponent extends A2UIComponent {
  final String text;
  TextComponent({required this.text}) : super('message');

  factory TextComponent.fromJson(Map<String, dynamic> json) {
    return TextComponent(text: json['content'] ?? '');
  }

  @override
  Map<String, dynamic> toJson() => {'type': 'message', 'content': text};
}

class RecipeComponent extends A2UIComponent {
  final String title;
  final List<String> ingredients;
  final List<String> instructions;
  final String calories;
  final String carbs;
  final String protein;
  final String fat;
  final String weight;
  final String sourceUrl;

  RecipeComponent({
    required this.title,
    required this.ingredients,
    required this.instructions,
    required this.calories,
    this.carbs = '',
    this.protein = '',
    this.fat = '',
    this.weight = '',
    this.sourceUrl = '',
  }) : super('recipe');

  factory RecipeComponent.fromJson(Map<String, dynamic> json) {
    return RecipeComponent(
      title: json['title'] ?? 'Unknown Recipe',
      ingredients: List<String>.from(json['ingredients'] ?? []),
      instructions: List<String>.from(json['instructions'] ?? []),
      calories: json['calories'] ?? '',
      carbs: json['carbs'] ?? '',
      protein: json['protein'] ?? '',
      fat: json['fat'] ?? '',
      weight: json['weight'] ?? '',
      sourceUrl: json['sourceUrl'] ?? '',
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'recipe',
    'title': title,
    'ingredients': ingredients,
    'instructions': instructions,
    'calories': calories,
    'carbs': carbs,
    'protein': protein,
    'fat': fat,
    'weight': weight,
    'sourceUrl': sourceUrl,
  };
}

class TipComponent extends A2UIComponent {
  final String title;
  final String description;

  TipComponent({required this.title, required this.description}) : super('tip');

  factory TipComponent.fromJson(Map<String, dynamic> json) {
    return TipComponent(
      title: json['title'] ?? 'Tip',
      description: json['description'] ?? '',
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'tip',
    'title': title,
    'description': description,
  };
}

class SuggestionsComponent extends A2UIComponent {
  final List<String> suggestions;

  SuggestionsComponent({required this.suggestions}) : super('quickReplies');

  factory SuggestionsComponent.fromJson(Map<String, dynamic> json) {
    return SuggestionsComponent(
      suggestions: List<String>.from(json['quickReplies'] ?? []),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'quickReplies',
    'quickReplies': suggestions,
  };
}
