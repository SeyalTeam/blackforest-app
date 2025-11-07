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
import 'package:esc_pos_printer/esc_pos_printer.dart';
import 'package:esc_pos_utils/esc_pos_utils.dart';

class CartPage extends StatefulWidget {
  const CartPage({super.key});

  @override
  _CartPageState createState() => _CartPageState();
}

class _CartPageState extends State<CartPage> {
  String? _branchId;
  String? _branchName;
  String? _branchGst;
  String? _branchMobile;
  String? _companyName;
  String? _userRole;
  bool _addCustomerDetails = false;
  String? _selectedPaymentMethod;

  @override
  void initState() {
    super.initState();
    _fetchUserData();
  }

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
          _branchName = (user['branch'] is Map) ? user['branch']['name'] : null;
          await _fetchBranchDetails(token, _branchId!);
        } else if (user['role'] == 'waiter') {
          await _fetchWaiterBranch(token);
        }

        setState(() {});
        Provider.of<CartProvider>(context, listen: false).setBranchId(_branchId);
      }
    } catch (_) {}
  }

  Future<void> _fetchBranchDetails(String token, String branchId) async {
    try {
      final response = await http.get(
        Uri.parse('https://admin.theblackforestcakes.com/api/branches/$branchId?depth=1'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final branch = jsonDecode(response.body);
        _branchName = branch['name'] ?? _branchName;
        _branchGst = branch['gst'];
        _branchMobile = branch['phone'] ?? null;

        if (branch['company'] != null && branch['company'] is Map) {
          _companyName = branch['company']['name'];
        } else if (branch['company'] != null) {
          await _fetchCompanyDetails(token, branch['company'].toString());
        }

        final cartProvider = Provider.of<CartProvider>(context, listen: false);
        cartProvider.setPrinterDetails(
          branch['printerIp'],
          branch['printerPort'],
          branch['printerProtocol'],
        );
      }
    } catch (_) {}
  }

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
    } catch (_) {}
  }

  Future<String?> _fetchDeviceIp() async {
    try {
      final info = NetworkInfo();
      final ip = await info.getWifiIP();
      return ip?.trim();
    } catch (_) {
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
                _branchId = branch['id'];
                _branchName = branch['name'];
                _branchGst = branch['gst'];
                _branchMobile = branch['phone'] ?? null;

                if (branch['company'] != null && branch['company'] is Map) {
                  _companyName = branch['company']['name'];
                } else if (branch['company'] != null) {
                  await _fetchCompanyDetails(token, branch['company'].toString());
                }

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
    } catch (_) {}
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
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error: Check your internet')),
      );
    }
  }

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
                  TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Customer Name')),
                  TextField(
                      controller: phoneController,
                      decoration: const InputDecoration(labelText: 'Phone'),
                      keyboardType: TextInputType.phone),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              TextButton(
                  onPressed: () => Navigator.pop(context, {'name': nameController.text, 'phone': phoneController.text}),
                  child: const Text('Submit')),
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
        'customerDetails': {'name': customerDetails['name'] ?? '', 'phone': customerDetails['phone'] ?? ''},
        'paymentMethod': _selectedPaymentMethod,
        'notes': '',
        'status': 'completed',
      };

      final response = await http.post(
        Uri.parse('https://admin.theblackforestcakes.com/api/billings'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
        body: jsonEncode(billingData),
      );

      final billingResponse = jsonDecode(response.body);
      print('📦 BILL RESPONSE: $billingResponse'); // Debugging line

      if (response.statusCode == 201) {
        await _printReceipt(cartProvider, billingResponse, customerDetails, _selectedPaymentMethod!);
        cartProvider.clearCart();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Billing submitted successfully')));
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const CategoriesPage()));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${response.statusCode}')));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unsupported printer protocol: $printerProtocol')),
      );
      return;
    }

    try {
      const PaperSize paper = PaperSize.mm80;
      final profile = await CapabilityProfile.load();
      final printer = NetworkPrinter(paper, profile);

      final PosPrintResult res = await printer.connect(printerIp, port: printerPort);

      if (res == PosPrintResult.success) {
        String invoiceNumber = billingResponse['invoiceNumber'] ?? billingResponse['doc']?['invoiceNumber'] ?? 'N/A';

        // Extract numeric part from invoice like CHI-YYYYMMDD-017 → 017
        final regex = RegExp(r'CHI-\d{8}-(\d+)$');
        final match = regex.firstMatch(invoiceNumber);
        String billNo = match != null ? match.group(1)! : invoiceNumber;
        billNo = billNo.padLeft(3, '0');

        // Date
        String dateStr = DateTime.now().toString().substring(0, 16).replaceAll('T', ' ');

        // Header
        printer.text(_companyName ?? 'BLACK FOREST CAKES', styles: const PosStyles(align: PosAlign.center, bold: true));
        printer.text('Branch: ${_branchName ?? _branchId}', styles: const PosStyles(align: PosAlign.center));
        printer.text('GST: ${_branchGst ?? 'N/A'}', styles: const PosStyles(align: PosAlign.center));
        printer.text('Mobile: ${_branchMobile ?? 'N/A'}', styles: const PosStyles(align: PosAlign.center));

        // Double bold separator line before date and bill no
        printer.hr(ch: '=');

        // Date + Bill No in same row
        printer.row([
          PosColumn(
            text: 'Date: $dateStr',
            width: 6,
            styles: const PosStyles(align: PosAlign.left),
          ),
          PosColumn(
            text: 'BILL NO - $billNo',
            width: 6,
            styles: const PosStyles(align: PosAlign.right, bold: true),
          ),
        ]);

        printer.hr(ch: '=');

        // Item Table Header
        printer.row([
          PosColumn(text: 'Item', width: 5, styles: const PosStyles(bold: true)),
          PosColumn(
              text: 'Qty',
              width: 2,
              styles: const PosStyles(bold: true, align: PosAlign.center)),
          PosColumn(
              text: 'Price',
              width: 2,
              styles: const PosStyles(bold: true, align: PosAlign.right)),
          PosColumn(
              text: 'Amount',
              width: 3,
              styles: const PosStyles(bold: true, align: PosAlign.right)),
        ]);

        printer.hr(ch: '-');

        // Items
        for (var item in cartProvider.cartItems) {
          printer.row([
            PosColumn(text: item.name, width: 5),
            PosColumn(
                text: '${item.quantity}',
                width: 2,
                styles: const PosStyles(align: PosAlign.center)),
            PosColumn(
                text: item.price.toStringAsFixed(2),
                width: 2,
                styles: const PosStyles(align: PosAlign.right)),
            PosColumn(
                text: (item.price * item.quantity).toStringAsFixed(2),
                width: 3,
                styles: const PosStyles(align: PosAlign.right)),
          ]);
        }

        printer.hr(ch: '-');

        // Total only (no GST)
        printer.row([
          PosColumn(
              text: 'TOTAL RS',
              width: 8,
              styles: const PosStyles(bold: true)),
          PosColumn(
            text: cartProvider.total.toStringAsFixed(2),
            width: 4,
            styles: const PosStyles(align: PosAlign.right, bold: true),
          ),
        ]);

        printer.text('Paid by: ${paymentMethod.toUpperCase()}');

        if (customerDetails['name']?.isNotEmpty == true || customerDetails['phone']?.isNotEmpty == true) {
          printer.hr();
          printer.text('Customer: ${customerDetails['name'] ?? ''}');
          printer.text('Phone: ${customerDetails['phone'] ?? ''}');
        }

        printer.hr(ch: '=');
        printer.text('Thank you! Visit Again', styles: const PosStyles(align: PosAlign.center));
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
        SnackBar(content: Text('Print failed: $e')),
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
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.shopping_cart_outlined, size: 100, color: Colors.grey),
                SizedBox(height: 20),
                Text('Your cart is empty. Add products from categories!',
                    style: TextStyle(color: Color(0xFF4A4A4A), fontSize: 18)),
              ]),
            );
          }

          return Column(children: [
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
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: () => cartProvider.updateQuantity(item.id, item.quantity - 1)),
                        Text('${item.quantity}', style: const TextStyle(fontSize: 16)),
                        IconButton(
                            icon: const Icon(Icons.add_circle_outline),
                            onPressed: () => cartProvider.updateQuantity(item.id, item.quantity + 1)),
                        IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.red),
                            onPressed: () => cartProvider.removeItem(item.id)),
                      ]),
                    ),
                  );
                },
              ),
            ),
            Container(
              color: Colors.grey.shade200,
              padding: const EdgeInsets.all(15),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text('Total:', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  Text('₹${cartProvider.total.toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 40, // Decreased height
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.money),
                          label: const Text('Cash'),
                          onPressed: () => setState(() => _selectedPaymentMethod = 'cash'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _selectedPaymentMethod == 'cash' ? Colors.green : null,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8), // Spacing between buttons
                    Expanded(
                      child: SizedBox(
                        height: 40,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.qr_code),
                          label: const Text('UPI'),
                          onPressed: () => setState(() => _selectedPaymentMethod = 'upi'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _selectedPaymentMethod == 'upi' ? Colors.green : null,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(
                        height: 40,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.credit_card),
                          label: const Text('Card'),
                          onPressed: () => setState(() => _selectedPaymentMethod = 'card'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _selectedPaymentMethod == 'card' ? Colors.green : null,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Switch(value: _addCustomerDetails, onChanged: (v) => setState(() => _addCustomerDetails = v)),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 200, // Reduced width for Generate Invoice button
                      height: 40,
                      child: ElevatedButton.icon(
                        onPressed: _submitBilling,
                        icon: const Icon(Icons.receipt_long),
                        label: const Text('Generate Invoice', style: TextStyle(fontSize: 18)),
                      ),
                    ),
                  ],
                ),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}