import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/common_scaffold.dart';

class ProductsPage extends StatefulWidget {
  final String categoryId;
  final String categoryName;
  final bool isPastryFilter; // New flag for pastry products

  const ProductsPage({
    super.key,
    required this.categoryId,
    required this.categoryName,
    this.isPastryFilter = false, // Default false for normal category filter
  });

  @override
  _ProductsPageState createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  List<dynamic> _products = [];
  bool _isLoading = true;
  Set<int> _selectedIndices = {}; // Track multiple selected product indices
  Map<int, int> _quantities = {}; // Track qty for each selected product

  @override
  void initState() {
    super.initState();
    if (widget.isPastryFilter) {
      _fetchPastryProducts();
    } else {
      _fetchProducts();
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

      final response = await http.get(
        Uri.parse('https://apib.theblackforestcakes.com/api/products?categoryId=${widget.categoryId}'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        setState(() {
          _products = jsonDecode(response.body);
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

  Future<void> _fetchPastryProducts() async {
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

      // Step 1: Fetch categories with isPastryProduct: true
      final categoryResponse = await http.get(
        Uri.parse('https://apib.theblackforestcakes.com/api/categories/list-categories'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (categoryResponse.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to fetch categories: ${categoryResponse.statusCode}')),
        );
        setState(() {
          _isLoading = false;
        });
        return;
      }

      final List<dynamic> allCategories = jsonDecode(categoryResponse.body);
      final pastryCategoryIds = allCategories
          .where((category) => category['isPastryProduct'] == true)
          .map((category) => category['_id'])
          .toList();

      if (pastryCategoryIds.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No pastry categories found')),
        );
        setState(() {
          _isLoading = false;
        });
        return;
      }

      // Step 2: Fetch products for all pastry categories
      List<dynamic> allProducts = [];
      for (String catId in pastryCategoryIds) {
        final productResponse = await http.get(
          Uri.parse('https://apib.theblackforestcakes.com/api/products?categoryId=$catId'),
          headers: {'Authorization': 'Bearer $token'},
        );

        if (productResponse.statusCode == 200) {
          final products = jsonDecode(productResponse.body);
          allProducts.addAll(products);
        }
      }

      setState(() {
        _products = allProducts;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error: Check your internet')),
      );
    }

    setState(() {
      _isLoading = false;
    });
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

  void _handleScan(String scanResult) {
    // Search for product with matching 'upc'
    for (int index = 0; index < _products.length; index++) {
      final product = _products[index];
      if (product['upc'] == scanResult) {
        _toggleProductSelection(index); // Select/increment Qty
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Product selected from scan: ${product['name']}')),
        );
        return;
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Product not found in this category')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: widget.categoryName,
      pageType: PageType.cart, // Placeholder for Billing
      onScanCallback: _handleScan, // Pass the scan handler
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.black))
          : _products.isEmpty
          ? const Center(child: Text('No products found', style: TextStyle(color: Color(0xFF4A4A4A), fontSize: 18)))
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
          );
        },
      ),
    );
  }
}