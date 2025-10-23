// stock_order.dart (renamed from pastry_products_page.dart)
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/common_scaffold.dart';

class StockOrderPage extends StatefulWidget {
  final String categoryId;
  final String categoryName;

  const StockOrderPage({
    super.key,
    required this.categoryId,
    required this.categoryName,
  });

  @override
  _StockOrderPageState createState() => _StockOrderPageState();
}

class _StockOrderPageState extends State<StockOrderPage> {
  List<dynamic> _products = [];
  bool _isLoading = true;
  Map<int, int?> _quantities = {}; // Track qty (nullable for empty)
  Map<int, int?> _inStockQuantities = {}; // Track inStock qty (nullable for empty)
  Map<int, bool> _isSelected = {}; // Track checkbox selection
  Map<int, TextEditingController> _inStockControllers = {}; // Persistent controllers
  Map<int, TextEditingController> _qtyControllers = {}; // Persistent controllers
  TextEditingController _searchController = TextEditingController();
  List<dynamic> _filteredProducts = [];
  String? _branchId;
  String? _userRole;

  @override
  void initState() {
    super.initState();
    _fetchProducts();
    _searchController.addListener(_filterProducts);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _inStockControllers.forEach((_, controller) => controller.dispose());
    _qtyControllers.forEach((_, controller) => controller.dispose());
    super.dispose();
  }

