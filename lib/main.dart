 import 'dart:io';
 import 'dart:typed_data';
 import 'dart:async';
 import 'dart:ui';
 import 'package:flutter/foundation.dart';
 import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/services.dart';
import 'package:health/health.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'services/background_uploader.dart' as bg;

// Include the widget files as parts
part 'widgets/common_widgets.dart';
part 'widgets/formatted_result_card.dart';
part 'widgets/expandable_day_section.dart';
part 'widgets/history_meal_card.dart';
part 'screens/barcode_scanner_screen.dart';
part 'models/off_product.dart';
// permission_handler not required for nutrition; we rely on health plugin's auth flow

// Split parts
part 'l10n/translations.dart';

// Notifications setup (Android): used to track background queue status
final FlutterLocalNotificationsPlugin _notifs = FlutterLocalNotificationsPlugin();
final StreamController<String?> notificationTapStream = StreamController<String?>.broadcast();
String? _initialNotifPayload;

Future<void> _initNotifications() async {
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  final initSettings = InitializationSettings(android: android);
  await _notifs.initialize(
    initSettings,
    onDidReceiveNotificationResponse: (resp) {
      notificationTapStream.add(resp.payload);
    },
    onDidReceiveBackgroundNotificationResponse: _onBgNotificationTap,
  );
  // Android 13+ runtime notifications permission
  final androidPlugin = _notifs.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.requestNotificationsPermission();
  // Ensure channel exists for our background queue
  const channel = AndroidNotificationChannel(
    'meal_queue',
    'Meal Queue',
    description: 'Background meal analysis status',
    importance: Importance.defaultImportance,
  );
  await androidPlugin?.createNotificationChannel(channel);
}

// Preparing/queued notification disabled per request; function removed

Future<void> _notifyDone({required String jobId, required String title, required String body, String? payload}) async {
  await _notifs.cancel(jobId.hashCode);
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
  await _notifs.show(jobId.hashCode, title, body, details, payload: payload);
}

@pragma('vm:entry-point')
void _onBgNotificationTap(NotificationResponse resp) {
  // Forward background tap to foreground via stream when app resumes
  notificationTapStream.add(resp.payload);
}

// Simple app settings with locale persistence
class AppSettings extends ChangeNotifier {
  Locale? _locale;
  Locale? get locale => _locale;
  bool _daltonian = false;
  bool get daltonian => _daltonian;
  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  static const _prefsKey = 'app_locale'; // values: 'system', 'en', 'fr'
  static const _prefsDaltonian = 'daltonian_mode';
  static const _prefsThemeMode = 'theme_mode'; // values: 'system', 'light', 'dark'

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_prefsKey);
    if (code == null || code == 'system') {
      _locale = null; // follow system
    } else {
      _locale = Locale(code);
      Intl.defaultLocale = code;
    }
    _daltonian = prefs.getBool(_prefsDaltonian) ?? false;
    
    // Load theme mode
    final themeModeString = prefs.getString(_prefsThemeMode) ?? 'system';
    switch (themeModeString) {
      case 'light':
        _themeMode = ThemeMode.light;
        break;
      case 'dark':
        _themeMode = ThemeMode.dark;
        break;
      default:
        _themeMode = ThemeMode.system;
        break;
    }
  }

  Future<void> setLocale(Locale? value) async {
    _locale = value;
    Intl.defaultLocale = value?.languageCode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (value == null) {
      await prefs.setString(_prefsKey, 'system');
    } else {
      await prefs.setString(_prefsKey, value.languageCode);
    }
  }

  Future<void> setDaltonian(bool value) async {
    _daltonian = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsDaltonian, value);
  }

  Future<void> setThemeMode(ThemeMode value) async {
    _themeMode = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    String themeModeString;
    switch (value) {
      case ThemeMode.light:
        themeModeString = 'light';
        break;
      case ThemeMode.dark:
        themeModeString = 'dark';
        break;
      default:
        themeModeString = 'system';
        break;
    }
    await prefs.setString(_prefsThemeMode, themeModeString);
  }
}

final appSettings = AppSettings();
String get kDefaultBaseUrl => dotenv.maybeGet('APP_BASE_URL') ?? 'http://141.145.210.115:3007';
// When PASSWORD_AUTH=false in .env.client, the app skips password login
bool get kPasswordAuthEnabled {
  final v = dotenv.maybeGet('PASSWORD_AUTH') ?? dotenv.maybeGet('password_auth');
  if (v == null) return true;
  final s = v.toLowerCase();
  return !(s == 'false' || s == '0' || s == 'off' || s == 'no');
}
class AuthState extends ChangeNotifier {
  String? _token;
  String? get token => _token;

  static const _tokenKey = 'jwt_token';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_tokenKey);
    notifyListeners();
  }

  Future<void> setToken(String? value) async {
    final prefs = await SharedPreferences.getInstance();
    _token = value;
    if (value == null) {
      await prefs.remove(_tokenKey);
    } else {
      await prefs.setString(_tokenKey, value);
    }
    notifyListeners();
  }
}

final authState = AuthState();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: '.env.client');
  } catch (_) {}
  await _initNotifications();
  // Ensure no stale foreground service/notification from previous session
  try {
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      final svc = FlutterBackgroundService();
      // Ask any running service instance to stop
      svc.invoke('stopService');
    }
    // Also clear stale notifications at boot
    await _notifs.cancelAll();
  } catch (_) {}
  try {
    final launch = await _notifs.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      _initialNotifPayload = launch?.notificationResponse?.payload;
    }
  } catch (_) {}
  // Configure background service once at startup (Android/iOS only)
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    await bg.initializeBgService(_notifs);
  }
  await appSettings.load();
  await authState.load();
  runApp(const RootApp());
}

// Hook into the first frame to handle notification that launched the app
class _NotifTapHandler extends StatefulWidget {
  final Widget child;
  const _NotifTapHandler({required this.child});
  @override
  State<_NotifTapHandler> createState() => _NotifTapHandlerState();
}

class _NotifTapHandlerState extends State<_NotifTapHandler> {
  StreamSubscription<String?>? _sub;
  @override
  void initState() {
    super.initState();
    // Listen runtime taps
    _sub = notificationTapStream.stream.listen(_handlePayload);
    // Handle initial payload if any
    if (_initialNotifPayload != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _handlePayload(_initialNotifPayload));
      _initialNotifPayload = null;
    }
  }

  void _handlePayload(String? payload) async {
    if (payload == null || payload.isEmpty) return;
    // Expected payload: meal:<timestamp>
    if (!mounted) return;
    final state = context.findAncestorStateOfType<_MainScreenState>();
    if (state == null) return;
    await state._loadHistory();
    final when = payload.startsWith('meal:') ? payload.substring(5) : '';
    Map<String, dynamic>? found;
    if (when.isNotEmpty) {
      final dt = DateTime.tryParse(when);
      if (dt != null) {
        found = state._history.cast<Map<String, dynamic>?>().firstWhere(
          (m) => m != null && state._asDateTime(m['time'])?.toIso8601String() == dt.toIso8601String(),
          orElse: () => null,
        );
      }
    }
    if (found == null && state._history.isNotEmpty) {
      found = state._history.last; // fallback to the latest
    }
    if (found != null) {
      // open details
      state._tabController.animateTo(0);
      state._showMealDetails(found);
    } else {
      // still refresh UI
      await state._loadQueue();
      state.setState(() {});
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class RootApp extends StatelessWidget {
  const RootApp({super.key});

  @override
  Widget build(BuildContext context) {
    const fallbackSeed = Color(0xFF6750A4);
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        final ColorScheme lightScheme = lightDynamic ?? ColorScheme.fromSeed(seedColor: fallbackSeed, brightness: Brightness.light);
        final ColorScheme darkScheme = darkDynamic ?? ColorScheme.fromSeed(seedColor: fallbackSeed, brightness: Brightness.dark);

        final ThemeData lightTheme = ThemeData(
          colorScheme: lightScheme,
          useMaterial3: true,
          appBarTheme: AppBarTheme(
            backgroundColor: lightScheme.surface,
            foregroundColor: lightScheme.onSurface,
            elevation: 0,
            centerTitle: true,
          ),
          cardTheme: const CardThemeData(
            elevation: 0,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
          ),
          inputDecorationTheme: InputDecorationTheme(
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            ),
          ),
        );

        final ThemeData darkTheme = ThemeData(
          colorScheme: darkScheme,
          useMaterial3: true,
          appBarTheme: AppBarTheme(
            backgroundColor: darkScheme.surface,
            foregroundColor: darkScheme.onSurface,
            elevation: 0,
            centerTitle: true,
          ),
          cardTheme: const CardThemeData(
            elevation: 0,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
          ),
          inputDecorationTheme: InputDecorationTheme(
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            ),
          ),
        );

        return AnimatedBuilder(
          animation: appSettings,
          builder: (context, _) => AnimatedTheme(
            duration: const Duration(milliseconds: 2000), // Slow, comfortable transition
            curve: Curves.easeInOut, // Standard ease-in-out for smooth start/end
            data: appSettings.themeMode == ThemeMode.dark 
                ? darkTheme 
                : appSettings.themeMode == ThemeMode.light 
                    ? lightTheme 
                    : MediaQuery.of(context).platformBrightness == Brightness.dark 
                        ? darkTheme 
                        : lightTheme,
            child: Builder(
              builder: (context) => _NotifTapHandler(child: MaterialApp(
                onGenerateTitle: (ctx) => S.of(ctx).appTitle,
                theme: lightTheme,
                darkTheme: darkTheme,
                themeMode: appSettings.themeMode,
                locale: appSettings.locale,
                supportedLocales: const [Locale('en'), Locale('fr')],
                localizationsDelegates: [
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                home: const AuthGate(),
              )),
            ),
          ),
        );
      },
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  @override
  void initState() {
    super.initState();
    authState.addListener(_onAuth);
  }

  @override
  void dispose() {
    authState.removeListener(_onAuth);
    super.dispose();
  }

  void _onAuth() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
  if (!kPasswordAuthEnabled) return const MainScreen();
  if (authState.token == null) return const LoginScreen();
    return const MainScreen();
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _u = TextEditingController();
  final _p = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _busy = true; _error = null; });
    try {
  final uri = Uri.parse('$kDefaultBaseUrl/auth/login');
      final resp = await http.post(uri, headers: {
        'Content-Type': 'application/json',
      }, body: jsonEncode({ 'username': _u.text.trim(), 'password': _p.text }));
      if (resp.statusCode != 200) {
        setState(() { _error = S.of(context).loginFailedCode(resp.statusCode); });
        return;
      }
      final jsonBody = json.decode(resp.body) as Map;
      if (jsonBody['ok'] != true) {
  setState(() { _error = (jsonBody['error']?.toString() ?? S.of(context).loginError); });
        return;
      }
      final token = jsonBody['token']?.toString();
      final force = jsonBody['forcePasswordReset'] == true;
      if (token == null || token.isEmpty) {
  setState(() { _error = S.of(context).noTokenReceived; });
        return;
      }
      await authState.setToken(token);
      if (!mounted) return;
      if (force) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const SetPasswordScreen()));
      } else {
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const MainScreen()));
      }
    } catch (e) {
      setState(() { _error = S.of(context).networkError; });
    } finally {
      if (mounted) setState(() { _busy = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
  appBar: AppBar(title: Text('${s.appTitle} • ${s.login}')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: _u,
                    decoration: InputDecoration(labelText: s.username),
                    validator: (v) => (v==null||v.trim().isEmpty) ? s.required : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _p,
                    obscureText: true,
                    decoration: InputDecoration(labelText: s.password),
                    validator: (v) => (v==null||v.isEmpty) ? s.required : null,
                  ),
                  const SizedBox(height: 16),
                  if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _busy ? null : _login,
                    child: _busy ? const SizedBox(width: 18,height:18,child:CircularProgressIndicator(strokeWidth:2)) : Text(s.login),
                  ),
                  const SizedBox(height: 24),
                  Text(s.betaSignup, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  IconButton(
                    tooltip: s.joinDiscordAction,
                    iconSize: 28,
                    onPressed: () async {
                      final uri = Uri.parse('https://discord.gg/8bDDqbvr8K');
                      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(s.openDiscordFailed)),
                          );
                        }
                      }
                    },
                    icon: const FaIcon(FontAwesomeIcons.discord),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SetPasswordScreen extends StatefulWidget {
  const SetPasswordScreen({super.key});
  @override
  State<SetPasswordScreen> createState() => _SetPasswordScreenState();
}

