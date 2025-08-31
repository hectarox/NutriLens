part of '../main.dart';

class _OffProduct {
  final String? name;
  final int? servingSizeGrams; // parsed from serving_size when possible
  final int? packageSizeGrams; // parsed from quantity (full package)
  final double? kcalPer100g;
  final double? carbsPer100g;
  final double? proteinPer100g;
  final double? fatPer100g;

  _OffProduct({this.name, this.servingSizeGrams, this.packageSizeGrams, this.kcalPer100g, this.carbsPer100g, this.proteinPer100g, this.fatPer100g});

  static _OffProduct? fromJson(Map<String, dynamic> p) {
    String? name = (p['product_name'] ?? p['generic_name']) as String?;
    final nutriments = p['nutriments'] as Map<String, dynamic>?;
    double? kcal100, carbs100, protein100, fat100;
    if (nutriments != null) {
      kcal100 = _toDouble(nutriments['energy-kcal_100g'] ?? nutriments['energy_100g']);
      carbs100 = _toDouble(nutriments['carbohydrates_100g']);
      protein100 = _toDouble(nutriments['proteins_100g']);
      fat100 = _toDouble(nutriments['fat_100g']);
    }
    int? servingSizeGrams;
    int? packageSizeGrams;
    final ss = p['serving_size'] as String?;
    if (ss != null) {
      final m = RegExp(r'(\d{1,4})\s*(g|ml)', caseSensitive: false).firstMatch(ss);
      if (m != null) {
        servingSizeGrams = int.tryParse(m.group(1)!);
      }
    }
    final qty = p['quantity'] as String?; // e.g., "330 ml" or "500 g"
    if (qty != null) {
      final m = RegExp(r'(\d{1,5})\s*(g|ml)', caseSensitive: false).firstMatch(qty);
      if (m != null) {
        packageSizeGrams = int.tryParse(m.group(1)!);
      }
    }
    return _OffProduct(
      name: name,
      servingSizeGrams: servingSizeGrams,
      packageSizeGrams: packageSizeGrams,
      kcalPer100g: kcal100,
      carbsPer100g: carbs100,
      proteinPer100g: protein100,
      fatPer100g: fat100,
    );
  }

  static double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  _ScaledNutrients scaleFor(int? grams) {
    if (grams == null || grams <= 0) {
      // fallback to full package if provided, else serving size, else assume 100g
      final g = packageSizeGrams ?? servingSizeGrams ?? 100;
      return _ScaledNutrients(
        kcal: kcalPer100g != null ? kcalPer100g! * g / 100.0 : null,
        carbs: carbsPer100g != null ? carbsPer100g! * g / 100.0 : null,
        protein: proteinPer100g != null ? proteinPer100g! * g / 100.0 : null,
        fat: fatPer100g != null ? fatPer100g! * g / 100.0 : null,
      );
    }
    return _ScaledNutrients(
      kcal: kcalPer100g != null ? kcalPer100g! * grams / 100.0 : null,
      carbs: carbsPer100g != null ? carbsPer100g! * grams / 100.0 : null,
      protein: proteinPer100g != null ? proteinPer100g! * grams / 100.0 : null,
      fat: fatPer100g != null ? fatPer100g! * grams / 100.0 : null,
    );
  }

  String prettyDescription(int? grams) {
    final parts = <String>[];
    if (name != null) parts.add(name!);
    if (grams != null && grams > 0) parts.add('~${grams}g');
    return parts.isEmpty ? 'Packaged food' : parts.join(' ');
  }
}

class _ScaledNutrients {
  final double? kcal;
  final double? carbs;
  final double? protein;
  final double? fat;
  _ScaledNutrients({this.kcal, this.carbs, this.protein, this.fat});
}
