import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:network_info_plus/network_info_plus.dart'; // ✅ Added
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
  Map<int, int?> _quantities = {};
  Map<int, int?> _inStockQuantities = {};
  Map<int, bool> _isSelected = {};
  Map<int, TextEditingController> _inStockControllers = {};
  Map<int, TextEditingController> _qtyControllers = {};
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
    _inStockControllers.forEach((_, c) => c.dispose());
    _qtyControllers.forEach((_, c) => c.dispose());
    super.dispose();
  }

  // ✅ Fetch private (LAN) IP instead of public IP
  Future<String?> _fetchDeviceIp() async {
    try {
      final info = NetworkInfo();
      final ip = await info.getWifiIP();
      return ip?.trim();
    } catch (e) {
      return null;
    }
  }

  int _ipToInt(String ip) {
    final parts = ip.split('.').map(int.parse).toList();
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
  }

  bool _isIpInRange(String deviceIp, String range) {
    final parts = range.split('-');
    if (parts.length != 2) return false;
    final startIp = _ipToInt(parts[0].trim());
    final endIp = _ipToInt(parts[1].trim());
    final device = _ipToInt(deviceIp);
    return device >= startIp && device <= endIp;
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
            String? bIpRange = branch['ipAddress']?.toString().trim();
            if (bIpRange != null) {
              if (bIpRange == deviceIp || _isIpInRange(deviceIp, bIpRange)) {
                setState(() {
                  _branchId = branch['id'];
                });
                break;
              }
            }
          }
        }
      }
    } catch (e) {
      // Handle silently
    }
  }

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
          _branchId =
          (user['branch'] is Map) ? user['branch']['id'] : user['branch'];
        } else if (user['role'] == 'waiter') {
          await _fetchWaiterBranch(token);
        }
      }
    } catch (e) {
      // Handle silently
    }
  }

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

      if (_branchId == null && _userRole == null) {
        await _fetchUserData(token);
      }

      String url =
          'https://admin.theblackforestcakes.com/api/products?where[category][equals]=${widget.categoryId}&limit=100&depth=1';
      if (_branchId != null && _userRole != 'superadmin') {
        url += '&where[branchOverrides.branch][equals]=$_branchId';
      }

      final response = await http.get(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _products = data['docs'] ?? [];
          _filteredProducts = _products;
          for (int i = 0; i < _products.length; i++) {
            _quantities[i] = null;
            _inStockQuantities[i] = null;
            _isSelected[i] = false;
            _inStockControllers[i] = TextEditingController();
            _qtyControllers[i] = TextEditingController();
          }
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Failed to fetch products: ${response.statusCode}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error: Check your internet')),
      );
    }
    setState(() => _isLoading = false);
  }

  void _filterProducts() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredProducts = _products
          .where((p) => p['name'].toString().toLowerCase().contains(query))
          .toList();
    });
  }

  void _handleScan(String scanResult) {
    for (int index = 0; index < _filteredProducts.length; index++) {
      final product = _filteredProducts[index];
      if (product['upc'] == scanResult) {
        setState(() {
          _quantities[index] = (_quantities[index] ?? 0) + 1;
          _inStockQuantities[index] = (_inStockQuantities[index] ?? 0) + 1;
          _isSelected[index] = true;
          _qtyControllers[index]?.text = _quantities[index].toString();
          _inStockControllers[index]?.text =
              _inStockQuantities[index].toString();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Product selected from scan: ${product['name']}')),
        );
        return;
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Product not found')),
    );
  }

  bool _isProductSelected(int index) {
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
          Padding(
            padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search products...',
                prefixIcon:
                const Icon(Icons.search, color: Colors.grey),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
              ),
            ),
          ),
          Expanded(
            child: _filteredProducts.isEmpty
                ? const Center(
                child: Text('No products found',
                    style: TextStyle(
                        color: Color(0xFF4A4A4A), fontSize: 18)))
                : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _filteredProducts.length,
              itemBuilder: (context, index) {
                final product = _filteredProducts[index];
                dynamic priceDetails =
                product['defaultPriceDetails'];
                if (_branchId != null &&
                    product['branchOverrides'] != null) {
                  for (var override
                  in product['branchOverrides']) {
                    var branch = override['branch'];
                    String branchOid = branch is Map
                        ? branch[r'$oid'] ??
                        branch['id'] ??
                        ''
                        : branch ?? '';
                    if (branchOid == _branchId) {
                      priceDetails = override;
                      break;
                    }
                  }
                }
                final price = priceDetails != null
                    ? '₹${priceDetails['price'] ?? 0}'
                    : '₹0';
                final unit = priceDetails?['unit'] ?? 'pcs';

                return Container(
                  margin:
                  const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF0F0),
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(
                      color: _isProductSelected(index)
                          ? Colors.green
                          : Colors.pink.shade300,
                      width: _isProductSelected(index)
                          ? 4
                          : 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color:
                        Colors.grey.withOpacity(0.3),
                        spreadRadius: 2,
                        blurRadius: 5,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment:
                    MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                          CrossAxisAlignment.start,
                          children: [
                            Text(product['name'] ?? 'Unknown',
                                style: const TextStyle(
                                    fontWeight:
                                    FontWeight.bold,
                                    fontSize: 16)),
                            const SizedBox(height: 4),
                            Text('$price / $unit',
                                style: const TextStyle(
                                    fontWeight:
                                    FontWeight.bold,
                                    color: Colors.black54)),
                          ],
                        ),
                      ),
                      Row(
                        children: [
                          _buildInputField(
                              'In Stock',
                              _inStockControllers[index]!,
                              Colors.red, (v) {
                            _inStockQuantities[index] =
                                int.tryParse(v);
                          }),
                          const SizedBox(width: 8),
                          _buildInputField('Qty',
                              _qtyControllers[index]!,
                              Colors.green, (v) {
                                _quantities[index] =
                                    int.tryParse(v);
                              }),
                          const SizedBox(width: 8),
                          Checkbox(
                            value: _isSelected[index] ?? false,
                            onChanged:
                            _inStockQuantities[index] !=
                                null
                                ? (value) {
                              setState(() {
                                _isSelected[index] =
                                    value ?? false;
                              });
                            }
                                : null,
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

  Widget _buildInputField(String label,
      TextEditingController controller, Color color, Function(String) onChange) {
    return Column(
      children: [
        Text(label,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Container(
          width: 48,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey),
          ),
          child: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            decoration: const InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 8),
            ),
            onChanged: onChange,
          ),
        ),
      ],
    );
  }
}
