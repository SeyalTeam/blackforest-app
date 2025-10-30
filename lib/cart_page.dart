import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:blackforest_app/cart_provider.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/categories_page.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:network_info_plus/network_info_plus.dart'; // ✅ Keep for IP detection

class CartPage extends StatefulWidget {
  const CartPage({super.key});

  @override
  _CartPageState createState() => _CartPageState();
}

class _CartPageState extends State<CartPage> {
  String? _branchId;
  String? _userRole;
  bool _addCustomerDetails = false;
  String? _selectedPaymentMethod;

  @override
  void initState() {
    super.initState();
    _fetchUserData();
  }

  // ✅ Fetch user data + branch based on private IP
  Future<void> _fetchUserData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) return;

      final response = await http.get(
        Uri.parse('https://admin.theblackforestcakes.com/api/users/me?depth=2'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final user = data['user'] ?? data;
        _userRole = user['role'];

        if (user['role'] == 'branch' && user['branch'] != null) {
          _branchId = (user['branch'] is Map)
              ? user['branch']['id']
              : user['branch'];
        } else if (user['role'] == 'waiter') {
          await _fetchWaiterBranch(token);
        }

        setState(() {});
        Provider.of<CartProvider>(context, listen: false)
            .setBranchId(_branchId);
      }
    } catch (e) {
      // Handle silently
    }
  }

  // ✅ Private IP fetching
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
    return (parts[0] << 24) |
    (parts[1] << 16) |
    (parts[2] << 8) |
    parts[3];
  }

  bool _isIpInRange(String deviceIp, String range) {
    final parts = range.split('-');
    if (parts.length != 2) return false;
    final startIp = _ipToInt(parts[0].trim());
    final endIp = _ipToInt(parts[1].trim());
    final device = _ipToInt(deviceIp);
    return device >= startIp && device <= endIp;
  }

  // ✅ Updated waiter branch detection using local IP + range
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
              if (bIpRange == deviceIp ||
                  _isIpInRange(deviceIp, bIpRange)) {
                _branchId = branch['id'];
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

  // ✅ Product Scan Handler
  Future<void> _handleScan(String scanResult) async {
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
        Uri.parse(
            'https://admin.theblackforestcakes.com/api/products?where[upc][equals]=$scanResult&limit=1&depth=1'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final List<dynamic> products = data['docs'] ?? [];
        if (products.isNotEmpty) {
          final product = products[0];
          final cartProvider =
          Provider.of<CartProvider>(context, listen: false);

          double price =
              product['defaultPriceDetails']?['price']?.toDouble() ?? 0.0;

          if (_branchId != null && product['branchOverrides'] != null) {
            for (var override in product['branchOverrides']) {
              var branch = override['branch'];
              String branchOid = branch is Map
                  ? branch[r'$oid'] ?? branch['id'] ?? ''
                  : branch ?? '';
              if (branchOid == _branchId) {
                price = override['price']?.toDouble() ?? price;
                break;
              }
            }
          }

          final item =
          CartItem.fromProduct(product, 1, branchPrice: price);
          cartProvider.addOrUpdateItem(item);
          final newQty = cartProvider.cartItems
              .firstWhere((i) => i.id == item.id)
              .quantity;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content:
                Text('${product['name']} added/updated (Qty: $newQty)')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Product not found')),
          );
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error: Check your internet')),
      );
    }
  }

  // ✅ Submit Billing (Printer Removed)
  Future<void> _submitBilling() async {
    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    if (cartProvider.cartItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cart is empty')),
      );
      return;
    }
    if (_selectedPaymentMethod == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a payment method')),
      );
      return;
    }

    Map<String, dynamic>? customerDetails;
    if (_addCustomerDetails) {
      customerDetails = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) {
          final nameController = TextEditingController();
          final phoneController = TextEditingController();
          return AlertDialog(
            title: const Text('Customer Details'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    decoration:
                    const InputDecoration(labelText: 'Customer Name'),
                  ),
                  TextField(
                    controller: phoneController,
                    decoration: const InputDecoration(labelText: 'Phone'),
                    keyboardType: TextInputType.phone,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, {
                  'name': nameController.text,
                  'phone': phoneController.text,
                }),
                child: const Text('Submit'),
              ),
            ],
          );
        },
      );
      if (customerDetails == null) return;
    } else {
      customerDetails = {};
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) return;

      final billingData = {
        'items': cartProvider.cartItems
            .map((item) => ({
          'product': item.id,
          'name': item.name,
          'quantity': item.quantity,
          'unitPrice': item.price,
          'subtotal': item.price * item.quantity,
          'branchOverride': _branchId != null,
        }))
            .toList(),
        'totalAmount': cartProvider.total,
        'branch': _branchId,
        'customerDetails': {
          'name': customerDetails['name'] ?? '',
          'phone': customerDetails['phone'] ?? '',
        },
        'paymentMethod': _selectedPaymentMethod,
        'notes': '',
        'status': 'completed',
      };

      final response = await http.post(
        Uri.parse('https://admin.theblackforestcakes.com/api/billings'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode(billingData),
      );

      if (response.statusCode == 201) {
        // 🧾 Removed printing; now only clear cart and navigate
        cartProvider.clearCart();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Billing submitted successfully')),
        );
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const CategoriesPage()),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
              Text('Failed to submit billing: ${response.statusCode}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Cart',
      pageType: PageType.cart,
      onScanCallback: _handleScan,
      body: Consumer<CartProvider>(
        builder: (context, cartProvider, child) {
          if (cartProvider.cartItems.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.shopping_cart_outlined,
                      size: 100, color: Colors.grey),
                  SizedBox(height: 20),
                  Text(
                    'Your cart is empty. Add products from categories!',
                    style:
                    TextStyle(color: Color(0xFF4A4A4A), fontSize: 18),
                  ),
                ],
              ),
            );
          }

          return Column(
            children: [
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(10),
                  itemCount: cartProvider.cartItems.length,
                  itemBuilder: (context, index) {
                    final item = cartProvider.cartItems[index];
                    return Card(
                      elevation: 2,
                      margin:
                      const EdgeInsets.symmetric(vertical: 5),
                      child: ListTile(
                        leading: item.imageUrl != null
                            ? CachedNetworkImage(
                          imageUrl: item.imageUrl!,
                          width: 60,
                          height: 60,
                          fit: BoxFit.cover,
                          placeholder: (context, url) =>
                          const CircularProgressIndicator(),
                          errorWidget: (context, url, error) =>
                          const Icon(Icons.error),
                        )
                            : const Icon(Icons.image_not_supported,
                            size: 60),
                        title: Text(item.name),
                        subtitle: Text(
                            '₹${item.price.toStringAsFixed(2)} x ${item.quantity} = ₹${(item.price * item.quantity).toStringAsFixed(2)}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(
                                  Icons.remove_circle_outline),
                              onPressed: () =>
                                  cartProvider.updateQuantity(
                                      item.id, item.quantity - 1),
                            ),
                            Text('${item.quantity}',
                                style: const TextStyle(fontSize: 16)),
                            IconButton(
                              icon: const Icon(
                                  Icons.add_circle_outline),
                              onPressed: () =>
                                  cartProvider.updateQuantity(
                                      item.id, item.quantity + 1),
                            ),
                            IconButton(
                              icon: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.red),
                              onPressed: () =>
                                  cartProvider.removeItem(item.id),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                        color: Colors.grey.withOpacity(0.2),
                        blurRadius: 5)
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment:
                      MainAxisAlignment.spaceEvenly,
                      children: [
                        for (final method in ['cash', 'upi', 'card'])
                          Expanded(
                            flex: 1,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4),
                              child: ElevatedButton(
                                onPressed: () => setState(() =>
                                _selectedPaymentMethod =
                                    method),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                  _selectedPaymentMethod ==
                                      method
                                      ? Colors.green
                                      : Colors.grey,
                                ),
                                child: Text(method.toUpperCase()),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Checkbox(
                          value: _addCustomerDetails,
                          onChanged: (value) {
                            setState(() {
                              _addCustomerDetails =
                                  value ?? false;
                            });
                          },
                        ),
                        Text(
                          'Total: ₹${cartProvider.total.toStringAsFixed(2)}',
                          style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.black),
                        ),
                        const Spacer(),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white),
                          onPressed: cartProvider
                              .cartItems.isNotEmpty
                              ? _submitBilling
                              : null,
                          child:
                          const Text('Proceed to Billing'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
