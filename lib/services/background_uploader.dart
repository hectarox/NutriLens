import 'dart:io';
import 'dart:ui';
import 'dart:convert';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';
import 'package:shared_preferences/shared_preferences.dart';

// This file runs in background service isolate. Keep it free of BuildContext.

class BgUploaderConfig {
  final String baseUrl;
  final String? authToken;
  final String lang;
  BgUploaderConfig({required this.baseUrl, required this.lang, this.authToken});
}

int? _extractGrams(Map<String, dynamic>? structured, String textSource) {
  int? fromStructured(dynamic node) {
    if (node is Map) {
      for (final entry in node.entries) {
        final k = entry.key.toString().toLowerCase();
        if (k.contains('weight') || k.contains('poids')) {
          final n = _numberFromAny(entry.value);
          if (n != null) return n.round();
        }
        final inner = fromStructured(entry.value);
        if (inner != null) return inner;
      }
    } else if (node is List) {
      for (final e in node) {
        final inner = fromStructured(e);
        if (inner != null) return inner;
      }
    }
    return null;
  }

  int? fromText(String s) {
    final r1 = RegExp(r'(?:weight|poids)[^\d]{0,12}(\d{1,4}(?:[\.,]\d{1,2})?)\s*g', caseSensitive: false);
    final m1 = r1.firstMatch(s);
    if (m1 != null) {
      final d = double.tryParse(m1.group(1)!.replaceAll(',', '.'));
      if (d != null) return d.round();
    }
    final r2 = RegExp(r'(\d{1,4}(?:[\.,]\d{1,2})?)\s*g[^A-Za-z]{0,6}(?:weight|poids)', caseSensitive: false);
    final m2 = r2.firstMatch(s);
    if (m2 != null) {
      final d = double.tryParse(m2.group(1)!.replaceAll(',', '.'));
      if (d != null) return d.round();
    }
    return null;
  }

  return fromStructured(structured) ?? fromText(textSource);
}

double? _numberFromAny(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  final s = v.toString();
  final m = RegExp(r'(\d{1,4}(?:[\.,]\d{1,2})?)').firstMatch(s);
  if (m != null) return double.tryParse(m.group(1)!.replaceAll(',', '.'));
  return null;
}

Future<void> initializeBgService(FlutterLocalNotificationsPlugin notifs) async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: _onStart,
      // Start in background; we'll promote to foreground only when a job starts
      isForegroundMode: false,
      autoStart: false,
      notificationChannelId: 'meal_queue',
      // No initial foreground notification
      initialNotificationTitle: '',
      initialNotificationContent: '',
    ),
    iosConfiguration: IosConfiguration(),
  );
}

