import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:blackforest_app/cart_provider.dart';
import 'package:blackforest_app/categories_page.dart';
import 'package:blackforest_app/login_page.dart';
import 'package:blackforest_app/home_page.dart';
import 'package:blackforest_app/home_navigation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:blackforest_app/api_server_prefs.dart';
import 'package:blackforest_app/notification_service.dart';
import 'package:blackforest_app/auth_session_manager.dart';
import 'package:blackforest_app/session_prefs.dart';
import 'package:blackforest_app/app_version.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:screen_protector/screen_protector.dart';
import 'package:blackforest_app/kot_auto_print_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppVersion.init(); // cache version before any HTTP requests
  await ensureApiHostRoutingReady();

  // Enable screenshot prevention and background data leakage protection
  unawaited(ScreenProtector.preventScreenshotOn());
  unawaited(ScreenProtector.protectDataLeakageOn());

  // Do not block startup for notification plugin initialization.
  unawaited(
    NotificationService().init().timeout(const Duration(seconds: 8)).catchError(
      (_) {
        // Startup must continue even if notification init fails.
      },
    ),
  );

  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'printing_service',
      channelName: 'Printing Service',
      channelDescription: 'Monitors and prints website orders',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(5000),
      autoRunOnBoot: true,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );

  runApp(
    MultiProvider(
      providers: [ChangeNotifierProvider(create: (context) => CartProvider())],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription? _notificationSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AuthSessionManager.instance.attachNavigatorKey(_navigatorKey);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      AuthSessionManager.instance.startHeartbeat();
    });

    _notificationSubscription = NotificationService().onNotificationClick
        .listen((payload) {
          if (payload != null && payload.isNotEmpty) {
            // Use post frame callback to ensure navigator is ready
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _handleNotificationClick(payload);
            });
          }
        });

    // Handle initial notification if app was terminated
    _checkInitialNotification();
  }

  Future<void> _checkInitialNotification() async {
    final details = await NotificationService().flutterLocalNotificationsPlugin
        .getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp ?? false) {
      final payload = details?.notificationResponse?.payload;
      if (payload != null && payload.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _handleNotificationClick(payload);
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _notificationSubscription?.cancel();
    AuthSessionManager.instance.stopHeartbeat();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      AuthSessionManager.instance.verifySession(force: true);
      AuthSessionManager.instance.startHeartbeat();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      AuthSessionManager.instance.stopHeartbeat();
    }
  }

  void _handleNotificationClick(String billId) {
    // We need a context that has the CartProvider
    // The navigatorKey's currentContext is usually the root of the app
    final context = _navigatorKey.currentContext;
    if (context != null) {
      final cartProvider = Provider.of<CartProvider>(context, listen: false);
      cartProvider.openBillAndNavigate(context, billId);
    }
  }

  Future<Widget> _getInitialPage() async {
    final prefs = await SharedPreferences.getInstance();
    final token = (prefs.getString('token') ?? '').trim();
    if (token.isEmpty) {
      return const LoginPage();
    }

    // Cache-first boot: avoid waiting on network before first frame.
    final loginTime = prefs.getInt('login_time') ?? 0;
    final cachedRole = (prefs.getString('role') ?? '').trim().toLowerCase();
    const longSessionRoles = <String>{
      'superadmin',
      'admin',
      'company',
      'factory',
    };
    if (loginTime > 0 && !longSessionRoles.contains(cachedRole)) {
      final diff = DateTime.now().millisecondsSinceEpoch - loginTime;
      if (diff > 50400000) {
        await clearSessionPreservingFavorites(prefs);
        return const LoginPage();
      }
    }

    final branchId = (prefs.getString('branchId') ?? '').trim();
    if (token.isNotEmpty && branchId.isNotEmpty) {
      unawaited(KotAutoPrintService.startService());
    }
    final showHomeNavigation = HomeNavigationService.readCachedVisibility(
      prefs,
      branchId: branchId,
      fallback: true,
    );
    final showTableNavigation = HomeNavigationService.readCachedTableVisibility(
      prefs,
      branchId: branchId,
      fallback: true,
    );

    unawaited(
      HomeNavigationService.loadVisibilityForCurrentBranch(
        prefs: prefs,
        forceRefresh: true,
        fallback: showHomeNavigation,
      ),
    );
    unawaited(
      HomeNavigationService.loadTableVisibilityForCurrentBranch(
        prefs: prefs,
        forceRefresh: true,
        fallback: showTableNavigation,
      ),
    );

    return IdleTimeoutWrapper(
      child: showHomeNavigation ? const HomePage() : const CategoriesPage(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Black Forest App',
      theme: ThemeData(
        primarySwatch: Colors.grey,
        scaffoldBackgroundColor: const Color(
          0xFFF5F5F5,
        ), // Light grey background
      ),
      home: FutureBuilder<Widget>(
        future: _getInitialPage(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            // Splash-like loader during check (no flash)
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          } else if (snapshot.hasError) {
            // Fallback to login on error
            return const LoginPage();
          } else {
            // Resolved widget (LoginPage or HomePage)
            return snapshot.data!;
          }
        },
      ),
      routes: {'/login': (context) => const LoginPage()},
    );
  }
}
