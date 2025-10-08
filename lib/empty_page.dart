import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

class EmptyPage extends StatefulWidget {
  const EmptyPage({super.key});

  @override
  _EmptyPageState createState() => _EmptyPageState();
}

class _EmptyPageState extends State<EmptyPage> {
  Timer? _inactivityTimer;

  @override
  void initState() {
    super.initState();
    _resetTimer(); // Start timer on page load
  }

  @override
  void dispose() {
    _inactivityTimer?.cancel();
    super.dispose();
  }

  void _resetTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer =
        Timer(const Duration(hours: 7), _logout); // Changed to 7 hours
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    Navigator.pushReplacementNamed(context, '/login'); // Go to login
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector( // Detect taps to reset timer
      onTap: _resetTimer, // Reset on any tap
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
              'Welcome Team', style: TextStyle(color: Colors.white)),
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
          // White menu icon
          actions: [
            IconButton(
              icon: const Icon(Icons.shopping_cart, color: Colors.grey),
              // Added cart icon
              onPressed: () {
                _resetTimer(); // Reset timer
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Cart screen coming soon')),
                );
              },
            ),
          ],
        ),
        drawer: Drawer(
          child: FutureBuilder<String?>(
            future: SharedPreferences.getInstance().then((prefs) => prefs.getString('username')),
            builder: (context, snapshot) {
              final username = snapshot.data ?? 'Menu';  // Fallback if no username
              return ListView(
                padding: EdgeInsets.zero,
                children: <Widget>[
                  DrawerHeader(
                    decoration: const BoxDecoration(
                      color: Colors.black,
                    ),
                    child: Text(
                      username,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                      ),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.shopping_cart, color: Colors.black),
                    title: const Text('Products'),
                    onTap: () {
                      _resetTimer();  // Reset timer on tap
                      Navigator.pop(context);  // Close drawer
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Products screen coming soon')),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.category, color: Colors.black),
                    title: const Text('Categories'),
                    onTap: () {
                      _resetTimer();
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Categories screen coming soon')),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.location_on, color: Colors.black),
                    title: const Text('Branches'),
                    onTap: () {
                      _resetTimer();
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Branches screen coming soon')),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.people, color: Colors.black),
                    title: const Text('Employees'),
                    onTap: () {
                      _resetTimer();
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Employees screen coming soon')),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.receipt, color: Colors.black),
                    title: const Text('Billing'),
                    onTap: () {
                      _resetTimer();
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Billing screen coming soon')),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.bar_chart, color: Colors.black),
                    title: const Text('Reports'),
                    onTap: () {
                      _resetTimer();
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Reports screen coming soon')),
                      );
                    },
                  ),
                  ListTile(  // Logout at bottom
                    leading: const Icon(Icons.logout, color: Colors.black),
                    title: const Text('Logout'),
                    onTap: () {
                      _resetTimer();
                      Navigator.pop(context);
                      _logout();
                    },
                  ),
                ],
              );
            },
          ),
        ),
        body: const Center(
          child: Text(
            'Hai Castro',
            style: TextStyle(fontSize: 20, color: Color(0xFF4A4A4A)),
          ),
        ),
        backgroundColor: Colors.white,
      ),
    );
  }
}