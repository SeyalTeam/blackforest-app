import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/common_scaffold.dart';

class ProductsPage extends StatefulWidget {
  final String categoryId;
  final String categoryName;

  const ProductsPage({
    super.key,
    required this.categoryId,
    required this.categoryName,
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
    _fetchProducts();
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
      title: 'Products in ${widget.categoryName}',
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
              String? imageUrl;
              // Null-safe image handling for images array
              if (product['images'] != null && product['images'].isNotEmpty &&
                  product['images'][0]['image'] != null && product['images'][0]['image']['url'] != null) {
                imageUrl = product['images'][0]['image']['url'];
                if (imageUrl != null && imageUrl.startsWith('/')) {
                  imageUrl = 'https://admin.theblackforestcakes.com$imageUrl';
                }
              }
              imageUrl ??= 'https://via.placeholder.com/150?text=No+Image';
              final price = product['defaultPriceDetails'] != null
                  ? '₹${product['defaultPriceDetails']['price'] ?? 0}'
                  : '₹0'; // Use defaultPriceDetails.price
              final isSelected = _selectedIndices.contains(index); // Check if selected
              final qty = _quantities[index] ?? 1; // Get qty or default 1

              return GestureDetector(
                onTap: () {
                  _toggleProductSelection(index);
                  final currentQty = _quantities[index] ?? 1; // Read after update
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('${product['name']} selected (Qty: $currentQty)')),
                  );
                },
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: isSelected ? Border.all(color: Colors.green, width: 4) : null,
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
                              child: CachedNetworkImage(
                                imageUrl: imageUrl,
                                fit: BoxFit.cover,
                                width: double.infinity,
                                placeholder: (context, url) =>
                                const Center(child: CircularProgressIndicator()),
                                errorWidget: (context, url, error) =>
                                const Center(child: Text('No Image', style: TextStyle(color: Colors.grey))),
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
                        top: 2,
                        left: 2,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            price,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10),
                          ),
                        ),
                      ),
                      if (isSelected)
                        Positioned.fill(
                          child: Align(
                            alignment: Alignment.center,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.7),
                                border: Border.all(color: Colors.grey, width: 1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              child: Text(
                                '$qty',
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