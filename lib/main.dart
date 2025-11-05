import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:blackforest_app/cart_provider.dart';
import 'package:blackforest_app/login_page.dart';
import 'package:blackforest_app/categories_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => CartProvider()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  Future<Widget> _getInitialPage() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    if (token != null) {
      // Validate token (recommended for security)
      try {
        final response = await http.get(
          Uri.parse('https://admin.theblackforestcakes.com/api/users/me'),
          headers: {'Authorization': 'Bearer $token'},
        );
        if (response.statusCode == 200) {
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
      title: 'Black Forest App',
      theme: ThemeData(
        primarySwatch: Colors.grey,
        scaffoldBackgroundColor: const Color(0xFFF5F5F5), // Light grey background
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
      routes: {
        '/login': (context) => const LoginPage(),
      },
    );
  }
}