import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:blackforest_app/cart_provider.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/categories_page.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:network_info_plus/network_info_plus.dart';
// New import for printing (ESC/POS base; add others if needed)
import 'package:esc_pos_printer/esc_pos_printer.dart';
import 'package:esc_pos_utils/esc_pos_utils.dart';

class CartPage extends StatefulWidget {
  const CartPage({super.key});
  @override
  _CartPageState createState() => _CartPageState();
}

class _CartPageState extends State<CartPage> {
  String? _branchId;
  String? _branchName;  // New: To store branch name
  String? _branchGst;   // New: To store branch GST
  String? _companyName; // New: To store company name
  String? _userRole;
  bool _addCustomerDetails = false;
  String? _selectedPaymentMethod;

  @override
  void initState() {
    super.initState();
    _fetchUserData();
  }

  // Updated to set printer details if branch role
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
          _branchId = (user['branch'] is Map) ? user['branch']['id'] : user['branch'];
          // Set branch name if available in user data
          _branchName = (user['branch'] is Map) ? user['branch']['name'] : null;
          // Updated: Fetch branch details to get printer IP/port/protocol and confirm name
          await _fetchBranchDetails(token, _branchId!);
        } else if (user['role'] == 'waiter') {
          await _fetchWaiterBranch(token);
        }

        setState(() {});
        Provider.of<CartProvider>(context, listen: false).setBranchId(_branchId);
      }
    } catch (e) {
      // Handle silently
    }
  }

  // Updated helper to fetch specific branch details including printer protocol, name, and GST
  Future<void> _fetchBranchDetails(String token, String branchId) async {
    try {
      final response = await http.get(
        Uri.parse('https://admin.theblackforestcakes.com/api/branches/$branchId?depth=1'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final branch = jsonDecode(response.body);
        _branchName = branch['name'] ?? _branchName;  // Set or update branch name
        _branchGst = branch['gst'];  // New: Set branch GST
        // New: Extract company name if populated (assuming depth=1 includes company relation)
        if (branch['company'] != null && branch['company'] is Map) {
          _companyName = branch['company']['name'];
        } else if (branch['company'] != null) {
          // If company is just ID, fetch company details
          await _fetchCompanyDetails(token, branch['company'].toString());
        }
        final cartProvider = Provider.of<CartProvider>(context, listen: false);
        cartProvider.setPrinterDetails(
          branch['printerIp'],
          branch['printerPort'],
          branch['printerProtocol'],  // New: Fetch protocol from API
        );
      }
    } catch (e) {
      // Handle silently
    }
  }

  // New: Helper to fetch company details if needed
  Future<void> _fetchCompanyDetails(String token, String companyId) async {
    try {
      final response = await http.get(
        Uri.parse('https://admin.theblackforestcakes.com/api/companies/$companyId?depth=1'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final company = jsonDecode(response.body);
        _companyName = company['name'] ?? 'Unknown Company';
      }
    } catch (e) {
      // Handle silently
    }
  }

  Future<String?> _fetchDeviceIp() async {
    try {
      final info = NetworkInfo();
      final ip = await info.getWifiIP(); // Gets private IP like 192.168.x.x
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

  // Updated to set printer details and branch name when matching branch
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
                _branchId = branch['id'];
                _branchName = branch['name'];  // New: Set branch name
                _branchGst = branch['gst'];    // New: Set branch GST
                // New: Set company name
                if (branch['company'] != null && branch['company'] is Map) {
                  _companyName = branch['company']['name'];
                } else if (branch['company'] != null) {
                  await _fetchCompanyDetails(token, branch['company'].toString());
                }
                // Updated: Set printer details including protocol
                final cartProvider = Provider.of<CartProvider>(context, listen: false);
                cartProvider.setPrinterDetails(
                  branch['printerIp'],
                  branch['printerPort'],
                  branch['printerProtocol'],
                );
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
          final cartProvider = Provider.of<CartProvider>(context, listen: false);
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

  // Updated to call print after success
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
                    decoration: const InputDecoration(labelText: 'Customer Name'),
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
        final billingResponse = jsonDecode(response.body);
        // Print before clearing cart
        await _printReceipt(cartProvider, billingResponse, customerDetails, _selectedPaymentMethod!);
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
          SnackBar(content: Text('Failed to submit billing: ${response.statusCode}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  // Updated: Function to print receipt with protocol handling
  Future<void> _printReceipt(
      CartProvider cartProvider,
      Map<String, dynamic> billingResponse,
      Map<String, dynamic> customerDetails,
      String paymentMethod,
      ) async {
    final printerIp = cartProvider.printerIp;
    final printerPort = cartProvider.printerPort;
    final printerProtocol = cartProvider.printerProtocol;

    if (printerIp == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No printer configured for this branch')),
      );
      return;
    }

    if (printerProtocol == null || printerProtocol != 'esc_pos') {
      // Fallback for other protocols (add support here if switching printers)
      // E.g., for 'zpl': Use zpl package - add to pubspec.yaml: zpl: ^latest
      // Then: import 'package:zpl/zpl.dart'; and build/send ZPL commands via socket.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unsupported printer protocol: $printerProtocol. Update app for support.')),
      );
      return;
    }

    try {
      // ESC/POS handling (works for Shreyans and most brands)
      const PaperSize paper = PaperSize.mm80; // Adjust to mm58 if needed for your printers
      final profile = await CapabilityProfile.load();
      final printer = NetworkPrinter(paper, profile);

      final PosPrintResult res = await printer.connect(printerIp, port: printerPort);

      if (res == PosPrintResult.success) {
        // Build receipt with 'Rs ' instead of ₹ for compatibility
        // Replaced fixed company name with fetched (assuming it's branch-related; adjust if separate API)
        printer.text(_companyName ?? 'Black Forest Cakes', styles: const PosStyles(align: PosAlign.center, bold: true));  // Keep as fixed or fetch if available
        printer.text('Branch: ${_branchName ?? _branchId}', styles: const PosStyles(align: PosAlign.center));
        if (_branchGst != null) {
          printer.text('GST: $_branchGst', styles: const PosStyles(align: PosAlign.center));
        }
        printer.text('Bill ID: ${billingResponse['id'] ?? 'N/A'}', styles: const PosStyles(align: PosAlign.center));
        printer.text('Date: ${DateTime.now().toString()}', styles: const PosStyles(align: PosAlign.center));
        printer.hr();

        // Header for items
        printer.row([
          PosColumn(text: 'Item', width: 5, styles: const PosStyles(bold: true)),
          PosColumn(text: 'Qty', width: 2, styles: const PosStyles(bold: true, align: PosAlign.center)),
          PosColumn(text: 'Price', width: 2, styles: const PosStyles(bold: true, align: PosAlign.right)),
          PosColumn(text: 'Amount', width: 3, styles: const PosStyles(bold: true, align: PosAlign.right)),
        ]);
        printer.hr(ch: '-');

        // Items from cart
        for (var item in cartProvider.cartItems) {
          printer.row([
            PosColumn(text: item.name, width: 5),
            PosColumn(text: '${item.quantity}', width: 2, styles: const PosStyles(align: PosAlign.center)),
            PosColumn(text: 'Rs ${item.price.toStringAsFixed(2)}', width: 2, styles: const PosStyles(align: PosAlign.right)),
            PosColumn(text: 'Rs ${(item.price * item.quantity).toStringAsFixed(2)}', width: 3, styles: const PosStyles(align: PosAlign.right)),
          ]);
        }

        printer.hr();
        printer.row([
          PosColumn(text: 'Total', width: 8, styles: const PosStyles(bold: true)),
          PosColumn(text: 'Rs ${cartProvider.total.toStringAsFixed(2)}', width: 4, styles: const PosStyles(align: PosAlign.right, bold: true)),
        ]);
        printer.text('Paid by: ${paymentMethod.toUpperCase()}');

        if (customerDetails['name']?.isNotEmpty == true || customerDetails['phone']?.isNotEmpty == true) {
          printer.hr();
          printer.text('Customer: ${customerDetails['name'] ?? ''}');
          printer.text('Phone: ${customerDetails['phone'] ?? ''}');
        }

        printer.hr();
        printer.text('Thank you! Visit again.', styles: const PosStyles(align: PosAlign.center));
        printer.feed(2);
        printer.cut();
        printer.disconnect();

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Receipt printed successfully')),
        );
      } else {
        throw Exception(res.msg);
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Print failed: Check printer connection ($e)')),
      );
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
                  Icon(Icons.shopping_cart_outlined, size: 100, color: Colors.grey),
                  SizedBox(height: 20),
                  Text(
                    'Your cart is empty. Add products from categories!',
                    style: TextStyle(color: Color(0xFF4A4A4A), fontSize: 18),
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
                      margin: const EdgeInsets.symmetric(vertical: 5),
                      child: ListTile(
                        leading: item.imageUrl != null
                            ? CachedNetworkImage(
                          imageUrl: item.imageUrl!,
                          width: 60,
                          height: 60,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => const CircularProgressIndicator(),
                          errorWidget: (context, url, error) => const Icon(Icons.error),
                        )
                            : const Icon(Icons.image_not_supported, size: 60),
                        title: Text(item.name),
                        subtitle: Text(
                            '₹${item.price.toStringAsFixed(2)} x ${item.quantity} = ₹${(item.price * item.quantity).toStringAsFixed(2)}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: () => cartProvider.updateQuantity(item.id, item.quantity - 1),
                            ),
                            Text('${item.quantity}', style: const TextStyle(fontSize: 16)),
                            IconButton(
                              icon: const Icon(Icons.add_circle_outline),
                              onPressed: () => cartProvider.updateQuantity(item.id, item.quantity + 1),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.red),
                              onPressed: () => cartProvider.removeItem(item.id),
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
                  boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.2), blurRadius: 5)],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        for (final method in ['cash', 'upi', 'card'])
                          Expanded(
                            flex: 1,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: ElevatedButton(
                                onPressed: () => setState(() => _selectedPaymentMethod = method),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _selectedPaymentMethod == method ? Colors.green : Colors.grey,
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
                              _addCustomerDetails = value ?? false;
                            });
                          },
                        ),
                        Text(
                          'Total: ₹${cartProvider.total.toStringAsFixed(2)}',
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black),
                        ),
                        const Spacer(),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                          onPressed: cartProvider.cartItems.isNotEmpty ? _submitBilling : null,
                          child: const Text('Proceed to Billing'),
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