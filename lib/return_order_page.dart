// The updated ReturnOrderPage.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:provider/provider.dart';
import 'package:blackforest_app/return_provider.dart'; // Add this import

class ReturnOrderPage extends StatefulWidget {
  final String categoryId;
  final String categoryName;

  const ReturnOrderPage({
    super.key,
    required this.categoryId,
    required this.categoryName,
  });

  @override
  _ReturnOrderPageState createState() => _ReturnOrderPageState();
}

class _ReturnOrderPageState extends State<ReturnOrderPage> {
  List<dynamic> _products = [];
  bool _isLoading = true;
  Map<String, TextEditingController> _qtyControllers = {}; // Keyed by product ID
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
    _qtyControllers.forEach((_, controller) => controller.dispose());
    super.dispose();
  }

  // 🧠 Convert IP to integer for range comparison
  int _ipToInt(String ip) {
    final parts = ip.split('.').map(int.parse).toList();
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
  }

  // ✅ Check if IP is in a range (e.g., 192.168.1.10-192.168.1.50)
  bool _isIpInRange(String deviceIp, String range) {
    final parts = range.split('-');
    if (parts.length != 2) return false;
    final startIp = _ipToInt(parts[0].trim());
    final endIp = _ipToInt(parts[1].trim());
    final device = _ipToInt(deviceIp);
    return device >= startIp && device <= endIp;
  }

  // ✅ Get local (private) IP address using network_info_plus
  Future<String?> _fetchDeviceIp() async {
    try {
      final info = NetworkInfo();
      final ip = await info.getWifiIP();
      return ip?.trim();
    } catch (e) {
      return null;
    }
  }

  // ✅ Fetch user's branch info
  Future<void> _fetchUserData(String token) async {
    try {
      final response = await http.get(
        Uri.parse('https://admin.theblackforestcakes.com/api/users/me?depth=2'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final user = data['user'] ?? data;
        setState(() {
          _userRole = user['role'];
        });
        if (user['role'] == 'branch' && user['branch'] != null) {
          setState(() {
            _branchId = (user['branch'] is Map) ? user['branch']['id'] : user['branch'];
          });
        } else if (user['role'] == 'waiter') {
          await _fetchWaiterBranch(token);
        }
      }
    } catch (e) {
      // Handle silently
    }
  }

  // ✅ Fetch branch based on private IP
  Future<void> _fetchWaiterBranch(String token) async {
    String? deviceIp = await _fetchDeviceIp();
    if (deviceIp == null) return;
    try {
      final response = await http.get(
        Uri.parse('https://admin.theblackforestcakes.com/api/branches?depth=1'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final branches = data['docs'] ?? [];
        for (var branch in branches) {
          String? branchIp = branch['ipAddress']?.toString().trim();
          if (branchIp == null) continue;
          // Match exact or IP range
          if (branchIp == deviceIp || _isIpInRange(deviceIp, branchIp)) {
            setState(() {
              _branchId = branch['id'];
            });
            break;
          }
        }
      }
    } catch (e) {
      // Handle silently
    }
  }

  // ✅ Fetch product list
  Future<void> _fetchProducts() async {
    setState(() => _isLoading = true);
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
      String url =
          'https://admin.theblackforestcakes.com/api/products?where[category][equals]=${widget.categoryId}&limit=100&depth=1';
      final response = await http.get(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _products = data['docs'] ?? [];
          _filteredProducts = _products;
          _qtyControllers = {};
          for (var product in _products) {
            final id = product['id'];
            _qtyControllers[id] = TextEditingController();
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
    setState(() => _isLoading = false);
  }

  // ✅ Search Filter
  void _filterProducts() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredProducts = _products
          .where((p) => p['name'].toString().toLowerCase().contains(query))
          .toList();
    });
  }

  // ✅ Barcode/QR scan handler
  void _handleScan(String scanResult) {
    final provider = Provider.of<ReturnProvider>(context, listen: false);
    for (var product in _filteredProducts) {
      if (product['upc'] == scanResult) {
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
        final price = priceDetails != null ? (priceDetails['price']?.toDouble() ?? 0.0) : 0.0;
        final matching = provider.returnItems.where((item) => item.id == product['id']).toList();
        final currentQty = matching.isNotEmpty ? matching.first.quantity : 0;
        final newQty = currentQty + 1;
        provider.addOrUpdateItem(product['id'], product['name'], newQty, price);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Product selected from scan: ${product['name']} (Qty: $newQty)')),
        );
        return;
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Product not found')),
    );
  }

  // ✅ Submit selected return orders using provider
  Future<void> _submitReturnOrders() async {
    final provider = Provider.of<ReturnProvider>(context, listen: false);
    await provider.submitReturn(context, _branchId);
  }

  bool _isProductSelected(int index, ReturnProvider provider) {
    final id = _filteredProducts[index]['id'];
    return provider.returnItems.any((i) => i.id == id);
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Return Order Products',
      pageType: PageType.stock,
      onScanCallback: _handleScan,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.black))
          : Column(
        children: [
          // Updated: Search (60% width) + Confirm button (40% width, red with white text and shadow)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  flex: 3, // 60%
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
                const SizedBox(width: 16), // Spacing between search and button
                Expanded(
                  flex: 2, // 40%
                  child: GestureDetector(
                    onTap: _submitReturnOrders,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.red,
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
                      child: const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            'Confirm',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Product list
          Expanded(
            child: _filteredProducts.isEmpty
                ? const Center(
              child: Text('No products found', style: TextStyle(color: Color(0xFF4A4A4A), fontSize: 18)),
            )
                : Consumer<ReturnProvider>(
              builder: (context, provider, child) {
                // Sync controllers with provider data
                for (int index = 0; index < _filteredProducts.length; index++) {
                  final product = _filteredProducts[index];
                  final String id = product['id'];
                  final matching = provider.returnItems.where((i) => i.id == id).toList();
                  final ReturnItem? item = matching.isNotEmpty ? matching.first : null;
                  if (item != null) {
                    if (_qtyControllers[id]!.text != item.quantity.toString()) {
                      _qtyControllers[id]!.text = item.quantity.toString();
                    }
                  } else if (_qtyControllers[id]!.text != '') {
                    _qtyControllers[id]!.text = '';
                  }
                }

                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: _filteredProducts.length,
                  itemBuilder: (context, index) {
                    final product = _filteredProducts[index];
                    final String id = product['id'];
                    dynamic priceDetails = product['defaultPriceDetails'];
                    if (_branchId != null && product['branchOverrides'] != null) {
                      for (var override in product['branchOverrides']) {
                        var branch = override['branch'];
                        String branchOid =
                        branch is Map ? branch[r'$oid'] ?? branch['id'] ?? '' : branch ?? '';
                        if (branchOid == _branchId) {
                          priceDetails = override;
                          break;
                        }
                      }
                    }
                    final double price = priceDetails != null ? (priceDetails['price']?.toDouble() ?? 0.0) : 0.0;
                    final String priceStr = priceDetails != null ? '₹${priceDetails['price'] ?? 0}' : '₹0';
                    final String unit = priceDetails != null ? priceDetails['unit'] ?? 'pcs' : 'pcs';

                    final matching = provider.returnItems.where((i) => i.id == id).toList();
                    final ReturnItem? item = matching.isNotEmpty ? matching.first : null;
                    final bool isSelected = item != null;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF0F0),
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(
                          color: isSelected ? Colors.green : Colors.pink.shade300,
                          width: isSelected ? 4 : 1,
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
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(product['name'] ?? 'Unknown',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                const SizedBox(height: 4),
                                Text('$priceStr / $unit',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold, fontSize: 14, color: Colors.black54)),
                              ],
                            ),
                          ),
                          Row(
                            children: [
                              Column(
                                children: [
                                  const Text('Return Qty',
                                      style: TextStyle(
                                          color: Colors.blue, fontSize: 12, fontWeight: FontWeight.bold)),
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
                                      controller: _qtyControllers[id],
                                      decoration: const InputDecoration(
                                        border: InputBorder.none,
                                        contentPadding: EdgeInsets.symmetric(vertical: 8),
                                      ),
                                      onChanged: (value) {
                                        final int qty = int.tryParse(value) ?? 0;
                                        provider.addOrUpdateItem(id, product['name'], qty, price);
                                      },
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(width: 8),
                              Checkbox(
                                value: isSelected,
                                onChanged: (bool? value) {
                                  if (value == true) {
                                    int qty = int.tryParse(_qtyControllers[id]!.text) ?? 0;
                                    if (qty <= 0) {
                                      qty = 1;
                                      _qtyControllers[id]!.text = '1';
                                    }
                                    provider.addOrUpdateItem(id, product['name'], qty, price);
                                  } else {
                                    provider.removeItem(id);
                                    _qtyControllers[id]!.text = '';
                                  }
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}