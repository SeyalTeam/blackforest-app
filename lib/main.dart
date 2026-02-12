import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:blackforest_app/cart_provider.dart';
import 'package:blackforest_app/login_page.dart';
import 'package:blackforest_app/categories_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import 'package:blackforest_app/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService().init();
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

class _MyAppState extends State<MyApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription? _notificationSubscription;

  @override
  void initState() {
    super.initState();
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
    _notificationSubscription?.cancel();
    super.dispose();
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
    final token = prefs.getString('token');
    if (token != null) {
      // Validate token (recommended for security)
      try {
        final response = await http.get(
          Uri.parse(
            'https://blackforest.vseyal.com/api/users/me?depth=5&showHiddenFields=true',
          ),
          headers: {'Authorization': 'Bearer $token'},
        );
        if (response.statusCode == 200) {
          try {
            final body = jsonDecode(response.body);
            final user = body is Map<String, dynamic>
                ? (body['user'] ?? body)
                : null;
            if (user is Map<String, dynamic>) {
              // --- Session Duration Check ---
              final loginTime = prefs.getInt('login_time') ?? 0;
              final role = user['role']?.toString() ?? '';

              // Roles allowed for 30 days
              const longSessionRoles = [
                'superadmin',
                'admin',
                'company',
                'factory',
              ];

              if (!longSessionRoles.contains(role)) {
                // For everyone else (Staff), enforce 14 hours (50400000 ms)
                final diff = DateTime.now().millisecondsSinceEpoch - loginTime;
                if (diff > 50400000) {
                  // 14 hours
                  await prefs.clear();
                  return const LoginPage();
                }
              }

              // Store user-level name as a secondary identifier
              final userName = user['name'] ?? user['username'];
              if (userName != null) {
                await prefs.setString('user_name', userName.toString());
              }

              final userId =
                  user['id']?.toString() ??
                  user['_id']?.toString() ??
                  user[r'$oid']?.toString();
              if (userId != null && userId.isNotEmpty) {
                await prefs.setString('user_id', userId);
              }

              final userRole = user['role']?.toString();
              if (userRole != null && userRole.isNotEmpty) {
                await prefs.setString('role', userRole);
              }

              final emp = user['employee'];
              if (emp is Map<String, dynamic>) {
                final empId =
                    emp['id']?.toString() ??
                    emp['_id']?.toString() ??
                    emp[r'$oid']?.toString();
                if (empId != null && empId.isNotEmpty) {
                  await prefs.setString('employee_id', empId);
                }

                // Strictly prioritize name from employee collection
                final empName = emp['name']?.toString();
                if (empName != null && empName.isNotEmpty) {
                  await prefs.setString('employee_name', empName);
                }

                final empCode =
                    emp['employeeId']?.toString() ??
                    emp['employeeID']?.toString() ??
                    emp['empId']?.toString();
                if (empCode != null && empCode.isNotEmpty) {
                  await prefs.setString('employee_code', empCode);
                }

                final photo = emp['photo'];
                String? photoUrl;
                if (photo is Map<String, dynamic>) {
                  photoUrl =
                      photo['thumbnailURL']?.toString() ??
                      photo['thumbnailUrl']?.toString() ??
                      photo['url']?.toString();
                } else if (photo is String) {
                  photoUrl = photo;
                }

                if (photoUrl != null && photoUrl.isNotEmpty) {
                  if (photoUrl.startsWith('/')) {
                    photoUrl = 'https://blackforest.vseyal.com$photoUrl';
                  }
                  await prefs.setString('employee_photo_url', photoUrl);
                }
              }
            }
          } catch (_) {}
          // Valid: Return wrapped CategoriesPage
          return const IdleTimeoutWrapper(child: CategoriesPage());
        }
      } catch (_) {}
      // Invalid: Clear prefs and fall to login
      await prefs.clear();
    }
    // No valid session: Return LoginPage
    return const LoginPage();
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
            // Resolved widget (LoginPage or CategoriesPage)
            return snapshot.data!;
          }
        },
      ),
      routes: {'/login': (context) => const LoginPage()},
    );
  }
}