@pragma('vm:entry-point')
void _onStart(ServiceInstance service) {
  // Ensure plugins (like shared_preferences or notifications) are registered
  DartPluginRegistrant.ensureInitialized();
  final notifs = FlutterLocalNotificationsPlugin();
  const init = InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher'));
  notifs.initialize(init);
  // Optionally listen for commands
  service.on('process').listen((data) async {
    if (data == null) return;
    final jobId = data['id']?.toString();
    final imagePath = data['imagePath']?.toString();
    final description = data['description']?.toString() ?? '';
    final baseUrl = data['baseUrl']?.toString() ?? '';
    final lang = data['lang']?.toString() ?? 'en';
    final auth = data['auth']?.toString();
    final isMock = data['isMock'] == true;
    if (jobId == null || baseUrl.isEmpty) return;

    try {
      // Promote to foreground only while processing
      if (service is AndroidServiceInstance) {
        service.setAsForegroundService();
        service.setForegroundNotificationInfo(title: 'Meal Queue', content: 'Working…');
      }

      // Handle mock mode with 5-second delay
      if (isMock) {
        // Wait 5 seconds to simulate processing time
        await Future.delayed(const Duration(seconds: 5));
        
        // Generate mock response similar to main app
        final random = DateTime.now().millisecondsSinceEpoch % 1000;
        final foodName = description.isNotEmpty ? description : 'Sample Food';
        
        // Generate realistic but varied mock data
        final baseCalories = 200 + (random % 400); // 200-600 calories
        final carbs = 20 + (random % 60); // 20-80g carbs
        final protein = 10 + (random % 30); // 10-40g protein
        final fat = 5 + (random % 25); // 5-30g fat
        final weight = 100 + (random % 300); // 100-400g weight
        
        final mockStructured = {
          'Name': foodName,
          'Calories': '$baseCalories kcal',
          'Carbs': '${carbs}g',
          'Proteins': '${protein}g', 
          'Fats': '${fat}g',
          'Weight (g)': '${weight}g',
          'Mock': 'This is mock data for UI testing (background queue)'
        };
        
        final pretty = const JsonEncoder.withIndent('  ').convert(mockStructured);
        
        // Process mock data using same logic as real response
        final prefs = await SharedPreferences.getInstance();
        
        // Check if meal builder mode is active by checking for a flag
        final mealBuilderActive = prefs.getBool('meal_builder_active') ?? false;
        
        if (mealBuilderActive) {
          // Meal builder is active, add to current meal results instead of history
          final currentMealRaw = prefs.getString('current_meal_results_json');
          List currentMealResults = [];
          if (currentMealRaw != null && currentMealRaw.isNotEmpty) {
            try { currentMealResults = json.decode(currentMealRaw) as List; } catch (_) {}
          }
          
          final newMeal = {
            'imagePath': imagePath,
            'description': description,
            'name': foodName,
            'result': pretty,
            'structured': mockStructured,
            'grams': weight,
            'kcal': baseCalories,
            'carbs': carbs,
            'protein': protein,
            'fat': fat,
            'time': DateTime.now().toIso8601String(),
            'hcWritten': false,
          };
          
          currentMealResults.add(newMeal);
          await prefs.setString('current_meal_results_json', json.encode(currentMealResults));
          await prefs.setInt('current_meal_updated_at', DateTime.now().millisecondsSinceEpoch);
        } else {
          // Normal mode - update history
          final histRaw = prefs.getString('history_json');
          List history = [];
          if (histRaw != null && histRaw.isNotEmpty) {
            try { history = json.decode(histRaw) as List; } catch (_) {}
          }
          
          final newMeal = {
            'imagePath': imagePath,
            'description': description,
            'name': foodName,
            'result': pretty,
            'structured': mockStructured,
            'grams': weight,
            'kcal': baseCalories,
            'carbs': carbs,
            'protein': protein,
            'fat': fat,
            'time': DateTime.now().toIso8601String(),
            'hcWritten': false,
          };
          
          history.add(newMeal);
          await prefs.setString('history_json', json.encode(history));
          await prefs.setInt('history_updated_at', DateTime.now().millisecondsSinceEpoch);
        }
        
        // Notify UI isolate to refresh
        try { service.invoke('db_updated', {'jobId': jobId, 'status': 'success'}); } catch (_) {}

        // Update queue - remove completed job
        final qRaw = prefs.getString('queue_json');
        if (qRaw != null && qRaw.isNotEmpty) {
          try {
            final list = json.decode(qRaw) as List;
            list.removeWhere((e) => (e is Map && e['id']?.toString() == jobId));
            await prefs.setString('queue_json', json.encode(list));
            await prefs.setInt('queue_updated_at', DateTime.now().millisecondsSinceEpoch);
          } catch (_) {}
        }

        // Notify success
        final details = NotificationDetails(
          android: AndroidNotificationDetails(
            'meal_queue', 'Meal Queue',
            channelDescription: 'Background meal analysis status',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            ongoing: false,
            visibility: NotificationVisibility.public,
          ),
        );
        await notifs.cancel(jobId.hashCode);
        await notifs.show(jobId.hashCode, 'Mock Result', 'Mock result saved', details);
        return;
      }
      final uri = Uri.parse('$baseUrl/data');
      final request = http.MultipartRequest('POST', uri)
        ..fields['message'] = description;
      request.headers['x-app-token'] = 'FromHectaroxWithLove';
      request.headers['Accept-Language'] = lang;
      request.fields['lang'] = lang;
      if (auth != null && auth.isNotEmpty) request.headers['Authorization'] = 'Bearer $auth';
      if (imagePath != null && imagePath.isNotEmpty && File(imagePath).existsSync()) {
        request.files.add(await http.MultipartFile.fromPath(
          'image',
          imagePath,
          contentType: MediaType.parse(lookupMimeType(imagePath) ?? 'application/octet-stream'),
        ));
      }
      final resp = await request.send();
      final body = await resp.stream.bytesToString();
      if (resp.statusCode == 200) {
        // Parse pretty and basic nutrition fields (dup of UI logic, simplified)
        String pretty = body;
        Map<String, dynamic>? structured;
        try {
          final decoded = json.decode(body);
          if (decoded is Map && decoded['ok'] == true) {
            final data = decoded['data'];
            if (data is String) {
              pretty = data;
            } else {
              structured = Map<String, dynamic>.from(data as Map);
              pretty = const JsonEncoder.withIndent('  ').convert(structured);
            }
          } else if (decoded is Map && decoded.containsKey('response')) {
            pretty = decoded['response'].toString();
          } else if (decoded is Map) {
            structured = Map<String, dynamic>.from(decoded);
            pretty = const JsonEncoder.withIndent('  ').convert(structured);
          }
        } catch (_) {}

        int? kcal;
        int? carbs;
        int? protein;
        int? fat;
        int? grams;
        String? mealName;
        try {
          final textSource = structured != null ? jsonEncode(structured) : pretty;
          // Prefer structured values when available (handles localized keys)
          if (structured != null) {
            // Name heuristic
            mealName = structured['Name']?.toString()
                ?? structured["Nom de l'aliment"]?.toString()
                ?? structured['name']?.toString();
            // Calories (kcal)
            final calVal = structured['Calories'] ?? structured['kcal'] ?? structured['calories'];
            if (calVal != null) {
              final m = RegExp(r'(\d+(?:[\.,]\d+)?)').firstMatch(calVal.toString());
              if (m != null) {
                final d = double.tryParse(m.group(1)!.replaceAll(',', '.'));
                if (d != null) kcal = d.round();
              }
            }
            // Carbs / Glucides
            final cVal = structured['Glucides'] ?? structured['carbs'] ?? structured['Carbs'];
            if (cVal != null) {
              final m = RegExp(r'(\d+(?:[\.,]\d+)?)').firstMatch(cVal.toString());
              if (m != null) {
                final d = double.tryParse(m.group(1)!.replaceAll(',', '.'));
                if (d != null) carbs = d.round();
              }
            }
            // Protein / Proteines
            final pVal = structured['Proteines'] ?? structured['protein'] ?? structured['Proteins'];
            if (pVal != null) {
              final m = RegExp(r'(\d+(?:[\.,]\d+)?)').firstMatch(pVal.toString());
              if (m != null) {
                final d = double.tryParse(m.group(1)!.replaceAll(',', '.'));
                if (d != null) protein = d.round();
              }
            }
            // Fat / Lipides
            final fVal = structured['Lipides'] ?? structured['fat'] ?? structured['Fats'];
            if (fVal != null) {
              final m = RegExp(r'(\d+(?:[\.,]\d+)?)').firstMatch(fVal.toString());
              if (m != null) {
                final d = double.tryParse(m.group(1)!.replaceAll(',', '.'));
                if (d != null) fat = d.round();
              }
            }
          }
          final kcalMatch = RegExp(r'(\d{1,5}(?:[\.,]\d{1,2})?)\s*(k?cal|kilo?calories?)', caseSensitive: false).firstMatch(textSource);
          if (kcalMatch != null && kcal == null) {
            final raw = kcalMatch.group(1)!.replaceAll(',', '.');
            final d = double.tryParse(raw);
            if (d != null) kcal = d.round();
          }
          final carbsMatch = RegExp(r'(\d{1,4}(?:[\.,]\d{1,2})?)\s*g\s*(carb|glucid\w*)', caseSensitive: false).firstMatch(textSource);
          if (carbsMatch != null && carbs == null) {
            final raw = carbsMatch.group(1)!.replaceAll(',', '.');
            final d = double.tryParse(raw);
            if (d != null) carbs = d.round();
          }
          final proteinMatch = RegExp(r'(\d{1,4}(?:[\.,]\d{1,2})?)\s*g\s*(protein|prot\w*)', caseSensitive: false).firstMatch(textSource);
          if (proteinMatch != null && protein == null) {
            final raw = proteinMatch.group(1)!.replaceAll(',', '.');
            final d = double.tryParse(raw);
            if (d != null) protein = d.round();
          }
          final fatMatch = RegExp(r'(\d{1,4}(?:[\.,]\d{1,2})?)\s*g\s*(fat|lipid\w*|gras)', caseSensitive: false).firstMatch(textSource);
          if (fatMatch != null && fat == null) {
            final raw = fatMatch.group(1)!.replaceAll(',', '.');
            final d = double.tryParse(raw);
            if (d != null) fat = d.round();
          }
          // grams from structured or text
          grams = _extractGrams(structured, textSource);
        } catch (_) {}

        // Append to history and remove from queue
        final prefs = await SharedPreferences.getInstance();
        
        // Check if meal builder mode is active by checking for a flag
        final mealBuilderActive = prefs.getBool('meal_builder_active') ?? false;
        
        if (mealBuilderActive) {
          // Meal builder is active, add to current meal results instead of history
          final currentMealRaw = prefs.getString('current_meal_results_json');
          List currentMealResults = [];
          if (currentMealRaw != null && currentMealRaw.isNotEmpty) {
            try { currentMealResults = json.decode(currentMealRaw) as List; } catch (_) {}
          }
          
          final newMeal = {
            'imagePath': imagePath,
            'description': description,
            'name': mealName ?? (description.isNotEmpty ? description : null),
            'result': pretty,
            'structured': structured,
            'grams': grams,
            'kcal': kcal,
            'carbs': carbs,
            'protein': protein,
            'fat': fat,
            'time': DateTime.now().toIso8601String(),
            'hcWritten': false,
          };
          
          currentMealResults.add(newMeal);
          await prefs.setString('current_meal_results_json', json.encode(currentMealResults));
          await prefs.setInt('current_meal_updated_at', DateTime.now().millisecondsSinceEpoch);
        } else {
          // Normal mode - update history
          final histRaw = prefs.getString('history_json');
          List history = [];
          if (histRaw != null && histRaw.isNotEmpty) {
            try { history = json.decode(histRaw) as List; } catch (_) {}
          }
          
          final newMeal = {
            'imagePath': imagePath,
            'description': description,
            'name': mealName ?? (description.isNotEmpty ? description : null),
            'result': pretty,
            'structured': structured,
            'grams': grams,
            'kcal': kcal,
            'carbs': carbs,
            'protein': protein,
            'fat': fat,
            'time': DateTime.now().toIso8601String(),
            'hcWritten': false,
          };
          
          history.add(newMeal);
          await prefs.setString('history_json', json.encode(history));
          await prefs.setInt('history_updated_at', DateTime.now().millisecondsSinceEpoch);
        }
        
        // Notify UI isolate to refresh
        try { service.invoke('db_updated', {'jobId': jobId, 'status': 'success'}); } catch (_) {}

        // Update queue
        final qRaw = prefs.getString('queue_json');
        if (qRaw != null && qRaw.isNotEmpty) {
          try {
            final list = json.decode(qRaw) as List;
            list.removeWhere((e) => (e is Map && e['id']?.toString() == jobId));
            await prefs.setString('queue_json', json.encode(list));
            await prefs.setInt('queue_updated_at', DateTime.now().millisecondsSinceEpoch);
          } catch (_) {}
        }

        // Notify success
        final details = NotificationDetails(
          android: AndroidNotificationDetails(
            'meal_queue', 'Meal Queue',
            channelDescription: 'Background meal analysis status',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            ongoing: false,
            visibility: NotificationVisibility.public,
          ),
        );
        await notifs.cancel(jobId.hashCode);
        await notifs.show(jobId.hashCode, 'Result', 'Result saved', details);
      } else {
        // Mark job as error
        final prefs = await SharedPreferences.getInstance();
        final qRaw = prefs.getString('queue_json');
        if (qRaw != null && qRaw.isNotEmpty) {
          try {
            final list = (json.decode(qRaw) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
            for (final m in list) {
              if (m['id']?.toString() == jobId) {
                m['status'] = 'error';
                m['error'] = 'HTTP ${resp.statusCode}';
              }
            }
            await prefs.setString('queue_json', json.encode(list));
            await prefs.setInt('queue_updated_at', DateTime.now().millisecondsSinceEpoch);
          } catch (_) {}
        }
  // Notify UI isolate to refresh
  try { service.invoke('db_updated', {'jobId': jobId, 'status': 'error'}); } catch (_) {}
        final details = NotificationDetails(
          android: AndroidNotificationDetails(
            'meal_queue', 'Meal Queue',
            channelDescription: 'Background meal analysis status',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            ongoing: false,
            visibility: NotificationVisibility.public,
          ),
        );
        await notifs.show(jobId.hashCode, 'Upload failed', 'Tap to retry later', details);
      }
    } catch (e) {
      // Persist error state
      try {
        final prefs = await SharedPreferences.getInstance();
        final qRaw = prefs.getString('queue_json');
        if (qRaw != null && qRaw.isNotEmpty) {
          final list = (json.decode(qRaw) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          for (final m in list) {
            if (m['id']?.toString() == jobId) {
              m['status'] = 'error';
              m['error'] = e.toString();
            }
          }
          await prefs.setString('queue_json', json.encode(list));
        }
      } catch (_) {}
    } finally {
  // Stop the service; this removes its foreground notification
      service.stopSelf();
    }
  });
}

/// Start the foreground service (if not running) and dispatch a single upload job.
Future<void> startBackgroundUpload(Map<String, dynamic> jobData) async {
  final service = FlutterBackgroundService();
  // Start service if needed
  await service.startService();
  // Dispatch the job payload
  service.invoke('process', jobData);
}