  Future<void> _fetchUserData(String token) async {
    try {
      final response = await http.get(
        Uri.parse('https://admin.theblackforestcakes.com/api/users/me?depth=2'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final user = data['user'] ?? data; // Depending on response structure
        setState(() {
          _userRole = user['role'];
          if (user['role'] == 'branch' && user['branch'] != null) {
            _branchId = (user['branch'] is Map) ? user['branch']['id'] : user['branch'];
          }
        });
      } else {
        // Handle error silently
      }
    } catch (e) {
      // Handle error silently
    }
  }

  Future<void> _fetchProducts() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No token found. Please login again.')),
        );
        return;
      }

      // Fetch user data if not already fetched
      if (_branchId == null && _userRole == null) {
        await _fetchUserData(token);
      }

      final url =
          'https://admin.theblackforestcakes.com/api/products?where[category][equals]=${widget.categoryId}&limit=100&depth=1';
      final response = await http.get(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        setState(() {
          _products = data['docs'] ?? [];
          _filteredProducts = _products;
          // Initialize quantities, inStock, and controllers
          for (int i = 0; i < _products.length; i++) {
            _quantities[i] = null; // No default for Qty
            _inStockQuantities[i] = null; // Default empty for In Stock
            _isSelected[i] = false; // Default unchecked
            _inStockControllers[i] = TextEditingController(text: '');
            _qtyControllers[i] = TextEditingController(text: '');
          }
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to fetch products: ${response.statusCode}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error: Check your internet')),
      );
    }

    setState(() {
      _isLoading = false;
    });
  }

  void _filterProducts() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredProducts = _products.where((product) {
        return product['name'].toString().toLowerCase().contains(query);
      }).toList();
      // Update controllers for filtered products
      final newInStockControllers = <int, TextEditingController>{};
      final newQtyControllers = <int, TextEditingController>{};
      for (int i = 0; i < _filteredProducts.length; i++) {
        final index = _products.indexOf(_filteredProducts[i]);
        newInStockControllers[i] = _inStockControllers[index] ?? TextEditingController(text: '');
        newQtyControllers[i] = _qtyControllers[index] ?? TextEditingController(text: '');
      }
      _inStockControllers = newInStockControllers;
      _qtyControllers = newQtyControllers;
    });
  }

  void _handleScan(String scanResult) {
    // Search for product with matching 'upc'
    for (int index = 0; index < _filteredProducts.length; index++) {
      final product = _filteredProducts[index];
      if (product['upc'] == scanResult) {
        setState(() {
          _quantities[index] = (_quantities[index] ?? 0) + 1;
          _inStockQuantities[index] = (_inStockQuantities[index] ?? 0) + 1;
          _isSelected[index] = true;
          _qtyControllers[index]?.text = _quantities[index].toString();
          _inStockControllers[index]?.text = _inStockQuantities[index].toString();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Product selected from scan: ${product['name']}')),
        );
        return;
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Product not found')),
    );
  }

  bool _isProductSelected(int index) {
    // Product is selected if both fields are non-zero and checkbox is checked
    return (_quantities[index] ?? 0) > 0 &&
        _inStockQuantities[index] != null &&
        (_isSelected[index] ?? false);
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Products',
      pageType: PageType.pastry,
      onScanCallback: _handleScan,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.black))
          : Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: Colors.grey.withOpacity(0.3),
                    spreadRadius: 2,
                    blurRadius: 5,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search products...',
                  prefixIcon: const Icon(Icons.search, color: Colors.grey),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: Colors.white,
                ),
              ),
            ),
          ),
          // Product list
          Expanded(
            child: _filteredProducts.isEmpty
                ? const Center(child: Text('No products found', style: TextStyle(color: Color(0xFF4A4A4A), fontSize: 18)))
                : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              itemCount: _filteredProducts.length,
              itemBuilder: (context, index) {
                final product = _filteredProducts[index];
                // Determine price details based on branch override
                dynamic priceDetails = product['defaultPriceDetails'];
                if (_branchId != null && product['branchOverrides'] != null) {
                  for (var override in product['branchOverrides']) {
                    var branch = override['branch'];
                    String branchOid = branch is Map ? branch[r'$oid'] ?? branch['id'] ?? '' : branch ?? '';
                    if (branchOid == _branchId) {
                      priceDetails = override;
                      break;
                    }
                  }
                }
                final price = priceDetails != null
                    ? '₹${priceDetails['price'] ?? 0}'
                    : '₹0';
                final unit = priceDetails != null
                    ? priceDetails['unit'] ?? 'pcs'
                    : 'pcs';
                return Container(
                  margin: const EdgeInsets.only(bottom: 12.0),
                  padding: const EdgeInsets.all(10.0),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF0F0), // Light pink background
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(
                      color: _isProductSelected(index) ? Colors.green : Colors.pink.shade300,
                      width: _isProductSelected(index) ? 4 : 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.grey.withOpacity(0.3),
                        spreadRadius: 2,
                        blurRadius: 5,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Name, Price, Unit
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              product['name'] ?? 'Unknown',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '$price / $unit',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                                color: Colors.black54,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // In Stock, Quantity, Checkbox
                      Row(
                        children: [
                          // In Stock input
                          Column(
                            children: [
                              const Text(
                                'In Stock',
                                style: TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 4),
                              Container(
                                width: 48,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.grey),
                                ),
                                child: TextField(
                                  keyboardType: TextInputType.number,
                                  textAlign: TextAlign.center,
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.symmetric(vertical: 8),
                                  ),
                                  controller: _inStockControllers[index],
                                  onChanged: (value) {
                                    setState(() {
                                      _inStockQuantities[index] = int.tryParse(value);
                                    });
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 8),
                          // Quantity input
                          Column(
                            children: [
                              const Text(
                                'Qty',
                                style: TextStyle(color: Colors.green, fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 4),
                              Container(
                                width: 48,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.grey),
                                ),
                                child: TextField(
                                  keyboardType: TextInputType.number,
                                  textAlign: TextAlign.center,
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.symmetric(vertical: 8),
                                  ),
                                  controller: _qtyControllers[index],
                                  onChanged: (value) {
                                    setState(() {
                                      _quantities[index] = int.tryParse(value);
                                    });
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 8),
                          Checkbox(
                            value: _isSelected[index] ?? false,
                            onChanged: _inStockQuantities[index] != null
                                ? (value) {
                              setState(() {
                                _isSelected[index] = value ?? false;
                              });
                            }
                                : null, // Disable if In Stock is null
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}