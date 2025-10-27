import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/cart_provider.dart';

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
  String? _branchId;
  String? _userRole;

  @override
  void initState() {
    super.initState();
    _fetchProducts();
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
          } else if (user['role'] == 'waiter') {
            _fetchWaiterBranch(token);
          }
        });
      } else {
        // Handle error silently
      }
    } catch (e) {
      // Handle error silently
    }
  }

  Future<String?> _fetchDeviceIp() async {
    try {
      final ipResponse = await http.get(Uri.parse('https://api.ipify.org?format=json')).timeout(const Duration(seconds: 10));
      if (ipResponse.statusCode == 200) {
        final ipData = jsonDecode(ipResponse.body);
        return ipData['ip']?.toString().trim();
      }
    } catch (e) {
      // Handle silently
    }
    return null;
  }

  Future<void> _fetchWaiterBranch(String token) async {
    String? deviceIp = await _fetchDeviceIp();
    if (deviceIp == null) return;

    try {
      final allBranchesResponse = await http.get(
        Uri.parse('https://admin.theblackforestcakes.com/api/branches?depth=1'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (allBranchesResponse.statusCode == 200) {
        final branchesData = jsonDecode(allBranchesResponse.body);
        if (branchesData['docs'] != null && branchesData['docs'] is List) {
          for (var branch in branchesData['docs']) {
            String? bIp = branch['ipAddress']?.toString().trim();
            if (bIp == deviceIp) {
              setState(() {
                _branchId = branch['id'];
              });
              break; // Use the first matching branch
            }
          }
        }
      }
    } catch (e) {
      // Handle silently
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
      String url = 'https://admin.theblackforestcakes.com/api/products?where[category][equals]=${widget.categoryId}&limit=100&depth=1';
      if (_branchId != null && _userRole != 'superadmin') {
        url += '&where[branchOverrides.branch][equals]=$_branchId';
      }
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
    final product = _products[index];
    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    // Get branch-specific price if available
    double price = product['defaultPriceDetails']?['price']?.toDouble() ?? 0.0;
    if (_branchId != null && product['branchOverrides'] != null) {
      for (var override in product['branchOverrides']) {
        var branch = override['branch'];
        String branchOid = branch is Map ? branch[r'$oid'] ?? branch['id'] ?? '' : branch ?? '';
        if (branchOid == _branchId) {
          price = override['price']?.toDouble() ?? price;
          break;
        }
      }
    }
    final item = CartItem.fromProduct(product, 1, branchPrice: price);
    cartProvider.addOrUpdateItem(item);
    final newQty = cartProvider.cartItems.firstWhere((i) => i.id == item.id).quantity;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${product['name']} added/updated (Qty: $newQty)')),
    );
  }

  void _handleScan(String scanResult) {
    for (int index = 0; index < _products.length; index++) {
      final product = _products[index];
      if (product['upc'] == scanResult) {
        _toggleProductSelection(index);
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
      pageType: PageType.billing, // Updated to billing as per context; change if needed
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
              if (product['images'] != null && product['images'].isNotEmpty && product['images'][0]['image'] != null && product['images'][0]['image']['url'] != null) {
                imageUrl = product['images'][0]['image']['url'];
                if (imageUrl != null && imageUrl.startsWith('/')) {
                  imageUrl = 'https://admin.theblackforestcakes.com$imageUrl';
                }
              }
              imageUrl ??= 'https://via.placeholder.com/150?text=No+Image';
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
              final price = priceDetails != null ? '₹${priceDetails['price'] ?? 0}' : '₹0'; // Use price from details
              return GestureDetector(
                onTap: () => _toggleProductSelection(index),
                child: Consumer<CartProvider>(
                  builder: (context, cartProvider, child) {
                    final isSelected = cartProvider.cartItems.any((i) => i.id == product['id']);
                    final qty = cartProvider.cartItems.firstWhere(
                          (i) => i.id == product['id'],
                      orElse: () => CartItem(id: '', name: '', price: 0, quantity: 0),
                    ).quantity;
                    return Container(
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
                                    imageUrl: imageUrl!, // Fixed here with !
                                    fit: BoxFit.cover,
                                    width: double.infinity,
                                    placeholder: (context, url) => const Center(child: CircularProgressIndicator()),
                                    errorWidget: (context, url, error) => const Center(child: Text('No Image', style: TextStyle(color: Colors.grey))),
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
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}