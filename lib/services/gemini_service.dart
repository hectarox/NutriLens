import 'dart:convert';
import 'dart:ui' show Locale;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/a2ui_models.dart';
import '../main.dart'; // For kDefaultBaseUrl and authState

class GeminiService {
  final List<Map<String, dynamic>> _history = [];

  GeminiService({String? nutritionContext}) {
    // Initialize with system prompt
    String systemPrompt = 'You are a helpful nutrition assistant. You help users with diets, recipes, and healthy eating tips. You must output JSON.';
    if (nutritionContext != null && nutritionContext.isNotEmpty) {
      systemPrompt += '\n\nUser Context:\n$nutritionContext';
    }

    _history.add({
      'role': 'user',
      'parts': [{'text': systemPrompt}]
    });
    _history.add({
      'role': 'model',
      'parts': [{'text': '[]'}] // Dummy response to match user turn
    });
  }

  Future<List<A2UIComponent>> sendMessage(String message) async {
    try {
      debugPrint('[chat] sending to /chat: ${message.length} chars');
      final s = S(appSettings.locale ?? const Locale('en'));
      final uri = Uri.parse('$kDefaultBaseUrl/chat');
      final headers = {
        'Content-Type': 'application/json',
        'x-app-token': kAppToken,
        if (authState.token != null) 'Authorization': 'Bearer ${authState.token}',
      };

      final body = jsonEncode({
        'message': message,
        'history': _history,
        'lang': (appSettings.locale ?? const Locale('en')).languageCode,
      });

      final response = await http.post(uri, headers: headers, body: body);
      debugPrint('[chat] status ${response.statusCode}');

      if (response.statusCode != 200) {
        print('Error: ${response.statusCode} ${response.body}');
        return [TextComponent(text: s.chatServerError(response.statusCode))];
      }

      final decoded = jsonDecode(response.body);
      final List<dynamic> jsonList = decoded is List ? decoded : [decoded];
      
      // Update history
      _history.add({
        'role': 'user',
        'parts': [{'text': message}]
      });
      _history.add({
        'role': 'model',
        'parts': [
          {
            'text': decoded is String ? decoded : jsonEncode(decoded)
          }
        ] // Store the raw JSON response as text
      });

      return jsonList.map((e) => A2UIComponent.fromJson(e)).toList();
    } catch (e) {
      print('Error sending message: $e');
      final s = S(appSettings.locale ?? const Locale('en'));
      return [TextComponent(text: s.chatGenericError(e.toString()))];
    }
  }
}
