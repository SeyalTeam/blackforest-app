import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:blackforest_app/cart_provider.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/categories_page.dart';
import 'package:blackforest_app/table.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:esc_pos_printer/esc_pos_printer.dart';
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:qr/qr.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:intl/intl.dart';
import 'dart:async';

class CartPage extends StatefulWidget {
  const CartPage({super.key});

  @override
  State<CartPage> createState() => _CartPageState();
}

class _CartPageState extends State<CartPage> {
  String? _branchId;
  String? _branchName;
  String? _branchGst;
  String? _branchMobile;
  String? _companyName;
  String? _companyId; // Added to store company ID for billing
  // String? _userRole; // Removed as unused according to lint
  bool _addCustomerDetails = true; // Default to ON as requested
  String? _selectedPaymentMethod;
  bool _isBillingInProgress = false; // Prevent duplicate bill taps
  List<dynamic>? _kotPrinters; // Store KOT printer configs
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _fetchUserData();
    _startPolling();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (mounted) {
        final cartProvider = Provider.of<CartProvider>(context, listen: false);
        if (cartProvider.recalledBillId != null) {
          cartProvider.refreshRecalledBill();
          // Auto-clear notifications only if THIS cart page is the active screen
          // (i.e. not in background when notification page is open)
          if (ModalRoute.of(context)?.isCurrent == true) {
            cartProvider.markBillAsRead(cartProvider.recalledBillId!);
          }
        }
      }
    });
  }

  // -------------------------
  // ---------- NETWORK / DATA HELPERS (UNCHANGED LOGIC) ----------
  // -------------------------

  Future<void> _fetchUserData() async {
    // Assuming name is derived from email or stored separately; adjust if you have 'name' field
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) return;

      final response = await http.get(
        Uri.parse('https://blackforest.vseyal.com/api/users/me?depth=2'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final user = data['user'] ?? data;
        // _userRole = user['role']; // Assigned but unused

        if (user['role'] == 'branch' && user['branch'] != null) {
          _branchId = (user['branch'] is Map)
              ? user['branch']['id']
              : user['branch'];
          _branchName = (user['branch'] is Map) ? user['branch']['name'] : null;
          await _fetchBranchDetails(token, _branchId!);
        } else if (user['role'] == 'waiter') {
          await _fetchWaiterBranch(token);
        }

        if (!mounted) return;
        setState(() {});
        Provider.of<CartProvider>(
          context,
          listen: false,
        ).setBranchId(_branchId);
      }
    } catch (_) {}
  }

  Future<void> _fetchBranchDetails(String token, String branchId) async {
    try {
      String? globalPrinterIp;

      // 1. Fetch from Priority Global Settings
      try {
        final gRes = await http.get(
          Uri.parse(
            'https://blackforest.vseyal.com/api/globals/branch-geo-settings',
          ),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
        );

        if (gRes.statusCode == 200) {
          final settings = jsonDecode(gRes.body);
          final locations = settings['locations'] as List?;
          if (locations != null) {
            final branchConfig = locations.firstWhere((loc) {
              final locBranch = loc['branch'];
              String? locBranchId;
              if (locBranch is Map) {
                locBranchId =
                    locBranch['id']?.toString() ??
                    locBranch['_id']?.toString() ??
                    locBranch['\$oid']?.toString();
              } else {
                locBranchId = locBranch?.toString();
              }
              return locBranchId == branchId;
            }, orElse: () => null);

            if (branchConfig != null) {
              globalPrinterIp = branchConfig['printerIp']?.toString().trim();
              _kotPrinters = branchConfig['kotPrinters'] as List?;

              // Store Geo settings for future use
              final prefs = await SharedPreferences.getInstance();
              if (branchConfig['latitude'] != null) {
                await prefs.setDouble(
                  'branchLat',
                  (branchConfig['latitude'] as num).toDouble(),
                );
              }
              if (branchConfig['longitude'] != null) {
                await prefs.setDouble(
                  'branchLng',
                  (branchConfig['longitude'] as num).toDouble(),
                );
              }
              if (branchConfig['radius'] != null) {
                await prefs.setInt(
                  'branchRadius',
                  (branchConfig['radius'] as num).toInt(),
                );
              }
              if (branchConfig['ipAddress'] != null) {
                await prefs.setString(
                  'branchIp',
                  branchConfig['ipAddress'].toString(),
                );
              }
            }
          }
        }
      } catch (e) {
        debugPrint("Error fetching global settings in cart: $e");
      }

      // 2. Fetch from Branches Collection
      final response = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/branches/$branchId?depth=1',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final branch = jsonDecode(response.body);
        _branchName = branch['name'] ?? _branchName;
        _branchGst = branch['gst'];
        _branchMobile = branch['phone'];

        if (branch['company'] != null) {
          final company = branch['company'];
          if (company is Map) {
            _companyName = company['name'] ?? 'Unknown Company';
            _companyId = (company['id'] ?? company['_id'] ?? company[r'$oid'])
                ?.toString();
          } else {
            _companyId = company.toString();
            await _fetchCompanyDetails(token, _companyId!);
          }
        }

        final cartProvider = Provider.of<CartProvider>(context, listen: false);

        // Prioritize globalPrinterIp if it exists
        final printerIpToUse =
            (globalPrinterIp != null && globalPrinterIp.isNotEmpty)
            ? globalPrinterIp
            : branch['printerIp'];

        cartProvider.setPrinterDetails(
          printerIpToUse,
          branch['printerPort'],
          branch['printerProtocol'],
        );
      }
    } catch (_) {}
  }

  Future<void> _fetchCompanyDetails(String token, String companyId) async {
    try {
      final response = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/companies/$companyId?depth=1',
        ),
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
    // 0. Prioritize stored branchId from login
    final prefs = await SharedPreferences.getInstance();
    final storedBranchId = prefs.getString('branchId');
    if (storedBranchId != null) {
      _branchId = storedBranchId;
      await _fetchBranchDetails(token, storedBranchId);
      return;
    }

    String? deviceIp = await _fetchDeviceIp();
    if (deviceIp == null) return;

    try {
      // 1. Try Global Settings first
      final gRes = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/globals/branch-geo-settings',
        ),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      if (gRes.statusCode == 200) {
        final settings = jsonDecode(gRes.body);
        final locations = settings['locations'] as List?;
        if (locations != null) {
          for (var loc in locations) {
            String? bIpRange = loc['ipAddress']?.toString().trim();
            if (bIpRange != null &&
                (bIpRange == deviceIp || _isIpInRange(deviceIp, bIpRange))) {
              final branchRef = loc['branch'];
              final String? branchId = (branchRef is Map)
                  ? branchRef['id']?.toString()
                  : branchRef?.toString();
              if (branchId != null) {
                _branchId = branchId;
                await _fetchBranchDetails(token, branchId);
                return;
              }
            }
          }
        }
      }

      // 2. Fallback to Branches Collection
      final allBranchesResponse = await http.get(
        Uri.parse('https://blackforest.vseyal.com/api/branches?depth=1'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (allBranchesResponse.statusCode == 200) {
        final branchesData = jsonDecode(allBranchesResponse.body);
        if (branchesData['docs'] != null && branchesData['docs'] is List) {
          for (var branch in branchesData['docs']) {
            String? bIpRange = branch['ipAddress']?.toString().trim();
            if (bIpRange != null &&
                (bIpRange == deviceIp || _isIpInRange(deviceIp, bIpRange))) {
              _branchId = branch['id'];
              await _fetchBranchDetails(token, _branchId!);
              return;
            }
          }
        }
      }
    } catch (_) {}
  }

  bool _isKOTEnabled(String? categoryId) {
    if (categoryId == null || _kotPrinters == null || _kotPrinters!.isEmpty) {
      return false;
    }
    for (var printerConfig in _kotPrinters!) {
      final categories = printerConfig['categories'] as List?;
      if (categories == null) continue;
      final printerCategoryIds = categories.map((c) {
        if (c is Map) {
          return (c['id'] ?? c['_id'] ?? c[r'$oid'])?.toString();
        }
        return c.toString();
      }).toList();
      if (printerCategoryIds.contains(categoryId)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _handleScan(String scanResult) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No token found. Please login again.')),
        );
        return;
      }

      final response = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/products?where[upc][equals]=$scanResult&limit=1&depth=2',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final List<dynamic> products = data['docs'] ?? [];
        if (products.isNotEmpty) {
          final product = products[0];
          if (!mounted) return;
          final cartProvider = Provider.of<CartProvider>(
            context,
            listen: false,
          );
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

          final item = CartItem.fromProduct(product, 1, branchPrice: price);
          cartProvider.addOrUpdateItem(item);
          final newQty = cartProvider.cartItems
              .firstWhere((i) => i.id == item.id)
              .quantity;

          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${product['name']} added/updated (Qty: $newQty)'),
            ),
          );
        } else {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Product not found')));
        }
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error: Check your internet')),
      );
    }
  }

  // -------------------------
  // ---------- BILLING FLOW (UNCHANGED LOGIC) ----------
  // -------------------------

  Future<void> _submitBilling({
    String status = 'completed',
    bool isReminder = false,
  }) async {
    if (_isBillingInProgress) return; // lock
    setState(() => _isBillingInProgress = true);

    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    if (cartProvider.cartItems.isEmpty && cartProvider.recalledItems.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Cart is empty')));
      setState(() => _isBillingInProgress = false);
      return;
    }

    if (status == 'completed' && _selectedPaymentMethod == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a payment method')),
      );
      setState(() => _isBillingInProgress = false);
      return;
    }

    if (status == 'pending' && _selectedPaymentMethod != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Payment method is only for BILL')),
      );
      setState(() => _isBillingInProgress = false);
      return;
    }

    Map<String, dynamic>? customerDetails;
    if (_addCustomerDetails && status != 'pending') {
      customerDetails = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          final nameCtrl = TextEditingController(
            text: cartProvider.customerName ?? '',
          );
          final phoneCtrl = TextEditingController(
            text: cartProvider.customerPhone ?? '',
          );

          return Dialog(
            backgroundColor: const Color(0xFF1E1E1E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            insetPadding: const EdgeInsets.symmetric(horizontal: 28),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // TITLE
                      Center(
                        child: Text(
                          "Customer Details",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      // PHONE FIELD
                      Text(
                        "Phone Number",
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF121212),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: const Color(
                              0xFF0A84FF,
                            ).withValues(alpha: 0.5),
                          ),
                        ),
                        child: TextField(
                          controller: phoneCtrl,
                          keyboardType: TextInputType.phone,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                            border: InputBorder.none,
                            hintText: "Enter phone number",
                            hintStyle: TextStyle(color: Colors.white38),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      // NAME FIELD
                      Text(
                        "Customer Name",
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF121212),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: const Color(
                              0xFF0A84FF,
                            ).withValues(alpha: 0.5),
                          ),
                        ),
                        child: TextField(
                          controller: nameCtrl,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                            border: InputBorder.none,
                            hintText: "Enter customer name",
                            hintStyle: TextStyle(color: Colors.white38),
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      // BUTTON ROW
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () =>
                                  Navigator.pop(context, <String, dynamic>{}),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white70,
                                side: BorderSide(color: Colors.white24),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              child: const Text("Skip"),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () {
                                if (nameCtrl.text.trim().isNotEmpty &&
                                    phoneCtrl.text.trim().isEmpty) {
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        "Phone number is required when adding a customer name",
                                      ),
                                    ),
                                  );
                                  return;
                                }

                                Navigator.pop(context, <String, dynamic>{
                                  'name': nameCtrl.text,
                                  'phone': phoneCtrl.text,
                                });
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF0A84FF),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              child: const Text(
                                "Submit",
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Positioned(
                  right: 8,
                  top: 8,
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.pop(context, null),
                  ),
                ),
              ],
            ),
          );
        },
      );

      if (customerDetails == null) {
        setState(() => _isBillingInProgress = false);
        return;
      }
    } else {
      // For KOT/RE-KOT (pending), use existing details or empty map
      customerDetails = {
        'name': cartProvider.customerName ?? '',
        'phone': cartProvider.customerPhone ?? '',
      };
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) {
        setState(() => _isBillingInProgress = false);
        return;
      }

      debugPrint(
        '📦 SUBMITTING BILL: Branch: $_branchId, Company: $_companyId',
      ); // DEBUG LOG

      // 1. Merge active cart items with previously ordered items
      final Map<String, CartItem> mergedMap = {};

      // Start with recalled items (existing bill state)
      for (var item in cartProvider.recalledItems) {
        mergedMap[item.id] = item;
      }

      // Add/update with new cart items (active draft)
      for (var item in cartProvider.cartItems) {
        if (mergedMap.containsKey(item.id)) {
          // If already ordered, we increment the quantity
          final existing = mergedMap[item.id]!;
          existing.quantity += item.quantity;
          // Keep the special note if provided for the new item, or append?
          // Typically, for KOT, new notes are important.
          if (item.specialNote != null && item.specialNote!.isNotEmpty) {
            existing.specialNote =
                (existing.specialNote == null || existing.specialNote!.isEmpty)
                ? item.specialNote
                : '${existing.specialNote}, ${item.specialNote}';
          }
        } else {
          mergedMap[item.id] = item;
        }
      }

      final mergedItems = mergedMap.values.toList();

      final billingData = {
        'items': mergedItems
            .map(
              (item) => ({
                'product': item.id,
                'name': item.name,
                'quantity': item.quantity,
                'unitPrice': item.price,
                'subtotal': item.price * item.quantity,
                'branchOverride': _branchId != null,
                'specialNote': item.specialNote,
                'status': item.status, // Preserve status (e.g. delivered)
              }),
            )
            .toList(),
        'totalAmount': cartProvider.total,
        'branch': _branchId,
        'company': _companyId,
        'tableDetails': {
          'section': cartProvider.selectedSection,
          'tableNumber': cartProvider.selectedTable,
        },
        'recalledBillId': cartProvider.recalledBillId, // PASS RECALLED ID
        'customerDetails': {
          'name': customerDetails['name'] ?? '',
          'phoneNumber': customerDetails['phone'] ?? '',
          'address': '', // Placeholder as shown in schema
        },
        'paymentMethod': _selectedPaymentMethod,
        'isReminder': isReminder,
        'notes': cartProvider.cartItems
            .where(
              (item) =>
                  item.specialNote != null && item.specialNote!.isNotEmpty,
            )
            .map((item) => '${item.name}: ${item.specialNote}')
            .join(', '),
        'status': status,
      };

      final billId = cartProvider.recalledBillId;
      final url = billId != null
          ? Uri.parse('https://blackforest.vseyal.com/api/billings/$billId')
          : Uri.parse('https://blackforest.vseyal.com/api/billings');

      final response = billId != null
          ? await http.patch(
              url,
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              body: jsonEncode(billingData),
            )
          : await http.post(
              url,
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              body: jsonEncode(billingData),
            );

      debugPrint('📦 METHOD: ${billId != null ? "PATCH" : "POST"}');
      debugPrint('📦 PAYLOAD JSON: ${jsonEncode(billingData)}');

      final billingResponse = jsonDecode(response.body);
      debugPrint('📦 BILL RESPONSE: $billingResponse');

      if (response.statusCode == 201 || response.statusCode == 200) {
        // Play success sound
        try {
          debugPrint('🔊 Attempting to play payment sound...');
          final player = AudioPlayer();
          // Increase volume just in case
          await player.setVolume(1.0);
          await player.play(AssetSource('sounds/pay.mp3'));
          debugPrint('🔊 Sound command sent successfully');
        } catch (e) {
          debugPrint("Error playing sound: $e");
        }

        if (!mounted) return;

        if (status == 'pending') {
          await _handleKOTPrinting(
            cartProvider,
            billingResponse,
            customerDetails,
          );
        } else {
          await _printReceipt(
            cartProvider,
            billingResponse,
            customerDetails,
            _selectedPaymentMethod!,
          );
        }

        cartProvider.clearCart();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              status == 'pending'
                  ? 'KOT SENT SUCCESSFULLY'
                  : 'Billing submitted successfully',
            ),
          ),
        );
        if (status == 'pending' && cartProvider.currentType == CartType.table) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (context) => const TablePage()),
            (route) => false,
          );
        } else {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const CategoriesPage()),
          );
        }
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: ${response.statusCode}')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      setState(() => _isBillingInProgress = false);
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
        SnackBar(
          content: Text('Unsupported printer protocol: $printerProtocol'),
        ),
      );
      return;
    }

    // Fetch waiter name
    String? waiterName;
    try {
      final prefs = await SharedPreferences.getInstance();
      waiterName = prefs.getString('user_name');

      if (waiterName == null || waiterName.isEmpty || waiterName == 'Unknown') {
        if (billingResponse['createdBy'] != null) {
          var createdBy = billingResponse['createdBy'];
          String userId = '';

          // Case 1: createdBy is already the user object with a name
          if (createdBy is Map &&
              (createdBy['name'] != null || createdBy['username'] != null)) {
            waiterName = createdBy['name'] ?? createdBy['username'];
          }

          // Case 2: Extract ID to fetch user
          if (waiterName == null) {
            if (createdBy is String) {
              userId = createdBy;
            } else if (createdBy is Map) {
              if (createdBy.containsKey(r'$oid')) {
                userId = createdBy[r'$oid'];
              } else if (createdBy.containsKey('_id')) {
                var idVal = createdBy['_id'];
                if (idVal is Map && idVal.containsKey(r'$oid')) {
                  userId = idVal[r'$oid'];
                } else {
                  userId = idVal.toString();
                }
              } else if (createdBy.containsKey('id')) {
                userId = createdBy['id'];
              }
            }

            if (userId.isNotEmpty) {
              final token = prefs.getString('token');
              if (token != null) {
                final userResponse = await http.get(
                  Uri.parse(
                    'https://blackforest.vseyal.com/api/users/$userId?depth=1',
                  ),
                  headers: {'Authorization': 'Bearer $token'},
                );
                if (userResponse.statusCode == 200) {
                  final user = jsonDecode(userResponse.body);
                  waiterName = user['name'] ?? user['username'] ?? 'Unknown';
                  // Cache it for next time
                  if (waiterName != null && waiterName != 'Unknown') {
                    await prefs.setString('user_name', waiterName!);
                  }
                }
              }
            }
          }
        }
      }

      // Final attempt: Fetch current user if we still don't have a name
      if (waiterName == null || waiterName == 'Unknown') {
        final token = prefs.getString('token');
        if (token != null) {
          final meResponse = await http.get(
            Uri.parse('https://blackforest.vseyal.com/api/users/me'),
            headers: {'Authorization': 'Bearer $token'},
          );
          if (meResponse.statusCode == 200) {
            final body = jsonDecode(meResponse.body);
            if (body['user'] != null) {
              waiterName = body['user']['name'] ?? body['user']['username'];
              if (waiterName != null) {
                await prefs.setString('user_name', waiterName!);
              }
            }
          }
        }
      }
    } catch (_) {
      waiterName = 'Unknown';
    }

    try {
      const PaperSize paper = PaperSize.mm80;
      final profile = await CapabilityProfile.load();
      final printer = NetworkPrinter(paper, profile);

      final PosPrintResult res = await printer.connect(
        printerIp,
        port: printerPort,
      );

      if (res == PosPrintResult.success) {
        String invoiceNumber =
            billingResponse['invoiceNumber'] ??
            billingResponse['doc']?['invoiceNumber'] ??
            'N/A';
        // Extract numeric part from invoice like CHI-YYYYMMDD-017 → 017
        final regex = RegExp(r'^[A-Z]+-\d{8}-(KOT)?(\d+)$');
        final match = regex.firstMatch(invoiceNumber);
        String billNo = invoiceNumber;
        if (match != null) {
          final prefix = match.group(1) ?? ""; // "KOT" or null
          final digits = match.group(2)!;
          billNo = "$prefix$digits".replaceAll("KOT", "KOT ");
        }

        DateTime now = DateTime.now();
        String date =
            '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
        int hour = now.hour;
        String ampm = hour >= 12 ? 'PM' : 'AM';
        hour = hour % 12;
        if (hour == 0) hour = 12;
        String time = '$hour:${now.minute.toString().padLeft(2, '0')}$ampm';
        String dateStr = '$date $time';

        printer.text(
          _companyName ?? 'BLACK FOREST CAKES',
          styles: const PosStyles(
            align: PosAlign.center,
            bold: true,
            height: PosTextSize.size2,
            width: PosTextSize.size2,
          ),
        );
        printer.text(
          'Branch: ${_branchName ?? _branchId}',
          styles: const PosStyles(align: PosAlign.center),
        );
        printer.text(
          'GST: ${_branchGst ?? 'N/A'}',
          styles: const PosStyles(align: PosAlign.center),
        );
        printer.text(
          'Mobile: ${_branchMobile ?? 'N/A'}',
          styles: const PosStyles(align: PosAlign.center),
        );
        printer.hr(ch: '=');
        printer.row([
          PosColumn(
            text: 'Date: $dateStr',
            width: 6,
            styles: const PosStyles(
              align: PosAlign.left,
            ), // Confirmed Left Align
          ),
          PosColumn(
            text: 'BILL NO - $billNo',
            width: 6,
            styles: const PosStyles(align: PosAlign.right, bold: true),
          ),
        ]);
        if (waiterName != null) {
          printer.text(
            'Assigned by: $waiterName',
            styles: const PosStyles(align: PosAlign.left),
          );
        }
        printer.hr(ch: '=');
        printer.row([
          PosColumn(
            text: 'Item',
            width: 5,
            styles: const PosStyles(bold: true),
          ),
          PosColumn(
            text: 'Qty',
            width: 2,
            styles: const PosStyles(bold: true, align: PosAlign.center),
          ),
          PosColumn(
            text: 'Price',
            width: 2,
            styles: const PosStyles(bold: true, align: PosAlign.right),
          ),
          PosColumn(
            text: 'Amount',
            width: 3,
            styles: const PosStyles(bold: true, align: PosAlign.right),
          ),
        ]);
        printer.hr(ch: '-');

        for (var item in cartProvider.cartItems) {
          final qtyStr = item.quantity % 1 == 0
              ? item.quantity.toStringAsFixed(0)
              : item.quantity.toStringAsFixed(2);
          printer.row([
            PosColumn(text: item.name, width: 5),
            PosColumn(
              text: qtyStr,
              width: 2,
              styles: const PosStyles(align: PosAlign.center),
            ),
            PosColumn(
              text: item.price.toStringAsFixed(2),
              width: 2,
              styles: const PosStyles(align: PosAlign.right),
            ),
            PosColumn(
              text: (item.price * item.quantity).toStringAsFixed(2),
              width: 3,
              styles: const PosStyles(align: PosAlign.right),
            ),
          ]);
        }

        printer.hr(ch: '-');
        printer.row([
          PosColumn(
            text: 'PAID BY: ${paymentMethod.toUpperCase()}',
            width: 5,
            styles: const PosStyles(align: PosAlign.left, bold: true),
          ),
          PosColumn(
            text: 'TOTAL RS ${cartProvider.total.toStringAsFixed(2)}',
            width: 7,
            styles: const PosStyles(
              align: PosAlign.right,
              bold: true,
              height: PosTextSize.size2,
              width: PosTextSize.size1,
            ),
          ),
        ]);
        printer.hr(ch: '='); // Double line after Total Row as requested

        if (customerDetails['name']?.isNotEmpty == true ||
            customerDetails['phone']?.isNotEmpty == true) {
          printer.hr();
          printer.text('Customer: ${customerDetails['name'] ?? ''}');
          printer.text('Phone: ${customerDetails['phone'] ?? ''}');
        }

        // QR Code for Billings
        // Matches style of 'printer.text(_companyName ... bold: true)'

        // QR Code for Billings
        // Matches style of 'printer.text(_companyName ... bold: true)'

        bool shouldShowFeedback = cartProvider.cartItems.any((item) {
          final dept = item.department?.trim().toLowerCase();
          print(
            '🧐 Item: ${item.name}, Dept: "${item.department}", Processed: "$dept"',
          );
          return dept != null && dept.isNotEmpty && dept != 'others';
        });
        print('🧐 shouldShowFeedback: $shouldShowFeedback');

        if (shouldShowFeedback) {
          try {
            final ByteData data = await rootBundle.load(
              'assets/feedback_full.png',
            );
            final Uint8List bytes = data.buffer.asUint8List();
            final img.Image? image = img.decodeImage(bytes);
            if (image != null) {
              // Resize to full width (approx 550-570 dots for 80mm printer)
              final img.Image resized = img.copyResize(image, width: 550);
              printer.image(resized, align: PosAlign.center);
            }
          } catch (e) {
            print("Error printing image: $e");
            // Fallback text
            printer.text(
              'THE CREATOR OF THIS PRODUCT IS WAITING FOR YOUR',
              styles: const PosStyles(align: PosAlign.center, bold: true),
            );
            printer.text(
              'FEEDBACK',
              styles: const PosStyles(
                align: PosAlign.center,
                bold: true,
                height: PosTextSize.size2,
                width: PosTextSize.size2,
              ),
            );
          }

          printer.feed(1); // Added space after feedback image as requested
        }
        String billingUrl = 'http://blackforest.vseyal.com/billings';
        String? billingId =
            billingResponse['id'] ??
            billingResponse['doc']?['id'] ??
            billingResponse['_id'];
        if (billingId != null) {
          billingUrl = '$billingUrl/$billingId';
        }

        if (shouldShowFeedback) {
          try {
            // 1. Generate QR Code Image
            final qrCode = QrCode(4, QrErrorCorrectLevel.L);
            qrCode.addData(billingUrl);

            final qrImageMatrix = QrImage(qrCode);

            const int pixelSize =
                8; // Increased from 5 to 8 to match 'Size 6' (approx 33 modules * 8 = 264px)
            final int qrWidth = qrImageMatrix.moduleCount * pixelSize;
            final int qrHeight = qrImageMatrix.moduleCount * pixelSize;
            final img.Image qrImage = img.Image(qrWidth, qrHeight);

            // Fill background white
            img.fill(qrImage, img.getColor(255, 255, 255));

            for (int x = 0; x < qrImageMatrix.moduleCount; x++) {
              for (int y = 0; y < qrImageMatrix.moduleCount; y++) {
                if (qrImageMatrix.isDark(y, x)) {
                  img.fillRect(
                    qrImage,
                    x * pixelSize,
                    y * pixelSize,
                    (x + 1) * pixelSize,
                    (y + 1) * pixelSize,
                    img.getColor(0, 0, 0),
                  );
                }
              }
            }

            // 2. Load Chef Image
            final ByteData chefData = await rootBundle.load('assets/chef.png');
            final Uint8List chefBytes = chefData.buffer.asUint8List();
            final img.Image? chefImageRaw = img.decodeImage(chefBytes);

            if (chefImageRaw != null) {
              // 3. Resize Chef Image
              // Max width avail = ~550 (paper) - qrWidth - gap
              // 550 - 264 - 10 = ~276px available for chef
              const int maxWidth = 550;
              const int gap = 10;
              final int remainingWidth = maxWidth - qrWidth - gap;

              // Resize chef to fit in the remaining width, preserving aspect ratio
              // We prioritize width fit.
              final img.Image chefImage = img.copyResize(
                chefImageRaw,
                width: remainingWidth > 100 ? remainingWidth : 100,
              );

              // 4. Create Combined Canvas centered
              const int canvasWidth = 550; // Use full available width
              final int contentWidth = qrWidth + gap + chefImage.width;
              final int startX =
                  (canvasWidth - contentWidth) ~/ 2; // Center the content group

              // Define Text Block Logic
              const int textBlockHeight = 40; // Increased for larger font
              final int qrBlockHeight = qrHeight + textBlockHeight;

              final int totalHeight = max(qrBlockHeight, chefImage.height);

              final img.Image combinedImage = img.Image(
                canvasWidth,
                totalHeight,
              );
              img.fill(
                combinedImage,
                img.getColor(255, 255, 255),
              ); // White background

              // Calculate Y positions
              final int qrBlockY = (totalHeight - qrBlockHeight) ~/ 2;
              final int chefY = (totalHeight - chefImage.height) ~/ 2;

              // Draw QR
              img.drawImage(
                combinedImage,
                qrImage,
                dstX: startX,
                dstY: qrBlockY,
              );

              // Draw Black Box under QR
              img.fillRect(
                combinedImage,
                startX,
                qrBlockY + qrHeight,
                startX + qrWidth,
                qrBlockY + qrHeight + textBlockHeight,
                img.getColor(0, 0, 0),
              );

              // Draw Text "SCAN TO REVIEW"
              // Approximating centering for arial_24 (approx 15-16px width per char? "SCAN TO REVIEW" is 14 chars)
              // 14 chars * 16px = 224px. QR width is ~264px. (264 - 224) / 2 = 20px padding
              img.drawString(
                combinedImage,
                img.arial_24,
                startX + (qrWidth - (14 * 16)) ~/ 2,
                qrBlockY + qrHeight + (textBlockHeight - 24) ~/ 2,
                'SCAN TO REVIEW',
                color: img.getColor(255, 255, 255),
              );

              // Draw Chef
              img.drawImage(
                combinedImage,
                chefImage,
                dstX: startX + qrWidth + gap,
                dstY: chefY,
              );

              // 5. Print Combined Image
              printer.image(combinedImage, align: PosAlign.center);
            } else {
              // Fallback: Print QR only if chef image fails
              printer.image(qrImage, align: PosAlign.center);
            }
          } catch (e) {
            print("Error generating/printing side-by-side QR: $e");
            // Fallback to standard command
            printer.qrcode(
              billingUrl,
              align: PosAlign.center,
              size: QRSize.Size6,
            );
          }
        }

        printer.feed(1); // Space before message
        printer.text(
          'Thank you! Visit Again',
          styles: const PosStyles(align: PosAlign.center),
        );
        printer.cut();
        printer.disconnect();

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Receipt printed successfully')),
        );
      } else {
        throw Exception(res.msg);
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Print failed: $e')));
    }
  }

  // -------------------------
  // ---------- KOT PRINTING LOGIC ----------
  // -------------------------

  Future<void> _handleKOTPrinting(
    CartProvider cartProvider,
    dynamic billingResponse,
    Map<String, dynamic> customerDetails,
  ) async {
    if (_kotPrinters == null || _kotPrinters!.isEmpty) {
      debugPrint('ℹ️ No KOT printers configured for this branch.');
      return;
    }

    final groupedKots = <String, List<CartItem>>{}; // Printer IP -> Items

    for (var printerConfig in _kotPrinters!) {
      final ip = printerConfig['printerIp']?.toString().trim();
      final categories = printerConfig['categories'] as List?;
      if (ip == null || categories == null) continue;

      final printerCategoryIds = categories.map((c) {
        if (c is Map) {
          return (c['id'] ?? c['_id'] ?? c[r'$oid'])?.toString();
        }
        return c.toString();
      }).toList();

      final itemsForThisPrinter = cartProvider.cartItems.where((item) {
        return printerCategoryIds.contains(item.categoryId);
      }).toList();

      if (itemsForThisPrinter.isNotEmpty) {
        groupedKots[ip] = itemsForThisPrinter;
      }
    }

    if (groupedKots.isEmpty) {
      debugPrint('ℹ️ No items in cart matched any KOT printer categories.');
      return;
    }

    List<String> failedIps = [];
    for (var entry in groupedKots.entries) {
      debugPrint(
        '🖨️ Printing KOT to ${entry.key} (${entry.value.length} items)',
      );
      final res = await _printKOTReceipt(
        entry.value,
        entry.key,
        billingResponse,
        customerDetails,
      );
      if (res != PosPrintResult.success) {
        failedIps.add(entry.key);
      }
    }

    if (failedIps.isNotEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('KOT Print Failed for: ${failedIps.join(", ")}'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('KOTs printed successfully'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<PosPrintResult> _printKOTReceipt(
    List<CartItem> items,
    String printerIp,
    dynamic billingResponse,
    Map<String, dynamic> customerDetails,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final printerPort =
        int.tryParse(prefs.getString('printerPort') ?? '9100') ?? 9100;
    String? waiterName = prefs.getString('user_name');

    try {
      if (waiterName == null || waiterName == 'Unknown') {
        final token = prefs.getString('token');
        if (token != null) {
          final meResponse = await http.get(
            Uri.parse('https://blackforest.vseyal.com/api/users/me'),
            headers: {'Authorization': 'Bearer $token'},
          );
          if (meResponse.statusCode == 200) {
            final body = jsonDecode(meResponse.body);
            if (body['user'] != null) {
              waiterName = body['user']['name'] ?? body['user']['username'];
            }
          }
        }
      }
    } catch (_) {}

    try {
      const PaperSize paper = PaperSize.mm80;
      final profile = await CapabilityProfile.load();
      final printer = NetworkPrinter(paper, profile);

      final PosPrintResult res = await printer.connect(
        printerIp,
        port: printerPort,
      );

      if (res == PosPrintResult.success) {
        String invoiceNumber =
            billingResponse['invoiceNumber'] ??
            billingResponse['doc']?['invoiceNumber'] ??
            billingResponse['id']?.toString() ??
            'N/A';

        String digits = invoiceNumber;
        if (invoiceNumber.contains('-')) {
          digits = invoiceNumber.split('-').last.replaceAll('KOT', '');
        }

        DateTime now = DateTime.now();
        String timeStr = DateFormat('yyyy-MM-dd hh:mm a').format(now);

        // KOT HEADER
        String tableNum =
            (billingResponse['tableDetails']?['tableNumber'] ??
                    billingResponse['doc']?['tableDetails']?['tableNumber'] ??
                    'N/A')
                .toString();
        // Format to 2 digits if possible
        String tableDisplay = 'TABLE-${tableNum.padLeft(2, '0')}';

        if (_branchName != null) {
          printer.text(
            _branchName!.toUpperCase(),
            styles: const PosStyles(
              align: PosAlign.center,
              bold: true,
              height: PosTextSize.size1,
              width: PosTextSize.size1,
            ),
          );
        }

        printer.row([
          PosColumn(
            text: 'KOT NO: $digits',
            width: 7,
            styles: const PosStyles(
              bold: true,
              height: PosTextSize.size2,
              width: PosTextSize.size2,
            ),
          ),
          PosColumn(
            text: tableDisplay,
            width: 5,
            styles: const PosStyles(
              align: PosAlign.right,
              bold: true,
              height: PosTextSize.size2,
              width: PosTextSize.size2,
            ),
          ),
        ]);
        printer.hr(ch: '=');

        final String displayWaiter = (waiterName ?? '').trim();
        printer.row([
          PosColumn(
            text: 'Ordered by: $displayWaiter',
            width: 6,
            styles: const PosStyles(bold: true, align: PosAlign.left),
          ),
          PosColumn(
            text: timeStr,
            width: 6,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]);
        printer.hr(ch: '=');

        // COLUMN HEADERS
        printer.row([
          PosColumn(
            text: 'ITEM',
            width: 6,
            styles: const PosStyles(bold: true),
          ),
          PosColumn(
            text: 'NOTE',
            width: 4,
            styles: const PosStyles(bold: true),
          ),
          PosColumn(
            text: 'QTY',
            width: 2,
            styles: const PosStyles(bold: true, align: PosAlign.right),
          ),
        ]);
        printer.hr(ch: '-');

        // ITEMS
        for (int i = 0; i < items.length; i++) {
          final item = items[i];
          final qtyStr = item.quantity % 1 == 0
              ? item.quantity.toStringAsFixed(0)
              : item.quantity.toStringAsFixed(2);

          printer.row([
            PosColumn(
              text: '${i + 1}. ${item.name.toUpperCase()}',
              width: 7, // Increased from 6 to 7 to accommodate larger text
              styles: const PosStyles(
                bold: true,
                fontType:
                    PosFontType.fontA, // Back to FontA but keeping it bold
                height: PosTextSize.size1,
                width: PosTextSize.size1,
              ),
            ),
            PosColumn(
              text: item.specialNote ?? '-',
              width: 3, // Reduced from 4 to 3
              styles: const PosStyles(bold: true),
            ),
            PosColumn(
              text: qtyStr,
              width: 2,
              styles: const PosStyles(bold: true, align: PosAlign.right),
            ),
          ]);
          printer.feed(1);
        }

        printer.hr(ch: '=');

        // Print Top-level Notes
        String? topLevelNotes = billingResponse['notes']?.toString();
        if (topLevelNotes != null && topLevelNotes.isNotEmpty) {
          printer.text(
            'NOTES: $topLevelNotes',
            styles: const PosStyles(bold: true),
          );
          printer.hr(ch: '=');
        }

        if (customerDetails['name']?.isNotEmpty == true ||
            customerDetails['phone']?.isNotEmpty == true) {
          printer.text('Customer: ${customerDetails['name'] ?? ''}');
          printer.text('Phone: ${customerDetails['phone'] ?? ''}');
        }

        printer.feed(2);
        printer.cut();
        printer.disconnect();
        return PosPrintResult.success;
      }
      return res;
    } catch (e) {
      debugPrint("Error printing KOT to $printerIp: $e");
      return PosPrintResult.timeout;
    }
  }

  // -------------------------
  // ---------- REGULAR RECEIPT PRINTING ----------
  // -------------------------

  // Colors for Carbon Black theme
  final Color _bg = const Color(0xFF121212);
  final Color _card = const Color(0xFF1E1E1E);
  final Color _muted = const Color(0xFF9E9E9E);
  final Color _accent = const Color(0xFF0A84FF); // electric blue accent
  final Color _chipBg = const Color(0xFF19232E);

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.shopping_cart_outlined,
            size: 110,
            color: Colors.grey[700],
          ),
          const SizedBox(height: 18),
          Text(
            'Your cart is empty',
            style: TextStyle(
              color: Colors.grey[300],
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Add items from categories to start billing',
            style: TextStyle(color: _muted, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentChips() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _PaymentChip(
          label: 'Cash',
          icon: Icons.money,
          selected: _selectedPaymentMethod == 'cash',
          onTap: () => setState(
            () => _selectedPaymentMethod = _selectedPaymentMethod == 'cash'
                ? null
                : 'cash',
          ),
          accent: _accent,
          chipBg: _chipBg,
          width: 95, // increase width
        ),
        _PaymentChip(
          label: 'UPI',
          icon: Icons.qr_code,
          selected: _selectedPaymentMethod == 'upi',
          onTap: () => setState(
            () => _selectedPaymentMethod = _selectedPaymentMethod == 'upi'
                ? null
                : 'upi',
          ),
          accent: _accent,
          chipBg: _chipBg,
          width: 95,
        ),
        _PaymentChip(
          label: 'Card',
          icon: Icons.credit_card,
          selected: _selectedPaymentMethod == 'card',
          onTap: () => setState(
            () => _selectedPaymentMethod = _selectedPaymentMethod == 'card'
                ? null
                : 'card',
          ),
          accent: _accent,
          chipBg: _chipBg,
          width: 95,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cartProvider = Provider.of<CartProvider>(context);
    return CommonScaffold(
      title: 'Cart',
      pageType: cartProvider.currentType == CartType.billing
          ? PageType.billing
          : PageType.table,
      onScanCallback: _handleScan,
      body: Container(
        color: _bg,
        child: Consumer<CartProvider>(
          builder: (context, cartProvider, child) {
            final items = cartProvider.cartItems;
            // Calculate total items as sum of quantities (assuming double, but display as int if whole)
            final totalQuantity = cartProvider.cartItems.fold<double>(
              0,
              (sum, item) => sum + item.quantity,
            );
            final totalItemsDisplay = totalQuantity % 1 == 0
                ? totalQuantity.toInt().toString()
                : totalQuantity.toStringAsFixed(2);

            return SafeArea(
              child: Stack(
                children: [
                  // Main content
                  Column(
                    children: [
                      // If both empty show empty state
                      if (items.isEmpty && cartProvider.recalledItems.isEmpty)
                        Expanded(child: _buildEmptyState())
                      else
                        Expanded(
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 140),
                            children: [
                              // 🛒 NEW ITEMS (ACTIVE DRAFT)
                              if (items.isNotEmpty) ...[
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 4,
                                    bottom: 12,
                                    top: 4,
                                  ),
                                  child: Text(
                                    "NEW ITEMS",
                                    style: TextStyle(
                                      color: _accent,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                      letterSpacing: 1.2,
                                    ),
                                  ),
                                ),
                                ...items.map((item) {
                                  return _CartItemCard(
                                    key: ValueKey(
                                      '${item.id}_${item.quantity}',
                                    ),
                                    item: item,
                                    cardColor: _card,
                                    accent: _accent,
                                    onRemove: () =>
                                        cartProvider.removeItem(item.id),
                                    onQuantityChange: (q) =>
                                        cartProvider.updateQuantity(item.id, q),
                                    onNoteChange: (note) =>
                                        cartProvider.updateNote(item.id, note),
                                    showNoteIcon: _isKOTEnabled(
                                      item.categoryId,
                                    ),
                                  );
                                }).toList(),
                                const SizedBox(height: 20),
                              ],

                              // 🧾 PREVIOUSLY ORDERED ITEMS (RECALLED)
                              if (cartProvider.recalledItems.isNotEmpty) ...[
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 4,
                                    bottom: 12,
                                    top: 8,
                                  ),
                                  child: Row(
                                    children: [
                                      Text(
                                        "PREVIOUS ORDERS",
                                        style: TextStyle(
                                          color: Colors.white70,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                          letterSpacing: 1.2,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Divider(
                                          color: Colors.white10,
                                          thickness: 1,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                ...cartProvider.recalledItems.asMap().entries.map((
                                  entry,
                                ) {
                                  final index = entry.key;
                                  final item = entry.value;
                                  final status =
                                      item.status?.toLowerCase() ?? 'ordered';

                                  // Workflow: Ordered -> Confirmed -> Prepared -> Delivered
                                  String? nextStatus;
                                  Color statusColor = Colors.white70;
                                  String displayStatus = status.toUpperCase();

                                  switch (status) {
                                    case 'ordered':
                                      nextStatus = null; // Kitchen only
                                      statusColor = Colors.yellow;
                                      break;
                                    case 'confirmed':
                                      nextStatus = null; // Kitchen only
                                      statusColor = const Color(
                                        0xFF0A84FF,
                                      ); // Blue
                                      break;
                                    case 'prepared':
                                      nextStatus = 'delivered';
                                      statusColor = const Color(
                                        0xFF2EBF3B,
                                      ); // Green
                                      break;
                                    case 'delivered':
                                      nextStatus = null; // End of chain
                                      statusColor = const Color(
                                        0xFFFF2D55,
                                      ); // Pink
                                      break;
                                    default:
                                      nextStatus = null;
                                      statusColor = Colors.yellow;
                                  }

                                  return GestureDetector(
                                    onDoubleTap: nextStatus == null
                                        ? null
                                        : () => cartProvider
                                              .updateRecalledItemStatus(
                                                context,
                                                index,
                                                nextStatus!,
                                              ),
                                    onLongPress: () {
                                      if (status == 'ordered' ||
                                          status == 'confirmed') {
                                        _showCancelDialog(
                                          context,
                                          cartProvider,
                                          index,
                                          item.name,
                                        );
                                      } else {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              '${status.toUpperCase()} items cannot be cancelled',
                                              style: const TextStyle(
                                                color: Colors.white,
                                              ),
                                            ),
                                            backgroundColor: Colors.red,
                                            duration: const Duration(
                                              seconds: 2,
                                            ),
                                          ),
                                        );
                                      }
                                    },
                                    child: Container(
                                      margin: const EdgeInsets.only(bottom: 8),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 12,
                                      ),
                                      decoration: BoxDecoration(
                                        color: statusColor.withOpacity(0.08),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: statusColor.withOpacity(0.2),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  item.name,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                                if (item.specialNote != null &&
                                                    item
                                                        .specialNote!
                                                        .isNotEmpty)
                                                  Text(
                                                    item.specialNote!,
                                                    style: TextStyle(
                                                      color: _muted,
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        top: 4,
                                                      ),
                                                  child: Text(
                                                    displayStatus,
                                                    style: TextStyle(
                                                      color: statusColor,
                                                      fontSize: 10,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      letterSpacing: 1,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Text(
                                            '${item.quantity % 1 == 0 ? item.quantity.toInt() : item.quantity} ${item.unit ?? "pcs"}',
                                            style: TextStyle(
                                              color: _muted,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          Text(
                                            '₹${(item.price * item.quantity).toStringAsFixed(2)}',
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ],
                            ],
                          ),
                        ),
                    ],
                  ),
                  // Sticky bottom bar
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.black.withValues(alpha: 0.6),
                            Colors.black.withValues(alpha: 0.85),
                          ],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                        border: Border(
                          top: BorderSide(
                            color: Colors.white.withValues(alpha: 0.04),
                          ),
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // UPDATED: Total with colors, space between amount and items, toggle switch on right
                          if (cartProvider.currentType != CartType.table ||
                              (cartProvider.recalledBillId != null &&
                                  cartProvider.cartItems.isEmpty)) ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    const Text(
                                      'Total: ',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      '₹${cartProvider.total.toStringAsFixed(2)}',
                                      style: const TextStyle(
                                        color: Colors.green,
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(
                                      width: 12,
                                    ), // Space between amount and items
                                    Text(
                                      totalItemsDisplay,
                                      style: const TextStyle(
                                        color: Colors.yellow,
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const Text(
                                      ' Items',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                Switch(
                                  value: _addCustomerDetails,
                                  onChanged: (v) =>
                                      setState(() => _addCustomerDetails = v),
                                  activeColor: _accent,
                                  inactiveThumbColor: Colors.grey,
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            // Payment chips row (full width)
                            _buildPaymentChips(),
                          ],
                          const SizedBox(height: 16),
                          // BILLING BUTTONS
                          Row(
                            children: [
                              // OK BILL
                              if (cartProvider.currentType != CartType.table ||
                                  (cartProvider.recalledBillId != null &&
                                      cartProvider.cartItems.isEmpty))
                                Expanded(
                                  child: SizedBox(
                                    height: 40,
                                    child: ElevatedButton(
                                      onPressed: _isBillingInProgress
                                          ? null
                                          : () => _submitBilling(
                                              status: 'completed',
                                            ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFF2EBF3B,
                                        ),
                                        disabledBackgroundColor: const Color(
                                          0xFF2EBF3B,
                                        ),
                                        disabledForegroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                        elevation: 4,
                                      ),
                                      child: const Text(
                                        'BILL',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),

                              if (cartProvider.currentType == CartType.table &&
                                  (cartProvider.recalledBillId == null ||
                                      cartProvider.cartItems.isNotEmpty))
                                // KOT
                                Expanded(
                                  child: SizedBox(
                                    height: 40,
                                    child: ElevatedButton(
                                      onPressed: _isBillingInProgress
                                          ? null
                                          : () => _submitBilling(
                                              status: 'pending',
                                              isReminder:
                                                  cartProvider.recalledBillId !=
                                                  null,
                                            ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFF0A84FF,
                                        ),
                                        disabledBackgroundColor: const Color(
                                          0xFF0A84FF,
                                        ),
                                        disabledForegroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                        elevation: 4,
                                      ),
                                      child: const Text(
                                        'KOT',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _showCancelDialog(
    BuildContext context,
    CartProvider cartProvider,
    int index,
    String itemName,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Cancel Item', style: TextStyle(color: Colors.white)),
        content: Text(
          'Are you sure you want to cancel "$itemName"? This cannot be undone.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('NO'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              cartProvider.updateRecalledItemStatus(
                context,
                index,
                'cancelled',
              );
            },
            child: const Text(
              'YES, CANCEL',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------------
// ---------- SMALL WIDGETS ----------
// -------------------------

class _CartItemCard extends StatefulWidget {
  final CartItem item;
  final VoidCallback onRemove;
  final Function(double) onQuantityChange;
  final Function(String) onNoteChange;
  final Color cardColor;
  final Color accent;
  final bool showNoteIcon;

  const _CartItemCard({
    Key? key,
    required this.item,
    required this.onRemove,
    required this.onQuantityChange,
    required this.onNoteChange,
    required this.cardColor,
    required this.accent,
    required this.showNoteIcon,
  }) : super(key: key);

  @override
  _CartItemCardState createState() => _CartItemCardState();
}

class _CartItemCardState extends State<_CartItemCard> {
  late TextEditingController _qtyController;
  late double _step;

  String _qtyDisplay(double qty) {
    if (qty % 1 == 0) return qty.toInt().toString();
    return qty.toStringAsFixed(2);
  }

  double _calculateStep(double qty) {
    if (qty == 0) return 0.25; // Default step
    int a = (qty * 100).round().abs();
    int b = 100;
    int g = _gcd(a, b);
    return g / 100.0;
  }

  int _gcd(int a, int b) {
    while (b != 0) {
      int t = b;
      b = a % b;
      a = t;
    }
    return a;
  }

  @override
  void initState() {
    super.initState();
    _qtyController = TextEditingController(
      text: _qtyDisplay(widget.item.quantity),
    );
    _step = _calculateStep(widget.item.quantity);
  }

  @override
  void didUpdateWidget(covariant _CartItemCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.quantity != widget.item.quantity) {
      _qtyController.text = _qtyDisplay(widget.item.quantity);
      _step = _calculateStep(widget.item.quantity);
    }
  }

  @override
  void dispose() {
    _qtyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: widget.cardColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            // 🟦 IMAGE → Tap to REMOVE
            GestureDetector(
              onTap: widget.onRemove,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: widget.item.imageUrl != null
                    ? CachedNetworkImage(
                        imageUrl: widget.item.imageUrl!,
                        width: 68,
                        height: 68,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => SizedBox(
                          width: 68,
                          height: 68,
                          child: Center(
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: widget.accent,
                            ),
                          ),
                        ),
                        errorWidget: (context, url, error) => Container(
                          width: 68,
                          height: 68,
                          color: Colors.grey[800],
                          child: Icon(
                            Icons.image_not_supported,
                            color: Colors.grey[600],
                          ),
                        ),
                      )
                    : Container(
                        width: 68,
                        height: 68,
                        color: Colors.grey[800],
                        child: Icon(
                          Icons.image_not_supported,
                          color: Colors.grey[600],
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            // 🟦 Name + Price + Subtotal
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.item.name,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '₹${widget.item.price.toStringAsFixed(2)} each',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Subtotal: ₹${(widget.item.price * widget.item.quantity).toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (widget.item.specialNote != null &&
                      widget.item.specialNote!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Note: ${widget.item.specialNote}',
                        style: TextStyle(
                          color: widget.accent.withOpacity(0.8),
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (widget.showNoteIcon)
              IconButton(
                icon: Icon(
                  widget.item.specialNote?.isNotEmpty == true
                      ? Icons.note_alt
                      : Icons.note_add_outlined,
                  color: widget.accent,
                  size: 20,
                ),
                onPressed: () async {
                  final note = await showDialog<String>(
                    context: context,
                    builder: (context) {
                      final ctrl = TextEditingController(
                        text: widget.item.specialNote,
                      );
                      return AlertDialog(
                        backgroundColor: const Color(0xFF1E1E1E),
                        title: const Text(
                          'Special Note',
                          style: TextStyle(color: Colors.white),
                        ),
                        content: TextField(
                          controller: ctrl,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            hintText: 'Enter instructions...',
                            hintStyle: TextStyle(color: Colors.white38),
                          ),
                          autofocus: true,
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, ctrl.text),
                            child: const Text('Save'),
                          ),
                        ],
                      );
                    },
                  );
                  if (note != null) {
                    widget.onNoteChange(note);
                  }
                },
              ),
            const SizedBox(width: 4),
            // 🟦 Quantity controls with input field
            Column(
              children: [
                _QuantityButton(
                  icon: Icons.add_circle_outline,
                  onTap: () => widget.onQuantityChange(
                    (widget.item.quantity + _step).clamp(0.0, double.infinity),
                  ),
                  accent: widget.accent,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: SizedBox(
                    width: 50,
                    child: TextField(
                      controller: _qtyController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        border: InputBorder.none,
                      ),
                      onSubmitted: (value) {
                        double newQty =
                            double.tryParse(value) ?? widget.item.quantity;
                        newQty = newQty.clamp(0.0, double.infinity);
                        widget.onQuantityChange(newQty);
                        // Step will be updated in didUpdateWidget
                      },
                    ),
                  ),
                ),
                _QuantityButton(
                  icon: Icons.remove_circle_outline,
                  onTap: () => widget.onQuantityChange(
                    (widget.item.quantity - _step).clamp(0.0, double.infinity),
                  ),
                  accent: widget.accent,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _QuantityButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color accent;

  const _QuantityButton({
    Key? key,
    required this.icon,
    required this.onTap,
    required this.accent,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withOpacity(0.04)),
        ),
        child: Icon(icon, color: accent, size: 22),
      ),
    );
  }
}

class _PaymentChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final Color accent;
  final Color chipBg;
  final double width;

  const _PaymentChip({
    Key? key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    required this.accent,
    required this.chipBg,
    required this.width,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: width, // 🔥 FIXED WIDTH
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? accent.withOpacity(0.18) : chipBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? accent : Colors.transparent),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: selected ? accent : Colors.white70),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: selected ? accent : Colors.white70,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
