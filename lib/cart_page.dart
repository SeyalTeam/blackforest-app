import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:blackforest_app/cart_provider.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/categories_page.dart';
import 'package:blackforest_app/table.dart';
import 'package:blackforest_app/app_http.dart' as http;
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
import 'package:blackforest_app/customer_history_dialog.dart';
import 'package:blackforest_app/table_customer_details_visibility_service.dart';

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
  final Map<String, String> _categoryToKitchenMap = {}; // ID mapping
  final TextEditingController _sharedTableController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchUserData();
    _startPolling();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _sharedTableController.dispose();
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

        // Load kitchen mappings for KOT routing
        await _fetchKitchensForMapping();

        cartProvider.setPrinterDetails(
          printerIpToUse,
          branch['printerPort'],
          branch['printerProtocol'],
        );
      }
    } catch (_) {}
  }

  Future<void> _fetchKitchensForMapping() async {
    if (_branchId == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      final response = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/kitchens?where[branches][contains]=$_branchId&limit=100',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final docs = data['docs'] as List;
        _categoryToKitchenMap.clear();
        for (var k in docs) {
          final kId = k['id']?.toString();
          final cats = k['categories'] as List?;
          if (kId != null && cats != null) {
            for (var c in cats) {
              final cId = (c is Map) ? c['id']?.toString() : c?.toString();
              if (cId != null) {
                _categoryToKitchenMap[cId] = kId;
              }
            }
          }
        }
        debugPrint(
          "✅ Kitchen Mapping Loaded: ${_categoryToKitchenMap.length} categories mapped",
        );
      }
    } catch (e) {
      debugPrint("Error fetching kitchen mapping: $e");
    }
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
    if (_kotPrinters == null || _kotPrinters!.isEmpty) {
      return false;
    }

    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    final selectedKitchenId = cartProvider.selectedKitchenId;

    if (selectedKitchenId == null) {
      return false;
    }

    for (var printerConfig in _kotPrinters!) {
      final kitchens = printerConfig['kitchens'] as List?;
      if (kitchens == null) continue;
      final printerKitchenIds = kitchens.map((k) {
        if (k is Map) {
          return (k['id'] ?? k['_id'] ?? k[r'$oid'])?.toString();
        }
        return k.toString();
      }).toList();

      if (printerKitchenIds.contains(selectedKitchenId)) {
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
    FocusManager.instance.primaryFocus?.unfocus();
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
    final hasTableForCustomerFlow =
        cartProvider.selectedTable?.trim().isNotEmpty == true;
    final hasSectionForCustomerFlow =
        cartProvider.selectedSection?.trim().isNotEmpty == true;
    final isTableOrderForCustomerFlow =
        cartProvider.currentType == CartType.table &&
        (hasTableForCustomerFlow ||
            hasSectionForCustomerFlow ||
            cartProvider.isSharedTableOrder);
    bool showCustomerDetailsForTableOrders = true;
    bool allowSkipCustomerDetailsForTableOrders = true;
    bool showCustomerDetailsForBillingOrders = true;
    bool allowSkipCustomerDetailsForBillingOrders = true;
    if (status != 'pending') {
      final customerDetailsVisibilityConfig =
          await TableCustomerDetailsVisibilityService.getConfigForBranch(
            branchId: _branchId,
          );
      showCustomerDetailsForTableOrders =
          customerDetailsVisibilityConfig.showCustomerDetailsForTableOrders;
      allowSkipCustomerDetailsForTableOrders = customerDetailsVisibilityConfig
          .allowSkipCustomerDetailsForTableOrders;
      showCustomerDetailsForBillingOrders =
          customerDetailsVisibilityConfig.showCustomerDetailsForBillingOrders;
      allowSkipCustomerDetailsForBillingOrders = customerDetailsVisibilityConfig
          .allowSkipCustomerDetailsForBillingOrders;
      if (!mounted) return;
    }

    final showCustomerDetailsForActiveFlow = isTableOrderForCustomerFlow
        ? showCustomerDetailsForTableOrders
        : showCustomerDetailsForBillingOrders;
    final allowSkipForActiveFlow = isTableOrderForCustomerFlow
        ? allowSkipCustomerDetailsForTableOrders
        : allowSkipCustomerDetailsForBillingOrders;

    final shouldShowCustomerDetailsDialog =
        _addCustomerDetails &&
        status != 'pending' &&
        showCustomerDetailsForActiveFlow;

    if (shouldShowCustomerDetailsDialog) {
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
          Timer? debounceTimer;
          Map<String, dynamic>? customerLookupData;
          bool isLookupInProgress = false;
          String? lookupError;
          bool applyCustomerOffer = false;
          bool didAutoLookup = false;
          int offerPageIndex = 0;

          double readMoney(dynamic value) {
            if (value is num) {
              final parsed = value.toDouble();
              return parsed < 0 ? 0 : parsed;
            }
            return 0;
          }

          Map<String, dynamic>? readOfferData(
            Map<String, dynamic>? customerData,
          ) {
            if (customerData == null) return null;
            final raw = customerData['offer'];
            if (raw is Map) {
              return Map<String, dynamic>.from(raw);
            }
            return null;
          }

          Map<String, dynamic>? readProductOfferData(
            Map<String, dynamic>? customerData,
          ) {
            if (customerData == null) return null;
            final raw = customerData['productOfferPreview'];
            if (raw is Map) {
              return Map<String, dynamic>.from(raw);
            }
            return null;
          }

          List<Map<String, dynamic>> readProductOfferMatches(
            Map<String, dynamic>? customerData,
          ) {
            final preview = readProductOfferData(customerData);
            final matches = preview?['matches'];
            if (matches is! List) return const <Map<String, dynamic>>[];
            return matches
                .whereType<Map>()
                .map((raw) => Map<String, dynamic>.from(raw))
                .toList();
          }

          Map<String, dynamic>? readProductPriceOfferData(
            Map<String, dynamic>? customerData,
          ) {
            if (customerData == null) return null;
            final raw = customerData['productPriceOfferPreview'];
            if (raw is Map) {
              return Map<String, dynamic>.from(raw);
            }
            return null;
          }

          List<Map<String, dynamic>> readProductPriceOfferMatches(
            Map<String, dynamic>? customerData,
          ) {
            final preview = readProductPriceOfferData(customerData);
            final matches = preview?['matches'];
            if (matches is! List) return const <Map<String, dynamic>>[];
            return matches
                .whereType<Map>()
                .map((raw) => Map<String, dynamic>.from(raw))
                .toList();
          }

          Map<String, dynamic>? readTotalPercentageOfferData(
            Map<String, dynamic>? customerData,
          ) {
            if (customerData == null) return null;
            final raw = customerData['totalPercentageOfferPreview'];
            if (raw is Map) {
              return Map<String, dynamic>.from(raw);
            }
            return null;
          }

          Map<String, dynamic>? readCustomerEntryPercentageOfferData(
            Map<String, dynamic>? customerData,
          ) {
            if (customerData == null) return null;
            final raw = customerData['customerEntryPercentageOfferPreview'];
            if (raw is Map) {
              return Map<String, dynamic>.from(raw);
            }
            return null;
          }

          Map<String, dynamic>? readRandomCustomerOfferData(
            Map<String, dynamic>? customerData,
          ) {
            if (customerData == null) return null;
            final raw = customerData['randomCustomerOfferPreview'];
            if (raw is Map) {
              return Map<String, dynamic>.from(raw);
            }
            return null;
          }

          List<Map<String, dynamic>> readRandomCustomerOfferMatches(
            Map<String, dynamic>? customerData,
          ) {
            final preview = readRandomCustomerOfferData(customerData);
            final matches = preview?['matches'];
            if (matches is! List) return const <Map<String, dynamic>>[];
            return matches
                .whereType<Map>()
                .map((raw) => Map<String, dynamic>.from(raw))
                .toList();
          }

          String formatQty(double value) {
            if (value % 1 == 0) {
              return value.toInt().toString();
            }
            return value.toStringAsFixed(2);
          }

          Future<void> lookupCustomer(
            String rawPhone,
            void Function(void Function()) setDialogState,
          ) async {
            final phone = rawPhone.trim();
            final lookupPhone = phone.length >= 10 ? phone : '';

            setDialogState(() {
              lookupError = null;
              isLookupInProgress = true;
            });

            try {
              final activeTableNumber =
                  cartProvider.selectedTable?.trim() ?? '';
              final activeSection = cartProvider.selectedSection?.trim() ?? '';
              final lookupIsTableOrder =
                  cartProvider.currentType == CartType.table &&
                  (activeTableNumber.isNotEmpty || activeSection.isNotEmpty);
              final data = await cartProvider.fetchCustomerData(
                lookupPhone,
                isTableOrder: lookupIsTableOrder,
                tableSection: activeSection,
                tableNumber: activeTableNumber,
              );
              final latestPhone = phoneCtrl.text.trim();
              final isSameLongPhone = latestPhone == phone;
              final bothShortPhone =
                  latestPhone.length < 10 && phone.length < 10;
              if (!isSameLongPhone && !bothShortPhone) return;

              setDialogState(() {
                customerLookupData = data;
                isLookupInProgress = false;
                lookupError = null;

                if (data != null) {
                  final fetchedName = data['name']?.toString().trim() ?? '';
                  final isNewCustomerLookup = data['isNewCustomer'] == true;
                  if (!isNewCustomerLookup &&
                      fetchedName.isNotEmpty &&
                      nameCtrl.text.trim().isEmpty) {
                    nameCtrl.text = fetchedName;
                  }
                }

                final offerData = readOfferData(data);
                final eligible =
                    offerData?['enabled'] == true &&
                    (offerData?['isOfferEligible'] == true ||
                        offerData?['historyBasedEligible'] == true);
                applyCustomerOffer = eligible;
              });
            } catch (_) {
              final latestPhone = phoneCtrl.text.trim();
              final isSameLongPhone = latestPhone == phone;
              final bothShortPhone =
                  latestPhone.length < 10 && phone.length < 10;
              if (!isSameLongPhone && !bothShortPhone) return;
              setDialogState(() {
                customerLookupData = null;
                isLookupInProgress = false;
                lookupError = 'Unable to fetch customer details';
                applyCustomerOffer = false;
              });
            }
          }

          return StatefulBuilder(
            builder: (context, setDialogState) {
              if (!didAutoLookup) {
                didAutoLookup = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  lookupCustomer(phoneCtrl.text, setDialogState);
                });
              }

              final offerData = readOfferData(customerLookupData);
              final productOfferData = readProductOfferData(customerLookupData);
              final productOfferMatches = readProductOfferMatches(
                customerLookupData,
              );
              final isNewCustomer =
                  customerLookupData?['isNewCustomer'] == true;
              final productPriceOfferData = readProductPriceOfferData(
                customerLookupData,
              );
              final productPriceOfferMatches = readProductPriceOfferMatches(
                customerLookupData,
              );
              final totalPercentageOfferData = readTotalPercentageOfferData(
                customerLookupData,
              );
              final customerEntryPercentageOfferData =
                  readCustomerEntryPercentageOfferData(customerLookupData);
              final randomCustomerOfferData = readRandomCustomerOfferData(
                customerLookupData,
              );
              final randomCustomerOfferMatches = readRandomCustomerOfferMatches(
                customerLookupData,
              );
              final randomCustomerOfferSelectedMatchRaw =
                  randomCustomerOfferData?['selectedMatch'];
              Map<String, dynamic>? randomCustomerOfferSelectedMatch;
              if (randomCustomerOfferSelectedMatchRaw is Map) {
                randomCustomerOfferSelectedMatch = Map<String, dynamic>.from(
                  randomCustomerOfferSelectedMatchRaw,
                );
              } else {
                for (final match in randomCustomerOfferMatches) {
                  if (match['eligible'] == true) {
                    randomCustomerOfferSelectedMatch = match;
                    break;
                  }
                }
              }
              final offerEnabled = offerData?['enabled'] == true;
              final productOfferEnabled = productOfferData?['enabled'] == true;
              final productPriceOfferEnabled =
                  productPriceOfferData?['enabled'] == true;
              final totalPercentageOfferEnabled =
                  totalPercentageOfferData?['enabled'] == true;
              final customerEntryPercentageOfferEnabled =
                  customerEntryPercentageOfferData?['enabled'] == true;
              final customerEntryPercentagePreviewEligible =
                  customerEntryPercentageOfferData?['previewEligible'] == true;
              final randomCustomerOfferEnabled =
                  randomCustomerOfferData?['enabled'] == true;
              final randomCustomerOfferEligible =
                  randomCustomerOfferEnabled &&
                  randomCustomerOfferData?['isEligible'] == true;
              final randomOfferCampaignCode =
                  randomCustomerOfferData?['campaignCode']?.toString().trim() ??
                  '';
              final historyBasedEligible =
                  offerData?['historyBasedEligible'] == true;
              final serverEligible =
                  offerEnabled && offerData?['isOfferEligible'] == true;
              final offerEligible =
                  offerEnabled && (serverEligible || historyBasedEligible);
              final hasEligibleProductOffer = productOfferMatches.any(
                (match) => match['eligible'] == true,
              );
              final hasEligibleProductPriceOffer = productPriceOfferMatches.any(
                (match) => match['eligible'] == true,
              );
              final hasEligibleRandomOffer = randomCustomerOfferEligible;
              final hasEligibleItemLevelOffer =
                  hasEligibleProductOffer ||
                  hasEligibleProductPriceOffer ||
                  hasEligibleRandomOffer;
              final canApplyCustomerOffer =
                  offerEligible && !hasEligibleItemLevelOffer;
              final effectiveApplyCustomerOffer =
                  canApplyCustomerOffer && applyCustomerOffer;
              final highestPriorityAppliedPreviewName = hasEligibleProductOffer
                  ? 'Product-to-Product Offer'
                  : hasEligibleProductPriceOffer
                  ? 'Product Price Offer'
                  : hasEligibleRandomOffer
                  ? 'Random Product Offer'
                  : effectiveApplyCustomerOffer
                  ? 'Customer Credit Offer'
                  : customerEntryPercentagePreviewEligible
                  ? 'Customer Entry Percentage Offer'
                  : null;
              final hasOfferPreview =
                  offerEnabled ||
                  productOfferEnabled ||
                  productPriceOfferEnabled ||
                  customerEntryPercentageOfferEnabled ||
                  totalPercentageOfferEnabled ||
                  randomCustomerOfferEligible;
              final offerAmount = readMoney(offerData?['offerAmount']);
              final rewardPoints = readMoney(offerData?['rewardPoints']);
              final pointsNeeded = readMoney(
                offerData?['pointsNeededForOffer'],
              );
              final remainingPoints = readMoney(
                offerData?['remainingPointsForOffer'],
              );
              final remainingSpend = readMoney(
                offerData?['remainingSpendForOffer'],
              );
              final completedBillsCount =
                  (offerData?['completedBillsCount'] as num?)?.toInt() ?? 0;
              final completedSpendAmount = readMoney(
                offerData?['completedSpendAmount'],
              );
              final billTotal = cartProvider.total;
              final previewDiscount = effectiveApplyCustomerOffer
                  ? (offerAmount > billTotal ? billTotal : offerAmount)
                  : 0.0;
              final previewPayable = (billTotal - previewDiscount)
                  .clamp(0.0, double.infinity)
                  .toDouble();
              final mediaQuery = MediaQuery.of(context);
              final dialogMaxHeight = max(
                280.0,
                mediaQuery.size.height - mediaQuery.viewInsets.bottom - 32,
              );
              final offerCards = <Widget>[
                if (offerEnabled)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F1A11),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: const Color(0xFF2EBF3B).withValues(alpha: 0.45),
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Customer Credit Offer',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Points: ${rewardPoints.toStringAsFixed(0)} / ${pointsNeeded.toStringAsFixed(0)}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                          if (isNewCustomer)
                            const Text(
                              'New customer: points start from this completed bill.',
                              style: TextStyle(
                                color: Colors.orangeAccent,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          Text(
                            'Completed bills used: $completedBillsCount | ₹${completedSpendAmount.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                          const Text(
                            'Only completed bills earn points.',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                          Text(
                            offerEligible
                                ? 'Eligible: Offer discount ₹${offerAmount.toStringAsFixed(2)}'
                                : 'Need ${remainingPoints.toStringAsFixed(0)} more points',
                            style: TextStyle(
                              color: offerEligible
                                  ? const Color(0xFF2EBF3B)
                                  : Colors.orangeAccent,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (!offerEligible && remainingSpend > 0)
                            Text(
                              'Spend ₹${remainingSpend.toStringAsFixed(2)} more to unlock offer',
                              style: const TextStyle(
                                color: Colors.orangeAccent,
                                fontSize: 12,
                              ),
                            ),
                          if (historyBasedEligible && !serverEligible)
                            const Text(
                              'Eligible from completed history. Final offer is validated on submit.',
                              style: TextStyle(
                                color: Colors.orangeAccent,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          if (hasEligibleItemLevelOffer)
                            Text(
                              'Blocked by higher-priority offer: ${highestPriorityAppliedPreviewName ?? 'Item-level offer'}.',
                              style: const TextStyle(
                                color: Colors.orangeAccent,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          const SizedBox(height: 8),
                          IgnorePointer(
                            ignoring: !canApplyCustomerOffer,
                            child: Opacity(
                              opacity: canApplyCustomerOffer ? 1 : 0.5,
                              child: CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: const Text(
                                  'Apply customer offer on this bill',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                                value: effectiveApplyCustomerOffer,
                                onChanged: (value) {
                                  setDialogState(() {
                                    applyCustomerOffer = value == true;
                                  });
                                },
                                activeColor: const Color(0xFF2EBF3B),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Bill total: ₹${billTotal.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            'Offer discount: ₹${previewDiscount.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: Color(0xFF2EBF3B),
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            'Remaining payable: ₹${previewPayable.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (productOfferEnabled && productOfferMatches.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121729),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: const Color(0xFF0A84FF).withValues(alpha: 0.45),
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Product to Product Offer',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          ...productOfferMatches.map((match) {
                            final buyProductName =
                                match['buyProductName']?.toString() ??
                                'Buy Product';
                            final freeProductName =
                                match['freeProductName']?.toString() ??
                                'Free Product';
                            final buyQtyStep = readMoney(
                              match['buyQuantityStep'],
                            );
                            final buyQtyInCart = readMoney(
                              match['buyQuantityInCart'],
                            );
                            final freeQtyStep = readMoney(
                              match['freeQuantityStep'],
                            );
                            final freeQtyApplied = readMoney(
                              match['predictedFreeQuantity'],
                            );
                            final remainingQty = readMoney(
                              match['remainingBuyQuantity'],
                            );
                            final buyUnitPrice = readMoney(
                              match['buyUnitPrice'],
                            );
                            final freeUnitPrice = readMoney(
                              match['freeUnitPrice'],
                            );
                            final estimatedDiscount = readMoney(
                              match['estimatedDiscount'],
                            );
                            final isEligible = match['eligible'] == true;
                            final usageLimitEnabled =
                                match['usageLimitEnabled'] == true;
                            final usageLimitReached =
                                match['usageLimitReached'] == true;
                            final globalLimitReached =
                                match['globalLimitReached'] == true;
                            final customerLimitReached =
                                match['customerLimitReached'] == true;
                            final blockedWithoutCustomer =
                                match['blockedWithoutCustomer'] == true;
                            final blockedForNewCustomer =
                                match['blockedForNewCustomer'] == true;
                            final nextBillMessage = match['nextBillMessage']
                                ?.toString();
                            final maxOfferCount = readMoney(
                              match['maxOfferCount'],
                            );
                            final offerGivenCount = readMoney(
                              match['offerGivenCount'],
                            );
                            final globalRemaining = readMoney(
                              match['globalRemaining'],
                            );
                            final maxCustomerCount = readMoney(
                              match['maxCustomerCount'],
                            );
                            final offerCustomerCount = readMoney(
                              match['offerCustomerCount'],
                            );
                            final customerRemaining = readMoney(
                              match['customerRemaining'],
                            );
                            final maxUsagePerCustomer = readMoney(
                              match['maxUsagePerCustomer'],
                            );
                            final customerUsageCount = readMoney(
                              match['customerUsageCount'],
                            );
                            final customerUsageRemaining = readMoney(
                              match['customerUsageRemaining'],
                            );

                            return Container(
                              width: double.infinity,
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.08),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Buy $buyProductName x${formatQty(buyQtyStep)} (₹${buyUnitPrice.toStringAsFixed(2)})',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    'In cart: ${formatQty(buyQtyInCart)}',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Text(
                                    'Get $freeProductName x${formatQty(freeQtyStep)} FREE (₹${freeUnitPrice.toStringAsFixed(2)})',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                  if (maxOfferCount > 0)
                                    Text(
                                      'Global usage: ${formatQty(offerGivenCount)} / ${formatQty(maxOfferCount)} (remaining ${formatQty(globalRemaining)})',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),
                                  if (maxCustomerCount > 0)
                                    Text(
                                      'Customer count: ${formatQty(offerCustomerCount)} / ${formatQty(maxCustomerCount)} (remaining ${formatQty(customerRemaining)})',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),
                                  if (usageLimitEnabled)
                                    Text(
                                      'Usage: ${formatQty(customerUsageCount)} / ${formatQty(maxUsagePerCustomer)}',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),
                                  const SizedBox(height: 4),
                                  Text(
                                    blockedForNewCustomer
                                        ? (nextBillMessage ??
                                              'This offer will be available from next bill after customer is created.')
                                        : blockedWithoutCustomer
                                        ? 'Customer is required for usage/customer limits.'
                                        : globalLimitReached
                                        ? 'Global offer limit reached.'
                                        : customerLimitReached
                                        ? 'Customer-count limit reached.'
                                        : usageLimitReached
                                        ? 'Usage limit reached for this customer.'
                                        : isEligible
                                        ? 'Potential free: $freeProductName x${formatQty(freeQtyApplied)} | Est. discount ₹${estimatedDiscount.toStringAsFixed(2)}'
                                        : 'Need ${formatQty(remainingQty)} more $buyProductName',
                                    style: TextStyle(
                                      color: blockedForNewCustomer
                                          ? Colors.orangeAccent
                                          : blockedWithoutCustomer ||
                                                globalLimitReached ||
                                                customerLimitReached ||
                                                usageLimitReached
                                          ? Colors.redAccent
                                          : isEligible
                                          ? const Color(0xFF2EBF3B)
                                          : Colors.orangeAccent,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (usageLimitEnabled &&
                                      !blockedForNewCustomer &&
                                      !usageLimitReached &&
                                      customerUsageRemaining > 0)
                                    Text(
                                      'Remaining uses: ${formatQty(customerUsageRemaining)}',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),
                                ],
                              ),
                            );
                          }),
                          const SizedBox(height: 4),
                          const Text(
                            'Preview only. Final free item and discount are applied by server on submit.',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (productPriceOfferEnabled &&
                    productPriceOfferMatches.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A1912),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: const Color(0xFFFF9F0A).withValues(alpha: 0.45),
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Product Price Offer',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          ...productPriceOfferMatches.map((match) {
                            final productName =
                                match['productName']?.toString() ?? 'Product';
                            final quantityInCart = readMoney(
                              match['quantityInCart'],
                            );
                            final baseUnitPrice = readMoney(
                              match['baseUnitPrice'],
                            );
                            final discountPerUnit = readMoney(
                              match['discountPerUnit'],
                            );
                            final offerUnitPrice = readMoney(
                              match['offerUnitPrice'],
                            );
                            final predictedAppliedUnits = readMoney(
                              match['predictedAppliedUnits'],
                            );
                            final predictedDiscountTotal = readMoney(
                              match['predictedDiscountTotal'],
                            );
                            final predictedSubtotal = readMoney(
                              match['predictedSubtotal'],
                            );
                            final predictedEffectiveUnitPrice = readMoney(
                              match['predictedEffectiveUnitPrice'],
                            );
                            final usageLimitEnabled =
                                match['usageLimitEnabled'] == true;
                            final usageLimitReached =
                                match['usageLimitReached'] == true;
                            final globalLimitReached =
                                match['globalLimitReached'] == true;
                            final customerLimitReached =
                                match['customerLimitReached'] == true;
                            final blockedWithoutCustomer =
                                match['blockedWithoutCustomer'] == true;
                            final blockedForNewCustomer =
                                match['blockedForNewCustomer'] == true;
                            final nextBillMessage = match['nextBillMessage']
                                ?.toString();
                            final maxOfferCount = readMoney(
                              match['maxOfferCount'],
                            );
                            final offerGivenCount = readMoney(
                              match['offerGivenCount'],
                            );
                            final globalRemaining = readMoney(
                              match['globalRemaining'],
                            );
                            final maxCustomerCount = readMoney(
                              match['maxCustomerCount'],
                            );
                            final offerCustomerCount = readMoney(
                              match['offerCustomerCount'],
                            );
                            final customerRemaining = readMoney(
                              match['customerRemaining'],
                            );
                            final maxUsagePerCustomer = readMoney(
                              match['maxUsagePerCustomer'],
                            );
                            final customerUsageCount = readMoney(
                              match['customerUsageCount'],
                            );
                            final customerUsageRemaining = readMoney(
                              match['customerUsageRemaining'],
                            );
                            final isEligible = match['eligible'] == true;

                            return Container(
                              width: double.infinity,
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.08),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '$productName x${formatQty(quantityInCart)}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    'Unit: ₹${baseUnitPrice.toStringAsFixed(2)} | Discount: ₹${discountPerUnit.toStringAsFixed(2)} | Pay: ₹${offerUnitPrice.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                  if (maxOfferCount > 0)
                                    Text(
                                      'Global usage: ${formatQty(offerGivenCount)} / ${formatQty(maxOfferCount)} (remaining ${formatQty(globalRemaining)})',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),
                                  if (maxCustomerCount > 0)
                                    Text(
                                      'Customer count: ${formatQty(offerCustomerCount)} / ${formatQty(maxCustomerCount)} (remaining ${formatQty(customerRemaining)})',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),
                                  if (usageLimitEnabled)
                                    Text(
                                      'Usage: ${formatQty(customerUsageCount)} / ${formatQty(maxUsagePerCustomer)}',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),
                                  const SizedBox(height: 4),
                                  Text(
                                    blockedForNewCustomer
                                        ? (nextBillMessage ??
                                              'This offer will be available from next bill after customer is created.')
                                        : blockedWithoutCustomer
                                        ? 'Customer is required for usage/customer limits.'
                                        : globalLimitReached
                                        ? 'Global offer limit reached.'
                                        : customerLimitReached
                                        ? 'Customer-count limit reached.'
                                        : usageLimitReached
                                        ? 'Usage limit reached for this customer.'
                                        : isEligible
                                        ? 'Discounted units: ${formatQty(predictedAppliedUnits)} | Est. discount ₹${predictedDiscountTotal.toStringAsFixed(2)}'
                                        : 'No eligible discounted units in current cart.',
                                    style: TextStyle(
                                      color: blockedForNewCustomer
                                          ? Colors.orangeAccent
                                          : blockedWithoutCustomer ||
                                                globalLimitReached ||
                                                customerLimitReached ||
                                                usageLimitReached
                                          ? Colors.redAccent
                                          : isEligible
                                          ? const Color(0xFF2EBF3B)
                                          : Colors.orangeAccent,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    'Preview subtotal: ₹${predictedSubtotal.toStringAsFixed(2)} | Effective unit: ₹${predictedEffectiveUnitPrice.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                  if (usageLimitEnabled &&
                                      !blockedForNewCustomer &&
                                      !usageLimitReached &&
                                      customerUsageRemaining > 0)
                                    Text(
                                      'Remaining discounted units: ${formatQty(customerUsageRemaining)}',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),
                                ],
                              ),
                            );
                          }),
                          const SizedBox(height: 4),
                          const Text(
                            'Preview only. Final price-offer units and totals are applied by server on submit.',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (customerEntryPercentageOfferEnabled)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF132323),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: const Color(0xFF26C6DA).withValues(alpha: 0.45),
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: Builder(
                        builder: (context) {
                          final discountPercent = readMoney(
                            customerEntryPercentageOfferData?['discountPercent'],
                          );
                          final scheduleMatched =
                              customerEntryPercentageOfferData?['scheduleMatched'] ==
                              true;
                          final scheduleBlocked =
                              customerEntryPercentageOfferData?['scheduleBlocked'] ==
                              true;

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Customer Entry Percentage Offer',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Discount: ${discountPercent.toStringAsFixed(2)}%',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              const Text(
                                'No checkbox needed. Backend applies this on completed bill.',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              const Text(
                                'Compulsory when enabled and schedule is active.',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              Text(
                                'Schedule: ${scheduleMatched ? 'active now' : 'outside active window'}',
                                style: TextStyle(
                                  color: scheduleMatched
                                      ? Colors.white70
                                      : Colors.orangeAccent,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                scheduleBlocked
                                    ? 'Offer is outside active date/time window.'
                                    : customerEntryPercentagePreviewEligible
                                    ? 'Eligible preview. Final discount comes from backend on submit.'
                                    : 'Final eligibility is checked by backend on submit.',
                                style: TextStyle(
                                  color: scheduleBlocked
                                      ? Colors.orangeAccent
                                      : customerEntryPercentagePreviewEligible
                                      ? const Color(0xFF2EBF3B)
                                      : Colors.white70,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'This offer does not stack with Total Percentage Offer.',
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                ),
                              ),
                              const Text(
                                'Final payable uses backend totalAmount after submit.',
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                if (totalPercentageOfferEnabled)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F172B),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: const Color(0xFF9B7DFF).withValues(alpha: 0.45),
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: Builder(
                        builder: (context) {
                          final discountPercent = readMoney(
                            totalPercentageOfferData?['discountPercent'],
                          );
                          final maxOfferCount = readMoney(
                            totalPercentageOfferData?['maxOfferCount'],
                          );
                          final maxCustomerCount = readMoney(
                            totalPercentageOfferData?['maxCustomerCount'],
                          );
                          final maxUsagePerCustomer = readMoney(
                            totalPercentageOfferData?['maxUsagePerCustomer'],
                          );
                          final givenCount = readMoney(
                            totalPercentageOfferData?['givenCount'],
                          );
                          final customerCount = readMoney(
                            totalPercentageOfferData?['customerCount'],
                          );
                          final usageForCustomer = readMoney(
                            totalPercentageOfferData?['usageForCustomer'],
                          );
                          final globalRemaining = readMoney(
                            totalPercentageOfferData?['globalRemaining'],
                          );
                          final customerRemaining = readMoney(
                            totalPercentageOfferData?['customerRemaining'],
                          );
                          final usageRemaining = readMoney(
                            totalPercentageOfferData?['usageRemaining'],
                          );
                          final blockedWithoutCustomer =
                              totalPercentageOfferData?['blockedWithoutCustomer'] ==
                              true;
                          final globalLimitReached =
                              totalPercentageOfferData?['globalLimitReached'] ==
                              true;
                          final customerLimitReached =
                              totalPercentageOfferData?['customerLimitReached'] ==
                              true;
                          final usageLimitReached =
                              totalPercentageOfferData?['usageLimitReached'] ==
                              true;
                          final randomOnly =
                              totalPercentageOfferData?['randomOnly'] == true;
                          final randomSelectionChancePercent = readMoney(
                            totalPercentageOfferData?['randomSelectionChancePercent'],
                          );
                          final randomGatePassed =
                              totalPercentageOfferData?['randomGatePassed'] ==
                              true;
                          final randomGateBlocked =
                              totalPercentageOfferData?['randomGateBlocked'] ==
                              true;
                          final scheduleMatched =
                              totalPercentageOfferData?['scheduleMatched'] ==
                              true;
                          final scheduleBlocked =
                              totalPercentageOfferData?['scheduleBlocked'] ==
                              true;
                          final blockedByHigherPriority =
                              highestPriorityAppliedPreviewName != null;
                          final hasLimitBlock =
                              blockedWithoutCustomer ||
                              globalLimitReached ||
                              customerLimitReached ||
                              usageLimitReached;
                          final hasGatingBlock =
                              randomGateBlocked || scheduleBlocked;
                          final amountAfterCustomerOffer =
                              (billTotal - previewDiscount)
                                  .clamp(0.0, double.infinity)
                                  .toDouble();
                          final canEstimatePercentageDiscount =
                              discountPercent > 0 &&
                              !hasLimitBlock &&
                              !hasGatingBlock &&
                              !blockedByHigherPriority;
                          final estimatedPercentageDiscount =
                              canEstimatePercentageDiscount
                              ? double.parse(
                                  (amountAfterCustomerOffer *
                                          discountPercent /
                                          100)
                                      .toStringAsFixed(2),
                                )
                              : 0.0;
                          final estimatedPayableAfterPercentage =
                              (amountAfterCustomerOffer -
                                      estimatedPercentageDiscount)
                                  .clamp(0.0, double.infinity)
                                  .toDouble();

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Total Amount Percentage Offer',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Discount: ${discountPercent.toStringAsFixed(2)}%',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              Text(
                                'No checkbox needed. Backend auto-applies when eligible.',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              Text(
                                'Order: Gross -> Customer offer -> Percentage offer -> Final total',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              if (randomOnly)
                                Text(
                                  'Random-only mode: ${randomSelectionChancePercent.toStringAsFixed(2)}% chance (${randomGatePassed ? 'passed' : 'not selected'})',
                                  style: TextStyle(
                                    color: randomGatePassed
                                        ? Colors.white70
                                        : Colors.orangeAccent,
                                    fontSize: 12,
                                  ),
                                ),
                              Text(
                                'Schedule: ${scheduleMatched ? 'active now' : 'outside active window'}',
                                style: TextStyle(
                                  color: scheduleMatched
                                      ? Colors.white70
                                      : Colors.orangeAccent,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                maxOfferCount > 0
                                    ? 'Global usage: ${formatQty(givenCount)} / ${formatQty(maxOfferCount)} (remaining ${formatQty(globalRemaining)})'
                                    : 'Global usage: unlimited',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              Text(
                                maxCustomerCount > 0
                                    ? 'Customer count: ${formatQty(customerCount)} / ${formatQty(maxCustomerCount)} (remaining ${formatQty(customerRemaining)})'
                                    : 'Customer count limit: unlimited',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              Text(
                                maxUsagePerCustomer > 0
                                    ? 'Your usage: ${formatQty(usageForCustomer)} / ${formatQty(maxUsagePerCustomer)} (remaining ${formatQty(usageRemaining)})'
                                    : 'Per-customer usage limit: unlimited',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Bill total: ₹${billTotal.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              if (previewDiscount > 0)
                                Text(
                                  'Credit offer discount: ₹${previewDiscount.toStringAsFixed(2)}',
                                  style: const TextStyle(
                                    color: Color(0xFF2EBF3B),
                                    fontSize: 12,
                                  ),
                                ),
                              Text(
                                canEstimatePercentageDiscount
                                    ? 'Percentage offer discount (est.): ₹${estimatedPercentageDiscount.toStringAsFixed(2)}'
                                    : 'Percentage offer discount (est.): ₹0.00',
                                style: TextStyle(
                                  color: canEstimatePercentageDiscount
                                      ? const Color(0xFF9B7DFF)
                                      : Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              Text(
                                'Estimated payable: ₹${estimatedPayableAfterPercentage.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const Text(
                                'Final payable uses backend totalAmount after submit.',
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                blockedByHigherPriority
                                    ? 'Blocked by higher-priority offer: $highestPriorityAppliedPreviewName.'
                                    : blockedWithoutCustomer
                                    ? 'Phone number is required for customer-limit checks.'
                                    : scheduleBlocked
                                    ? 'Percentage offer is outside active date/time window.'
                                    : randomGateBlocked
                                    ? 'Random selection not hit for percentage offer.'
                                    : globalLimitReached
                                    ? 'Global percentage-offer limit reached.'
                                    : customerLimitReached
                                    ? 'Customer-count limit reached.'
                                    : usageLimitReached
                                    ? 'Per-customer usage limit reached.'
                                    : 'Limits look open. Final eligibility is checked by backend on submit.',
                                style: TextStyle(
                                  color:
                                      blockedByHigherPriority ||
                                          hasLimitBlock ||
                                          hasGatingBlock
                                      ? Colors.orangeAccent
                                      : const Color(0xFF2EBF3B),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                if (randomCustomerOfferEligible)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF102229),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: const Color(0xFF00B8D9).withValues(alpha: 0.45),
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Random Customer Offer',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          if (randomOfferCampaignCode.isNotEmpty)
                            Text(
                              'Campaign: $randomOfferCampaignCode',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          if (randomCustomerOfferSelectedMatch != null) ...[
                            (() {
                              final match = randomCustomerOfferSelectedMatch!;
                              final productName =
                                  match['productName']?.toString() ?? 'Product';
                              final remainingCount = readMoney(
                                match['remainingCount'],
                              );
                              final usageLimitEnabled =
                                  match['usageLimitEnabled'] == true;
                              final maxUsagePerCustomer = readMoney(
                                match['maxUsagePerCustomer'],
                              );
                              final customerUsageCount = readMoney(
                                match['customerUsageCount'],
                              );
                              final customerUsageRemaining = readMoney(
                                match['customerUsageRemaining'],
                              );
                              return Container(
                                width: double.infinity,
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.08),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '$productName (Free x1)',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      'Remaining winners: ${formatQty(remainingCount)}',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),
                                    if (usageLimitEnabled)
                                      Text(
                                        'Usage: ${formatQty(customerUsageCount)} / ${formatQty(maxUsagePerCustomer)} | Remaining: ${formatQty(customerUsageRemaining)}',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 12,
                                        ),
                                      ),
                                  ],
                                ),
                              );
                            })(),
                          ],
                          const Text(
                            'Eligible now. Server will add one random free item on submit.',
                            style: TextStyle(
                              color: Color(0xFF2EBF3B),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (isNewCustomer)
                            const Text(
                              'New customer is supported. Backend creates customer on completed bill.',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          const SizedBox(height: 4),
                          const Text(
                            'Preview only. Final random offer check is done by server on submit.',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ];
              int runningCardIndex = 0;
              int? creditCardIndex;
              int? productToProductCardIndex;
              int? productPriceCardIndex;
              int? totalPercentageCardIndex;
              int? customerEntryPercentageCardIndex;
              int? randomCardIndex;

              if (offerEnabled) {
                creditCardIndex = runningCardIndex++;
              }
              if (productOfferEnabled && productOfferMatches.isNotEmpty) {
                productToProductCardIndex = runningCardIndex++;
              }
              if (productPriceOfferEnabled &&
                  productPriceOfferMatches.isNotEmpty) {
                productPriceCardIndex = runningCardIndex++;
              }
              if (customerEntryPercentageOfferEnabled) {
                customerEntryPercentageCardIndex = runningCardIndex++;
              }
              if (totalPercentageOfferEnabled) {
                totalPercentageCardIndex = runningCardIndex++;
              }
              if (randomCustomerOfferEligible) {
                randomCardIndex = runningCardIndex++;
              }

              int? primaryOfferCardIndex;
              if (hasEligibleProductOffer &&
                  productToProductCardIndex != null) {
                primaryOfferCardIndex = productToProductCardIndex;
              } else if (hasEligibleProductPriceOffer &&
                  productPriceCardIndex != null) {
                primaryOfferCardIndex = productPriceCardIndex;
              } else if (hasEligibleRandomOffer && randomCardIndex != null) {
                primaryOfferCardIndex = randomCardIndex;
              } else if (effectiveApplyCustomerOffer &&
                  creditCardIndex != null) {
                primaryOfferCardIndex = creditCardIndex;
              } else if (totalPercentageCardIndex != null) {
                primaryOfferCardIndex = totalPercentageCardIndex;
              } else if (canApplyCustomerOffer && creditCardIndex != null) {
                primaryOfferCardIndex = creditCardIndex;
              } else if (productToProductCardIndex != null) {
                primaryOfferCardIndex = productToProductCardIndex;
              } else if (productPriceCardIndex != null) {
                primaryOfferCardIndex = productPriceCardIndex;
              } else if (randomCardIndex != null) {
                primaryOfferCardIndex = randomCardIndex;
              } else if (totalPercentageCardIndex != null) {
                primaryOfferCardIndex = totalPercentageCardIndex;
              }

              final focusedCards = <Widget>[];
              if (primaryOfferCardIndex != null &&
                  primaryOfferCardIndex >= 0 &&
                  primaryOfferCardIndex < offerCards.length) {
                focusedCards.add(offerCards[primaryOfferCardIndex]);
              }
              if (customerEntryPercentageCardIndex != null &&
                  customerEntryPercentageCardIndex >= 0 &&
                  customerEntryPercentageCardIndex < offerCards.length &&
                  customerEntryPercentagePreviewEligible) {
                final customerEntryCard =
                    offerCards[customerEntryPercentageCardIndex];
                if (!focusedCards.contains(customerEntryCard)) {
                  focusedCards.add(customerEntryCard);
                }
              }
              if (focusedCards.isEmpty &&
                  customerEntryPercentageCardIndex != null &&
                  customerEntryPercentageCardIndex >= 0 &&
                  customerEntryPercentageCardIndex < offerCards.length) {
                focusedCards.add(offerCards[customerEntryPercentageCardIndex]);
              }
              if (focusedCards.isNotEmpty &&
                  focusedCards.length < offerCards.length) {
                offerCards
                  ..clear()
                  ..addAll(focusedCards);
                offerPageIndex = 0;
              }
              if (offerPageIndex >= offerCards.length) {
                offerPageIndex = 0;
              }

              return Dialog(
                backgroundColor: const Color(0xFF1E1E1E),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                insetPadding: const EdgeInsets.symmetric(horizontal: 28),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: dialogMaxHeight),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
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
                              Text(
                                "Phone Number",
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                ),
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
                                  onChanged: (val) {
                                    setDialogState(() {});
                                    debounceTimer?.cancel();
                                    debounceTimer = Timer(
                                      const Duration(milliseconds: 500),
                                      () => lookupCustomer(val, setDialogState),
                                    );
                                  },
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
                              if (isLookupInProgress) ...[
                                const SizedBox(height: 10),
                                const Center(
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Color(0xFF0A84FF),
                                    ),
                                  ),
                                ),
                              ],
                              if (lookupError != null) ...[
                                const SizedBox(height: 10),
                                Text(
                                  lookupError!,
                                  style: const TextStyle(
                                    color: Colors.redAccent,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 18),
                              Text(
                                "Customer Name",
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                ),
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
                              if (customerLookupData != null) ...[
                                const SizedBox(height: 14),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF121212),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: 0.12,
                                      ),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Customer: ${(() {
                                          final lookupName = customerLookupData!['name']?.toString().trim() ?? '';
                                          if (lookupName.isNotEmpty) {
                                            return lookupName;
                                          }
                                          if (customerLookupData!['isNewCustomer'] == true) {
                                            return 'New customer';
                                          }
                                          return 'N/A';
                                        })()}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        'History: ${customerLookupData!['totalBills'] ?? 0} bills | ₹${readMoney(customerLookupData!['totalAmount']).toStringAsFixed(2)} spent',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              if (hasOfferPreview && offerCards.isNotEmpty) ...[
                                const SizedBox(height: 12),
                                const Text(
                                  'Up to 2 offers per bill: Customer Entry Percentage + one backend-selected offer path.',
                                  style: TextStyle(
                                    color: Colors.white54,
                                    fontSize: 11,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                SizedBox(
                                  height: 250,
                                  child: PageView.builder(
                                    reverse: false,
                                    itemCount: offerCards.length,
                                    onPageChanged: (index) {
                                      setDialogState(() {
                                        offerPageIndex = index;
                                      });
                                    },
                                    itemBuilder: (context, index) {
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 2,
                                        ),
                                        child: offerCards[index],
                                      );
                                    },
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: List.generate(offerCards.length, (
                                    index,
                                  ) {
                                    final isActive = index == offerPageIndex;
                                    return AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 180,
                                      ),
                                      margin: const EdgeInsets.symmetric(
                                        horizontal: 3,
                                      ),
                                      width: isActive ? 9 : 6,
                                      height: isActive ? 9 : 6,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: isActive
                                            ? const Color(0xFF0A84FF)
                                            : Colors.white24,
                                      ),
                                    );
                                  }),
                                ),
                              ],
                              const SizedBox(height: 28),
                              if (allowSkipForActiveFlow)
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton(
                                        onPressed: () {
                                          debounceTimer?.cancel();
                                          Navigator.pop(
                                            context,
                                            <String, dynamic>{},
                                          );
                                        },
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: Colors.white70,
                                          side: BorderSide(
                                            color: Colors.white24,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 12,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                          ),
                                        ),
                                        child: const Text("Skip"),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: ElevatedButton(
                                        onPressed: () {
                                          final customerName = nameCtrl.text
                                              .trim();
                                          final customerPhone = phoneCtrl.text
                                              .trim();
                                          if (customerName.isEmpty &&
                                              customerPhone.isEmpty) {
                                            if (!mounted) return;
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                  "Please enter customer name or phone number, or use Skip",
                                                ),
                                              ),
                                            );
                                            return;
                                          }
                                          debounceTimer?.cancel();
                                          Navigator.pop(
                                            context,
                                            <String, dynamic>{
                                              'name': customerName,
                                              'phone': customerPhone,
                                              'applyCustomerOffer':
                                                  effectiveApplyCustomerOffer,
                                              'hasProductOfferMatch':
                                                  hasEligibleProductOffer,
                                              'hasProductPriceOfferMatch':
                                                  hasEligibleProductPriceOffer,
                                              'hasTotalPercentageOfferEnabled':
                                                  totalPercentageOfferEnabled,
                                              'hasRandomOfferMatch':
                                                  hasEligibleRandomOffer,
                                            },
                                          );
                                        },
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(
                                            0xFF0A84FF,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 12,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
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
                                )
                              else
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    onPressed: () {
                                      final customerName = nameCtrl.text.trim();
                                      final customerPhone = phoneCtrl.text
                                          .trim();
                                      if (customerName.isEmpty &&
                                          customerPhone.isEmpty) {
                                        if (!mounted) return;
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              "Please enter customer name or phone number",
                                            ),
                                          ),
                                        );
                                        return;
                                      }
                                      debounceTimer?.cancel();
                                      Navigator.pop(context, <String, dynamic>{
                                        'name': customerName,
                                        'phone': customerPhone,
                                        'applyCustomerOffer':
                                            effectiveApplyCustomerOffer,
                                        'hasProductOfferMatch':
                                            hasEligibleProductOffer,
                                        'hasProductPriceOfferMatch':
                                            hasEligibleProductPriceOffer,
                                        'hasTotalPercentageOfferEnabled':
                                            totalPercentageOfferEnabled,
                                        'hasRandomOfferMatch':
                                            hasEligibleRandomOffer,
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
                              if (phoneCtrl.text.length >= 10) ...[
                                const SizedBox(height: 20),
                                Center(
                                  child: InkWell(
                                    onTap: () {
                                      showDialog(
                                        context: context,
                                        builder: (context) =>
                                            CustomerHistoryDialog(
                                              phoneNumber: phoneCtrl.text
                                                  .trim(),
                                            ),
                                      );
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.green.shade700,
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.history,
                                            color: Colors.white,
                                            size: 18,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            "Customer History",
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        right: 8,
                        top: 8,
                        child: IconButton(
                          icon: const Icon(Icons.close, color: Colors.white54),
                          onPressed: () {
                            debounceTimer?.cancel();
                            Navigator.pop(context, null);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );

      if (customerDetails == null) {
        setState(() => _isBillingInProgress = false);
        return;
      }
    } else {
      if (status != 'pending' && !showCustomerDetailsForActiveFlow) {
        cartProvider.setCustomerDetails();
        customerDetails = {'name': '', 'phone': ''};
      } else {
        // For KOT/RE-KOT (pending), use existing details or empty map
        customerDetails = {
          'name': cartProvider.customerName ?? '',
          'phone': cartProvider.customerPhone ?? '',
        };
      }
    }

    final shouldApplyCustomerOffer =
        status == 'completed' &&
        (customerDetails['applyCustomerOffer'] == true);
    final hasProductOfferMatch =
        customerDetails['hasProductOfferMatch'] == true;
    final hasProductPriceOfferMatch =
        customerDetails['hasProductPriceOfferMatch'] == true;
    final hasTotalPercentageOfferEnabled =
        customerDetails['hasTotalPercentageOfferEnabled'] == true;
    final hasRandomOfferMatch = customerDetails['hasRandomOfferMatch'] == true;
    String billingCustomerName =
        (customerDetails['name'] ?? cartProvider.customerName ?? '')
            .toString()
            .trim();
    String billingCustomerPhone =
        (customerDetails['phone'] ?? cartProvider.customerPhone ?? '')
            .toString()
            .trim();
    final requiresPhoneForOffer =
        status == 'completed' &&
        (shouldApplyCustomerOffer ||
            hasProductOfferMatch ||
            hasProductPriceOfferMatch ||
            hasTotalPercentageOfferEnabled ||
            hasRandomOfferMatch);

    String? tableNumberForSubmit = cartProvider.selectedTable;
    String? sectionForSubmit = cartProvider.selectedSection;

    if (status == 'pending' &&
        cartProvider.currentType == CartType.table &&
        cartProvider.isSharedTableOrder) {
      final typedSharedTable = _sharedTableController.text.trim();
      final existingTable = tableNumberForSubmit?.trim() ?? '';
      final resolvedTable = typedSharedTable.isNotEmpty
          ? typedSharedTable
          : existingTable;

      if (resolvedTable.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter table number for shared KOT')),
        );
        setState(() => _isBillingInProgress = false);
        return;
      }

      tableNumberForSubmit = resolvedTable;
      sectionForSubmit = CartProvider.sharedTablesSectionName;
      if (cartProvider.selectedTable != tableNumberForSubmit ||
          cartProvider.selectedSection != sectionForSubmit) {
        cartProvider.setSelectedTableMetadata(
          tableNumberForSubmit,
          sectionForSubmit,
        );
      }
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

      String? parseAnyId(dynamic value) {
        if (value == null) return null;
        if (value is String) return value;
        if (value is num) return value.toString();
        if (value is Map) {
          final map = Map<String, dynamic>.from(value);
          final id = map['id'] ?? map['_id'] ?? map[r'$oid'];
          if (id is String) return id;
          if (id is num) return id.toString();
        }
        return null;
      }

      String? resolveRelationId(dynamic value) {
        if (value == null) return null;
        if (value is String) return value;
        if (value is num) return value.toString();
        if (value is Map) {
          final map = Map<String, dynamic>.from(value);
          final id = map['id'] ?? map['_id'] ?? map[r'$oid'];
          if (id is String) return id;
          if (id is num) return id.toString();
        }
        return null;
      }

      double toNonNegativeDouble(dynamic value) {
        if (value is num) {
          final parsed = value.toDouble();
          return parsed < 0 ? 0 : parsed;
        }
        if (value is String) {
          final parsed = double.tryParse(value);
          if (parsed == null) return 0;
          return parsed < 0 ? 0 : parsed;
        }
        return 0;
      }

      Map<String, dynamic>? toPurchasedPatchItem(Map<String, dynamic> rawItem) {
        final notesValue = (rawItem['notes'] ?? rawItem['specialNote'] ?? '')
            .toString()
            .trim();
        final isOfferFreeItem = rawItem['isOfferFreeItem'] == true;
        final isRandomCustomerOfferItem =
            rawItem['isRandomCustomerOfferItem'] == true ||
            notesValue.toUpperCase() == 'RANDOM CUSTOMER OFFER';
        if (isOfferFreeItem || isRandomCustomerOfferItem) {
          return null;
        }

        final productId =
            resolveRelationId(rawItem['product']) ?? rawItem['product'];
        if (productId == null || productId.toString().trim().isEmpty) {
          return null;
        }

        final quantity = toNonNegativeDouble(rawItem['quantity']) > 0
            ? toNonNegativeDouble(rawItem['quantity'])
            : 1.0;
        final unitPrice = toNonNegativeDouble(
          rawItem['unitPrice'] ??
              rawItem['price'] ??
              rawItem['effectiveUnitPrice'],
        );
        final subtotal = rawItem.containsKey('subtotal')
            ? toNonNegativeDouble(rawItem['subtotal'])
            : quantity * unitPrice;

        final payload = <String, dynamic>{
          if (rawItem['id'] != null) 'id': rawItem['id'].toString(),
          'product': productId,
          'name': rawItem['name']?.toString() ?? 'Item',
          'quantity': quantity,
          'unitPrice': unitPrice,
          'subtotal': subtotal,
        };

        final status = rawItem['status']?.toString();
        if (status != null && status.isNotEmpty) {
          payload['status'] = status;
        }

        final noteValue = rawItem['specialNote'] ?? rawItem['notes'];
        if (noteValue != null && noteValue.toString().trim().isNotEmpty) {
          payload['specialNote'] = noteValue.toString();
        }

        final unit = rawItem['unit']?.toString();
        if (unit != null && unit.isNotEmpty) {
          payload['unit'] = unit;
        }

        return payload;
      }

      Map<String, dynamic>? toPurchasedCartItemPayload(CartItem item) {
        if (item.isOfferFreeItem || item.isRandomCustomerOfferItem) {
          return null;
        }

        final payload = item.toBillingPayload(
          includeSubtotal: true,
          includeBranchOverride: true,
          branchOverrideValue: _branchId != null,
        );

        payload.remove('isOfferFreeItem');
        payload.remove('offerRuleKey');
        payload.remove('offerTriggerProduct');
        payload.remove('isRandomCustomerOfferItem');
        payload.remove('randomCustomerOfferCampaignCode');
        payload.remove('isPriceOfferApplied');
        payload.remove('priceOfferRuleKey');
        payload.remove('priceOfferDiscountPerUnit');
        payload.remove('priceOfferAppliedUnits');
        payload.remove('effectiveUnitPrice');

        return payload;
      }

      bool hasActiveLookupItems(dynamic rawItems) {
        if (rawItems is! List || rawItems.isEmpty) return false;
        for (final rawItem in rawItems) {
          if (rawItem is! Map) continue;
          final status =
              rawItem['status']?.toString().toLowerCase().trim() ?? '';
          if (status != 'cancelled') {
            return true;
          }
        }
        return false;
      }

      // 1. Combine active cart items with previously ordered items
      // OLD LOGIC: Merged by product ID (caused "2x Tea" instead of "1 Tea, 1 Tea")
      // NEW LOGIC: Just append new items to the list. Server handles them as separate subdocs.

      final List<CartItem> mergedItems = [];

      // Add all recalled items (already ordered)
      mergedItems.addAll(cartProvider.recalledItems);

      // Add all new cart items (new orders)
      mergedItems.addAll(cartProvider.cartItems);

      final hasTableNumberForSubmit =
          tableNumberForSubmit?.trim().isNotEmpty == true;
      final hasSectionForSubmit = sectionForSubmit?.trim().isNotEmpty == true;
      final isTableOrderForSubmit =
          cartProvider.currentType == CartType.table &&
          (hasTableNumberForSubmit || hasSectionForSubmit);

      String? billId = cartProvider.recalledBillId;
      final List<Map<String, dynamic>> existingServerItemsPayload = [];
      if (isTableOrderForSubmit &&
          billId == null &&
          hasTableNumberForSubmit &&
          hasSectionForSubmit) {
        final lookupNow = DateTime.now();
        final lookupDayStart = DateTime(
          lookupNow.year,
          lookupNow.month,
          lookupNow.day,
        );
        final todayStartForLookup = lookupDayStart.toUtc().toIso8601String();
        final lookupParams = <String, String>{
          'where[status][in]': 'pending,ordered',
          'where[tableDetails.tableNumber][equals]': tableNumberForSubmit!,
          'where[tableDetails.section][equals]': sectionForSubmit!,
          'where[createdAt][greater_than_equal]': todayStartForLookup,
          'limit': '5',
          'sort': '-updatedAt',
          'depth': '3',
        };
        if (_branchId != null && _branchId!.trim().isNotEmpty) {
          lookupParams['where[branch][equals]'] = _branchId!;
        }

        try {
          final lookupResponse = await http.get(
            Uri.https('blackforest.vseyal.com', '/api/billings', lookupParams),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          );
          if (lookupResponse.statusCode == 200) {
            final lookupRaw = jsonDecode(lookupResponse.body);
            final lookupMap = lookupRaw is Map
                ? Map<String, dynamic>.from(lookupRaw)
                : <String, dynamic>{};
            final docsRaw = lookupMap['docs'];
            final docs = docsRaw is List
                ? docsRaw.whereType<Map>().toList()
                : const <Map>[];
            if (docs.isNotEmpty) {
              Map<String, dynamic>? existingBillDoc;
              for (final rawDoc in docs) {
                final doc = Map<String, dynamic>.from(rawDoc);
                if (!hasActiveLookupItems(doc['items'])) {
                  continue;
                }
                existingBillDoc = doc;
                break;
              }
              if (existingBillDoc == null) {
                debugPrint(
                  '📦 Existing table bill lookup skipped: no active (non-cancelled) items found for table today.',
                );
              } else {
                final existingBillId =
                    parseAnyId(existingBillDoc['id']) ??
                    parseAnyId(existingBillDoc['_id']);
                if (existingBillId != null && existingBillId.isNotEmpty) {
                  billId = existingBillId;
                  final existingCustomerDetails =
                      existingBillDoc['customerDetails'];
                  if (existingCustomerDetails is Map) {
                    final customerMap = Map<String, dynamic>.from(
                      existingCustomerDetails,
                    );
                    final existingName =
                        customerMap['name']?.toString().trim() ?? '';
                    final existingPhone =
                        customerMap['phoneNumber']?.toString().trim() ?? '';
                    if (billingCustomerName.isEmpty &&
                        existingName.isNotEmpty) {
                      billingCustomerName = existingName;
                    }
                    if (billingCustomerPhone.isEmpty &&
                        existingPhone.isNotEmpty) {
                      billingCustomerPhone = existingPhone;
                    }
                  }

                  final existingItemsRaw = existingBillDoc['items'];
                  if (existingItemsRaw is List) {
                    for (final rawItem in existingItemsRaw) {
                      if (rawItem is! Map) continue;
                      final mapped = toPurchasedPatchItem(
                        Map<String, dynamic>.from(rawItem),
                      );
                      if (mapped == null) continue;
                      existingServerItemsPayload.add(mapped);
                    }
                  }
                  debugPrint(
                    '📦 Reusing existing table bill via lookup: $billId (items preserved: ${existingServerItemsPayload.length})',
                  );
                }
              }
            }
          }
        } catch (e) {
          debugPrint('📦 Existing table bill lookup failed: $e');
        }
      }

      if (requiresPhoneForOffer && billingCustomerPhone.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Customer phone number is required to apply offers'),
          ),
        );
        setState(() => _isBillingInProgress = false);
        return;
      }

      customerDetails['name'] = billingCustomerName;
      customerDetails['phone'] = billingCustomerPhone;

      final payloadItems = <Map<String, dynamic>>[];
      if (existingServerItemsPayload.isNotEmpty) {
        payloadItems.addAll(existingServerItemsPayload);
      }
      final itemsToAppend = existingServerItemsPayload.isNotEmpty
          ? cartProvider.cartItems
          : mergedItems;
      for (final item in itemsToAppend) {
        final mapped = toPurchasedCartItemPayload(item);
        if (mapped != null) {
          payloadItems.add(mapped);
        }
      }

      final billingData = <String, dynamic>{
        'items': payloadItems,
        'totalAmount': cartProvider.total,
        'branch': _branchId,
        'company': _companyId,
        'recalledBillId': billId, // PASS RESOLVED BILL ID
        'customerDetails': {
          'name': billingCustomerName,
          'phoneNumber': billingCustomerPhone,
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
        'applyCustomerOffer': shouldApplyCustomerOffer,
        'status': status,
      };
      if (isTableOrderForSubmit) {
        billingData['tableDetails'] = {
          'section': sectionForSubmit,
          'tableNumber': tableNumberForSubmit,
        };
      }

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

      double? readServerMoney(dynamic value) {
        if (value is num) {
          final parsed = value.toDouble();
          return parsed < 0 ? 0 : parsed;
        }
        if (value is String) {
          final parsed = double.tryParse(value);
          if (parsed == null) return null;
          return parsed < 0 ? 0 : parsed;
        }
        return null;
      }

      double? readServerQuantity(dynamic value) {
        if (value is num) return value.toDouble();
        if (value is String) return double.tryParse(value);
        return null;
      }

      bool hasServerKey(Map<String, dynamic> map, String key) {
        return map.containsKey(key);
      }

      final responseMap = billingResponse is Map
          ? Map<String, dynamic>.from(billingResponse)
          : <String, dynamic>{};
      final responseDoc = responseMap['doc'];
      Map<String, dynamic> finalBillDoc = responseDoc is Map
          ? Map<String, dynamic>.from(responseDoc)
          : responseMap;

      String? billDocId(dynamic value) {
        if (value == null) return null;
        if (value is String) return value;
        if (value is num) return value.toString();
        if (value is Map) {
          final map = Map<String, dynamic>.from(value);
          final id = map['id'] ?? map['_id'] ?? map[r'$oid'];
          if (id is String) return id;
          if (id is num) return id.toString();
        }
        return null;
      }

      final savedBillId =
          billDocId(finalBillDoc['id']) ??
          billDocId(finalBillDoc['_id']) ??
          billDocId(responseMap['id']) ??
          billDocId(responseMap['_id']) ??
          billDocId(responseMap['doc']);

      if ((response.statusCode == 200 || response.statusCode == 201) &&
          status == 'completed' &&
          savedBillId != null &&
          savedBillId.isNotEmpty) {
        try {
          final savedBillResponse = await http.get(
            Uri.parse(
              'https://blackforest.vseyal.com/api/billings/$savedBillId?depth=3',
            ),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          );
          if (savedBillResponse.statusCode == 200) {
            final savedBillRaw = jsonDecode(savedBillResponse.body);
            if (savedBillRaw is Map) {
              final savedBillMap = Map<String, dynamic>.from(savedBillRaw);
              final savedBillDoc = savedBillMap['doc'];
              finalBillDoc = savedBillDoc is Map
                  ? Map<String, dynamic>.from(savedBillDoc)
                  : savedBillMap;
              debugPrint('📦 REFETCHED SAVED BILL: $savedBillId');
            }
          } else {
            debugPrint(
              '📦 REFETCH BILL FAILED: ${savedBillResponse.statusCode}',
            );
          }
        } catch (e) {
          debugPrint('📦 REFETCH BILL ERROR: $e');
        }
      }

      final billedTotal =
          readServerMoney(finalBillDoc['totalAmount']) ?? cartProvider.total;
      final billedGrossAmount =
          readServerMoney(finalBillDoc['grossAmount']) ?? billedTotal;
      final serverOfferApplied = finalBillDoc['customerOfferApplied'] == true;
      final serverOfferDiscount =
          readServerMoney(finalBillDoc['customerOfferDiscount']) ?? 0.0;
      final serverTotalPercentageOfferApplied =
          finalBillDoc['totalPercentageOfferApplied'] == true;
      final serverTotalPercentageOfferDiscount =
          readServerMoney(finalBillDoc['totalPercentageOfferDiscount']) ?? 0.0;
      final serverCustomerEntryPercentageOfferApplied =
          finalBillDoc['customerEntryPercentageOfferApplied'] == true;
      final serverCustomerEntryPercentageOfferDiscount =
          readServerMoney(
            finalBillDoc['customerEntryPercentageOfferDiscount'],
          ) ??
          0.0;

      if (finalBillDoc.isNotEmpty) {
        debugPrint(
          '📦 FINAL BILL MONEY (server): gross=$billedGrossAmount | total=$billedTotal',
        );
      }

      String? relationId(dynamic value) {
        if (value == null) return null;
        if (value is String) return value;
        if (value is num) return value.toString();
        if (value is Map) {
          final map = Map<String, dynamic>.from(value);
          final id = map['id'] ?? map['_id'] ?? map[r'$oid'];
          if (id is String) return id;
          if (id is num) return id.toString();
        }
        return null;
      }

      CartItem? findFallbackItem(
        String? productId,
        String name,
        bool isOfferFreeItem,
        bool isRandomCustomerOfferItem,
      ) {
        for (final item in mergedItems) {
          if (productId != null &&
              item.id == productId &&
              item.isOfferFreeItem == isOfferFreeItem &&
              item.isRandomCustomerOfferItem == isRandomCustomerOfferItem) {
            return item;
          }
        }
        for (final item in mergedItems) {
          if (item.name == name &&
              item.isOfferFreeItem == isOfferFreeItem &&
              item.isRandomCustomerOfferItem == isRandomCustomerOfferItem) {
            return item;
          }
        }
        return null;
      }

      List<CartItem> finalServerItems = mergedItems;
      final responseItems = finalBillDoc['items'];
      if (responseItems is List) {
        finalServerItems = responseItems.map((raw) {
          final item = raw is Map
              ? Map<String, dynamic>.from(raw)
              : <String, dynamic>{};
          final product = item['product'];
          final productMap = product is Map
              ? Map<String, dynamic>.from(product)
              : null;
          final productId = relationId(product);
          final itemName = item['name']?.toString() ?? 'Unknown';
          final isOfferFreeItem = item['isOfferFreeItem'] == true;
          final notesValue = (item['notes'] ?? item['specialNote'] ?? '')
              .toString()
              .trim();
          final isRandomCustomerOfferItem =
              item['isRandomCustomerOfferItem'] == true ||
              notesValue.toUpperCase() == 'RANDOM CUSTOMER OFFER';
          final isReadOnlyOfferItem =
              isOfferFreeItem || isRandomCustomerOfferItem;
          final fallback = findFallbackItem(
            productId,
            itemName,
            isOfferFreeItem,
            isRandomCustomerOfferItem,
          );

          String? imageUrl = fallback?.imageUrl;
          String? department = fallback?.department;
          String? categoryId = fallback?.categoryId;
          if (productMap != null) {
            final images = productMap['images'];
            if (images is List && images.isNotEmpty) {
              final first = images.first;
              if (first is Map) {
                final image = first['image'];
                final imageUrlRaw = image is Map ? image['url'] : null;
                if (imageUrlRaw is String && imageUrlRaw.isNotEmpty) {
                  imageUrl = imageUrlRaw.startsWith('/')
                      ? 'https://blackforest.vseyal.com$imageUrlRaw'
                      : imageUrlRaw;
                }
              }
            }

            final productDepartment = productMap['department'];
            if (productDepartment is Map) {
              department = productDepartment['name']?.toString();
            } else if (productDepartment != null) {
              department = productDepartment.toString();
            }

            categoryId = relationId(productMap['category']) ?? categoryId;
          }

          final unitPrice =
              readServerMoney(
                item['effectiveUnitPrice'] ??
                    item['unitPrice'] ??
                    item['price'],
              ) ??
              0.0;
          final quantity = isRandomCustomerOfferItem
              ? 1.0
              : (readServerQuantity(item['quantity']) ??
                    fallback?.quantity ??
                    0.0);
          final lineSubtotal = isRandomCustomerOfferItem
              ? 0.0
              : hasServerKey(item, 'subtotal')
              ? readServerMoney(item['subtotal']) ?? 0.0
              : fallback?.lineSubtotal;
          final effectiveUnitPrice = hasServerKey(item, 'effectiveUnitPrice')
              ? readServerMoney(item['effectiveUnitPrice'])
              : fallback?.effectiveUnitPrice;
          final isPriceOfferApplied =
              item['isPriceOfferApplied'] == true ||
              fallback?.isPriceOfferApplied == true;
          final priceOfferRuleKey =
              item['priceOfferRuleKey']?.toString() ??
              fallback?.priceOfferRuleKey;
          final priceOfferDiscountPerUnit =
              readServerMoney(item['priceOfferDiscountPerUnit']) ??
              fallback?.priceOfferDiscountPerUnit ??
              0.0;
          final priceOfferAppliedUnits =
              readServerMoney(item['priceOfferAppliedUnits']) ??
              fallback?.priceOfferAppliedUnits ??
              0.0;

          return CartItem(
            id: productId ?? fallback?.id ?? '',
            billingItemId: item['id']?.toString() ?? fallback?.billingItemId,
            name: itemName,
            price: isReadOnlyOfferItem ? 0.0 : unitPrice,
            imageUrl: imageUrl,
            quantity: quantity,
            unit: item['unit']?.toString() ?? fallback?.unit,
            department: department,
            categoryId: categoryId,
            specialNote:
                item['specialNote']?.toString() ??
                item['notes']?.toString() ??
                fallback?.specialNote,
            status: item['status']?.toString() ?? fallback?.status,
            isOfferFreeItem: isOfferFreeItem,
            offerRuleKey:
                item['offerRuleKey']?.toString() ?? fallback?.offerRuleKey,
            offerTriggerProductId:
                relationId(item['offerTriggerProduct']) ??
                fallback?.offerTriggerProductId,
            isRandomCustomerOfferItem: isRandomCustomerOfferItem,
            randomCustomerOfferCampaignCode:
                item['randomCustomerOfferCampaignCode']?.toString() ??
                fallback?.randomCustomerOfferCampaignCode,
            isPriceOfferApplied: isPriceOfferApplied,
            priceOfferRuleKey: priceOfferRuleKey,
            priceOfferDiscountPerUnit: priceOfferDiscountPerUnit,
            priceOfferAppliedUnits: priceOfferAppliedUnits,
            effectiveUnitPrice: isReadOnlyOfferItem ? 0.0 : effectiveUnitPrice,
            lineSubtotal: lineSubtotal,
          );
        }).toList();
      }

      debugPrint(
        '📦 FINAL BILL (server): total=$billedTotal | creditApplied=$serverOfferApplied | creditDiscount=$serverOfferDiscount | entryPercentageApplied=$serverCustomerEntryPercentageOfferApplied | entryPercentageDiscount=$serverCustomerEntryPercentageOfferDiscount | percentageApplied=$serverTotalPercentageOfferApplied | percentageDiscount=$serverTotalPercentageOfferDiscount',
      );

      if (response.statusCode == 201 || response.statusCode == 200) {
        // Play success sound (non-blocking)
        try {
          debugPrint('🔊 Attempting to play payment sound...');
          final player = AudioPlayer();
          player.setVolume(1.0);
          player.play(AssetSource('sounds/pay.mp3'));
          debugPrint('🔊 Sound command sent');
        } catch (e) {
          debugPrint("Error playing sound: $e");
        }

        if (!mounted) return;

        if (status == 'pending') {
          // Snapshot active cart items for KOT
          final kotItems = List<CartItem>.from(cartProvider.cartItems);
          _handleKOTPrinting(
            items: kotItems,
            billingResponse: billingResponse,
            customerDetails: customerDetails,
          );
        } else {
          _printReceipt(
            items: finalServerItems,
            totalAmount: billedTotal,
            grossAmount: billedGrossAmount,
            printerIp: cartProvider.printerIp!,
            printerPort: cartProvider.printerPort,
            printerProtocol: cartProvider.printerProtocol ?? 'esc_pos',
            billingResponse: finalBillDoc,
            customerDetails: customerDetails,
            paymentMethod: _selectedPaymentMethod!,
          );
        }

        if (status == 'pending' && cartProvider.currentType == CartType.table) {
          cartProvider.loadKOTItems(
            finalServerItems,
            billId: savedBillId ?? billId,
            cName: billingCustomerName,
            cPhone: billingCustomerPhone,
            tName: tableNumberForSubmit,
            tSection: sectionForSubmit,
          );
        } else {
          cartProvider.clearCart();
        }
        final totalSavedAmount = (billedGrossAmount - billedTotal)
            .clamp(0.0, double.infinity)
            .toDouble();
        final successMessage = status == 'pending'
            ? 'KOT SENT SUCCESSFULLY'
            : totalSavedAmount > 0.0001
            ? 'Billing submitted. Payable: ₹${billedTotal.toStringAsFixed(2)} (Saved ₹${totalSavedAmount.toStringAsFixed(2)})'
            : 'Billing submitted. Payable: ₹${billedTotal.toStringAsFixed(2)}';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successMessage)));
        FocusManager.instance.primaryFocus?.unfocus();
        await Future<void>.delayed(const Duration(milliseconds: 16));
        if (!mounted) return;
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
      if (mounted) {
        setState(() => _isBillingInProgress = false);
      }
    }
  }

  String _formatOfferQty(double value) {
    if (value % 1 == 0) return value.toInt().toString();
    return value.toStringAsFixed(2);
  }

  Future<bool> _confirmKotOfferPreview(CartProvider cartProvider) async {
    final phone = (cartProvider.customerPhone ?? '').trim();
    final lookupPhone = phone.length >= 10 ? phone : '';

    final tableNumber = (cartProvider.selectedTable ?? '').trim();
    final section = (cartProvider.selectedSection ?? '').trim();

    try {
      final data = await cartProvider.fetchCustomerData(
        lookupPhone,
        isTableOrder: true,
        tableSection: section,
        tableNumber: tableNumber,
      );
      if (data == null) return true;

      double readMoney(dynamic value) {
        if (value is num) return value.toDouble();
        if (value is String) return double.tryParse(value) ?? 0.0;
        return 0.0;
      }

      Map<String, dynamic>? readMap(dynamic raw) {
        if (raw is Map) return Map<String, dynamic>.from(raw);
        return null;
      }

      List<Map<String, dynamic>> readMapList(dynamic raw) {
        if (raw is! List) return const <Map<String, dynamic>>[];
        return raw
            .whereType<Map>()
            .map((entry) => Map<String, dynamic>.from(entry))
            .toList();
      }

      final productOfferMatches = readMapList(
        readMap(data['productOfferPreview'])?['matches'],
      ).where((entry) => entry['eligible'] == true).toList();
      final productPriceOfferMatches = readMapList(
        readMap(data['productPriceOfferPreview'])?['matches'],
      ).where((entry) => entry['eligible'] == true).toList();
      final randomOfferData = readMap(data['randomCustomerOfferPreview']);
      final randomOfferMatches = readMapList(
        randomOfferData?['matches'],
      ).where((entry) => entry['eligible'] == true).toList();
      final totalPercentageOfferData = readMap(
        data['totalPercentageOfferPreview'],
      );
      final customerEntryPercentageOfferData = readMap(
        data['customerEntryPercentageOfferPreview'],
      );
      final totalPercentageOfferEnabled =
          totalPercentageOfferData?['enabled'] == true;
      final totalPercentageOfferPreviewEligible =
          totalPercentageOfferData?['previewEligible'] == true;
      final customerEntryPercentageOfferEnabled =
          customerEntryPercentageOfferData?['enabled'] == true;
      final customerEntryPercentageOfferPreviewEligible =
          customerEntryPercentageOfferData?['previewEligible'] == true;
      final creditOfferEnabled = readMap(data['offer'])?['enabled'] == true;

      final kotPreviewItems = List<CartItem>.from(cartProvider.cartItems);
      final offerPreviewItems = <Map<String, dynamic>>[];
      final previewLines = <String>[];

      if (productOfferMatches.isNotEmpty) {
        for (final match in productOfferMatches) {
          final freeName =
              match['freeProductName']?.toString().trim().isNotEmpty == true
              ? match['freeProductName'].toString().trim()
              : 'Free Item';
          final freeQty = readMoney(match['predictedFreeQuantity']);
          if (freeQty > 0) {
            offerPreviewItems.add({
              'name': freeName,
              'qty': freeQty,
              'price': 0.0,
              'badge': 'FREE OFFER ITEM',
            });
          }
        }
      } else if (productPriceOfferMatches.isNotEmpty) {
        for (final match in productPriceOfferMatches) {
          final productName =
              match['productName']?.toString().trim().isNotEmpty == true
              ? match['productName'].toString().trim()
              : 'Product';
          final discountPerUnit = readMoney(match['discountPerUnit']);
          final discountedUnits = readMoney(match['predictedAppliedUnits']);
          if (discountPerUnit > 0 && discountedUnits > 0) {
            previewLines.add(
              '$productName ₹${discountPerUnit.toStringAsFixed(2)} off x${_formatOfferQty(discountedUnits)}',
            );
          }
        }
      } else if (randomOfferMatches.isNotEmpty) {
        final selectedRaw = randomOfferData?['selectedMatch'];
        final selectedMatch = selectedRaw is Map
            ? Map<String, dynamic>.from(selectedRaw)
            : randomOfferMatches.first;
        final productName =
            selectedMatch['productName']?.toString().trim().isNotEmpty == true
            ? selectedMatch['productName'].toString().trim()
            : 'Random Item';
        offerPreviewItems.add({
          'name': productName,
          'qty': 1.0,
          'price': 0.0,
          'badge': 'RANDOM FREE ITEM',
        });
      } else if (creditOfferEnabled) {
        previewLines.add('Customer Credit Offer may apply on final billing.');
      } else if (totalPercentageOfferEnabled &&
          totalPercentageOfferPreviewEligible) {
        previewLines.add('Total Percentage Offer may apply on final billing.');
      }

      if (customerEntryPercentageOfferEnabled &&
          customerEntryPercentageOfferPreviewEligible) {
        final offer6Percent = readMoney(
          customerEntryPercentageOfferData?['discountPercent'],
        );
        previewLines.add(
          'Customer Entry Percentage Offer: ${offer6Percent.toStringAsFixed(2)}% auto-applied by backend.',
        );
      }

      if (offerPreviewItems.isEmpty && previewLines.isEmpty) {
        return true;
      }

      if (!mounted) return true;

      final customerName = (data['name']?.toString().trim().isNotEmpty == true)
          ? data['name'].toString().trim()
          : (cartProvider.customerName ?? '').trim();
      final tableDisplay = tableNumber.isNotEmpty ? tableNumber : '-';

      return (await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              backgroundColor: const Color(0xFF1E1E1E),
              title: const Text(
                'Offer Preview Before KOT',
                style: TextStyle(color: Colors.white),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Table: $tableDisplay${customerName.isNotEmpty ? ' | Customer: $customerName' : ''}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (kotPreviewItems.isNotEmpty) ...[
                      const Text(
                        'Current KOT items:',
                        style: TextStyle(color: Colors.white, fontSize: 13),
                      ),
                      const SizedBox(height: 6),
                      ...kotPreviewItems.map(
                        (item) => Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  item.name,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Text(
                                'x${_formatOfferQty(item.quantity)}',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    if (offerPreviewItems.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Offer items to be auto-added:',
                        style: TextStyle(color: Colors.white, fontSize: 13),
                      ),
                      const SizedBox(height: 6),
                      ...offerPreviewItems.map(
                        (entry) => Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF102229),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: const Color(
                                0xFF2EBF3B,
                              ).withValues(alpha: 0.55),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      entry['name']?.toString() ?? 'Offer Item',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    'x${_formatOfferQty(readMoney(entry['qty']))}',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Price: ₹${readMoney(entry['price']).toStringAsFixed(2)}',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              Text(
                                entry['badge']?.toString() ?? 'OFFER ITEM',
                                style: const TextStyle(
                                  color: Color(0xFF2EBF3B),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    if (previewLines.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      ...previewLines.map(
                        (line) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            line,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    const Text(
                      'Final offer application is confirmed by backend after save.',
                      style: TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text(
                    'Back',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0A84FF),
                  ),
                  child: const Text(
                    'Send KOT',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          )) ??
          false;
    } catch (e) {
      debugPrint('Offer preview lookup failed before KOT: $e');
      return true;
    }
  }

  Future<void> _printReceipt({
    required List<CartItem> items,
    required double totalAmount,
    required double grossAmount,
    required String printerIp,
    required int printerPort,
    required String printerProtocol,
    required Map<String, dynamic> billingResponse,
    required Map<String, dynamic> customerDetails,
    required String paymentMethod,
  }) async {
    if (printerProtocol != 'esc_pos') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Unsupported printer protocol: $printerProtocol'),
          ),
        );
      }
      return;
    }

    double toNonNegativeMoney(dynamic value) {
      if (value is num) {
        final parsed = value.toDouble();
        return parsed < 0 ? 0 : parsed;
      }
      if (value is String) {
        final parsed = double.tryParse(value);
        if (parsed == null) return 0.0;
        return parsed < 0 ? 0 : parsed;
      }
      return 0.0;
    }

    final customerOfferDiscountFromServer = toNonNegativeMoney(
      billingResponse['customerOfferDiscount'],
    );
    final totalPercentageOfferDiscountFromServer = toNonNegativeMoney(
      billingResponse['totalPercentageOfferDiscount'],
    );
    final totalPercentageOfferApplied =
        billingResponse['totalPercentageOfferApplied'] == true;
    final customerEntryPercentageOfferDiscountFromServer = toNonNegativeMoney(
      billingResponse['customerEntryPercentageOfferDiscount'],
    );
    final customerEntryPercentageOfferApplied =
        billingResponse['customerEntryPercentageOfferApplied'] == true;

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
        // Extract KOT Number for side-by-side display
        String kotDisplayDigits = 'N/A';
        if (billingResponse['kotNumber'] != null) {
          kotDisplayDigits = billingResponse['kotNumber']
              .toString()
              .split('-')
              .last
              .replaceAll('KOT', '');
        } else if (billingResponse['doc']?['kotNumber'] != null) {
          kotDisplayDigits = billingResponse['doc']['kotNumber']
              .toString()
              .split('-')
              .last
              .replaceAll('KOT', '');
        } else {
          // Fallback to parse from invoiceNumber CHI-20260207-KOT006
          final kotRegex = RegExp(r'^[A-Z]+-\d{8}-(KOT)?(\d+)$');
          final kotMatch = kotRegex.firstMatch(invoiceNumber);
          if (kotMatch != null) {
            kotDisplayDigits = kotMatch.group(2)!;
          }
        }

        printer.row([
          PosColumn(
            text: 'Assigned by: ${waiterName ?? 'Unknown'}',
            width: 7,
            styles: const PosStyles(align: PosAlign.left),
          ),
          PosColumn(
            text: 'KOT NO - $kotDisplayDigits',
            width: 5,
            styles: const PosStyles(align: PosAlign.right, bold: true),
          ),
        ]);

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

        for (var item in items) {
          final qtyStr = item.quantity % 1 == 0
              ? item.quantity.toStringAsFixed(0)
              : item.quantity.toStringAsFixed(2);
          final unitPriceToPrint = item.effectiveUnitPrice ?? item.price;
          final lineAmount = item.lineTotal;
          printer.row([
            PosColumn(text: item.name, width: 5),
            PosColumn(
              text: qtyStr,
              width: 2,
              styles: const PosStyles(align: PosAlign.center),
            ),
            PosColumn(
              text: unitPriceToPrint.toStringAsFixed(2),
              width: 2,
              styles: const PosStyles(align: PosAlign.right),
            ),
            PosColumn(
              text: lineAmount.toStringAsFixed(2),
              width: 3,
              styles: const PosStyles(align: PosAlign.right),
            ),
          ]);
          if (item.isPriceOfferApplied &&
              item.priceOfferDiscountPerUnit > 0 &&
              item.priceOfferAppliedUnits > 0) {
            printer.text(
              '  PRICE OFFER: -₹${item.priceOfferDiscountPerUnit.toStringAsFixed(2)} x ${item.priceOfferAppliedUnits.toStringAsFixed(2)} unit(s)',
              styles: const PosStyles(align: PosAlign.left),
            );
          }
          if (item.isRandomCustomerOfferItem) {
            printer.text(
              '  RANDOM OFFER APPLIED (FREE)',
              styles: const PosStyles(align: PosAlign.left),
            );
          }
        }

        printer.hr(ch: '-');
        final billDiscount = (grossAmount - totalAmount)
            .clamp(0.0, double.infinity)
            .toDouble();
        if (billDiscount > 0.0001) {
          printer.row([
            PosColumn(
              text: 'GROSS RS ${grossAmount.toStringAsFixed(2)}',
              width: 12,
              styles: const PosStyles(align: PosAlign.right),
            ),
          ]);
          printer.row([
            PosColumn(
              text: 'DISCOUNT RS ${billDiscount.toStringAsFixed(2)}',
              width: 12,
              styles: const PosStyles(align: PosAlign.right),
            ),
          ]);
          if (customerOfferDiscountFromServer > 0.0001) {
            printer.row([
              PosColumn(
                text:
                    'CREDIT OFFER RS ${customerOfferDiscountFromServer.toStringAsFixed(2)}',
                width: 12,
                styles: const PosStyles(align: PosAlign.right),
              ),
            ]);
          }
          if (totalPercentageOfferApplied &&
              totalPercentageOfferDiscountFromServer > 0.0001) {
            printer.row([
              PosColumn(
                text:
                    'PERCENT OFFER RS ${totalPercentageOfferDiscountFromServer.toStringAsFixed(2)}',
                width: 12,
                styles: const PosStyles(align: PosAlign.right),
              ),
            ]);
          }
          if (customerEntryPercentageOfferApplied &&
              customerEntryPercentageOfferDiscountFromServer > 0.0001) {
            printer.row([
              PosColumn(
                text:
                    'ENTRY PERCENT OFFER RS ${customerEntryPercentageOfferDiscountFromServer.toStringAsFixed(2)}',
                width: 12,
                styles: const PosStyles(align: PosAlign.right),
              ),
            ]);
          }
        }
        printer.row([
          PosColumn(
            text: 'PAID BY: ${paymentMethod.toUpperCase()}',
            width: 5,
            styles: const PosStyles(align: PosAlign.left, bold: true),
          ),
          PosColumn(
            text: 'TOTAL RS ${totalAmount.toStringAsFixed(2)}',
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

        bool shouldShowFeedback = items.any((item) {
          final dept = item.department?.trim().toLowerCase();
          debugPrint(
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

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Receipt printed successfully')),
          );
        }
      } else {
        throw Exception(res.msg);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Print failed: $e')));
      }
    }
  }

  // -------------------------
  // ---------- KOT PRINTING LOGIC ----------
  // -------------------------

  Future<void> _handleKOTPrinting({
    required List<CartItem> items,
    required dynamic billingResponse,
    required Map<String, dynamic> customerDetails,
  }) async {
    if (_kotPrinters == null || _kotPrinters!.isEmpty) {
      debugPrint('ℹ️ No KOT printers configured for this branch.');
      return;
    }

    final groupedKots = <String, List<CartItem>>{}; // Printer IP -> Items

    // 1. Build Kitchen -> PrinterIP map for faster lookup
    final kitchenToPrinterMap = <String, String>{};
    for (var printerConfig in _kotPrinters!) {
      final ip = printerConfig['printerIp']?.toString().trim();
      final kitchens = printerConfig['kitchens'] as List?;
      if (ip != null && kitchens != null) {
        for (var k in kitchens) {
          final kId = (k is Map)
              ? (k['id'] ?? k['_id'] ?? k[r'$oid'])?.toString()
              : k.toString();
          if (kId != null) {
            kitchenToPrinterMap[kId] = ip;
          }
        }
      }
    }

    // 2. Route items to printers based on Category -> Kitchen -> Printer
    for (var item in items) {
      final catId = item.categoryId;
      if (catId != null) {
        final kitchenId = _categoryToKitchenMap[catId];
        if (kitchenId != null) {
          final ip = kitchenToPrinterMap[kitchenId];
          if (ip != null) {
            groupedKots.putIfAbsent(ip, () => []).add(item);
          } else {
            debugPrint('⚠️ No printer found for kitchen: $kitchenId');
          }
        } else {
          debugPrint('⚠️ No kitchen found for category: $catId');
          // Fallback: If no specific kitchen map, try to send to ALL KOT printers?
          // Or maybe check if there is a "default" kitchen?
          // For now, we log it.
        }
      } else {
        debugPrint('⚠️ Item ${item.name} has no category ID');
      }
    }

    if (groupedKots.isEmpty) {
      debugPrint('ℹ️ No KOT items could be routed to any printer.');
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
        // COLUMN HEADERS
        printer.row([
          PosColumn(
            text: 'ITEM',
            width: 7,
            styles: const PosStyles(bold: true),
          ),
          PosColumn(
            text: 'QTY',
            width: 2,
            styles: const PosStyles(bold: true, align: PosAlign.center),
          ),
          PosColumn(
            text: 'NOTE',
            width: 3,
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
              width: 7,
              styles: const PosStyles(
                bold: true,
                fontType: PosFontType.fontA,
                height: PosTextSize.size1,
                width: PosTextSize.size1,
              ),
            ),
            PosColumn(
              text: qtyStr,
              width: 2,
              styles: const PosStyles(bold: true, align: PosAlign.center),
            ),
            PosColumn(
              text: item.specialNote ?? '-',
              width: 3,
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
            final showSharedTableInput =
                cartProvider.currentType == CartType.table &&
                cartProvider.isSharedTableOrder &&
                (cartProvider.recalledBillId == null ||
                    cartProvider.cartItems.isNotEmpty);

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
                                ...items.asMap().entries.map((entry) {
                                  final index = entry.key;
                                  final item = entry.value;
                                  return _CartItemCard(
                                    key: ValueKey(
                                      '${item.billingItemId ?? item.id}_${index}_${item.quantity}_${item.isOfferFreeItem}_${item.isRandomCustomerOfferItem}',
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
                                  final isOfferFreeItem = item.isOfferFreeItem;
                                  final isRandomOfferItem =
                                      item.isRandomCustomerOfferItem;
                                  final isReadOnlyOfferItem =
                                      isOfferFreeItem || isRandomOfferItem;
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
                                    onDoubleTap:
                                        isReadOnlyOfferItem ||
                                            nextStatus == null
                                        ? null
                                        : () => cartProvider
                                              .updateRecalledItemStatus(
                                                context,
                                                index,
                                                nextStatus!,
                                              ),
                                    onLongPress: () {
                                      if (isReadOnlyOfferItem) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Offer items are read-only',
                                              style: TextStyle(
                                                color: Colors.white,
                                              ),
                                            ),
                                            duration: Duration(seconds: 1),
                                          ),
                                        );
                                        return;
                                      }
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
                                                if (isReadOnlyOfferItem)
                                                  Row(
                                                    children: [
                                                      Expanded(
                                                        child: Text(
                                                          item.name,
                                                          style:
                                                              const TextStyle(
                                                                color: Colors
                                                                    .white,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w500,
                                                              ),
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 8),
                                                      Flexible(
                                                        fit: FlexFit.loose,
                                                        child: ConstrainedBox(
                                                          constraints:
                                                              const BoxConstraints(
                                                                maxWidth: 150,
                                                              ),
                                                          child: Container(
                                                            padding:
                                                                const EdgeInsets.symmetric(
                                                                  horizontal: 8,
                                                                  vertical: 2,
                                                                ),
                                                            decoration: BoxDecoration(
                                                              color:
                                                                  (isRandomOfferItem
                                                                          ? const Color(
                                                                              0xFFFF9F0A,
                                                                            )
                                                                          : const Color(
                                                                              0xFF2EBF3B,
                                                                            ))
                                                                      .withValues(
                                                                        alpha:
                                                                            0.16,
                                                                      ),
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    6,
                                                                  ),
                                                              border: Border.all(
                                                                color:
                                                                    (isRandomOfferItem
                                                                            ? const Color(
                                                                                0xFFFF9F0A,
                                                                              )
                                                                            : const Color(
                                                                                0xFF2EBF3B,
                                                                              ))
                                                                        .withValues(
                                                                          alpha:
                                                                              0.45,
                                                                        ),
                                                              ),
                                                            ),
                                                            child: Text(
                                                              isRandomOfferItem
                                                                  ? 'RANDOM FREE ITEM'
                                                                  : 'FREE ITEM OFFER',
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: TextStyle(
                                                                color:
                                                                    isRandomOfferItem
                                                                    ? const Color(
                                                                        0xFFFF9F0A,
                                                                      )
                                                                    : const Color(
                                                                        0xFF2EBF3B,
                                                                      ),
                                                                fontSize: 10,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700,
                                                                letterSpacing:
                                                                    0.5,
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  )
                                                else
                                                  Text(
                                                    item.name,
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontWeight:
                                                          FontWeight.w500,
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
                                            '₹${item.lineTotal.toStringAsFixed(2)}',
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
                          if (showSharedTableInput) ...[
                            Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFF151515),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.16),
                                ),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: TextField(
                                controller: _sharedTableController,
                                style: const TextStyle(color: Colors.white),
                                textInputAction: TextInputAction.done,
                                onTapOutside: (_) => FocusManager
                                    .instance
                                    .primaryFocus
                                    ?.unfocus(),
                                onEditingComplete: () => FocusManager
                                    .instance
                                    .primaryFocus
                                    ?.unfocus(),
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(
                                    RegExp(r'[a-zA-Z0-9\- ]'),
                                  ),
                                ],
                                decoration: const InputDecoration(
                                  border: InputBorder.none,
                                  hintText: 'Enter shared table number',
                                  hintStyle: TextStyle(
                                    color: Colors.white54,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
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
                                          : () async {
                                              final proceed =
                                                  await _confirmKotOfferPreview(
                                                    cartProvider,
                                                  );
                                              if (!proceed) return;
                                              if (!mounted) return;
                                              await _submitBilling(
                                                status: 'pending',
                                                isReminder:
                                                    cartProvider
                                                        .recalledBillId !=
                                                    null,
                                              );
                                            },
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
    final isFreeOfferItem = widget.item.isOfferFreeItem;
    final isRandomOfferItem = widget.item.isRandomCustomerOfferItem;
    final isReadOnlyOfferItem = isFreeOfferItem || isRandomOfferItem;
    final isPriceOfferItem = widget.item.isPriceOfferApplied;
    final unitPriceDisplay =
        widget.item.effectiveUnitPrice ?? widget.item.price;

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
              onTap: isReadOnlyOfferItem ? null : widget.onRemove,
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
                  if (isReadOnlyOfferItem)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.item.name,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          fit: FlexFit.loose,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 150),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    (isRandomOfferItem
                                            ? const Color(0xFFFF9F0A)
                                            : const Color(0xFF2EBF3B))
                                        .withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color:
                                      (isRandomOfferItem
                                              ? const Color(0xFFFF9F0A)
                                              : const Color(0xFF2EBF3B))
                                          .withValues(alpha: 0.5),
                                ),
                              ),
                              child: Text(
                                isRandomOfferItem
                                    ? 'RANDOM FREE ITEM'
                                    : 'FREE ITEM OFFER',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: isRandomOfferItem
                                      ? const Color(0xFFFF9F0A)
                                      : const Color(0xFF2EBF3B),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.6,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  else
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
                  if (isPriceOfferItem && !isReadOnlyOfferItem) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0A84FF).withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: const Color(0xFF0A84FF).withValues(alpha: 0.5),
                        ),
                      ),
                      child: Text(
                        'PRICE OFFER: -₹${widget.item.priceOfferDiscountPerUnit.toStringAsFixed(2)} x ${widget.item.priceOfferAppliedUnits.toStringAsFixed(2)}',
                        style: const TextStyle(
                          color: Color(0xFF0A84FF),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    isReadOnlyOfferItem
                        ? 'FREE (₹0.00)'
                        : '₹${unitPriceDisplay.toStringAsFixed(2)} each',
                    style: TextStyle(
                      color: isReadOnlyOfferItem
                          ? (isRandomOfferItem
                                ? const Color(0xFFFF9F0A)
                                : const Color(0xFF2EBF3B))
                          : Colors.white70,
                      fontSize: 13,
                      fontWeight: isReadOnlyOfferItem
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Subtotal: ₹${widget.item.lineTotal.toStringAsFixed(2)}',
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
            if (widget.showNoteIcon && !isReadOnlyOfferItem)
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
            // 🟦 Quantity controls (offer items are read-only)
            if (isReadOnlyOfferItem)
              Column(
                children: [
                  Text(
                    _qtyDisplay(widget.item.quantity),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'LOCKED',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              )
            else
              Column(
                children: [
                  _QuantityButton(
                    icon: Icons.add_circle_outline,
                    onTap: () => widget.onQuantityChange(
                      (widget.item.quantity + _step).clamp(
                        0.0,
                        double.infinity,
                      ),
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
                      (widget.item.quantity - _step).clamp(
                        0.0,
                        double.infinity,
                      ),
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
