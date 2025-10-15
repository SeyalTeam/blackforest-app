import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/products_page.dart'; // Import ProductsPage

class CategoriesPage extends StatefulWidget {
  const CategoriesPage({super.key});

  @override
  _CategoriesPageState createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  Timer? _inactivityTimer;
  List<dynamic> _bilingCategories = [];
  bool _isLoading = true;
  String _username = 'Menu'; // Fallback

  @override
  void initState() {
    super.initState();
    _loadUsername();
    _fetchBilingCategories();
    _resetTimer(); // Start timer
  }

  @override
  void dispose() {
    _inactivityTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadUsername() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _username = prefs.getString('username') ?? 'Menu';
    });
  }

  Future<void> _fetchBilingCategories() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) {
        _showError('No token found. Please login again.');
        return;
      }

      final response = await http.get(
        Uri.parse('https://apib.theblackforestcakes.com/api/categories/list-categories?type=biling'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        setState(() {
          _bilingCategories = jsonDecode(response.body);
        });
      } else {
        _showError('Failed to fetch categories: ${response.statusCode}');
      }
    } catch (e) {
      _showError('Network error: Check your internet');
    }

    setState(() {
      _isLoading = false;
    });
  }

  void _resetTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(const Duration(hours: 7), _logout); // 7 hours timeout
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    Navigator.pushReplacementNamed(context, '/login'); // Go to login
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.grey[800],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector( // Detect taps to reset timer
      onTap: _resetTimer,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Welcome Team', style: TextStyle(color: Colors.white)),
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white), // White menu icon
          actions: [
            IconButton(
              icon: const Icon(Icons.shopping_cart, color: Colors.grey), // Cart icon
              onPressed: () {
                _resetTimer(); // Reset timer
                _showError('Cart screen coming soon');
              },
            ),
          ],
        ),
        drawer: Drawer( // Left sidebar menu
          child: ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              DrawerHeader(
                decoration: const BoxDecoration(
                  color: Colors.black,
                ),
                child: Text(
                  _username,
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
                  _resetTimer(); // Reset timer on tap
                  Navigator.pop(context); // Close drawer
                  _showError('Products screen coming soon');
                },
              ),
              ListTile(
                leading: const Icon(Icons.category, color: Colors.black),
                title: const Text('Categories'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
                  _showError('Categories screen coming soon');
                },
              ),
              ListTile(
                leading: const Icon(Icons.location_on, color: Colors.black),
                title: const Text('Branches'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
                  _showError('Branches screen coming soon');
                },
              ),
              ListTile(
                leading: const Icon(Icons.people, color: Colors.black),
                title: const Text('Employees'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
                  _showError('Employees screen coming soon');
                },
              ),
              ListTile(
                leading: const Icon(Icons.receipt, color: Colors.black),
                title: const Text('Billing'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
                  _showError('Billing screen coming soon');
                },
              ),
              ListTile(
                leading: const Icon(Icons.bar_chart, color: Colors.black),
                title: const Text('Reports'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
                  _showError('Reports screen coming soon');
                },
              ),
              ListTile( // Logout at bottom
                leading: const Icon(Icons.logout, color: Colors.black),
                title: const Text('Logout'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
                  _logout();
                },
              ),
            ],
          ),
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator(color: Colors.black))
            : _bilingCategories.isEmpty
            ? const Center(child: Text('No biling categories found', style: TextStyle(color: Color(0xFF4A4A4A), fontSize: 18)))
            : LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final crossAxisCount = (width > 600) ? 5 : 3; // 3 on phones, 5 on desktop/web/tablets
            return GridView.builder(
              padding: const EdgeInsets.all(10),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 0.75, // Rectangular
              ),
              itemCount: _bilingCategories.length,
              itemBuilder: (context, index) {
                final category = _bilingCategories[index];
                final imageUrl = category['image'] != null
                    ? 'https://apib.theblackforestcakes.com/uploads/categories/${category['image'].split('/').last}'
                    : 'https://via.placeholder.com/150?text=No+Image'; // Fallback

                return GestureDetector(
                  onTap: () {
                    _resetTimer(); // Reset timer on tap
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ProductsPage(
                          categoryId: category['_id'],
                          categoryName: category['name'],
                        ),
                      ),
                    );
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.grey.withOpacity(0.1),
                          spreadRadius: 2,
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Expanded(
                          flex: 8, // 80% image
                          child: ClipRRect(
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                            child: Image.network(
                              imageUrl,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              errorBuilder: (context, error, stackTrace) {
                                return const Center(child: Text('No Image', style: TextStyle(color: Colors.grey)));
                              },
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2, // 20% name
                          child: Container(
                            width: double.infinity,
                            decoration: const BoxDecoration(
                              color: Colors.black,
                              borderRadius: BorderRadius.vertical(bottom: Radius.circular(8)),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              category['name'] ?? 'Unknown',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
        backgroundColor: Colors.white,
      ),
    );
  }
}