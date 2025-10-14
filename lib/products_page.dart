import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ProductsPage extends StatefulWidget {
  final String categoryId;
  final String categoryName; // Added for title

  const ProductsPage({
    super.key,
    required this.categoryId,
    required this.categoryName,
  });

  @override
  _ProductsPageState createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  Timer? _inactivityTimer;
  List<dynamic> _products = [];
  bool _isLoading = true;
  String _username = 'Menu'; // Fallback
  Set<int> _selectedIndices = {}; // Track multiple selected product indices
  Map<int, int> _quantities = {}; // Track qty for each selected product

  @override
  void initState() {
    super.initState();
    _loadUsername();
    _fetchProducts();
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

  Future<void> _fetchProducts() async {
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
        Uri.parse('https://apib.theblackforestcakes.com/api/products?categoryId=${widget.categoryId}'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        setState(() {
          _products = jsonDecode(response.body);
        });
      } else {
        _showError('Failed to fetch products: ${response.statusCode}');
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

  void _toggleProductSelection(int index) {
    setState(() {
      if (_selectedIndices.contains(index)) {
        // Increase qty on subsequent taps
        _quantities[index] = (_quantities[index] ?? 1) + 1;
      } else {
        // Select and set default qty 1
        _selectedIndices.add(index);
        _quantities[index] = 1;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector( // Detect taps to reset timer
      onTap: _resetTimer,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Products in ${widget.categoryName}', style: const TextStyle(color: Colors.white)), // Use categoryName in title
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white), // White menu icon
          actions: [
            IconButton(
              icon: const Icon(Icons.shopping_cart, color: Colors.grey), // Cart icon
              onPressed: () {
                _resetTimer(); // Reset timer
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Cart screen coming soon')),
                );
              },
            ),
          ],
        ),
        drawer: Drawer( // Left sidebar menu (same as before)
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
            : _products.isEmpty
            ? const Center(child: Text('No products found', style: TextStyle(color: Color(0xFF4A4A4A), fontSize: 18)))
            : GridView.builder(
          padding: const EdgeInsets.all(10),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3, // 3 columns
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 0.75, // Rectangular
          ),
          itemCount: _products.length,
          itemBuilder: (context, index) {
            final product = _products[index];
            final filename = product['images'] != null && product['images'].isNotEmpty ? product['images'][0] : null; // Use 'images' array, first item
            final encodedFilename = filename != null ? Uri.encodeComponent(filename) : null;
            final imageUrl = encodedFilename != null
                ? 'https://apib.theblackforestcakes.com/uploads/products/$encodedFilename'
                : 'https://via.placeholder.com/150?text=No+Image'; // Fallback
            final price = product['priceDetails'] != null && product['priceDetails'].isNotEmpty
                ? '₹${product['priceDetails'][0]['price'] ?? 0}'
                : '₹0'; // Use priceDetails[0].price
            final isSelected = _selectedIndices.contains(index); // Check if selected
            final qty = _quantities[index] ?? 1; // Get qty or default 1

            return GestureDetector(
              onTap: () {
                _resetTimer(); // Reset timer on tap
                _toggleProductSelection(index); // Toggle multi-select and increase qty
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('${product['name']} selected (Qty: $qty)')),
                );
              },
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: isSelected ? Border.all(color: Colors.green, width: 4) : null, // Increased border width to 4
                  boxShadow: [
                    BoxShadow(
                      color: Colors.grey.withOpacity(0.1),
                      spreadRadius: 2,
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    Column(
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
                              product['name'] ?? 'Unknown',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Positioned(
                      top: 2, // Moved up more
                      left: 2, // Moved left more
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2), // Reduced padding more for smaller background
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          price,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10), // Reduced font size more
                        ),
                      ),
                    ),
                    if (isSelected)
                      Positioned.fill( // Overlay on image
                        child: Align(
                          alignment: Alignment.center,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.7), // Semi-transparent black
                              border: Border.all(color: Colors.grey, width: 1), // Added grey border
                              borderRadius: BorderRadius.circular(4),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), // Maintain size
                            child: Text(
                              '$qty', // Removed "Qty:" text, just number
                              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
        backgroundColor: Colors.white,
      ),
    );
  }
}