class _SetPasswordScreenState extends State<SetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _p1 = TextEditingController();
  final _p2 = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
  if (!_formKey.currentState!.validate()) return;
  if (_p1.text != _p2.text) { setState((){_error=S.of(context).passwordsDoNotMatch;}); return; }
    setState(() { _busy = true; _error = null; });
    try {
  final uri = Uri.parse('$kDefaultBaseUrl/auth/set-password');
      final resp = await http.post(uri, headers: {
        'Content-Type': 'application/json',
        if (authState.token != null) 'Authorization': 'Bearer ${authState.token}',
      }, body: jsonEncode({ 'newPassword': _p1.text }));
      if (resp.statusCode != 200) {
        setState(() { _error = S.of(context).failedWithCode(resp.statusCode); });
        return;
      }
      final body = json.decode(resp.body) as Map;
      if (body['ok'] != true) {
        setState(() { _error = (body['error']?.toString() ?? S.of(context).error); });
        return;
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const MainScreen()));
    } catch (e) {
      setState(() { _error = S.of(context).networkError; });
    } finally {
      if (mounted) setState(() { _busy = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
  appBar: AppBar(title: Text('${s.appTitle} • ${s.setPasswordTitle}')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: _p1,
                    obscureText: true,
                    decoration: InputDecoration(labelText: s.newPassword),
                    validator: (v) => (v==null||v.length<6) ? s.min6 : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _p2,
                    obscureText: true,
                    decoration: InputDecoration(labelText: s.confirmPassword),
                    validator: (v) => (v==null||v.length<6) ? s.min6 : null,
                  ),
                  const SizedBox(height: 16),
                  if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _busy ? null : _save,
                    child: _busy ? const SizedBox(width: 18,height:18,child:CircularProgressIndicator(strokeWidth:2)) : const Text('Save'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

// Helper function to create web-compatible image widgets with error handling
Widget _buildImageWidget(dynamic imageSource, {double? width, double? height, BoxFit? fit}) {
  if (kIsWeb) {
    // On web, use Image.network for XFile or Image.memory for bytes
    if (imageSource is XFile) {
      return FutureBuilder<Uint8List>(
        future: imageSource.readAsBytes(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            if (snapshot.hasData && snapshot.data != null) {
              try {
                return Image.memory(
                  snapshot.data!,
                  width: width,
                  height: height,
                  fit: fit ?? BoxFit.cover,
                );
              } catch (e) {
                // Handle image decoding errors
                return Container(
                  width: width,
                  height: height,
                  color: Colors.grey[300],
                  child: const Icon(Icons.broken_image),
                );
              }
            } else {
              // Failed to read bytes
              return Container(
                width: width,
                height: height,
                color: Colors.grey[300],
                child: const Icon(Icons.image_not_supported),
              );
            }
          } else {
            // Still loading
            return Container(
              width: width,
              height: height,
              color: Colors.grey[300],
              child: const Icon(Icons.image),
            );
          }
        },
      );
    } else if (imageSource is String) {
      // For file paths on web, we can't access them directly
      return Container(
        width: width,
        height: height,
        color: Colors.grey[300],
        child: const Icon(Icons.image_not_supported),
      );
    }
  } else {
    // On mobile platforms, use Image.file as normal with error handling
    String? path;
    if (imageSource is XFile) {
      path = imageSource.path;
    } else if (imageSource is String) {
      path = imageSource;
    }
    
    if (path != null) {
      // Check if file exists before trying to load it
      if (File(path).existsSync()) {
        return Image.file(
          File(path),
          width: width,
          height: height,
          fit: fit ?? BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            // Handle image loading errors
            return Container(
              width: width,
              height: height,
              color: Colors.grey[300],
              child: const Icon(Icons.broken_image),
            );
          },
        );
      } else {
        // File doesn't exist
        return Container(
          width: width,
          height: height,
          color: Colors.grey[300],
          child: const Icon(Icons.image_not_supported),
        );
      }
    }
  }
  
  return Container(
    width: width,
    height: height,
    color: Colors.grey[300],
    child: const Icon(Icons.image),
  );
}

// Moved _image and _controller to the class level to ensure state persistence
class _MainScreenState extends State<MainScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  final List<Map<String, dynamic>> _history = [];
  final TextEditingController _controller = TextEditingController();
  XFile? _image;
  String _resultText = '';
  bool _loading = false;
  int _dailyLimit = 2000;
  String? _serverHostOverride; // legacy host-only override
  final Health _health = Health();
  bool _healthConfigured = false;
  bool? _healthAuthorized; // null = unknown
  String? _healthLastError;
  HealthConnectSdkStatus? _hcSdkStatus;
  // Health: energy burned cache for today
  double? _todayTotalBurnedKcal;
  double? _todayActiveBurnedKcal;
  bool _loadingBurned = false;

  // Announcement
  bool _announcementChecked = false;
  bool _announcementsDisabled = false;
  // Queue & notifications
  final List<Map<String, dynamic>> _queue = [];
  final List<Map<String, dynamic>> _notifications = [];
  bool _queueMode = false;
  // Meal builder mode
  bool _mealBuilderActive = false;
  final List<Map<String, dynamic>> _currentMealResults = [];
  StreamSubscription<dynamic>? _bgDbSub;
  Timer? _refreshTimer;
  int? _lastHistMark;
  int? _lastQueueMark;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  _tabController = TabController(length: 3, vsync: this, initialIndex: 1);
  _loadPrefs();
  _loadHistory();
  _loadQueue();
  _pruneHistory();
  // Live-refresh history/queue when background service writes results
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    _bgDbSub = FlutterBackgroundService().on('db_updated').listen((event) async {
      await _reloadFromDiskWithMealBuilderSupport();
      if (!mounted) return;
      _addNotification(S.of(context).resultSaved);
      
      // Show popup for the most recent result when background queue completes
      // This ensures popups work in queue mode just like in direct processing
      if (!_mealBuilderActive && _history.isNotEmpty) {
        final mostRecent = _history.last;
        // Use addPostFrameCallback for Android compatibility like in direct processing
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _showMealDetails(mostRecent);
          }
        });
      }
    });
    // Periodic fallback: watch SharedPreferences update markers to catch missed events
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        // Ensure we see updates written by the background service process
        await prefs.reload();
        final histMark = prefs.getInt('history_updated_at') ?? 0;
        final queueMark = prefs.getInt('queue_updated_at') ?? 0;
        // store last seen in State (local variables)
        _lastHistMark ??= histMark;
        _lastQueueMark ??= queueMark;
        if (histMark != _lastHistMark || queueMark != _lastQueueMark) {
          _lastHistMark = histMark;
          _lastQueueMark = queueMark;
          await _reloadFromDiskWithMealBuilderSupport();
        }
      } catch (_) {}
    });
  }
  // Proactively check Health Connect status on supported platforms
  if (!kIsWeb && Platform.isAndroid) {
    // fire and forget; UI will update when done
    // ignore: discarded_futures
    _checkHealthStatus();
  }
  // Try to prefetch burned energy for today (no-op on unsupported platforms)
  // ignore: discarded_futures
  _loadTodayBurned();
  // Fetch announcement after first frame so context is ready
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // ignore: discarded_futures
    _checkAnnouncement();
  });
  }


  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    _bgDbSub?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Retry pending/error jobs when app returns to foreground.
    if (state == AppLifecycleState.resumed) {
      // Reload to reflect any background service updates
      // Do an immediate reload and a short delayed one to catch late writes
      _reloadFromDiskWithMealBuilderSupport();
      Future.delayed(const Duration(milliseconds: 750), () {
        if (mounted) _reloadFromDiskWithMealBuilderSupport();
      });
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) _reloadFromDiskWithMealBuilderSupport();
      });
      _autoRetryPending();
    }
  }

  // Force-reload queue and history from SharedPreferences
  Future<void> _reloadFromDisk() async {
    try {
  final prefs = await SharedPreferences.getInstance();
  // Pull latest values written by other isolates/processes
  await prefs.reload();
  await _loadQueue();
  await _loadHistory();
    } catch (_) {
      // ignore
    }
  }

  // Reload from disk with meal builder support - checks if meal builder is active
  // and routes background-processed items to the meal builder basket instead of history
  Future<void> _reloadFromDiskWithMealBuilderSupport() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Pull latest values written by other isolates/processes
      await prefs.reload();
      await _loadQueue();
      
      // Check if meal builder is active
      final mealBuilderActive = prefs.getBool('meal_builder_active') ?? false;
      if (mealBuilderActive) {
        // Load current meal results
        await _loadCurrentMealResults();
      }
      
      // Load history normally
      await _loadHistory();
    } catch (_) {
      // ignore
    }
  }

  Future<void> _checkAnnouncement() async {
    if (_announcementChecked) return;
    _announcementChecked = true;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('disable_announcements_globally') == true) return;
    try {
      final localeCode = (S.of(context).locale.languageCode == 'fr') ? 'fr' : 'en';
    final uri = Uri.parse('${kDefaultBaseUrl}/announcement?lang=$localeCode');
      final res = await http.get(uri, headers: {
        'Accept-Language': localeCode,
      });
      if (res.statusCode == 200) {
        final map = json.decode(res.body);
        if (map is Map && map['ok'] == true) {
          final md = (map['markdown']?.toString() ?? '').trim();
          final id = map['id']?.toString();
          final hiddenId = prefs.getString('hidden_announcement_id_$localeCode')
              ?? prefs.getString('hidden_announcement_id'); // legacy fallback
          if (md.isNotEmpty && (id == null || id != hiddenId) && mounted) {
            await _showAnnouncementDialog(md, id: id, localeCode: localeCode);
          }
        }
      }
    } catch (_) {
      // ignore network errors
    }
  }

  Future<void> _showAnnouncementDialog(String md, {String? id, String? localeCode}) async {
    final s = S.of(context);
    bool hideForever = false;
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final scrollCtrl = ScrollController();
        final maxHeight = MediaQuery.of(ctx).size.height * 0.6; // responsive height for high-DPI
        final dialogWidth = MediaQuery.of(ctx).size.width.clamp(320.0, 520.0);
        return AlertDialog(
          title: Text(s.info),
          content: SizedBox(
            width: dialogWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxHeight),
                  child: Scrollbar(
                    controller: scrollCtrl,
                    interactive: true,
                    thumbVisibility: true,
                    thickness: 6,
                    radius: const Radius.circular(8),
                    child: SingleChildScrollView(
                      controller: scrollCtrl,
                      physics: const ClampingScrollPhysics(),
                      padding: const EdgeInsets.only(right: 8),
                      child: MarkdownBody(
                        data: md,
                        onTapLink: (text, href, title) async {
                          if (href == null) return;
                          try {
                            await launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
                          } catch (_) {}
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                StatefulBuilder(
                  builder: (ctx2, setSB) => CheckboxListTile(
                    value: hideForever,
                    onChanged: (v) => setSB(() => hideForever = v ?? false),
                    title: Text(S.of(context).hideForever),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(s.ok),
            ),
          ],
        );
      },
    );
    if (hideForever) {
      final prefs = await SharedPreferences.getInstance();
      if (id != null && id.isNotEmpty) {
  final key = 'hidden_announcement_id_${localeCode ?? S.of(context).locale.languageCode}';
  await prefs.setString(key, id);
      } else {
        await prefs.setBool('hide_announcement_forever', true);
      }
    }
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _dailyLimit = prefs.getInt('daily_limit_kcal') ?? 2000;
  _serverHostOverride = prefs.getString('server_host');
  _announcementsDisabled = prefs.getBool('disable_announcements_globally') ?? false;
  _queueMode = prefs.getBool('queue_mode_enabled') ?? (!kIsWeb); // default: on for mobile, off for web
    });
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('history_json');
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = json.decode(raw);
      if (decoded is List) {
        final List<Map<String, dynamic>> loaded = [];
        for (final e in decoded) {
          if (e is Map) {
            final m = Map<String, dynamic>.from(e);
            // Ensure types
            if (m['time'] is String) {
              final t = DateTime.tryParse(m['time']);
              if (t != null) m['time'] = t;
            }
            if (m['hcStart'] is String) {
              final t = DateTime.tryParse(m['hcStart']);
              if (t != null) m['hcStart'] = t; else m.remove('hcStart');
            }
            if (m['hcEnd'] is String) {
              final t = DateTime.tryParse(m['hcEnd']);
              if (t != null) m['hcEnd'] = t; else m.remove('hcEnd');
            }
            // Groups: normalize children
            if (m['children'] is List) {
              final List<Map<String, dynamic>> kids = [];
              for (final c in (m['children'] as List)) {
                if (c is Map) {
                  final cm = Map<String, dynamic>.from(c);
                  if (cm['time'] is String) {
                    final t = DateTime.tryParse(cm['time']);
                    if (t != null) cm['time'] = t;
                  }
                  if (cm['hcStart'] is String) {
                    final t = DateTime.tryParse(cm['hcStart']);
                    if (t != null) cm['hcStart'] = t; else cm.remove('hcStart');
                  }
                  if (cm['hcEnd'] is String) {
                    final t = DateTime.tryParse(cm['hcEnd']);
                    if (t != null) cm['hcEnd'] = t; else cm.remove('hcEnd');
                  }
                  kids.add(cm);
                }
              }
              m['children'] = kids;
            }
            loaded.add(m);
          }
        }
        setState(() {
          _history
            ..clear()
            ..addAll(loaded);
        });
      }
    } catch (_) {
      // ignore malformed history
    }
  }

  // Load current meal results when meal builder is active
  Future<void> _loadCurrentMealResults() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('current_meal_results_json');
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = json.decode(raw);
      if (decoded is List) {
        final List<Map<String, dynamic>> loaded = [];
        for (final e in decoded) {
          if (e is Map) {
            final m = Map<String, dynamic>.from(e);
            // Ensure types
            if (m['time'] is String) {
              final t = DateTime.tryParse(m['time']);
              if (t != null) m['time'] = t;
            }
            if (m['hcStart'] is String) {
              final t = DateTime.tryParse(m['hcStart']);
              if (t != null) m['hcStart'] = t; else m.remove('hcStart');
            }
            if (m['hcEnd'] is String) {
              final t = DateTime.tryParse(m['hcEnd']);
              if (t != null) m['hcEnd'] = t; else m.remove('hcEnd');
            }
            // Groups: normalize children
            if (m['children'] is List) {
              final List<Map<String, dynamic>> kids = [];
              for (final c in (m['children'] as List)) {
                if (c is Map) {
                  final cm = Map<String, dynamic>.from(c);
                  if (cm['time'] is String) {
                    final t = DateTime.tryParse(cm['time']);
                    if (t != null) cm['time'] = t;
                  }
                  if (cm['hcStart'] is String) {
                    final t = DateTime.tryParse(cm['hcStart']);
                    if (t != null) cm['hcStart'] = t; else cm.remove('hcStart');
                  }
                  if (cm['hcEnd'] is String) {
                    final t = DateTime.tryParse(cm['hcEnd']);
                    if (t != null) cm['hcEnd'] = t; else cm.remove('hcEnd');
                  }
                  kids.add(cm);
                }
              }
              m['children'] = kids;
            }
            loaded.add(m);
          }
        }
        setState(() {
          _currentMealResults
            ..clear()
            ..addAll(loaded);
        });
      }
    } catch (_) {
      // ignore malformed current meal results
    }
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic> toJson(Map<String, dynamic> x) {
      return {
        'isGroup': x['isGroup'] == true,
        'imagePath': (x['imagePath'] as String?) ?? (x['image'] is XFile ? (x['image'] as XFile).path : null),
        'description': x['description'],
        'name': x['name'],
        'result': x['result'],
        'structured': x['structured'],
  'grams': x['grams'],
        'kcal': x['kcal'],
        'carbs': x['carbs'],
        'protein': x['protein'],
        'fat': x['fat'],
        'time': (x['time'] is DateTime) ? (x['time'] as DateTime).toIso8601String() : x['time'],
        'hcStart': (x['hcStart'] is DateTime) ? (x['hcStart'] as DateTime).toIso8601String() : x['hcStart'],
        'hcEnd': (x['hcEnd'] is DateTime) ? (x['hcEnd'] as DateTime).toIso8601String() : x['hcEnd'],
        'hcWritten': x['hcWritten'] == true,
        if (x['children'] is List) 'children': (x['children'] as List).map((c) => toJson(Map<String, dynamic>.from(c))).toList(),
      };
    }
    final serializable = _history.map((m) => toJson(m)).toList();
    await prefs.setString('history_json', json.encode(serializable));
  }

  // Queue & notifications UI
  void _addNotification(String msg) {
    setState(() {
      _notifications.insert(0, {
        'time': DateTime.now(),
        'message': msg,
      });
      if (_notifications.length > 50) _notifications.removeLast();
    });
  }

  Future<void> _saveQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final serializable = _queue.map((j) {
      final m = Map<String, dynamic>.from(j);
      final created = m['createdAt'];
      if (created is DateTime) m['createdAt'] = created.toIso8601String();
      return m;
    }).toList();
    await prefs.setString('queue_json', json.encode(serializable));
  }

  Future<void> _loadQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('queue_json');
    if (raw == null || raw.isEmpty) return;
    try {
      final list = json.decode(raw);
      if (list is List) {
        final restored = <Map<String, dynamic>>[];
        for (final e in list) {
          if (e is Map) {
            final m = Map<String, dynamic>.from(e);
            if (m['createdAt'] is String) {
              final t = DateTime.tryParse(m['createdAt']);
              if (t != null) m['createdAt'] = t;
            }
            restored.add(m);
          }
        }
        if (mounted) setState(() { _queue..clear()..addAll(restored); });
      }
    } catch (_) {}
  }

  void _autoRetryPending() {
    final pending = _queue.where((j) => (j['status'] != 'in_progress')).toList(growable: false);
    for (final j in pending) {
      // ignore: discarded_futures
      _retryJob(j);
    }
  }

  Future<void> _retryJob(Map<String, dynamic> j) async {
    final imgPath = j['imagePath']?.toString();
    final text = j['description']?.toString() ?? '';
    final id = j['id']?.toString();
    if (id == null) return;
    setState(() {
      j['status'] = 'in_progress';
    });
    await _saveQueue();
  // Preparing upload notification disabled per request
    try {
      bg.startBackgroundUpload({
        'id': id,
        'imagePath': (imgPath ?? ''),
        'description': text,
        'baseUrl': _baseUrl(),
        'lang': S.of(context).locale.languageCode,
        'auth': kPasswordAuthEnabled ? (authState.token ?? '') : '',
        'isMock': _isMockMode,
      });
    } catch (_) {
      // Fallback in case service cannot start
      await _sendMessageCore(image: (imgPath != null && imgPath.isNotEmpty) ? XFile(imgPath) : null, text: text, useFlash: false, jobId: id);
    }
  }

  Future<void> _retryAll() async {
    final copy = _queue.toList();
    for (final j in copy) {
      // ignore: discarded_futures
      _retryJob(j);
    }
  }

  void _openQueue() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(S.of(context).backgroundQueue, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                if (_queue.isEmpty) Text(S.of(context).noPendingJobs),
                if (_queue.isNotEmpty)
                  ..._queue.map((j) {
                    final created = j['createdAt'] as DateTime? ?? DateTime.now();
                    final img = j['imagePath'] as String?;
                    final desc = j['description'] as String?;
                            final status = j['status']?.toString() ?? 'pending';
                            final statusLabel = status == 'error' ? S.of(context).statusError : S.of(context).statusPending;
                    return ListTile(
                      leading: img != null && img.isNotEmpty
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: _buildImageWidget(img, width: 40, height: 40, fit: BoxFit.cover),
                            )
                          : const Icon(Icons.image_not_supported),
                              title: Text(desc?.isNotEmpty == true ? desc! : S.of(context).noDescription),
                              subtitle: Text('#${j['id']} • ${_formatTimeShort(created)} • $statusLabel'),
                              trailing: Wrap(spacing: 0, children: [
                                IconButton(
                                  tooltip: 'Retry',
                                  icon: const Icon(Icons.refresh),
                                  onPressed: status == 'in_progress' ? null : () => _retryJob(j),
                                ),
                                IconButton(
                                  tooltip: 'Remove',
                                  icon: const Icon(Icons.close),
                                  onPressed: () async {
                                    setState(() { _queue.remove(j); });
                                    await _saveQueue();
                                  },
                                ),
                              ]),
                    );
                  }),
                if (_queue.isNotEmpty)
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: _retryAll,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry all'),
                    ),
                  ),
                const Divider(),
                Text(S.of(context).notifications, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (_notifications.isEmpty) Text(S.of(context).noNotificationsYet),
                if (_notifications.isNotEmpty)
                  SizedBox(
                    height: 200,
                    child: ListView(
                      children: _notifications.map((n) {
                        final t = n['time'] as DateTime? ?? DateTime.now();
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.notifications),
                          title: Text(n['message']?.toString() ?? ''),
                          subtitle: Text(_formatTimeShort(t)),
                        );
                      }).toList(),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _ensureHealthConfigured() async {
    if (_healthConfigured) return;
    await _health.configure();
    _healthConfigured = true;
  }

  Future<void> _saveDailyLimit() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('daily_limit_kcal', _dailyLimit);
  }

  

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);

    setState(() {
      if (pickedFile != null) {
        _image = XFile(pickedFile.path);
      }
    });
  }

  Future<void> _captureImage() async {
    // Camera not supported on Linux/Windows/macOS via image_picker.
    if (!kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Camera capture not supported on this platform. Use Pick Image instead.')),
      );
      return;
    }
    try {
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(source: ImageSource.camera);
      if (!mounted) return;
      setState(() {
        if (pickedFile != null) {
          _image = XFile(pickedFile.path);
        }
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to open camera: $e')),
      );
    }
  }

  // _sendMessage removed in favor of _sendOrQueue()

  String _newJobId() => 'job_${DateTime.now().microsecondsSinceEpoch}_${DateTime.now().millisecondsSinceEpoch % 10000}';

  Future<void> _sendOrQueue() async {
    final capturedImage = _image;
    final capturedText = _controller.text;
    if (capturedImage == null && capturedText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of(context).provideMsgOrImage)),
      );
      return;
    }
    if (_queueMode && !kIsWeb) {
      final jobId = _newJobId();
      // Persist image to app documents so it survives background/kill
      String? persistedPath;
      if (capturedImage != null) {
        try {
          final dir = await getApplicationDocumentsDirectory();
          final ext = _extensionSafe(capturedImage.path);
          final dest = File('${dir.path}/meal_${DateTime.now().millisecondsSinceEpoch}$ext');
          await dest.writeAsBytes(await capturedImage.readAsBytes());
          persistedPath = dest.path;
        } catch (_) {}
      }
      setState(() {
        _queue.add({
          'id': jobId,
          'imagePath': persistedPath ?? capturedImage?.path,
          'description': capturedText,
          'createdAt': DateTime.now(),
      'status': 'pending',
        });
        _image = null;
        _controller.clear();
      });
    // Persist queue to survive app background/kill
    await _saveQueue();
  // Preparing upload notification disabled per request
      // Start foreground service to process in background
      try {
        // Mark status in-progress
        final idx = _queue.indexWhere((e) => e['id'] == jobId);
        if (idx >= 0) {
          setState(() { _queue[idx]['status'] = 'in_progress'; });
          await _saveQueue();
        }
        bg.startBackgroundUpload({
          'id': jobId,
          'imagePath': (persistedPath ?? capturedImage?.path) ?? '',
          'description': capturedText,
          'baseUrl': _baseUrl(),
          'lang': S.of(context).locale.languageCode,
          'auth': kPasswordAuthEnabled ? (authState.token ?? '') : '',
          'isMock': _isMockMode,
        });
      } catch (_) {
        // Fallback to in-app processing if service fails to start
        // ignore: discarded_futures
        _sendMessageCore(image: persistedPath != null ? XFile(persistedPath) : capturedImage, text: capturedText, useFlash: false, jobId: jobId);
      }
  _addNotification(S.of(context).queuedRequest(jobId));
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.of(context).queuedWorking)));
    } else if (_queueMode && kIsWeb) {
      // Special handling for web + queue mode: simulate the 5-second delay in foreground (no background service)
      final jobId = _newJobId();
      setState(() {
        _queue.add({
          'id': jobId,
          'imagePath': capturedImage?.path,
          'description': capturedText,
          'createdAt': DateTime.now(),
          'status': 'in_progress',
        });
        _image = null;
        _controller.clear();
      });
      await _saveQueue();
      _addNotification(S.of(context).queuedRequest(jobId));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.of(context).queuedWorking)));
      
      // Wait 5 seconds then process (with mock data if in mock mode)
      Future.delayed(const Duration(seconds: 5), () async {
        if (!mounted) return;
        await _sendMessageCore(image: capturedImage, text: capturedText, useFlash: false, jobId: jobId);
      });
    } else {
      setState(() => _loading = true);
      try {
        await _sendMessageCore(image: capturedImage, text: capturedText, useFlash: false);
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    }
  }

  // Mock mode detection - checks if app is running in mock flavor or web build
  bool get _isMockMode {
    const flavor = String.fromEnvironment('FLAVOR', defaultValue: 'production');
    return flavor == 'mock' || kIsWeb;
  }

  // Mock barcode products for testing
  final Map<String, Map<String, dynamic>> _mockBarcodeProducts = {
    '3017620422003': {
      'product_name': 'Mock Chocolate Bar',
      'nutriments': {
        'energy-kcal_100g': 250.0,
        'carbohydrates_100g': 30.0,
        'proteins_100g': 5.0,
        'fat_100g': 12.0,
      },
      'serving_size': '50g',
      'quantity': '100g',
    },
    '3274080005003': {
      'product_name': 'Mock Apple',
      'nutriments': {
        'energy-kcal_100g': 52.0,
        'carbohydrates_100g': 14.0,
        'proteins_100g': 0.2,
        'fat_100g': 0.2,
      },
      'serving_size': '150g',
      'quantity': '150g',
    },
    '7613031234567': {
      'product_name': 'Mock Bread Slice',
      'nutriments': {
        'energy-kcal_100g': 265.0,
        'carbohydrates_100g': 49.0,
        'proteins_100g': 9.0,
        'fat_100g': 3.0,
      },
      'serving_size': '30g',
      'quantity': '500g',
    },
    '8076809513192': {
      'product_name': 'Mock Banana',
      'nutriments': {
        'energy-kcal_100g': 89.0,
        'carbohydrates_100g': 23.0,
        'proteins_100g': 1.1,
        'fat_100g': 0.3,
      },
      'serving_size': '120g',
      'quantity': '120g',
    },
    '7613287002434': {
      'product_name': 'Mock Yogurt',
      'nutriments': {
        'energy-kcal_100g': 61.0,
        'carbohydrates_100g': 4.0,
        'proteins_100g': 3.5,
        'fat_100g': 3.0,
      },
      'serving_size': '125g',
      'quantity': '125g',
    },
  };

  // Generate mock nutrition response for UI testing
  Map<String, dynamic> _generateMockResponse(String text, XFile? image) {
    final random = DateTime.now().millisecondsSinceEpoch % 1000;
    final foodName = text.isNotEmpty ? text : 'Sample Food';

    // Generate realistic but varied mock data
    final baseCalories = 200 + (random % 400); // 200-600 calories
    final carbs = 20 + (random % 60); // 20-80g carbs
    final protein = 10 + (random % 30); // 10-40g protein
    final fat = 5 + (random % 25); // 5-30g fat
    final weight = 100 + (random % 300); // 100-400g weight

    final mockData = {
      'Name': foodName,
      'Calories': '$baseCalories kcal',
      'Carbs': '${carbs}g',
      'Proteins': '${protein}g',
      'Fats': '${fat}g',
      'Weight (g)': '${weight}g',
      'Mock': 'This is mock data for UI testing'
    };

    return {
      'ok': true,
      'data': mockData
    };
  }

  Future<void> _sendMessageCore({required XFile? image, required String text, required bool useFlash, String? jobId}) async {
    // Check if we're in mock mode and return fake data immediately
    if (_isMockMode) {
      await Future.delayed(const Duration(milliseconds: 200)); // Small delay to simulate network
      final mockResponse = _generateMockResponse(text, image);
      final responseBody = json.encode(mockResponse);
      
      // Process mock response using same logic as real API response
      final decoded = json.decode(responseBody);
      final structured = Map<String, dynamic>.from(decoded['data'] as Map);
      final localizedStructured = _localizedStructured(structured);
      
      // Extract nutrition values from mock data
      final kcal = int.tryParse(structured['Calories']?.toString().replaceAll(RegExp(r'[^\d]'), '') ?? '0');
      final carbs = int.tryParse(structured['Carbs']?.toString().replaceAll(RegExp(r'[^\d]'), '') ?? '0');
      final protein = int.tryParse(structured['Proteins']?.toString().replaceAll(RegExp(r'[^\d]'), '') ?? '0');
      final fat = int.tryParse(structured['Fats']?.toString().replaceAll(RegExp(r'[^\d]'), '') ?? '0');
      final grams = int.tryParse(structured['Weight (g)']?.toString().replaceAll(RegExp(r'[^\d]'), '') ?? '0');
      final mealName = structured['Name']?.toString();
      
      final newMeal = {
        'image': image,
        'imagePath': image?.path,
        'description': text,
        'name': mealName ?? (text.isNotEmpty ? text : null),
        'result': const JsonEncoder.withIndent('  ').convert(localizedStructured),
        'structured': localizedStructured,
        'grams': grams,
        'kcal': kcal,
        'carbs': carbs,
        'protein': protein,
        'fat': fat,
        'time': DateTime.now(),
        'hcWritten': false,
      };
      
      setState(() {
        _resultText = const JsonEncoder.withIndent('  ').convert(localizedStructured);
        if (jobId != null) {
          final idx = _queue.indexWhere((j) => j['id'] == jobId);
          if (idx >= 0) _queue.removeAt(idx);
        }
        
        // Handle meal builder mode vs normal mode
        if (_mealBuilderActive) {
          // Add to current meal results instead of history
          _currentMealResults.add(newMeal);
        } else {
          // Normal mode: add to history and show popup
          _history.add(newMeal);
          _pruneHistory();
        }
      });
      
      if (!_mealBuilderActive) {
        await _saveHistory();
      }
      if (jobId != null) { await _saveQueue(); }
      
      if (jobId != null) {
        await _notifyDone(jobId: jobId, title: S.of(context).result, body: S.of(context).resultSaved);
      }
      

      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).resultSaved)),
        );
        if (jobId == null) {
          setState(() {
            _image = null;
            _controller.clear();
          });
        }
        
        // Only switch to history tab and show popup in normal mode
        if (!_mealBuilderActive) {
          if (jobId == null) {
            _tabController.animateTo(0);
          }
          // Direct popup call - no delays or callbacks
          if (mounted) {
            _showMealDetails(newMeal);
          }
        }
        
        _addNotification('Mock result saved${jobId != null ? ' (#$jobId)' : ''}');
      }
      return;
    }

    // Original real API logic continues below
    final uri = Uri.parse('${_baseUrl()}/data${useFlash ? '?flash=1' : ''}');
    final request = http.MultipartRequest('POST', uri)
      ..fields['message'] = text;
    request.headers['x-app-token'] = 'FromHectaroxWithLove';
    final _lang = S.of(context).locale.languageCode;
    request.headers['Accept-Language'] = _lang;
    request.fields['lang'] = _lang;
    if (kPasswordAuthEnabled && authState.token != null) {
      request.headers['Authorization'] = 'Bearer ${authState.token}';
    }
    if (image != null) {
      request.files.add(await http.MultipartFile.fromPath(
        'image',
        image.path,
        contentType: MediaType.parse(lookupMimeType(image.path) ?? 'application/octet-stream'),
      ));
    }
    http.StreamedResponse? response;
    String responseBody = '';
    try {
      response = await request.send();
      responseBody = await response.stream.bytesToString();

  if (response.statusCode == 200) {
  String pretty;
        try {
          final decoded = json.decode(responseBody);
          if (decoded is Map && decoded['ok'] == true) {
            final data = decoded['data'];
            if (data is String) {
              pretty = data;
            } else {
              pretty = const JsonEncoder.withIndent('  ').convert(data);
            }
          } else if (decoded is Map && decoded.containsKey('response')) {
            pretty = decoded['response'].toString();
          } else {
            pretty = responseBody;
          }
        } catch (_) {
          pretty = responseBody;
        }

  // Try to extract a structured map and kcal value for better UI
  Map<String, dynamic>? structured;
  int? kcal;
  int? carbs;
  int? protein;
  int? fat;
  String? mealName;
        try {
          final decoded = json.decode(responseBody);
          if (decoded is Map && decoded['ok'] == true && decoded['data'] is Map) {
            structured = Map<String, dynamic>.from(decoded['data'] as Map);
          } else if (decoded is Map) {
            structured = Map<String, dynamic>.from(decoded);
          }
        } catch (_) {}
        // Extract preferred fields if present
  if (structured != null) {
          // Localize/normalize structured keys for the current UI locale
          structured = _localizedStructured(structured);
          mealName = structured['Name']?.toString() ?? structured["Nom de l'aliment"]?.toString() ?? structured['name']?.toString();
        }

        // Fallback: attempt to parse calories & carbs/protein/fat from any text
        String textSource = structured != null ? jsonEncode(structured) : pretty;
        // kcal can be integer or decimal (rare); round to nearest int
        final kcalMatch = RegExp(r'(\d{1,5}(?:[\.,]\d{1,2})?)\s*(k?cal|kilo?calories?)', caseSensitive: false)
            .firstMatch(textSource);
        if (kcalMatch != null) {
          final raw = kcalMatch.group(1)!.replaceAll(',', '.');
          final d = double.tryParse(raw);
          if (d != null) kcal = d.round();
        } else if (structured != null) {
          final calVal = structured['Calories'] ?? structured['kcal'] ?? structured['calories'];
          if (calVal != null) {
            final numMatch = RegExp(r'(\d+(?:[\.,]\d+)?)').firstMatch(calVal.toString());
            if (numMatch != null) {
              final d = double.tryParse(numMatch.group(1)!.replaceAll(',', '.'));
              if (d != null) kcal = d.round();
            }
          }
        }

  // carbs can be decimal like 60.2g; round to nearest gram
        final carbsMatch = RegExp(r'(\d{1,4}(?:[\.,]\d{1,2})?)\s*g\s*(carb|glucid\w*)', caseSensitive: false)
            .firstMatch(textSource);
        if (carbsMatch != null) {
          final raw = carbsMatch.group(1)!.replaceAll(',', '.');
          final d = double.tryParse(raw);
          if (d != null) carbs = d.round();
        } else if (structured != null) {
          final cVal = structured['Glucides'] ?? structured['carbs'] ?? structured['Carbs'];
          if (cVal != null) {
            final numMatch = RegExp(r'(\d+(?:[\.,]\d+)?)').firstMatch(cVal.toString());
            if (numMatch != null) {
              final d = double.tryParse(numMatch.group(1)!.replaceAll(',', '.'));
              if (d != null) carbs = d.round();
            }
          }
        }

        // proteins
        final proteinMatch = RegExp(r'(\d{1,4}(?:[\.,]\d{1,2})?)\s*g\s*(protein|prot\w*)', caseSensitive: false)
            .firstMatch(textSource);
        if (proteinMatch != null) {
          final raw = proteinMatch.group(1)!.replaceAll(',', '.');
          final d = double.tryParse(raw);
          if (d != null) protein = d.round();
        } else if (structured != null) {
          final pVal = structured['Proteines'] ?? structured['protein'] ?? structured['Proteins'];
          if (pVal != null) {
            final numMatch = RegExp(r'(\d+(?:[\.,]\d+)?)').firstMatch(pVal.toString());
            if (numMatch != null) {
              final d = double.tryParse(numMatch.group(1)!.replaceAll(',', '.'));
              if (d != null) protein = d.round();
            }
          }
        }

        // fats
        final fatMatch = RegExp(r'(\d{1,4}(?:[\.,]\d{1,2})?)\s*g\s*(fat|lipid\w*|gras)', caseSensitive: false)
            .firstMatch(textSource);
        if (fatMatch != null) {
          final raw = fatMatch.group(1)!.replaceAll(',', '.');
          final d = double.tryParse(raw);
          if (d != null) fat = d.round();
        } else if (structured != null) {
          final fVal = structured['Lipides'] ?? structured['fat'] ?? structured['Fats'];
          if (fVal != null) {
            final numMatch = RegExp(r'(\d+(?:[\.,]\d+)?)').firstMatch(fVal.toString());
            if (numMatch != null) {
              final d = double.tryParse(numMatch.group(1)!.replaceAll(',', '.'));
              if (d != null) fat = d.round();
            }
          }
        }

        // Capture overall grams from AI output (structured or text)
        final aiGrams = _extractGrams(structured, textSource);

        final newMeal = {
          'image': image,
          'imagePath': image?.path,
          'description': text,
          'name': mealName ?? (text.isNotEmpty ? text : null),
          // Prefer pretty-printed, locale-normalized JSON when available
          'result': structured != null ? const JsonEncoder.withIndent('  ').convert(structured) : pretty,
          'structured': structured,
          'grams': aiGrams,
          'kcal': kcal,
          'carbs': carbs,
          'protein': protein,
          'fat': fat,
          'time': DateTime.now(),
          'hcWritten': false,
        };
        setState(() {
          _resultText = pretty;
          if (jobId != null) {
            final idx = _queue.indexWhere((j) => j['id'] == jobId);
            if (idx >= 0) _queue.removeAt(idx);
          }
          
          // Handle meal builder mode vs normal mode
          if (_mealBuilderActive) {
            // Add to current meal results instead of history
            _currentMealResults.add(newMeal);
          } else {
            // Normal mode: add to history and show popup
            _history.add(newMeal);
            _pruneHistory();
          }
        });
        
        if (!_mealBuilderActive) {
          await _saveHistory();
        }
        if (jobId != null) { await _saveQueue(); }
        if (jobId != null) {
          // ignore: discarded_futures
          _notifyDone(jobId: jobId, title: S.of(context).result, body: S.of(context).resultSaved);
        }



        // Notify, reset composer, and show the result in History so users see success
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(S.of(context).resultSaved)),
          );
          if (jobId == null) {
            setState(() {
              _image = null;
              _controller.clear();
            });
          }
          
          // Only switch to history tab and show popup in normal mode
          if (!_mealBuilderActive) {
            if (jobId == null) {
              _tabController.animateTo(0);
            }
            // Try immediate popup call for Android compatibility
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _showMealDetails(newMeal);
              }
            });
          }
          
          _addNotification('Result saved${jobId != null ? ' (#$jobId)' : ''}');
        }

        // Try to sync to Health Connect (Android) when available
        // Request permissions only when we have data to write
        try {
          await _ensureHealthConfigured();
          if (mounted && (kcal != null || carbs != null || protein != null || fat != null)) {
            // On Android, ensure Health Connect is installed/updated before asking permissions
            if (!kIsWeb && Platform.isAndroid) {
              final status = await _health.getHealthConnectSdkStatus();
              if (mounted) setState(() => _hcSdkStatus = status);
              if (status != HealthConnectSdkStatus.sdkAvailable) {
                if (mounted) {
                  final s = S.of(context);
                  final msg = status == HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired
                      ? s.updateHc
                      : s.installHc;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
                }
                // Offer to install/update via the Daily tab button; bail out of writing
                return;
              }
            }
            // Request Nutrition permissions (covers calories/macros on Android HC)
            final ok = await _health.requestAuthorization(
              [HealthDataType.NUTRITION],
              permissions: [HealthDataAccess.READ_WRITE],
            );
            if (ok) {
              final start = DateTime.now();
              // Ensure endTime is after startTime; some HC providers reject equal timestamps
              final end = start.add(const Duration(minutes: 1));
              // Store timestamps so we can delete the same record later
              newMeal['hcStart'] = start;
              newMeal['hcEnd'] = end;
              final written = await _health.writeMeal(
                mealType: MealType.UNKNOWN,
                startTime: start,
                endTime: end,
                caloriesConsumed: kcal?.toDouble(),
                carbohydrates: carbs?.toDouble(),
                protein: protein?.toDouble(),
                fatTotal: fat?.toDouble(),
                name: mealName ?? (text.isNotEmpty ? text : null),
              );
              if (mounted) {
                setState(() => _healthAuthorized = true);
                // Show quick feedback and capture failures for troubleshooting
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(written ? S.of(context).hcWriteOk : S.of(context).hcWriteFail)),
                );
                if (written) {
                  // mark written and persist
                  setState(() {
                    newMeal['hcWritten'] = true;
                  });
                  await _saveHistory();
                } else {
                  setState(() => _healthLastError = 'writeMeal returned false');
                }
              }
            }
          }
        } catch (e) {
          if (mounted) setState(() => _healthLastError = e.toString());
        }
      } else {
        // Try to show a friendly server-provided error first
        String? serverMsg;
        try {
          final decoded = json.decode(responseBody);
          if (decoded is Map && decoded['ok'] == false && decoded['error'] is String) {
            serverMsg = decoded['error'] as String;
          }
        } catch (_) {}
  final is50x = response.statusCode == 503 || response.statusCode == 500;
    final s = S.of(context);
    final msg = (serverMsg != null && serverMsg.isNotEmpty)
      ? serverMsg
      : (is50x
        ? s.aiOverloaded
        : s.requestFailedWithCode(response.statusCode));
        if (mounted) {
          if (jobId != null) {
            final idx = _queue.indexWhere((j) => j['id'] == jobId);
            if (idx >= 0) setState(() => _queue[idx]['status'] = 'error');
            _addNotification('Request failed (#$jobId): $msg');
            await _saveQueue();
            // ignore: discarded_futures
            _notifyDone(jobId: jobId, title: S.of(context).requestFailed, body: msg);
          }
          if (is50x) {
            // Show a popup dialog to switch to flash model
      showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
        title: Text(s.flashTitle),
        content: Text('$msg\n\n${s.flashExplain}'),
                actions: [
                  TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(s.cancel),
                  ),
                  OutlinedButton(
                    onPressed: () async {
                      Navigator.of(ctx).pop();
                      await _sendMessageFlashDebug();
                    },
                    child: Text(s.debugRaw),
                  ),
                  FilledButton(
                    onPressed: () async {
                      Navigator.of(ctx).pop();
                      await _sendMessageCore(image: image, text: text, useFlash: true, jobId: jobId);
                    },
          child: Text(s.useFlash),
                  ),
                ],
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(msg)),
            );
          }
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of(context).serviceUnavailable)),
      );
      if (jobId != null) {
        final idx = _queue.indexWhere((j) => j['id'] == jobId);
  if (idx >= 0) setState(() => _queue[idx]['status'] = 'error');
        _addNotification('Request failed (#$jobId)');
  await _saveQueue();
  // ignore: discarded_futures
  _notifyDone(jobId: jobId, title: S.of(context).requestFailed, body: S.of(context).serviceUnavailable);
      }
    } finally {
      // _loading handled by caller for non-queue mode
    }
  }

  // _sendMessageWithModel removed; flash path reuses _sendMessageCore with useFlash=true.

  Future<void> _sendMessageFlashDebug() async {
    // Sends the same request with flash=1 and shows the raw response body in a dialog for debugging.
    if (_image == null && _controller.text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).provideMsgOrImage)),
        );
      }
      return;
    }
  // Force pro model for debugging to compare against flash behavior
  final uri = Uri.parse('${_baseUrl()}/data?flash=0');
    final request = http.MultipartRequest('POST', uri)
      ..fields['message'] = _controller.text;
  request.headers['x-app-token'] = 'FromHectaroxWithLove';
  if (kPasswordAuthEnabled && authState.token != null) request.headers['Authorization'] = 'Bearer ${authState.token}';
    if (_image != null) {
      request.files.add(await http.MultipartFile.fromPath(
        'image',
        _image!.path,
        contentType: MediaType.parse(lookupMimeType(_image!.path) ?? 'application/octet-stream'),
      ));
    }
    if (mounted) setState(() => _loading = true);
    String body = '';
    int status = 0;
    try {
      final response = await request.send();
      status = response.statusCode;
      body = await response.stream.bytesToString();
    } catch (e) {
      body = 'Error: $e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (!mounted) return;
    final s = S.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${s.debugRawTitle} (${status})'),
        content: SingleChildScrollView(child: SelectableText(body.isEmpty ? s.emptyResponse : body)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(s.ok)),
        ],
      ),
    );
  }

  void _pruneHistory() {
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    _history.removeWhere((e) => (e['time'] as DateTime).isBefore(cutoff));
  }

  String _extensionSafe(String path) {
    final i = path.lastIndexOf('.');
    return i >= 0 ? path.substring(i) : '';
  }

  Future<void> _checkHealthStatus() async {
    try {
      await _ensureHealthConfigured();
      final status = await _health.getHealthConnectSdkStatus();
      final has = await _health.hasPermissions([HealthDataType.NUTRITION], permissions: [HealthDataAccess.READ_WRITE]);
      if (mounted) {
        setState(() {
          _hcSdkStatus = status;
          _healthAuthorized = has ?? false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _healthLastError = e.toString());
    }
  }

  Future<void> _requestHealthPermissions() async {
    try {
      await _ensureHealthConfigured();
  final ok = await _health.requestAuthorization([HealthDataType.NUTRITION], permissions: [HealthDataAccess.READ_WRITE]);
      if (mounted) setState(() => _healthAuthorized = ok);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? S.of(context).hcGranted : S.of(context).hcDenied)));
      }
    } catch (e) {
      if (mounted) setState(() => _healthLastError = e.toString());
    }
  }

  Future<void> _loadTodayBurned() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    DateTime now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end = now;
    try {
      await _ensureHealthConfigured();
      if (Platform.isAndroid) {
        final status = await _health.getHealthConnectSdkStatus();
        if (mounted) setState(() => _hcSdkStatus = status);
        if (status != HealthConnectSdkStatus.sdkAvailable) return;
      }
      // Mandatory permission: TOTAL_CALORIES_BURNED
      final totalGranted = await _health.requestAuthorization(
        [HealthDataType.TOTAL_CALORIES_BURNED],
        permissions: const [HealthDataAccess.READ],
      );
      if (!totalGranted) {
        if (mounted) setState(() => _healthLastError = 'Permission denied for TOTAL_CALORIES_BURNED');
        return;
      }
      // Optional permission: ACTIVE_ENERGY_BURNED (may be unavailable on some devices)
      bool activeGranted = false;
      try {
        activeGranted = await _health.requestAuthorization(
          [HealthDataType.ACTIVE_ENERGY_BURNED],
          permissions: const [HealthDataAccess.READ],
        );
      } catch (_) {
        activeGranted = false;
      }
      if (mounted) setState(() => _loadingBurned = true);
      // Fetch TOTAL points
      final totalPoints = await _health.getHealthDataFromTypes(
        startTime: start,
        endTime: end,
        types: const [HealthDataType.TOTAL_CALORIES_BURNED],
      );
      double sumTotal = 0.0;
      for (final dp in totalPoints) {
        final v = _asDouble(dp.value);
        if (v == null || !v.isFinite) continue;
        sumTotal += v;
      }
      // Fetch ACTIVE if granted
      double? sumActive;
      if (activeGranted) {
        try {
          final activePoints = await _health.getHealthDataFromTypes(
            startTime: start,
            endTime: end,
            types: const [HealthDataType.ACTIVE_ENERGY_BURNED],
          );
          double tmp = 0.0;
          for (final dp in activePoints) {
            final v = _asDouble(dp.value);
            if (v == null || !v.isFinite) continue;
            tmp += v;
          }
          sumActive = tmp;
        } catch (_) {
          sumActive = null;
        }
      }
      final total = sumTotal;
      if (mounted) {
        setState(() {
          _todayActiveBurnedKcal = sumActive;
          _todayTotalBurnedKcal = total;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _healthLastError = e.toString());
    } finally {
      if (mounted) setState(() => _loadingBurned = false);
    }
  }

  double? _asDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    final s = v.toString();
    final m = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(s);
    if (m != null) return double.tryParse(m.group(0)!);
    return null;
  }

  // --- Helpers to extract grams (overall weight) from AI outputs ---
  int? _extractGrams(dynamic structured, String textSource) {
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

  Map<String, List<Map<String, dynamic>>> _groupHistoryByDay() {
    final Map<String, List<Map<String, dynamic>>> groups = {};
    final now = DateTime.now();
    for (final item in _history..sort((a, b) => (b['time'] as DateTime).compareTo(a['time'] as DateTime))) {
      final dt = (item['time'] as DateTime).toLocal();
      final dayKey = _dayBucket(now, dt);
      groups.putIfAbsent(dayKey, () => []).add(item);
    }
    return groups;
  }

  String _dayBucket(DateTime now, DateTime dt) {
    final dNow = DateTime(now.year, now.month, now.day);
    final dDt = DateTime(dt.year, dt.month, dt.day);
    final diff = dNow.difference(dDt).inDays;
  if (diff == 0) return S.of(context).today;
  if (diff == 1) return S.of(context).yesterday;
    return DateFormat('d MMMM').format(dDt);
  }

  int _todayKcal() {
    final today = DateTime.now();
    final dToday = DateTime(today.year, today.month, today.day);
    int sum = 0;
    for (final item in _history) {
      final t = (item['time'] as DateTime);
      final d = DateTime(t.year, t.month, t.day);
      if (d == dToday && item['kcal'] is int) sum += item['kcal'] as int;
    }
    return sum;
  }

  String _baseUrl() {
    // Legacy host-only override
    if (_serverHostOverride != null && _serverHostOverride!.isNotEmpty) {
      return 'http://${_serverHostOverride}:3000';
    }
    // Defaults
    return 'http://141.145.210.115:3007';
  }

  // Check if camera is available on this platform
  bool get canUseCamera => !kIsWeb && !(Platform.isLinux || Platform.isWindows || Platform.isMacOS);

  // Build capture card widget
  Widget _buildCaptureCard() {
    final s = S.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
        ),
        boxShadow: [
          // Black shadow behind
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(
            Icons.photo_camera,
            size: 32,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 8),
          Text(
            'Capture',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Column(
            children: [
              // Always show take photo button
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: canUseCamera ? _captureImage : () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Camera not available in web mode')),
                    );
                  },
                  icon: const Icon(Icons.photo_camera_outlined, size: 18),
                  label: Text(s.takePhoto),
                  style: FilledButton.styleFrom(
                    backgroundColor: canUseCamera 
                      ? null // Use default primary color
                      : Theme.of(context).colorScheme.primary.withOpacity(0.6),
                    foregroundColor: canUseCamera
                      ? null // Use default onPrimary color
                      : Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _pickImage,
                  icon: const Icon(Icons.image_outlined, size: 18),
                  label: Text(s.pickImage),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Build other actions card widget with smaller font for long text
  Widget _buildOtherCard() {
    final s = S.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
        ),
        boxShadow: [
          // Black shadow behind
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(
            Icons.more_horiz,
            size: 32,
            color: Theme.of(context).colorScheme.secondary,
          ),
          const SizedBox(height: 8),
          Text(
            'Other',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.secondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Column(
            children: [
               // Always show scan barcode button with smaller font
               SizedBox(
                 width: double.infinity,
                 child: FilledButton.icon(
                   onPressed: (canUseCamera || _isMockMode) ? _scanBarcode : () {
                     ScaffoldMessenger.of(context).showSnackBar(
                       SnackBar(content: Text('Barcode scanning not available in web mode')),
                     );
                   },
                   icon: const Icon(Icons.qr_code_scanner, size: 16),
                   label: Text(
                     s.scanBarcode,
                     style: TextStyle(
                       fontSize: MediaQuery.of(context).size.width < 360 ? 10 : 12,
                       fontWeight: FontWeight.w500,
                     ),
                     maxLines: 1,
                     overflow: TextOverflow.ellipsis,
                   ),
                   style: FilledButton.styleFrom(
                     backgroundColor: (canUseCamera || _isMockMode)
                       ? Theme.of(context).colorScheme.secondary
                       : Theme.of(context).colorScheme.secondary.withOpacity(0.6),
                     foregroundColor: (canUseCamera || _isMockMode)
                       ? Theme.of(context).colorScheme.onSecondary
                       : Colors.white,
                     padding: EdgeInsets.symmetric(
                       vertical: MediaQuery.of(context).size.width < 360 ? 6 : 8,
                       horizontal: MediaQuery.of(context).size.width < 360 ? 6 : 8,
                     ),
                   ),
                 ),
               ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _addManualFood,
                  icon: const Icon(Icons.add, size: 16),
                  label: Text(
                    s.addManual,
                    style: TextStyle(
                      fontSize: MediaQuery.of(context).size.width < 360 ? 10 : 12,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Theme.of(context).colorScheme.secondary),
                    foregroundColor: Theme.of(context).colorScheme.secondary,
                    padding: EdgeInsets.symmetric(
                      vertical: MediaQuery.of(context).size.width < 360 ? 6 : 8,
                      horizontal: MediaQuery.of(context).size.width < 360 ? 6 : 8,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = S.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(s.appTitle),
        leading: IconButton(
          tooltip: S.of(context).info,
          icon: const Icon(Icons.info_outline),
          onPressed: _openInfo,
        ),
        actions: [
          Stack(
            children: [
              IconButton(
                tooltip: S.of(context).queueAndNotifications,
                onPressed: _openQueue,
                icon: const Icon(Icons.notifications_outlined),
              ),
              if (_queue.isNotEmpty)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.error,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _queue.length.toString(),
                      style: TextStyle(color: scheme.onError, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
            ],
          ),
          IconButton(
            tooltip: s.settings,
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          )
        ],
      ),
    body: TabBarView(
        controller: _tabController,
        children: [
          _buildHistoryTab(),
          _buildMainTab(),
      _buildDailyTab(),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Meal builder toggle button above bottom navigation
          Container(
            width: double.infinity,
            color: scheme.surface,
            child: SafeArea(
              top: false,
              bottom: false,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: FilledButton.icon(
                  onPressed: _toggleMealBuilder,
                  icon: Icon(_mealBuilderActive ? Icons.restaurant_menu : Icons.add_circle),
                  label: Text(_mealBuilderActive ? 'Finish Meal' : 'Start Meal'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _mealBuilderActive ? scheme.secondary : scheme.primary,
                    foregroundColor: _mealBuilderActive ? scheme.onSecondary : scheme.onPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
                  ),
                ),
              ),
            ),
          ),
          // Bottom navigation bar
          Material(
            color: scheme.surface,
            child: SafeArea(
              top: false,
              child: TabBar(
                controller: _tabController,
                tabs: [
                  Tab(icon: const Icon(Icons.history), text: s.tabHistory),
                  Tab(icon: const Icon(Icons.camera_alt), text: s.tabMain),
                  Tab(icon: const Icon(Icons.local_fire_department), text: s.tabDaily),
                ],
                indicatorColor: scheme.primary,
                labelColor: scheme.primary,
                unselectedLabelColor: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final s = S.of(context);
            final current = appSettings.locale?.languageCode ?? 'system';
            return SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              left: 0,
              right: 0,
              top: 0,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ListTile(
                        title: Text(s.settings, style: Theme.of(ctx).textTheme.titleLarge),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close),
                      tooltip: 'Close settings',
                    ),
                  ],
                ),
                RadioListTile<String>(
                  value: 'system',
                  groupValue: current,
                  title: Text(s.systemLanguage),
                  onChanged: (_) async {
                    await appSettings.setLocale(null);
                    setDialogState(() {
                      // Update the dialog state to reflect the change
                    });
                  },
                ),
                RadioListTile<String>(
                  value: 'en',
                  groupValue: current,
                  title: const Text('English'),
                  onChanged: (_) async {
                    await appSettings.setLocale(const Locale('en'));
                    setDialogState(() {
                      // Update the dialog state to reflect the change
                    });
                  },
                ),
                RadioListTile<String>(
                  value: 'fr',
                  groupValue: current,
                  title: const Text('Français'),
                  onChanged: (_) async {
                    await appSettings.setLocale(const Locale('fr'));
                    setDialogState(() {
                      // Update the dialog state to reflect the change
                    });
                  },
                ),
                const Divider(),
                ListTile(title: Text(s.theme, style: Theme.of(ctx).textTheme.titleMedium)),
                RadioListTile<ThemeMode>(
                  value: ThemeMode.system,
                  groupValue: appSettings.themeMode,
                  title: Text(s.systemTheme),
                  onChanged: (value) {
                    if (value != null) {
                      appSettings.setThemeMode(value);
                    }
                  },
                ),
                RadioListTile<ThemeMode>(
                  value: ThemeMode.light,
                  groupValue: appSettings.themeMode,
                  title: Text(s.lightTheme),
                  onChanged: (value) {
                    if (value != null) {
                      appSettings.setThemeMode(value);
                    }
                  },
                ),
                RadioListTile<ThemeMode>(
                  value: ThemeMode.dark,
                  groupValue: appSettings.themeMode,
                  title: Text(s.darkTheme),
                  onChanged: (value) {
                    if (value != null) {
                      appSettings.setThemeMode(value);
                    }
                  },
                ),
                const Divider(),
                SwitchListTile(
                  value: _queueMode,
                  title: Text(S.of(context).queueInBackground),
                  subtitle: Text(kIsWeb 
                    ? 'Web mode: 5-second delay simulation (no background service)'
                    : S.of(context).queueInBackgroundHint),
                  onChanged: (v) async {
                    final enabled = v;
                    setState(() => _queueMode = enabled);
                    setDialogState(() => _queueMode = enabled);
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('queue_mode_enabled', enabled);
                  },
                ),
                const Divider(),
                SwitchListTile(
                  value: _announcementsDisabled,
                  title: Text(S.of(context).disableAnnouncements),
                  subtitle: Text(S.of(context).disableAnnouncementsHint),
                  onChanged: (v) async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('disable_announcements_globally', v);
                    if (!mounted) return;
                    setState(() => _announcementsDisabled = v);
                    setDialogState(() => _announcementsDisabled = v);
                  },
                ),
                const Divider(),
                SwitchListTile(
                  value: appSettings.daltonian,
                  title: Text(s.daltonianMode),
                  subtitle: Text(s.daltonianModeHint),
                  onChanged: (v) async {
                    await appSettings.setDaltonian(v);
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.upload_file),
                  title: Text(s.exportHistory),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _exportHistory();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.download),
                  title: Text(s.importHistory),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _importHistory();
                  },
                ),
                if (kPasswordAuthEnabled) ...[
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.logout),
                    title: Text(S.of(context).logout),
                    onTap: () async {
                      await authState.setToken(null);
                      if (mounted) {
                        Navigator.pop(ctx);
                        Navigator.of(context).pushAndRemoveUntil(
                          MaterialPageRoute(builder: (_) => const LoginScreen()),
                          (route) => false,
                        );
                      }
                    },
                  ),
                ],
              ],
            ),
          ),
        );
          },
        );
      },
    );
  }

  Future<void> _exportHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('history_json') ?? json.encode(_history.map((m) {
        Map<String, dynamic> toJson(Map<String, dynamic> x) {
          return {
            'isGroup': x['isGroup'] == true,
            'imagePath': (x['imagePath'] as String?) ?? (x['image'] is XFile ? (x['image'] as XFile).path : null),
            'description': x['description'],
            'name': x['name'],
            'result': x['result'],
            'structured': x['structured'],
            'grams': x['grams'],
            'kcal': x['kcal'],
            'carbs': x['carbs'],
            'protein': x['protein'],
            'fat': x['fat'],
            'time': (x['time'] is DateTime) ? (x['time'] as DateTime).toIso8601String() : x['time'],
            'hcStart': (x['hcStart'] is DateTime) ? (x['hcStart'] as DateTime).toIso8601String() : x['hcStart'],
            'hcEnd': (x['hcEnd'] is DateTime) ? (x['hcEnd'] as DateTime).toIso8601String() : x['hcEnd'],
            'hcWritten': x['hcWritten'] == true,
            if (x['children'] is List) 'children': (x['children'] as List).map((c) => toJson(Map<String, dynamic>.from(c))).toList(),
          };
        }
        return toJson(Map<String, dynamic>.from(m));
      }).toList());

      final bytes = utf8.encode(raw);
      final filename = 'nutrilens-history-${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.json';
      final path = await FilePicker.platform.saveFile(
        dialogTitle: S.of(context).exportHistory,
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: Uint8List.fromList(bytes),
      );
      if (!mounted) return;
      if (path == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.of(context).exportCanceled)));
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.of(context).exportSuccess)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.of(context).exportFailed)));
    }
  }

  Future<void> _importHistory() async {
    final s = S.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.importHistory),
        content: Text(s.confirmImportReplace),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(MaterialLocalizations.of(ctx).okButtonLabel)),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final res = await FilePicker.platform.pickFiles(
        dialogTitle: S.of(context).importHistory,
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (res == null || res.files.isEmpty) return;
      final file = res.files.first;
      final data = file.bytes ?? await File(file.path!).readAsBytes();
      final decoded = json.decode(utf8.decode(data));
      if (decoded is! List) throw Exception('Invalid history');

      final List<Map<String, dynamic>> loaded = [];
      for (final e in decoded) {
        if (e is Map) {
          final m = Map<String, dynamic>.from(e);
          if (m['time'] is String) {
            final t = DateTime.tryParse(m['time']);
            if (t != null) m['time'] = t;
          }
          if (m['hcStart'] is String) {
            final t = DateTime.tryParse(m['hcStart']);
            if (t != null) m['hcStart'] = t; else m.remove('hcStart');
          }
          if (m['hcEnd'] is String) {
            final t = DateTime.tryParse(m['hcEnd']);
            if (t != null) m['hcEnd'] = t; else m.remove('hcEnd');
          }
          if (m['children'] is List) {
            final List<Map<String, dynamic>> kids = [];
            for (final c in (m['children'] as List)) {
              if (c is Map) {
                final cm = Map<String, dynamic>.from(c);
                if (cm['time'] is String) {
                  final t = DateTime.tryParse(cm['time']);
                  if (t != null) cm['time'] = t;
                }
                if (cm['hcStart'] is String) {
                  final t = DateTime.tryParse(cm['hcStart']);
                  if (t != null) cm['hcStart'] = t; else cm.remove('hcStart');
                }
                if (cm['hcEnd'] is String) {
                  final t = DateTime.tryParse(cm['hcEnd']);
                  if (t != null) cm['hcEnd'] = t; else cm.remove('hcEnd');
                }
                kids.add(cm);
              }
            }
            m['children'] = kids;
          }
          loaded.add(m);
        }
      }
      setState(() {
        _history
          ..clear()
          ..addAll(loaded);
      });
      await _saveHistory();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.of(context).importSuccess)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.of(context).importFailed)));
    }
  }

  Future<void> _openInfo() async {
    final s = S.of(context);
    PackageInfo info;
    try {
      info = await PackageInfo.fromPlatform();
    } catch (_) {
      info = PackageInfo(appName: 'App', packageName: 'app', version: 'unknown', buildNumber: '-', buildSignature: '', installerStore: null);
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(s.about, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(s.versionBuild(info.version, info.buildNumber)),
                const SizedBox(height: 12),
                ListTile(
                  leading: const FaIcon(FontAwesomeIcons.discord),
                  title: Text(s.joinDiscord),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () async {
                    final uri = Uri.parse('https://discord.gg/8bDDqbvr8K');
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  },
                ),
                ListTile(
                  leading: const FaIcon(FontAwesomeIcons.github),
                  title: Text(s.openGithubIssue),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () async {
                    final uri = Uri.parse('https://github.com/hectarox/NutriLens/issues');
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHistoryTab() {
    final scheme = Theme.of(context).colorScheme;
  final s = S.of(context);
    if (_history.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
      Text(s.noHistory, style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
        ),
      );
    }
    final grouped = _groupHistoryByDay();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: grouped.entries.map((entry) {
        final totalCarbs = entry.value.fold<int>(0, (s, e) => s + (e['carbs'] as int? ?? 0));
        final totalProtein = entry.value.fold<int>(0, (s, e) => s + (e['protein'] as int? ?? 0));
        final totalFat = entry.value.fold<int>(0, (s, e) => s + (e['fat'] as int? ?? 0));
        return _ExpandableDaySection(
          title: entry.key,
          totalKcal: entry.value.fold<int>(0, (s, e) => s + (e['kcal'] as int? ?? 0)),
          totalCarbs: totalCarbs,
          totalProtein: totalProtein,
          totalFat: totalFat,
          children: entry.value.map<Widget>((meal) {
            return _HistoryMealCard(
              meal: meal,
              onDelete: () async {
                // Attempt to delete from Health Connect if previously written
                try {
                  await _ensureHealthConfigured();
                  if (!kIsWeb && Platform.isAndroid && (meal['hcWritten'] == true)) {
                    final hs = meal['hcStart'];
                    final he = meal['hcEnd'];
                    final start = hs is DateTime ? hs : (hs is String ? DateTime.tryParse(hs) : null);
                    final end = he is DateTime ? he : (he is String ? DateTime.tryParse(he) : null);
                    if (start != null && end != null) {
                      // Ensure permissions and delete nutrition entries in the same timespan
                      await _health.requestAuthorization([HealthDataType.NUTRITION], permissions: [HealthDataAccess.READ_WRITE]);
                      await _health.delete(type: HealthDataType.NUTRITION, startTime: start, endTime: end);
                    }
                  }
                } catch (_) {}
                setState(() => _history.remove(meal));
                await _saveHistory();
              },
              onTap: () => _showMealDetails(meal),
              onDrop: (source) => _mergeMeals(source, meal),
            );
          }).toList(),
        );
      }).toList(),
    );
  }

  // Compact action button for the new experimental UI
  Widget _buildCompactActionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    required Color color,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isEnabled = onPressed != null;
    
    // Responsive design based on screen width and text scale factor
    final mediaQuery = MediaQuery.of(context);
    final screenWidth = mediaQuery.size.width;
    final textScaleFactor = mediaQuery.textScaleFactor;
    
    // Calculate responsive dimensions
    final double buttonHeight;
    final double iconSize;
    final double fontSize;
    final EdgeInsets padding;
    final double borderRadius;
    
    if (screenWidth < 320) {
      // Very small screens (old phones) - increased height for text visibility
      buttonHeight = 56.0;
      iconSize = 16.0;
      fontSize = 9.0;
      padding = const EdgeInsets.symmetric(horizontal: 4, vertical: 4);
      borderRadius = 12.0;
    } else if (screenWidth < 360) {
      // Small screens - increased height for text visibility
      buttonHeight = 60.0;
      iconSize = 18.0;
      fontSize = 10.0;
      padding = const EdgeInsets.symmetric(horizontal: 6, vertical: 4);
      borderRadius = 14.0;
    } else if (screenWidth < 420) {
      // Medium screens - increased height for text visibility
      buttonHeight = 64.0;
      iconSize = 20.0;
      fontSize = 11.0;
      padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 6);
      borderRadius = 16.0;
    } else {
      // Large screens - increased height for text visibility
      buttonHeight = 68.0;
      iconSize = 22.0;
      fontSize = 12.0;
      padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 8);
      borderRadius = 18.0;
    }
    
    // Adjust for accessibility text scaling but keep it reasonable
    final adjustedFontSize = (fontSize * textScaleFactor.clamp(0.8, 1.3));
    final adjustedIconSize = (iconSize * textScaleFactor.clamp(0.8, 1.2));
    final adjustedHeight = buttonHeight * textScaleFactor.clamp(0.9, 1.2);
    
    return Container(
      height: adjustedHeight,
      decoration: BoxDecoration(
        color: isEnabled ? color.withOpacity(0.1) : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: isEnabled ? color.withOpacity(0.3) : scheme.outline.withOpacity(0.2),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(borderRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(borderRadius),
          onTap: onPressed,
          child: Padding(
            padding: padding,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  color: isEnabled ? color : scheme.onSurfaceVariant.withOpacity(0.5),
                  size: adjustedIconSize,
                ),
                SizedBox(height: screenWidth < 360 ? 3 : 4),
                Expanded(
                  child: Center(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: adjustedFontSize,
                        fontWeight: FontWeight.w500,
                        color: isEnabled ? color : scheme.onSurfaceVariant.withOpacity(0.5),
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Build queue area widget
  Widget _buildQueueArea() {
    final scheme = Theme.of(context).colorScheme;
    
    if (_queue.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        margin: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withOpacity(0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outline.withOpacity(0.2)),
        ),
        child: Row(
          children: [
            Icon(Icons.queue_outlined, color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Text(
              'Queue is empty',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    
    return Container(
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outline.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.queue_outlined, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                'Processing Queue',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _queue.map((job) {
              final status = job['status']?.toString() ?? 'pending';
              final isProcessing = status == 'in_progress';
              final hasError = status == 'error';
              
              return Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: hasError 
                    ? scheme.errorContainer 
                    : scheme.primaryContainer,
                  border: Border.all(
                    color: hasError 
                      ? scheme.error 
                      : (isProcessing ? scheme.primary : scheme.outline),
                    width: isProcessing ? 2 : 1,
                  ),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Background icon
                    Icon(
                      hasError ? Icons.error : Icons.fastfood,
                      color: hasError 
                        ? scheme.onErrorContainer 
                        : scheme.onPrimaryContainer,
                      size: 24,
                    ),
                    // Loading animation overlay
                    if (isProcessing)
                      SizedBox(
                        width: 50,
                        height: 50,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
                        ),
                      ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  // Build total nutrition bar for meal builder mode
  Widget _buildTotalBar() {
    if (!_mealBuilderActive || _currentMealResults.isEmpty) {
      return const SizedBox.shrink();
    }
    
    final scheme = Theme.of(context).colorScheme;
    final s = S.of(context);
    
    // Calculate totals
    int totalKcal = 0;
    int totalCarbs = 0;
    int totalProtein = 0;
    int totalFat = 0;
    
    for (final result in _currentMealResults) {
      totalKcal += (result['kcal'] as int?) ?? 0;
      totalCarbs += (result['carbs'] as int?) ?? 0;
      totalProtein += (result['protein'] as int?) ?? 0;
      totalFat += (result['fat'] as int?) ?? 0;
    }
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withOpacity(0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.primary.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.calculate, color: scheme.primary, size: 16),
          const SizedBox(width: 8),
          Text(
            'Total:',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _CompactPill(label: "$totalKcal ${s.kcalSuffix}", color: Colors.redAccent),
                  const SizedBox(width: 6),
                  _CompactPill(label: "$totalCarbs ${s.carbsSuffix}", color: _carbsColor(context)),
                  const SizedBox(width: 6),
                  _CompactPill(label: "$totalProtein ${s.proteinSuffix}", color: Colors.teal),
                  const SizedBox(width: 6),
                  _CompactPill(label: "$totalFat ${s.fatSuffix}", color: Colors.purple),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Build result cards for meal builder mode
  Widget _buildResultCards() {
    if (!_mealBuilderActive || _currentMealResults.isEmpty) {
      return const SizedBox.shrink();
    }
    
    return Column(
      children: _currentMealResults.map((result) {
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: _buildResultCard(result),
        );
      }).toList(),
    );
  }

  // Build individual result card
  Widget _buildResultCard(Map<String, dynamic> result) {
    final scheme = Theme.of(context).colorScheme;
    final name = result['name'] ?? result['description'] ?? 'Food Item';
    final kcal = result['kcal'] as int?;
    final grams = result['grams'] as int?;
    
    return Card(
      elevation: 2,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: result['image'] != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _buildImageWidget(result['image'], width: 48, height: 48, fit: BoxFit.cover),
              )
            : Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.fastfood, color: scheme.onPrimaryContainer),
              ),
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${kcal ?? 0} kcal${grams != null ? ' • ${grams}g' : ''}',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          trailing: const Icon(Icons.expand_more),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (result['result'] != null)
                    _FormattedResultCard(resultText: result['result']),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () {
                          setState(() {
                            _currentMealResults.remove(result);
                          });
                        },
                        icon: const Icon(Icons.remove_circle_outline, size: 16),
                        label: const Text('Remove'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Show manual add menu
  void _showManualAddMenu() {
    final s = S.of(context);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outline.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Add Manually',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 20),
            ListTile(
              leading: Icon(Icons.edit, color: Theme.of(context).colorScheme.primary),
              title: const Text('Add meal manually'),
              subtitle: const Text('Enter nutrition information manually'),
              onTap: () {
                Navigator.pop(context);
                _addManualFood();
              },
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Widget _buildMainTab() {
    final s = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [


          // Main input card with modern chat-like design
          Container(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
              border: Border.all(color: scheme.outline.withOpacity(0.1)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Modern input field with integrated send button
                  Container(
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: scheme.outline.withOpacity(0.2)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            maxLines: 1,
                            decoration: InputDecoration(
                              labelText: s.describeMeal,
                              hintText: s.describeMealHint,
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                              labelStyle: TextStyle(color: scheme.primary),
                            ),
                          ),
                        ),
                        // Send button inside text field
                        Container(
                          margin: const EdgeInsets.all(4),
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [scheme.primary, scheme.primary.withOpacity(0.8)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: scheme.primary.withOpacity(0.4),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Material(
                            color: Colors.transparent,
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: (_loading && !_queueMode) ? null : _sendOrQueue,
                              child: Center(
                                child: _loading && !_queueMode
                                    ? SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor: AlwaysStoppedAnimation<Color>(scheme.onPrimary),
                                        ),
                                      )
                                    : Icon(
                                        Icons.send_rounded,
                                        color: scheme.onPrimary,
                                        size: 18,
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Image preview with clear guidance
                  if (_image != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: scheme.primary.withOpacity(0.2)),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: _buildImageWidget(_image!, width: 50, height: 50, fit: BoxFit.cover),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Image attached',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w500,
                                        color: scheme.onPrimaryContainer,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        Text(
                                          'Ready to upload. Please click on ',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: scheme.onPrimaryContainer.withOpacity(0.8),
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: scheme.primary.withOpacity(0.2),
                                            borderRadius: BorderRadius.circular(3),
                                          ),
                                          child: Icon(
                                            Icons.send_rounded,
                                            size: 12,
                                            color: scheme.primary,
                                          ),
                                        ),
                                        Expanded(
                                          child: Text(
                                            ' or add more description',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: scheme.onPrimaryContainer.withOpacity(0.8),
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                onPressed: () => setState(() => _image = null),
                                icon: Icon(Icons.close, color: scheme.onPrimaryContainer),
                                style: IconButton.styleFrom(
                                  backgroundColor: scheme.surface.withOpacity(0.8),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: 20),

                  // Compact action buttons row with responsive spacing
                  Row(
                    children: [
                      // Camera button
                      Expanded(
                        child: _buildCompactActionButton(
                          icon: Icons.photo_camera,
                          label: 'Camera',
                          onPressed: canUseCamera ? _captureImage : null,
                          color: scheme.primary,
                        ),
                      ),
                      SizedBox(width: MediaQuery.of(context).size.width < 360 ? 8 : 12),
                      // Gallery button
                      Expanded(
                        child: _buildCompactActionButton(
                          icon: Icons.photo_library,
                          label: 'Gallery',
                          onPressed: _pickImage,
                          color: scheme.secondary,
                        ),
                      ),
                      SizedBox(width: MediaQuery.of(context).size.width < 360 ? 8 : 12),
                       // Barcode button
                       Expanded(
                         child: _buildCompactActionButton(
                           icon: Icons.qr_code_scanner,
                           label: 'Scan',
                           onPressed: (canUseCamera || _isMockMode) ? _scanBarcode : null,
                           color: scheme.tertiary,
                         ),
                       ),
                      SizedBox(width: MediaQuery.of(context).size.width < 360 ? 8 : 12),
                      // Three-dot menu for manual adding with responsive sizing
                      Builder(
                        builder: (context) {
                          final screenWidth = MediaQuery.of(context).size.width;
                          final buttonSize = screenWidth < 360 ? 48.0 : 56.0;
                          final iconSize = screenWidth < 360 ? 20.0 : 24.0;
                          
                          return Container(
                            width: buttonSize,
                            height: buttonSize,
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHigh,
                              shape: BoxShape.circle,
                              border: Border.all(color: scheme.outline.withOpacity(0.2)),
                            ),
                            child: Material(
                              color: Colors.transparent,
                              shape: const CircleBorder(),
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: () => _showManualAddMenu(),
                                child: Icon(
                                  Icons.more_vert,
                                  color: scheme.onSurfaceVariant,
                                  size: iconSize,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),


                ],
              ),
            ),
          ),

          // Queue area (always visible)
          _buildQueueArea(),

          // Total nutrition bar (only in meal builder mode)
          _buildTotalBar(),

          // Result cards (only in meal builder mode)
          _buildResultCards(),


        ],
      ),
    );
  }

  Future<void> _scanBarcode() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _BarcodeScannerScreen()),
    );
    if (!mounted || code == null || code.isEmpty) return;
    // Fetch product from Open Food Facts
    final product = await _fetchOffProduct(code);
    if (product == null) {
      if (!mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.of(context).productNotFound)));
      return;
    }
    // Ask user quantity: empty for full package, or custom weight
    final qty = await _askQuantity(defaultServing: product.servingSizeGrams);
    if (!mounted) return;
    final grams = qty?.trim().isEmpty == true ? product.servingSizeGrams : int.tryParse(qty ?? '');
    // Build meal from OFF nutrients (per 100g scaled or per serving)
    final scaled = product.scaleFor(grams);
    final localizedStructured = _localizedStructured({
      'Name': product.name ?? '-',
      'Calories': '${scaled.kcal?.toStringAsFixed(0) ?? '-'} kcal',
      'Carbs': '${scaled.carbs?.toStringAsFixed(0) ?? '-'} g',
      'Proteins': '${scaled.protein?.toStringAsFixed(0) ?? '-'} g',
      'Fats': '${scaled.fat?.toStringAsFixed(0) ?? '-'} g',
  if (grams != null) 'Weight (g)': '${grams} g',
    });
    final newMeal = {
      'image': null,
      'imagePath': null,
  'description': product.name ?? S.of(context).packagedFood,
      'name': product.name,
      'result': const JsonEncoder.withIndent('  ').convert(localizedStructured),
      'structured': localizedStructured,
  'grams': grams,
      'kcal': scaled.kcal?.round(),
      'carbs': scaled.carbs?.round(),
      'protein': scaled.protein?.round(),
      'fat': scaled.fat?.round(),
      'time': DateTime.now(),
      'hcWritten': false,
    };
    setState(() {
      // Handle meal builder mode vs normal mode
      if (_mealBuilderActive) {
        // Add to current meal results instead of history
        _currentMealResults.add(newMeal);
      } else {
        // Normal mode: add to history and show popup
        _history.add(newMeal);
        _pruneHistory();
      }
    });
    
    if (!_mealBuilderActive) {
      await _saveHistory();
    }

    if (mounted) {
      // Only switch to history tab and show popup in normal mode
      if (!_mealBuilderActive) {
        _tabController.animateTo(0);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _showMealDetails(newMeal);
          }
        });
      }

    }
    // Optionally, write to Health Connect if desired
    try {
      await _ensureHealthConfigured();
      final kcal = scaled.kcal?.round();
      final carbs = scaled.carbs?.round();
      final protein = scaled.protein?.round();
      final fat = scaled.fat?.round();
      if ((kcal != null || carbs != null || protein != null || fat != null) && !kIsWeb && Platform.isAndroid) {
        final status = await _health.getHealthConnectSdkStatus();
        if (mounted) setState(() => _hcSdkStatus = status);
        if (status == HealthConnectSdkStatus.sdkAvailable) {
          final ok = await _health.requestAuthorization([HealthDataType.NUTRITION], permissions: [HealthDataAccess.READ_WRITE]);
          if (ok) {
            final start = DateTime.now();
            final end = start.add(const Duration(minutes: 1));
            newMeal['hcStart'] = start;
            newMeal['hcEnd'] = end;
            final written = await _health.writeMeal(
              mealType: MealType.UNKNOWN,
              startTime: start,
              endTime: end,
              caloriesConsumed: kcal?.toDouble(),
              carbohydrates: carbs?.toDouble(),
              protein: protein?.toDouble(),
              fatTotal: fat?.toDouble(),
              name: product.name,
            );
            if (mounted && written) {
              setState(() => newMeal['hcWritten'] = true);
              await _saveHistory();
            }
          }
        }
      }
    } catch (_) {}
  }

  Future<String?> _askQuantity({int? defaultServing}) async {
    final controller = TextEditingController();
    final s = S.of(context);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.quantityTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(defaultServing != null
                ? s.quantityHelpDefaultServing(defaultServing)
                : s.quantityHelpPackage),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(hintText: s.exampleNumber),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: Text(s.save)),
        ],
      ),
    );
  }

  Future<_OffProduct?> _fetchOffProduct(String barcode) async {
    // Check if we're in mock mode
    if (_isMockMode) {
      // Return mock product data
      final mockProduct = _mockBarcodeProducts[barcode];
      if (mockProduct != null) {
        return _OffProduct.fromJson(mockProduct);
      }
      // If barcode not found in mock data, return a generic mock product
      final genericMockProduct = {
        'product_name': 'Mock Product',
        'nutriments': {
          'energy-kcal_100g': 200.0,
          'carbohydrates_100g': 25.0,
          'proteins_100g': 8.0,
          'fat_100g': 7.0,
        },
        'serving_size': '100g',
        'quantity': '100g',
      };
      return _OffProduct.fromJson(genericMockProduct);
    }

    try {
      // Open Food Facts public API (no key required); "run the api on the device" interpreted as direct device-side HTTP call
      final uri = Uri.parse('https://world.openfoodfacts.org/api/v2/product/$barcode.json');
      final res = await http.get(uri);
      if (res.statusCode != 200) return null;
      final jsonMap = json.decode(res.body);
      if (jsonMap is! Map || jsonMap['product'] is! Map) return null;
      return _OffProduct.fromJson(jsonMap['product'] as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Widget _buildDailyTab() {
    final s = S.of(context);
    final todayKcal = _todayKcal();
    final todayCarbs = _todayCarbs();
    final pct = _dailyLimit == 0 ? 0.0 : (todayKcal / _dailyLimit).clamp(0.0, 2.0);
    Color barColor;
    if (pct < 0.7) {
      barColor = Colors.green;
    } else if (pct < 1.0) {
      barColor = Colors.orange;
    } else {
      final over = (pct - 1.0).clamp(0.0, 1.0);
      barColor = Color.lerp(Colors.red.shade600, Colors.red.shade900, over) ?? Colors.red;
    }
  return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(s.dailyIntake, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text('${s.today}: $todayKcal / $_dailyLimit ${s.kcalSuffix} • $todayCarbs ${s.carbsSuffix}'),
                  const SizedBox(height: 12),
                  _ProgressBar(value: pct.clamp(0.0, 1.5), color: barColor),
                  const SizedBox(height: 16),
                  Text(s.dailyLimit),
                  Slider(
                    value: _dailyLimit.toDouble(),
                    min: 1000,
                    max: 4000,
                    divisions: 30,
                    label: '$_dailyLimit ${s.kcalSuffix}',
                    onChanged: (v) {
                      setState(() => _dailyLimit = v.round());
                    },
                    onChangeEnd: (_) async {
                      await _saveDailyLimit();
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (!kIsWeb && (Platform.isAndroid || Platform.isIOS))
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.local_fire_department),
                        const SizedBox(width: 8),
                        Expanded(child: Text(s.burnedTodayTitle, style: Theme.of(context).textTheme.titleLarge)),
                        IconButton(
                          tooltip: s.burnedHelp,
                          onPressed: () {
                            showDialog(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: Text(s.burnedTodayTitle),
                                content: Text(s.burnedHelpText),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.ok)),
                                ],
                              ),
                            );
                          },
                          icon: const Icon(Icons.help_outline),
                        ),
                        IconButton(
                          tooltip: s.refreshBurned,
                          onPressed: _loadingBurned ? null : _loadTodayBurned,
                          icon: _loadingBurned
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Total burned (basal + active) — compare to today's consumed kcal instead of daily limit
                    Text(_todayTotalBurnedKcal != null
                        ? '${s.totalLabel}: ${_todayTotalBurnedKcal!.round()} ${s.kcalSuffix}'
                        : s.burnedNotAvailable),
                    const SizedBox(height: 8),
                    _ProgressBar(
                      value: todayKcal <= 0 || _todayTotalBurnedKcal == null
                          ? 0
                          : (_todayTotalBurnedKcal! / todayKcal).clamp(0.0, 1.5),
                      color: Colors.blueAccent,
                    ),
                    const SizedBox(height: 12),
                    // Active burned only
                    if (_todayActiveBurnedKcal != null) ...[
                      Text('${s.activeLabel}: ${_todayActiveBurnedKcal!.round()} ${s.kcalSuffix}'),
                      const SizedBox(height: 8),
                      _ProgressBar(
                        value: todayKcal <= 0
                            ? 0
                            : (_todayActiveBurnedKcal! / todayKcal).clamp(0.0, 1.5),
                        color: Colors.orangeAccent,
                      ),
                      const SizedBox(height: 12),
                    ],
                    Builder(builder: (_) {
                      final burned = _todayTotalBurnedKcal?.round() ?? 0;
                      final net = todayKcal - burned; // positive -> surplus, negative -> deficit
                      final isSurplus = net > 0;
                      final label = isSurplus ? s.surplusLabel : (net < 0 ? s.deficitLabel : s.netKcalLabel);
                      final display = net == 0 ? '0' : net.abs().toString();
                      return Text('${s.netKcalLabel}: ${isSurplus ? '+' : (net < 0 ? '-' : '')}$display ${s.kcalSuffix} • $label');
                    }),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          // Health Connect status & actions
          if (!kIsWeb && (Platform.isAndroid || Platform.isIOS))
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.favorite, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(child: Text(s.healthConnect, style: Theme.of(context).textTheme.titleLarge)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          _healthAuthorized == true ? Icons.verified_user : Icons.report_gmailerrorred,
                          color: _healthAuthorized == true ? Colors.green : Colors.orange,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _healthAuthorized == null
                                ? s.hcUnknown
                                : (_healthAuthorized == true ? s.hcAuthorized : s.hcNotAuthorized),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (_hcSdkStatus != null)
                      Text('HC SDK: ${_hcSdkStatus}', style: Theme.of(context).textTheme.bodySmall),
                    if (_healthLastError != null) ...[
                      const SizedBox(height: 6),
                      Text('${s.lastError}: $_healthLastError', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: _checkHealthStatus,
                          icon: const Icon(Icons.refresh),
                          label: Text(s.checkStatus),
                        ),
                        FilledButton.icon(
                          onPressed: _requestHealthPermissions,
                          icon: const Icon(Icons.lock_open),
                          label: Text(s.grantPermissions),
                        ),
                        if (_hcSdkStatus == HealthConnectSdkStatus.sdkUnavailable || _hcSdkStatus == HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired)
                          FilledButton.icon(
                            onPressed: () async { try { await _health.installHealthConnect(); } catch (e) { if (mounted) setState(() => _healthLastError = e.toString()); } },
                            icon: const Icon(Icons.download_rounded),
                            label: Text(_hcSdkStatus == HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired ? (s.updateHc) : (s.installHc)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  int _todayCarbs() {
    final today = DateTime.now();
    final dToday = DateTime(today.year, today.month, today.day);
    int sum = 0;
    for (final item in _history) {
      final t = (item['time'] as DateTime);
      final d = DateTime(t.year, t.month, t.day);
      if (d == dToday && item['carbs'] is int) sum += item['carbs'] as int;
    }
    return sum;
  }

  void _showMealDetails(Map<String, dynamic> meal) {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          maxChildSize: 0.95,
          minChildSize: 0.5,
          builder: (_, controller) => SingleChildScrollView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        (meal['name'] as String?)?.isNotEmpty == true ? meal['name'] : (meal['isGroup'] == true ? S.of(context).meal : S.of(context).mealDetails),
                        style: Theme.of(context).textTheme.titleLarge,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Builder(builder: (ctx) {
                      final dt = _asDateTime(meal['time']);
                      if (dt == null) return const SizedBox.shrink();
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          _formatTimeShort(dt),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      );
                    }),
                  ],
                ),
                const SizedBox(height: 12),
                if (meal['image'] != null || meal['imagePath'] != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: _buildImageWidget(meal['image'] ?? meal['imagePath'], height: 220, fit: BoxFit.cover),
                  ),
                const SizedBox(height: 8),
                if (meal['description'] != null)
                  Text(meal['description'], style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _FormattedResultCard(resultText: meal['result'] ?? ''),
                if (meal['isGroup'] == true && meal['children'] is List) ...[
                  const SizedBox(height: 8),
                  StatefulBuilder(builder: (localCtx, setLocal) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(S.of(context).itemsInMeal((meal['children'] as List).length), style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        ...((meal['children'] as List).cast<Map<String, dynamic>>()).map((child) {
                          final name = child['name'] ?? child['description'] ?? S.of(context).noDescription;
                          final kcal = child['kcal'] as int?;
                          final carbs = child['carbs'] as int?;
                          final protein = child['protein'] as int?;
                          final fat = child['fat'] as int?;
                          final grams = child['grams'] as int?;
                          final dt = _asDateTime(child['time']);
                          String? subtitle;
                          if (dt != null && kcal != null) {
                            subtitle = '${_formatTimeShort(dt)} • ${kcal} ${S.of(context).kcalSuffix}';
                          } else if (dt != null) {
                            subtitle = _formatTimeShort(dt);
                          } else if (kcal != null) {
                            subtitle = '${kcal} ${S.of(context).kcalSuffix}';
                          }
                          final imgPath = (child['image'] != null)
                              ? (child['image'].path as String)
                              : (child['imagePath'] is String ? child['imagePath'] as String : null);
                          return Card(
                            elevation: 0,
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: Theme(
                              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                              child: ExpansionTile(
                                leading: imgPath != null && imgPath.isNotEmpty
                                    ? ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: _buildImageWidget(
                                          imgPath,
                                          width: 48,
                                          height: 48,
                                          fit: BoxFit.cover,
                                        ),
                                      )
                                    : const Icon(Icons.fastfood),
                                title: Text(name),
                                subtitle: subtitle != null ? Text(subtitle) : null,
                                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                children: [
                                  if (child['description'] != null)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 8.0),
                                      child: Text(child['description'], style: Theme.of(context).textTheme.bodyMedium),
                                    ),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      if (kcal != null)
                                        _Pill(icon: Icons.local_fire_department, label: "$kcal ${S.of(context).kcalSuffix}", color: Colors.redAccent),
                                      if (carbs != null)
                                        _Pill(icon: Icons.grain, label: "$carbs ${S.of(context).carbsSuffix}", color: _carbsColor(context)),
                                      if (protein != null)
                                        const SizedBox(height: 4),
                                      if (protein != null)
                                        _Pill(icon: Icons.egg_alt, label: "$protein ${S.of(context).proteinSuffix}", color: Colors.teal),
                                      if (fat != null)
                                        _Pill(icon: Icons.blur_on, label: "$fat ${S.of(context).fatSuffix}", color: Colors.purple),
                                      if (grams != null)
                                        _Pill(icon: Icons.scale, label: "$grams g", color: Theme.of(context).colorScheme.primary),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  if (child['result'] is String && (child['result'] as String).trim().isNotEmpty)
                                    _FormattedResultCard(resultText: child['result']),
                                  const SizedBox(height: 8),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: OutlinedButton.icon(
                                      icon: const Icon(Icons.remove_circle_outline),
                                      label: Text(S.of(context).remove),
                                      onPressed: () async {
                                        setState(() {
                                          (meal['children'] as List).remove(child);
                                          final restored = Map<String, dynamic>.from(child);
                                          restored.remove('isGroup');
                                          restored.remove('children');
                                          restored['time'] = (restored['time'] is DateTime || restored['time'] is String)
                                              ? restored['time']
                                              : DateTime.now();
                                          _history.add(restored);
                                          _recomputeGroupSums(meal);
                                        });
                                        setLocal(() {});
                                        await _saveHistory();
                                        if ((meal['children'] as List).isEmpty && context.mounted) {
                                          final idx = _history.indexOf(meal);
                                          if (idx >= 0) {
                                            setState(() {
                                              _history.removeAt(idx);
   
                                            });
                                            await _saveHistory();
                                          }
                                          Navigator.pop(ctx);
                                        }
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                      ],
                    );
                  }),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      _ungroupMeal(meal);
                      await _saveHistory();
                      if (context.mounted) Navigator.pop(ctx);
                    },
                    icon: const Icon(Icons.call_split),
                    label: Text(S.of(context).ungroup),
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    if (meal['kcal'] != null)
                      _Pill(icon: Icons.local_fire_department, label: "${meal['kcal']} ${S.of(context).kcalSuffix}", color: Colors.redAccent),
                    if (meal['carbs'] != null)
                      _Pill(
                        icon: Icons.grain,
                        label: "${meal['carbs']} ${S.of(context).carbsSuffix}",
                        color: Theme.of(context).brightness == Brightness.light ? Colors.orange : Colors.amber,
                      ),
                    if (meal['protein'] != null)
                      _Pill(icon: Icons.egg_alt, label: "${meal['protein']} ${S.of(context).proteinSuffix}", color: Colors.teal),
                    if (meal['fat'] != null)
                      _Pill(icon: Icons.blur_on, label: "${meal['fat']} ${S.of(context).fatSuffix}", color: Colors.purple),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          // Activate new meal builder and add this item to current results
                          setState(() {
                            _mealBuilderActive = true;
                            _currentMealResults.clear();
                            if (meal['isGroup'] == true && meal['children'] is List) {
                              // If it's a group, add all children to current results
                              _currentMealResults.addAll((meal['children'] as List).cast<Map<String, dynamic>>());
                            } else {
                              // If it's a single item, add it to current results
                              _currentMealResults.add(meal);
                            }
                            // Remove the original meal from history since it's now in the builder
                            _history.remove(meal);
                          });
                          await _saveHistory();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Meal builder activated - add more items!')));
                            Navigator.pop(ctx);
                            _tabController.animateTo(1); // Go to Main tab to add more
                          }
                        },
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.add_circle_outline),
                            const SizedBox(height: 6),
                            Text(S.of(context).addAnother, textAlign: TextAlign.center),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final updated = await showDialog<Map<String, dynamic>>(
                            context: context,
                            builder: (dCtx) {
                              final nameCtrl = TextEditingController(text: meal['name']?.toString() ?? '');
                              final kcalCtrl = TextEditingController(text: meal['kcal']?.toString() ?? '');
                              final carbsCtrl = TextEditingController(text: meal['carbs']?.toString() ?? '');
                              final proteinCtrl = TextEditingController(text: meal['protein']?.toString() ?? '');
                              final fatCtrl = TextEditingController(text: meal['fat']?.toString() ?? '');
                              // Prefill grams with AI-provided value or, for groups, the combined sum of children
                              int? defaultG = meal['grams'] as int?;
                              if (defaultG == null && meal['isGroup'] == true && meal['children'] is List) {
                                int sum = 0;
                                int count = 0;
                                for (final c in (meal['children'] as List)) {
                                  if (c is Map && c['grams'] is int) { sum += c['grams'] as int; count++; }
                                }
                                if (count > 0 && sum > 0) defaultG = sum;
                              }
                              final gramsCtrl = TextEditingController(text: defaultG?.toString() ?? '');
                              bool linkValues = true;
                              final oldK = meal['kcal'] as int?;
                              final oldC = meal['carbs'] as int?;
                              final oldP = meal['protein'] as int?;
                              final oldF = meal['fat'] as int?;
                              // Use the AI/default grams or combined group grams as baseline when linking
                              final int? oldG = defaultG;
                              return StatefulBuilder(
                                builder: (context, setSB) => AlertDialog(
                                  title: Text(S.of(context).editMeal),
                                  content: SingleChildScrollView(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        TextField(controller: nameCtrl, decoration: InputDecoration(labelText: S.of(context).name)),
                                        const SizedBox(height: 8),
                                        TextField(controller: gramsCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: S.of(context).weightLabel)),
                                        CheckboxListTile(
                                          contentPadding: EdgeInsets.zero,
                                          value: linkValues,
                                          onChanged: (v) => setSB(() => linkValues = v ?? true),
                                          title: Text(S.of(context).linkValues),
                                        ),
                                        TextField(controller: kcalCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: S.of(context).kcalLabel)),
                                        const SizedBox(height: 8),
                                        TextField(controller: carbsCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: S.of(context).carbsLabel)),
                                        const SizedBox(height: 8),
                                        TextField(controller: proteinCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: S.of(context).proteinLabel)),
                                        const SizedBox(height: 8),
                                        TextField(controller: fatCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: S.of(context).fatLabel)),
                                      ],
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () {
                                        setSB(() {
                                          nameCtrl.text = meal['name']?.toString() ?? '';
                                          gramsCtrl.text = (defaultG?.toString() ?? '');
                                          kcalCtrl.text = (meal['kcal']?.toString() ?? '');
                                          carbsCtrl.text = (meal['carbs']?.toString() ?? '');
                                          proteinCtrl.text = (meal['protein']?.toString() ?? '');
                                          fatCtrl.text = (meal['fat']?.toString() ?? '');
                                        });
                                      },
                                      child: Text(S.of(context).restoreDefaults),
                                    ),
                                    TextButton(onPressed: () => Navigator.pop(dCtx), child: Text(S.of(context).cancel)),
                                    FilledButton(
                                      onPressed: () {
                                        int? newG = int.tryParse(gramsCtrl.text.trim());
                                        int? newK = int.tryParse(kcalCtrl.text.trim());
                                        int? newC = int.tryParse(carbsCtrl.text.trim());
                                        int? newP = int.tryParse(proteinCtrl.text.trim());
                                        int? newF = int.tryParse(fatCtrl.text.trim());
                                        if (linkValues) {
                                          double? factor;
                                          if (oldC != null && newC != null && oldC > 0 && newC != oldC) {
                                            factor = newC / oldC;
                                          } else if (oldP != null && newP != null && oldP > 0 && newP != oldP) {
                                            factor = newP / oldP;
                                          } else if (oldF != null && newF != null && oldF > 0 && newF != oldF) {
                                            factor = newF / oldF;
                                          } else if (oldK != null && newK != null && oldK > 0 && newK != oldK) {
                                            factor = newK / oldK;
                                          } else if (newG != null && oldG != null && oldG > 0 && newG != oldG) {
                                            factor = newG / oldG;
                                          }
                                          if (factor != null) {
                                            if ((newG == null || newG == oldG) && oldG != null) newG = (oldG * factor).round();
                                            if (newK == null || newK == oldK) newK = oldK != null ? (oldK * factor).round() : null;
                                            if (newC == null || newC == oldC) newC = oldC != null ? (oldC * factor).round() : null;
                                            if (newP == null || newP == oldP) newP = oldP != null ? (oldP * factor).round() : null;
                                            if (newF == null || newF == oldF) newF = oldF != null ? (oldF * factor).round() : null;
                                          }
                                        }
                                        Navigator.pop(dCtx, {
                                          'name': nameCtrl.text.trim().isEmpty ? null : nameCtrl.text.trim(),
                                          'grams': newG,
                                          'kcal': newK,
                                          'carbs': newC,
                                          'protein': newP,
                                          'fat': newF,
                                        });
                                      },
                                      child: Text(S.of(context).save),
                                    ),
                                  ],
                                ),
                              );
                            },
                          );
                          if (updated != null) {
                            setState(() {
                              meal['name'] = updated['name'] ?? meal['name'];
                              meal['grams'] = updated['grams'] ?? meal['grams'];
                              meal['kcal'] = updated['kcal'] ?? meal['kcal'];
                              meal['carbs'] = updated['carbs'] ?? meal['carbs'];
                              meal['protein'] = updated['protein'] ?? meal['protein'];
                              meal['fat'] = updated['fat'] ?? meal['fat'];
                            });
                            await _saveHistory();
                            if (context.mounted) {
                              Navigator.pop(ctx);
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.of(context).mealUpdated)));
                            }
                          }
                        },
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.edit_outlined),
                            const SizedBox(height: 6),
                            Text(S.of(context).editMeal, textAlign: TextAlign.center),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (dCtx) => AlertDialog(
                              title: Text(S.of(context).deleteItem),
                              content: Text(S.of(context).deleteConfirm),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(dCtx, false), child: Text(S.of(context).cancel)),
                                FilledButton(onPressed: () => Navigator.pop(dCtx, true), child: Text(S.of(context).delete)),
                              ],
                            ),
                          );
                          if (ok == true) {
                            try {
                              await _ensureHealthConfigured();
                              if (!kIsWeb && Platform.isAndroid && (meal['hcWritten'] == true)) {
                                final hs = meal['hcStart'];
                                final he = meal['hcEnd'];
                                final start = hs is DateTime ? hs : (hs is String ? DateTime.tryParse(hs) : null);
                                final end = he is DateTime ? he : (he is String ? DateTime.tryParse(he) : null);
                                if (start != null && end != null) {
                                  await _health.requestAuthorization([HealthDataType.NUTRITION], permissions: [HealthDataAccess.READ_WRITE]);
                                  await _health.delete(type: HealthDataType.NUTRITION, startTime: start, endTime: end);
                                }
                              }
                            } catch (_) {}
                            setState(() {
                              _history.remove(meal);
                            });
                            await _saveHistory();
                            if (context.mounted) {
                              Navigator.pop(ctx);
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.of(context).delete)));
                            }
                          }
                        },
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.delete_outline),
                            const SizedBox(height: 6),
                            Text(S.of(context).delete, textAlign: TextAlign.center),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---- Manual add & meal grouping helpers ----
  Future<void> _addManualFood() async {
    final s = S.of(context);
    final nameCtrl = TextEditingController();
    final kcalCtrl = TextEditingController();
    final carbsCtrl = TextEditingController();
    final proteinCtrl = TextEditingController();
    final fatCtrl = TextEditingController();
    final gramsCtrl = TextEditingController();
    bool linkValues = true; // reserved for future scaling on edit
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dCtx) => StatefulBuilder(
        builder: (context, setSB) => AlertDialog(
          title: Text(s.addManual),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameCtrl, decoration: InputDecoration(labelText: s.name)),
                const SizedBox(height: 8),
                TextField(controller: gramsCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: s.weightLabel)),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: linkValues,
                  onChanged: (v) => setSB(() => linkValues = v ?? true),
                  title: Text(s.linkValues),
                ),
                TextField(controller: kcalCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: s.kcalLabel)),
                const SizedBox(height: 8),
                TextField(controller: carbsCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: s.carbsLabel)),
                const SizedBox(height: 8),
                TextField(controller: proteinCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: s.proteinLabel)),
                const SizedBox(height: 8),
                TextField(controller: fatCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: s.fatLabel)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dCtx), child: Text(s.cancel)),
            FilledButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty) {
                  Navigator.pop(dCtx);
                  return;
                }
                Navigator.pop(dCtx, {
                  'name': nameCtrl.text.trim(),
                  'grams': int.tryParse(gramsCtrl.text.trim()),
                  'kcal': int.tryParse(kcalCtrl.text.trim()),
                  'carbs': int.tryParse(carbsCtrl.text.trim()),
                  'protein': int.tryParse(proteinCtrl.text.trim()),
                  'fat': int.tryParse(fatCtrl.text.trim()),
                });
              },
              child: Text(s.save),
            ),
          ],
        ),
      ),
    );
    if (data == null) return;
    final localizedStructured = _localizedStructured({
      'Name': data['name'] ?? '-',
      'Calories': data['kcal'] != null ? '${data['kcal']} kcal' : '-',
      'Carbs': data['carbs'] != null ? '${data['carbs']} g' : '-',
      'Proteins': data['protein'] != null ? '${data['protein']} g' : '-',
      'Fats': data['fat'] != null ? '${data['fat']} g' : '-',
  if (data['grams'] != null) 'Weight (g)': '${data['grams']} g',
    });
    final newMeal = {
      'image': null,
      'imagePath': null,
  'description': data['name'] ?? S.of(context).packagedFood,
      'name': data['name'],
      'result': const JsonEncoder.withIndent('  ').convert(localizedStructured),
      'structured': localizedStructured,
      'grams': data['grams'],
      'kcal': data['kcal'],
      'carbs': data['carbs'],
      'protein': data['protein'],
      'fat': data['fat'],
      'time': DateTime.now(),
      'hcWritten': false,
    };
    setState(() {
      // Handle meal builder mode vs normal mode
      if (_mealBuilderActive) {
        // Add to current meal results instead of history
        _currentMealResults.add(newMeal);
      } else {
        // Normal mode: add to history and show popup
        _history.add(newMeal);
        _pruneHistory();
      }
    });
    
    if (!_mealBuilderActive) {
      await _saveHistory();
    }

    if (!mounted) return;
    
    // Only switch to history tab and show popup in normal mode
    if (!_mealBuilderActive) {
      _tabController.animateTo(0);
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted) _showMealDetails(newMeal);
      });
    }
  
  }





  void _toggleMealBuilder() {
    setState(() {
      if (_mealBuilderActive) {
        // Finish meal - group all current results and add to history
        if (_currentMealResults.isNotEmpty) {
          _finishCurrentMeal();
        }
        _mealBuilderActive = false;
      } else {
        // Start meal
        _mealBuilderActive = true;
        _currentMealResults.clear();
      }
    });
    
    // Save meal builder state to SharedPreferences so background service can check it
    _saveMealBuilderState();
  }
  
  // Save meal builder state to SharedPreferences
  Future<void> _saveMealBuilderState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('meal_builder_active', _mealBuilderActive);
    
    if (_mealBuilderActive) {
      // Also save current meal results
      Map<String, dynamic> toJson(Map<String, dynamic> x) {
        return {
          'isGroup': x['isGroup'] == true,
          'imagePath': (x['imagePath'] as String?) ?? (x['image'] is XFile ? (x['image'] as XFile).path : null),
          'description': x['description'],
          'name': x['name'],
          'result': x['result'],
          'structured': x['structured'],
          'grams': x['grams'],
          'kcal': x['kcal'],
          'carbs': x['carbs'],
          'protein': x['protein'],
          'fat': x['fat'],
          'time': (x['time'] is DateTime) ? (x['time'] as DateTime).toIso8601String() : x['time'],
          'hcStart': (x['hcStart'] is DateTime) ? (x['hcStart'] as DateTime).toIso8601String() : x['hcStart'],
          'hcEnd': (x['hcEnd'] is DateTime) ? (x['hcEnd'] as DateTime).toIso8601String() : x['hcEnd'],
          'hcWritten': x['hcWritten'] == true,
          if (x['children'] is List) 'children': (x['children'] as List).map((c) => toJson(Map<String, dynamic>.from(c))).toList(),
        };
      }
      
      final serializable = _currentMealResults.map((m) => toJson(m)).toList();
      await prefs.setString('current_meal_results_json', json.encode(serializable));
    }
  }

  void _recomputeGroupSums(Map<String, dynamic> group) {
    int sumK = 0, sumC = 0, sumP = 0, sumF = 0;
    bool hasK = false, hasC = false, hasP = false, hasF = false;
    if (group['children'] is List) {
      for (final e in (group['children'] as List).cast<Map>()) {
        final k = e['kcal'];
        final c = e['carbs'];
        final p = e['protein'];
        final f = e['fat'];
        if (k is int) { sumK += k; hasK = true; }
        if (c is int) { sumC += c; hasC = true; }
        if (p is int) { sumP += p; hasP = true; }
        if (f is int) { sumF += f; hasF = true; }
      }
    }
    group['kcal'] = hasK ? sumK : null;
    group['carbs'] = hasC ? sumC : null;
    group['protein'] = hasP ? sumP : null;
    group['fat'] = hasF ? sumF : null;
    group['result'] = S.of(context).groupSummary(sumK, sumC, sumP, sumF);
  }

  void _finishCurrentMeal() {
    if (_currentMealResults.isEmpty) return;
    
    // Create a grouped meal from current results
    final group = <String, dynamic>{
      'isGroup': true,
      'name': S.of(context).meal,
      'time': DateTime.now(),
      'children': List.from(_currentMealResults),
      'image': _currentMealResults.first['image'],
      'imagePath': _currentMealResults.first['imagePath'],
      'hcWritten': false,
    };
    
    // Compute totals
    _recomputeGroupSums(group);
    
    // Add to history
    setState(() {
      _history.add(group);
      _currentMealResults.clear();
      _pruneHistory();
    });
    
    // Save and show feedback
    _saveHistory();
    _saveMealBuilderState(); // Also save meal builder state
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Meal saved to history')),
    );
  }

  // --- Formatting helpers ---
  DateTime? _asDateTime(dynamic t) {
    if (t is DateTime) return t;
    if (t is String) return DateTime.tryParse(t);
    return null;
  }

  String _formatTimeShort(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
  
  // Public wrapper methods for widgets
  DateTime? asDateTime(dynamic t) => _asDateTime(t);
  String formatTimeShort(DateTime t) => _formatTimeShort(t);

  // Normalize keys in a structured nutrition map to the current locale so UI shows consistent labels
  Map<String, dynamic> _localizedStructured(Map<String, dynamic> raw) {
    final code = S.of(context).locale.languageCode;
    String mapKey(String key) {
      if (code == 'fr') {
        switch (key) {
          case 'Name':
            return "Nom de l'aliment";
          case 'Carbs':
            return 'Glucides';
          case 'Proteins':
            return 'Proteines';
          case 'Fats':
            return 'Lipides';
          case 'Weight':
          case 'Weight (g)':
          case 'Weight(g)':
            return 'Poids (g)';
        }
      } else {
        switch (key) {
          case "Nom de l'aliment":
            return 'Name';
          case 'Glucides':
            return 'Carbs';
          case 'Proteines':
          case 'Protéines':
            return 'Proteins';
          case 'Lipides':
            return 'Fats';
          case 'Poids':
          case 'Poids (g)':
            return 'Weight (g)';
        }
      }
      return key;
    }

    Map<String, dynamic> walk(Map<String, dynamic> m) {
      final out = <String, dynamic>{};
      m.forEach((key, value) {
        final nk = mapKey(key);
        if (value is Map<String, dynamic>) {
          out[nk] = walk(value);
        } else if (value is Map) {
          out[nk] = walk(Map<String, dynamic>.from(value));
        } else if (value is List) {
      out[nk] = value
        .map((e) => e is Map ? walk(Map<String, dynamic>.from(e)) : e)
        .toList();
        } else {
          out[nk] = value;
        }
      });
      return out;
    }

    return walk(raw);
  }

  void _ungroupMeal(Map<String, dynamic> group) {
    if (group['isGroup'] == true && group['children'] is List) {
      final idx = _history.indexOf(group);
      if (idx >= 0) {
        setState(() {
          _history.removeAt(idx);
          final kids = (group['children'] as List).cast<Map<String, dynamic>>();
          _history.insertAll(idx, kids);

        });
      }
    }
  }

  void _mergeMeals(Map<String, dynamic> source, Map<String, dynamic> target) async {
    if (identical(source, target)) return;
    final tIdx = _history.indexOf(target);
    final sIdx = _history.indexOf(source);
    if (tIdx < 0 || sIdx < 0) return;
    setState(() {
      if (target['isGroup'] == true) {
        final List kids = target['children'] as List? ?? [];
        if (source['isGroup'] == true) {
          kids.addAll((source['children'] as List?) ?? const []);
        } else {
          kids.add(source);
        }
        target['children'] = kids;
        _recomputeGroupSums(target);
        _history.removeAt(sIdx);
      } else {
        final group = <String, dynamic>{
          'isGroup': true,
          'name': S.of(context).meal,
          'time': target['time'],
          'children': source['isGroup'] == true ? [target, ...(source['children'] as List? ?? const [])] : [target, source],
          'image': target['image'],
          'imagePath': target['imagePath'],
          'hcWritten': false,
        };
        _recomputeGroupSums(group);
        final keepIdx = _history.indexOf(target);
        _history[keepIdx] = group;
        final rmIdx = _history.indexOf(source);
        if (rmIdx >= 0) _history.removeAt(rmIdx);
      }
    });
    await _saveHistory();
  }

}