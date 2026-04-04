import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:blackforest_app/cart_provider.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/categories_page.dart';
import 'package:blackforest_app/customer_history_dialog.dart';
import 'package:blackforest_app/table_customer_details_visibility_service.dart';
import 'package:blackforest_app/table.dart';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:blackforest_app/kot_auto_print_service.dart';
import 'package:blackforest_app/printer/thermal_print_prefs.dart';
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
import 'package:blackforest_app/printer/unified_printer.dart';

class CartPage extends StatefulWidget {
  const CartPage({super.key});

  @override
  State<CartPage> createState() => _CartPageState();
}

class _CartPageState extends State<CartPage> {
  static const bool _enableCustomerLookup = true;
  static final bool _useSplitCustomerLookup = true;
  static const bool _fastBillingMode = false;
  static const bool _ultraFastBillingMode = true;
  static const bool _fastKotMode = true; // skip blocking table lookup for KOT
  static const bool _verboseBillingLogs = false;
  String? _branchId;
  String? _branchName;
  String? _branchGst;
  String? _branchMobile;
  String? _companyName;
  String? _companyId; // Added to store company ID for billing
  // String? _userRole; // Removed as unused according to lint
  TableCustomerDetailsVisibilityConfig _customerDetailsVisibilityConfig =
      TableCustomerDetailsVisibilityConfig.defaultValue;
  bool _hasLoadedCustomerDetailsVisibilityConfig = false;
  Future<void>? _customerDetailsVisibilityLoadFuture;
  String? _selectedPaymentMethod;
  bool _isBillingInProgress = false; // Prevent duplicate bill taps
  String _billingProgressLabel = 'Processing...';
  DateTime? _lastBillingTapAt;
  static const Duration _billTapDebounce = Duration(milliseconds: 1200);
  List<dynamic>? _kotPrinters; // Store KOT printer configs
  Timer? _refreshTimer;
  final Map<String, String> _categoryToKitchenMap = {}; // ID mapping
  final TextEditingController _sharedTableController = TextEditingController();

  Future<void> _submitBillingFromTap({
    required String status,
    bool isReminder = false,
  }) async {
    if (_isBillingInProgress) return;
    final now = DateTime.now();
    final lastTap = _lastBillingTapAt;
    if (lastTap != null && now.difference(lastTap) < _billTapDebounce) {
      return;
    }
    _lastBillingTapAt = now;
    await _submitBilling(status: status, isReminder: isReminder);
  }

  String? _extractPrinterIp(dynamic rawConfig) {
    if (rawConfig is! Map) return null;
    final config = Map<String, dynamic>.from(rawConfig);
    final nestedPrinter = config['printer'] is Map
        ? Map<String, dynamic>.from(config['printer'])
        : null;
    final candidates = [
      config['printerIp'],
      config['ipAddress'],
      config['ip'],
      config['host'],
      nestedPrinter?['printerIp'],
      nestedPrinter?['ipAddress'],
      nestedPrinter?['ip'],
      nestedPrinter?['host'],
    ];
    for (final value in candidates) {
      final ip = value?.toString().trim() ?? '';
      if (ip.isNotEmpty) return ip;
    }
    return null;
  }

  int _extractPrinterPort(dynamic rawConfig, {int defaultPort = 9100}) {
    if (rawConfig is! Map) return defaultPort;
    final config = Map<String, dynamic>.from(rawConfig);
    final nestedPrinter = config['printer'] is Map
        ? Map<String, dynamic>.from(config['printer'])
        : null;
    final candidates = [
      config['printerPort'],
      config['port'],
      nestedPrinter?['printerPort'],
      nestedPrinter?['port'],
    ];
    for (final value in candidates) {
      if (value is num) return value.toInt();
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null) return parsed;
      }
    }
    return defaultPort;
  }

  MapEntry<String, int>? _resolveFirstKotPrinterTarget() {
    final configs = _kotPrinters;
    if (configs == null || configs.isEmpty) return null;
    for (final raw in configs) {
      final ip = _extractPrinterIp(raw);
      if (ip == null || ip.isEmpty) continue;
      return MapEntry(ip, _extractPrinterPort(raw));
    }
    return null;
  }

  String _posPrintResultLabel(PosPrintResult result) {
    return '${result.msg} (code: ${result.value})';
  }

  void _showPrintStatusSnack(
    ScaffoldMessengerState messenger, {
    required String message,
    required bool isSuccess,
  }) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isSuccess ? Colors.green : Colors.redAccent,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

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
              final rawKotPrinters = branchConfig['kotPrinters'];
              if (rawKotPrinters is List) {
                _kotPrinters = List<dynamic>.from(rawKotPrinters);
              }

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
          if (_companyId != null) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('companyId', _companyId!);
            await prefs.setString('company_id', _companyId!);
          }
        }

        final cartProvider = Provider.of<CartProvider>(context, listen: false);

        // Prioritize globalPrinterIp if it exists
        final printerIpToUse =
            (globalPrinterIp != null && globalPrinterIp.isNotEmpty)
            ? globalPrinterIp
            : branch['printerIp'];
        final rawBranchPrinterPort = branch['printerPort'];
        int? branchPrinterPort;
        if (rawBranchPrinterPort is num) {
          branchPrinterPort = rawBranchPrinterPort.toInt();
        } else if (rawBranchPrinterPort is String) {
          branchPrinterPort = int.tryParse(rawBranchPrinterPort.trim());
        }
        final branchPrinterProtocol = branch['printerProtocol']?.toString();

        // Load kitchen mappings for KOT routing
        await _fetchKitchensForMapping();

        cartProvider.setPrinterDetails(
          printerIpToUse,
          branchPrinterPort,
          branchPrinterProtocol,
        );

        await _refreshCustomerDetailsVisibilityConfig(
          token: token,
          branchId: branchId,
        );
      }
    } catch (_) {}
  }

  Future<void> _refreshCustomerDetailsVisibilityConfig({
    required String token,
    required String branchId,
  }) async {
    final config =
        await TableCustomerDetailsVisibilityService.getConfigForBranch(
          branchId: branchId,
          token: token,
          forceRefresh: true,
        );
    if (!mounted) return;
    setState(() {
      _customerDetailsVisibilityConfig = config;
      _hasLoadedCustomerDetailsVisibilityConfig = true;
    });
  }

  Future<void> _ensureCustomerDetailsVisibilityConfigLoaded() async {
    if (_hasLoadedCustomerDetailsVisibilityConfig) return;
    final existing = _customerDetailsVisibilityLoadFuture;
    if (existing != null) {
      await existing;
      return;
    }

    final future = () async {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token')?.trim();
      final branchId =
          (_branchId?.trim().isNotEmpty == true
              ? _branchId?.trim()
              : prefs.getString('branchId')?.trim()) ??
          '';
      if (token == null || token.isEmpty || branchId.isEmpty) {
        return;
      }
      await _refreshCustomerDetailsVisibilityConfig(
        token: token,
        branchId: branchId,
      );
    }();

    _customerDetailsVisibilityLoadFuture = future.whenComplete(() {
      _customerDetailsVisibilityLoadFuture = null;
    });
    await _customerDetailsVisibilityLoadFuture;
  }

  Future<void> _openCustomerHistoryFromTableCart(
    CartProvider cartProvider,
  ) async {
    await _ensureCustomerDetailsVisibilityConfigLoaded();
    if (!mounted) return;

    final showCustomerHistoryByCms =
        _customerDetailsVisibilityConfig.showCustomerHistoryForTableOrders;
    if (!showCustomerHistoryByCms) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Customer history is disabled for table orders'),
        ),
      );
      return;
    }

    final customerPhone = (cartProvider.customerPhone ?? '').trim();
    final normalizedPhone = customerPhone.replaceAll(RegExp(r'\D'), '');
    if (normalizedPhone.length < 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Enter customer phone in customer details to view history',
          ),
        ),
      );
      return;
    }

    await showCustomerHistoryDialog(context, phoneNumber: customerPhone);
  }

  Future<void> _openCustomerHistoryFromBillingCart(
    CartProvider cartProvider,
  ) async {
    if (!mounted) return;
    final customerPhone = (cartProvider.customerPhone ?? '').trim();
    final normalizedPhone = customerPhone.replaceAll(RegExp(r'\D'), '');
    if (normalizedPhone.length < 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Enter customer phone in customer details to view history',
          ),
        ),
      );
      return;
    }

    await showCustomerHistoryDialog(context, phoneNumber: customerPhone);
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

  int? _parseTableNumberToken(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final direct = int.tryParse(trimmed);
    if (direct != null) return direct;
    final withoutPrefix = trimmed.replaceFirst(
      RegExp(r'^table[\s\-_:]*', caseSensitive: false),
      '',
    );
    return int.tryParse(withoutPrefix);
  }

  Future<String?> _resolveLiveSectionForTableNumber({
    required int tableNumber,
    required String branchId,
    required String token,
    String? preferredSection,
  }) async {
    try {
      final response = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/tables?where[branch][equals]=$branchId&limit=1&depth=1',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode != 200) return null;

      final decoded = jsonDecode(response.body);
      final docs = (decoded is Map && decoded['docs'] is List)
          ? List<dynamic>.from(decoded['docs'])
          : const <dynamic>[];
      if (docs.isEmpty || docs.first is! Map) return null;
      final root = Map<String, dynamic>.from(docs.first as Map);
      final sections = root['sections'] is List
          ? List<dynamic>.from(root['sections'])
          : const <dynamic>[];
      if (sections.isEmpty) return null;

      bool sectionHasTable(Map<String, dynamic> section) {
        final count =
            int.tryParse(section['tableCount']?.toString() ?? '0') ?? 0;
        return tableNumber > 0 && tableNumber <= count;
      }

      if (preferredSection != null && preferredSection.trim().isNotEmpty) {
        final preferredNormalized = preferredSection.trim().toLowerCase();
        for (final raw in sections) {
          if (raw is! Map) continue;
          final section = Map<String, dynamic>.from(raw);
          final name = section['name']?.toString().trim() ?? '';
          if (name.toLowerCase() == preferredNormalized &&
              sectionHasTable(section)) {
            return name;
          }
        }
      }

      for (final raw in sections) {
        if (raw is! Map) continue;
        final section = Map<String, dynamic>.from(raw);
        if (!sectionHasTable(section)) continue;
        final name = section['name']?.toString().trim() ?? '';
        if (name.isNotEmpty) return name;
      }
    } catch (_) {}
    return null;
  }

  Future<bool> _isLiveTableOccupied({
    required String tableNumber,
    required String sectionName,
    required String branchId,
    required String token,
  }) async {
    try {
      final lookupNow = DateTime.now();
      final lookupDayStart = DateTime(
        lookupNow.year,
        lookupNow.month,
        lookupNow.day,
      );
      final todayStartForLookup = lookupDayStart.toUtc().toIso8601String();

      final lookupParams = <String, String>{
        'where[status][in]': 'pending,ordered,confirmed,prepared,delivered',
        'where[tableDetails.tableNumber][equals]': tableNumber,
        'where[tableDetails.section][equals]': sectionName,
        'where[createdAt][greater_than_equal]': todayStartForLookup,
        'where[branch][equals]': branchId,
        'limit': '1',
        'depth': '0',
      };

      final response = await http.get(
        Uri.https('blackforest.vseyal.com', '/api/billings', lookupParams),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode != 200) return false;

      final decoded = jsonDecode(response.body);
      final docs = (decoded is Map && decoded['docs'] is List)
          ? List<dynamic>.from(decoded['docs'])
          : const <dynamic>[];
      return docs.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> _resolveSharedInputTarget({
    required String tableNumberInput,
    required String branchId,
    required String token,
    String? preferredSection,
  }) async {
    final parsedTable = _parseTableNumberToken(tableNumberInput);
    final tableNumber = tableNumberInput.trim();
    if (parsedTable == null || tableNumber.isEmpty) {
      return <String, dynamic>{
        'tableNumber': tableNumber,
        'section': CartProvider.sharedTablesSectionName,
        'useShared': true,
      };
    }

    final liveSection = await _resolveLiveSectionForTableNumber(
      tableNumber: parsedTable,
      branchId: branchId,
      token: token,
      preferredSection: preferredSection,
    );
    if (liveSection == null || liveSection.isEmpty) {
      return <String, dynamic>{
        'tableNumber': tableNumber,
        'section': CartProvider.sharedTablesSectionName,
        'useShared': true,
      };
    }

    final occupied = await _isLiveTableOccupied(
      tableNumber: tableNumber,
      sectionName: liveSection,
      branchId: branchId,
      token: token,
    );
    if (occupied) {
      return <String, dynamic>{
        'tableNumber': tableNumber,
        'section': CartProvider.sharedTablesSectionName,
        'useShared': true,
      };
    }

    return <String, dynamic>{
      'tableNumber': tableNumber,
      'section': liveSection,
      'useShared': false,
    };
  }

  Future<void> _syncCustomerDetailsForFastMode({
    required String token,
    required String billId,
    required String customerName,
    required String customerPhone,
    bool applyCustomerOffer = false,
  }) async {
    final trimmedBillId = billId.trim();
    if (trimmedBillId.isEmpty) return;
    final trimmedName = customerName.trim();
    final trimmedPhone = customerPhone.trim();
    if (trimmedName.isEmpty && trimmedPhone.isEmpty) return;

    final url = Uri.parse(
      'https://blackforest.vseyal.com/api/billings/$trimmedBillId?depth=0',
    );
    final payload = <String, dynamic>{
      'customerDetails': {
        'name': trimmedName,
        'phoneNumber': trimmedPhone,
        'address': '',
      },
      'applyCustomerOffer': applyCustomerOffer,
    };

    try {
      final response = await http
          .patch(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 200) {
        debugPrint(
          '📦 FAST MODE: customer details synced for bill $trimmedBillId',
        );
      } else {
        debugPrint(
          '📦 FAST MODE: customer details sync failed (${response.statusCode}) for bill $trimmedBillId',
        );
      }
    } catch (error) {
      debugPrint(
        '📦 FAST MODE: customer details sync error for bill $trimmedBillId: $error',
      );
    }
  }

  Future<void> _finalizeHybridOfferAndPrint({
    required String token,
    required String billId,
    required String customerName,
    required String customerPhone,
    required bool applyCustomerOffer,
    required bool expectOfferSync,
    required List<CartItem> items,
    required Map<String, dynamic> customerDetails,
    required String paymentMethod,
    required Map<String, dynamic> initialBillingResponse,
    required double initialTotalAmount,
    required double initialGrossAmount,
    required ScaffoldMessengerState messenger,
    String? printerIp,
    int printerPort = 9100,
    String printerProtocol = 'esc_pos',
  }) async {
    final trimmedBillId = billId.trim();
    if (trimmedBillId.isEmpty) return;

    double readMoney(dynamic value) {
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

    Map<String, dynamic> normalizeDoc(dynamic raw) {
      if (raw is Map) {
        final map = Map<String, dynamic>.from(raw);
        final doc = map['doc'];
        if (doc is Map) return Map<String, dynamic>.from(doc);
        return map;
      }
      return <String, dynamic>{};
    }

    Map<String, dynamic> finalDoc = Map<String, dynamic>.from(
      initialBillingResponse,
    );
    double finalTotal = initialTotalAmount;
    double finalGross = initialGrossAmount;
    bool customerOfferApplied = finalDoc['customerOfferApplied'] == true;
    bool totalPercentageOfferApplied =
        finalDoc['totalPercentageOfferApplied'] == true;
    bool customerEntryPercentageOfferApplied =
        finalDoc['customerEntryPercentageOfferApplied'] == true;
    double customerOfferDiscount = readMoney(finalDoc['customerOfferDiscount']);
    double totalPercentageOfferDiscount = readMoney(
      finalDoc['totalPercentageOfferDiscount'],
    );
    double customerEntryPercentageOfferDiscount = readMoney(
      finalDoc['customerEntryPercentageOfferDiscount'],
    );

    void applyBillDoc(Map<String, dynamic> doc) {
      finalDoc = doc;
      finalTotal = readMoney(doc['totalAmount']);
      finalGross = readMoney(doc['grossAmount']);
      customerOfferApplied = doc['customerOfferApplied'] == true;
      totalPercentageOfferApplied = doc['totalPercentageOfferApplied'] == true;
      customerEntryPercentageOfferApplied =
          doc['customerEntryPercentageOfferApplied'] == true;
      customerOfferDiscount = readMoney(doc['customerOfferDiscount']);
      totalPercentageOfferDiscount = readMoney(
        doc['totalPercentageOfferDiscount'],
      );
      customerEntryPercentageOfferDiscount = readMoney(
        doc['customerEntryPercentageOfferDiscount'],
      );
    }

    bool hasVisibleOffer() {
      final totalDiscount = (finalGross - finalTotal).clamp(
        0.0,
        double.infinity,
      );
      return customerOfferApplied ||
          totalPercentageOfferApplied ||
          customerEntryPercentageOfferApplied ||
          customerOfferDiscount > 0.0001 ||
          totalPercentageOfferDiscount > 0.0001 ||
          customerEntryPercentageOfferDiscount > 0.0001 ||
          totalDiscount > 0.0001;
    }

    final patchUrl = Uri.parse(
      'https://blackforest.vseyal.com/api/billings/$trimmedBillId?depth=0',
    );
    final patchPayload = <String, dynamic>{
      'customerDetails': {
        'name': customerName.trim(),
        'phoneNumber': customerPhone.trim(),
        'address': '',
      },
      'applyCustomerOffer': applyCustomerOffer,
    };

    Future<Map<String, dynamic>?> fetchLatestBillDoc({
      Duration timeout = const Duration(milliseconds: 1500),
    }) async {
      try {
        final response = await http
            .get(
              Uri.parse(
                'https://blackforest.vseyal.com/api/billings/$trimmedBillId?depth=0',
              ),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
            )
            .timeout(timeout);
        if (response.statusCode != 200) {
          debugPrint(
            '⚡ Hybrid finalize fetch failed (${response.statusCode}) for bill $trimmedBillId',
          );
          return null;
        }
        final raw = jsonDecode(response.body);
        final doc = normalizeDoc(raw);
        if (doc.isEmpty) return null;
        return doc;
      } catch (error) {
        debugPrint(
          '⚡ Hybrid finalize fetch error for bill $trimmedBillId: $error',
        );
        return null;
      }
    }

    final patchResultFuture = () async {
      try {
        final patchResponse = await http
            .patch(
              patchUrl,
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              body: jsonEncode(patchPayload),
              timeout: const Duration(seconds: 15),
            )
            .timeout(const Duration(seconds: 15));
        if (patchResponse.statusCode != 200) {
          debugPrint(
            '⚡ Hybrid finalize PATCH failed (${patchResponse.statusCode}) for bill $trimmedBillId',
          );
          return null;
        }
        final patchRaw = jsonDecode(patchResponse.body);
        final patchDoc = normalizeDoc(patchRaw);
        if (patchDoc.isNotEmpty) {
          debugPrint(
            '⚡ Hybrid finalize PATCH done: gross=${readMoney(patchDoc["grossAmount"])} | total=${readMoney(patchDoc["totalAmount"])}',
          );
        }
        return patchDoc.isEmpty ? null : patchDoc;
      } catch (error) {
        debugPrint(
          '⚡ Hybrid finalize PATCH error for bill $trimmedBillId: $error',
        );
        return null;
      }
    }();
    Map<String, dynamic>? completedPatchDoc;
    bool patchFutureSettled = false;
    final patchCompletionSignal = patchResultFuture.then<void>((patchDoc) {
      patchFutureSettled = true;
      if (patchDoc != null) {
        completedPatchDoc = patchDoc;
      }
    });

    final normalizedPhone = customerPhone.replaceAll(RegExp(r'\D'), '');
    final shouldWaitForOfferSync = expectOfferSync;
    final settleDelay = shouldWaitForOfferSync && normalizedPhone.length >= 10
        ? const Duration(milliseconds: 1800)
        : const Duration(milliseconds: 400);
    await Future<void>.delayed(settleDelay);

    void tryConsumePatchResult() {
      final patchDoc = completedPatchDoc;
      if (patchDoc == null) return;
      completedPatchDoc = null;
      applyBillDoc(patchDoc);
    }

    tryConsumePatchResult();

    final fetchWaits = shouldWaitForOfferSync && normalizedPhone.length >= 10
        ? <Duration>[
            Duration.zero,
            const Duration(milliseconds: 1200),
            const Duration(milliseconds: 1600),
            const Duration(milliseconds: 2200),
            const Duration(milliseconds: 2800),
            const Duration(milliseconds: 3200),
          ]
        : <Duration>[Duration.zero];

    for (var i = 0; i < fetchWaits.length; i++) {
      if (i > 0) {
        if (patchFutureSettled) {
          await Future<void>.delayed(fetchWaits[i]);
        } else {
          await Future.any<void>([
            patchCompletionSignal,
            Future<void>.delayed(fetchWaits[i]),
          ]);
        }
      }
      tryConsumePatchResult();
      if (!shouldWaitForOfferSync || hasVisibleOffer()) {
        break;
      }
      final fetchedDoc = await fetchLatestBillDoc();
      if (fetchedDoc != null) {
        applyBillDoc(fetchedDoc);
        debugPrint(
          '⚡ Hybrid finalize fetch #${i + 1}: gross=$finalGross | total=$finalTotal',
        );
      }
      if (!shouldWaitForOfferSync || hasVisibleOffer()) {
        break;
      }
    }

    if (!shouldWaitForOfferSync) {
      debugPrint('⚡ Hybrid finalize: skipping offer wait (offer not expected)');
    } else if (!hasVisibleOffer()) {
      debugPrint(
        '⚠️ Hybrid finalize: offer still not visible after fetch window for bill $trimmedBillId',
      );
    }

    final offerStillSyncing = shouldWaitForOfferSync && !hasVisibleOffer();
    final totalSavedAmount = (finalGross - finalTotal)
        .clamp(0.0, double.infinity)
        .toDouble();
    final summaryMessage = offerStillSyncing
        ? 'Billing submitted. Offer syncing...'
        : totalSavedAmount > 0.0001
        ? 'Billing submitted. Payable: ₹${finalTotal.toStringAsFixed(2)} (Saved ₹${totalSavedAmount.toStringAsFixed(2)})'
        : 'Billing submitted. Payable: ₹${finalTotal.toStringAsFixed(2)}';
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(summaryMessage)));

    final resolvedPrinterIp = (printerIp ?? '').trim();
    if (resolvedPrinterIp.isEmpty) {
      debugPrint(
        '⚡ Hybrid finalize: bill updated without receipt print (no printer configured).',
      );
      return;
    }

    if (offerStillSyncing) {
      debugPrint(
        '⚠️ Hybrid finalize: delaying receipt print because final offer total is not ready for bill $trimmedBillId',
      );
      _showPrintStatusSnack(
        messenger,
        message: 'Bill saved. Offer still syncing before receipt print.',
        isSuccess: false,
      );
      return;
    }

    await _printReceipt(
      items: items,
      totalAmount: finalTotal,
      grossAmount: finalGross,
      printerIp: resolvedPrinterIp,
      printerPort: printerPort,
      printerProtocol: printerProtocol,
      billingResponse: finalDoc,
      customerDetails: customerDetails,
      paymentMethod: paymentMethod,
      messenger: messenger,
    );
  }

  Future<void> _ensureBillingIdentifiers({
    required CartProvider cartProvider,
    required SharedPreferences prefs,
  }) async {
    _branchId ??= cartProvider.branchId ?? prefs.getString('branchId');
    _companyId ??=
        prefs.getString('companyId') ?? prefs.getString('company_id');

    if (_branchId != null) {
      await prefs.setString('branchId', _branchId!);
      cartProvider.setBranchId(_branchId);
    }
    if (_companyId != null) {
      await prefs.setString('companyId', _companyId!);
      await prefs.setString('company_id', _companyId!);
    }
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

          final item = CartItem.fromProduct(
            product,
            1,
            branchPrice: price,
            branchId: _branchId,
          );
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
    _billingProgressLabel = status == 'pending'
        ? 'Sending KOT...'
        : 'Submitting bill...';
    _isBillingInProgress = true;
    if (mounted) {
      setState(() {});
    }

    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    final stopwatch = Stopwatch()..start();
    int userInputMs = 0;
    int? billApiStartMs;
    int? billApiDurationMs;
    debugPrint('⏱️ [START] _submitBilling (${status.toUpperCase()})');
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

    await _ensureCustomerDetailsVisibilityConfigLoaded();

    final existingCustomerName = (cartProvider.customerName ?? '').trim();
    final existingCustomerPhone = (cartProvider.customerPhone ?? '').trim();
    final isTableOrderFlow = cartProvider.currentType == CartType.table;
    final isPendingOrderAction = status == 'pending' && isTableOrderFlow;
    final showCustomerDetailsByCms = isTableOrderFlow
        ? _customerDetailsVisibilityConfig.showCustomerDetailsForTableOrders
        : _customerDetailsVisibilityConfig.showCustomerDetailsForBillingOrders;
    final allowSkipCustomerDetailsByCms = isTableOrderFlow
        ? _customerDetailsVisibilityConfig
              .allowSkipCustomerDetailsForTableOrders
        : _customerDetailsVisibilityConfig
              .allowSkipCustomerDetailsForBillingOrders;
    final showCustomerHistoryByCms = isTableOrderFlow
        ? _customerDetailsVisibilityConfig.showCustomerHistoryForTableOrders
        : _customerDetailsVisibilityConfig.showCustomerHistoryForBillingOrders;
    final autoSubmitCustomerDetailsByCms = isTableOrderFlow
        ? _customerDetailsVisibilityConfig
              .autoSubmitCustomerDetailsForTableOrders
        : _customerDetailsVisibilityConfig
              .autoSubmitCustomerDetailsForBillingOrders;
    final hasExistingCustomerDetails =
        existingCustomerName.isNotEmpty || existingCustomerPhone.isNotEmpty;
    final skipDialogForExistingCustomer = hasExistingCustomerDetails;
    final shouldShowCustomerDetailsDialog =
        showCustomerDetailsByCms &&
        (status != 'pending' || isPendingOrderAction) &&
        !skipDialogForExistingCustomer;
    final skipActionLabel = isPendingOrderAction
        ? 'Skip & Order'
        : 'Skip & Bill';
    final submitActionLabel = isPendingOrderAction
        ? 'Submit & Order'
        : 'Submit & Bill';
    debugPrint(
      '🧩 Customer popup config: flow=${isTableOrderFlow ? 'table' : 'billing'} currentType=${cartProvider.currentType.name} table=${cartProvider.selectedTable ?? '-'} section=${cartProvider.selectedSection ?? '-'} show=$showCustomerDetailsByCms skip=$allowSkipCustomerDetailsByCms history=$showCustomerHistoryByCms autoSubmit=$autoSubmitCustomerDetailsByCms hasCustomer=$hasExistingCustomerDetails skipDialogForExistingCustomer=$skipDialogForExistingCustomer',
    );

    Map<String, dynamic>? customerDetails;

    if (shouldShowCustomerDetailsDialog) {
      final nameCtrl = TextEditingController(
        text: cartProvider.customerName ?? '',
      );
      final phoneCtrl = TextEditingController(
        text: cartProvider.customerPhone ?? '',
      );
      Timer? quickLookupDebounceTimer;
      Map<String, dynamic>? customerLookupData;
      bool isLookupInProgress = false;
      String? lookupError;
      bool applyCustomerOffer = false;
      bool isDialogSubmitting = false;
      bool didAutoLookup = false;
      bool isDialogActive = true;
      bool didCloseDialog = false;
      int lookupSequence = 0;
      final enableCustomerLookup = _enableCustomerLookup;
      int offerPageIndex = 0;

      customerDetails = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
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
            int requestId,
          ) async {
            String normalizePhone(String value) =>
                value.replaceAll(RegExp(r'\D'), '');
            final phone = normalizePhone(rawPhone);
            if (phone.length < 10) {
              if (!isDialogActive) return;
              setDialogState(() {
                customerLookupData = null;
                isLookupInProgress = false;
                lookupError = null;
                applyCustomerOffer = false;
              });
              return;
            }

            Map<String, dynamic> buildAutoSubmitPayload(
              Map<String, dynamic>? lookupData,
            ) {
              final customerName = nameCtrl.text.trim();
              final customerPhone = phoneCtrl.text.trim();
              final hasProductOfferMatch = readProductOfferMatches(
                lookupData,
              ).any((match) => match['eligible'] == true);
              final hasProductPriceOfferMatch = readProductPriceOfferMatches(
                lookupData,
              ).any((match) => match['eligible'] == true);
              final randomOfferData = readRandomCustomerOfferData(lookupData);
              final hasRandomOfferMatch =
                  randomOfferData?['enabled'] == true &&
                  randomOfferData?['isEligible'] == true;
              final hasTotalPercentageOfferEnabled =
                  readTotalPercentageOfferData(lookupData)?['enabled'] == true;

              final offerData = readOfferData(lookupData);
              final hasEligibleItemLevelOffer =
                  hasProductOfferMatch ||
                  hasProductPriceOfferMatch ||
                  hasRandomOfferMatch;
              final canApplyCustomerOffer =
                  customerPhone.isNotEmpty &&
                  offerData?['enabled'] == true &&
                  (offerData?['isOfferEligible'] == true ||
                      offerData?['historyBasedEligible'] == true) &&
                  !hasEligibleItemLevelOffer;
              final autoApplyCustomerOffer =
                  canApplyCustomerOffer && applyCustomerOffer;

              return <String, dynamic>{
                'name': customerName,
                'phone': customerPhone,
                'applyCustomerOffer': autoApplyCustomerOffer,
                'hasProductOfferMatch': hasProductOfferMatch,
                'hasProductPriceOfferMatch': hasProductPriceOfferMatch,
                'hasTotalPercentageOfferEnabled':
                    hasTotalPercentageOfferEnabled,
                'hasCustomerEntryPercentageOfferEnabled':
                    readCustomerEntryPercentageOfferData(
                      lookupData,
                    )?['enabled'] ==
                    true,
                'hasRandomOfferMatch': hasRandomOfferMatch,
              };
            }

            bool hasOfferPreviewPayload(Map<String, dynamic>? lookupData) {
              if (lookupData == null) return false;
              return lookupData['offer'] is Map ||
                  lookupData['productOfferPreview'] is Map ||
                  lookupData['productPriceOfferPreview'] is Map ||
                  lookupData['totalPercentageOfferPreview'] is Map ||
                  lookupData['customerEntryPercentageOfferPreview'] is Map ||
                  lookupData['randomCustomerOfferPreview'] is Map;
            }

            Map<String, dynamic> mergeOfferPreviewData({
              required Map<String, dynamic>? baseData,
              required Map<String, dynamic>? offerData,
            }) {
              final merged = Map<String, dynamic>.from(baseData ?? const {});
              if (offerData == null) return merged;
              const previewKeys = <String>[
                'offer',
                'productOfferPreview',
                'productPriceOfferPreview',
                'totalPercentageOfferPreview',
                'customerEntryPercentageOfferPreview',
                'randomCustomerOfferPreview',
              ];
              for (final key in previewKeys) {
                final value = offerData[key];
                if (value != null) {
                  merged[key] = value;
                }
              }
              final mergedName = merged['name']?.toString().trim() ?? '';
              final offerName = offerData['name']?.toString().trim() ?? '';
              if (mergedName.isEmpty && offerName.isNotEmpty) {
                merged['name'] = offerName;
              }
              final mergedPhone =
                  merged['phoneNumber']?.toString().trim() ?? '';
              final offerPhone =
                  offerData['phoneNumber']?.toString().trim() ?? '';
              if (mergedPhone.isEmpty && offerPhone.isNotEmpty) {
                merged['phoneNumber'] = offerPhone;
              }
              return merged;
            }

            void autoSubmitIfReady(Map<String, dynamic>? lookupData) {
              if (!autoSubmitCustomerDetailsByCms) return;
              if (status != 'completed') return;
              if (!isDialogActive || isDialogSubmitting || didCloseDialog) {
                return;
              }
              final normalizedPhone = normalizePhone(phoneCtrl.text);
              final lookupName = lookupData?['name']?.toString().trim() ?? '';
              final customerName = nameCtrl.text.trim();
              if (normalizedPhone.length < 10 ||
                  lookupName.isEmpty ||
                  customerName.isEmpty) {
                return;
              }

              final payload = buildAutoSubmitPayload(lookupData);
              didCloseDialog = true;
              setDialogState(() {
                isDialogSubmitting = true;
              });
              isDialogActive = false;
              lookupSequence += 1;
              quickLookupDebounceTimer?.cancel();

              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                final nav = Navigator.of(context);
                if (nav.canPop()) {
                  nav.pop(payload);
                }
              });
            }

            if (!isDialogActive) return;
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
              final lookupFlowLabel = lookupIsTableOrder ? 'table' : 'billing';
              final useSplitLookup =
                  enableCustomerLookup && _useSplitCustomerLookup;
              Map<String, dynamic>? data;
              if (enableCustomerLookup && !useSplitLookup) {
                final combinedLookupStopwatch = Stopwatch()..start();
                data = await cartProvider.fetchCustomerData(
                  phone,
                  isTableOrder: lookupIsTableOrder,
                  tableSection: activeSection,
                  tableNumber: activeTableNumber,
                );
                combinedLookupStopwatch.stop();
                debugPrint(
                  '⏱️ [Customer Lookup][$lookupFlowLabel] combined lookup: '
                  '${combinedLookupStopwatch.elapsedMilliseconds}ms (phone=$phone)',
                );
              } else {
                // Fast mode: resolve customer name first with lightweight lookup.
                final nameLookupStopwatch = Stopwatch()..start();
                final quickData = await cartProvider.fetchCustomerLookupPreview(
                  phone,
                  limit: 1,
                  useHeavyFallback: false,
                  includeGlobalLookup: false,
                );
                nameLookupStopwatch.stop();
                debugPrint(
                  '⏱️ [Customer Lookup][$lookupFlowLabel] name lookup: '
                  '${nameLookupStopwatch.elapsedMilliseconds}ms (phone=$phone)',
                );
                final latestPhoneForQuick = normalizePhone(phoneCtrl.text);
                if (!isDialogActive ||
                    latestPhoneForQuick != phone ||
                    requestId != lookupSequence) {
                  return;
                }

                final quickName = quickData?['name']?.toString().trim() ?? '';
                if (quickName.isNotEmpty && nameCtrl.text.trim().isEmpty) {
                  nameCtrl.text = quickName;
                }

                final offerData = readOfferData(quickData);
                final eligible =
                    enableCustomerLookup &&
                    offerData?['enabled'] == true &&
                    (offerData?['isOfferEligible'] == true ||
                        offerData?['historyBasedEligible'] == true);
                setDialogState(() {
                  customerLookupData = quickData;
                  isLookupInProgress = false;
                  lookupError = null;
                  applyCustomerOffer = eligible;
                });
                autoSubmitIfReady(quickData);

                if (!lookupIsTableOrder && !hasOfferPreviewPayload(quickData)) {
                  unawaited(() async {
                    final offerPreviewStopwatch = Stopwatch()..start();
                    try {
                      final offerPreviewData = await cartProvider
                          .fetchCustomerData(
                            phone,
                            isTableOrder: lookupIsTableOrder,
                            tableSection: activeSection,
                            tableNumber: activeTableNumber,
                            includeBillHistory: false,
                          );
                      offerPreviewStopwatch.stop();
                      debugPrint(
                        '⏱️ [Customer Lookup][$lookupFlowLabel] offer preview backfill: '
                        '${offerPreviewStopwatch.elapsedMilliseconds}ms (phone=$phone)',
                      );
                      final latestPhoneForOffer = normalizePhone(
                        phoneCtrl.text,
                      );
                      if (!isDialogActive ||
                          latestPhoneForOffer != phone ||
                          requestId != lookupSequence) {
                        return;
                      }
                      final mergedPreviewData = mergeOfferPreviewData(
                        baseData: customerLookupData,
                        offerData: offerPreviewData,
                      );
                      final mergedOfferData = readOfferData(mergedPreviewData);
                      final mergedEligible =
                          enableCustomerLookup &&
                          mergedOfferData?['enabled'] == true &&
                          (mergedOfferData?['isOfferEligible'] == true ||
                              mergedOfferData?['historyBasedEligible'] == true);
                      setDialogState(() {
                        customerLookupData = mergedPreviewData;
                        applyCustomerOffer = mergedEligible;
                        lookupError = null;
                      });
                      autoSubmitIfReady(mergedPreviewData);
                    } catch (e) {
                      offerPreviewStopwatch.stop();
                      debugPrint(
                        '⚠️ [Customer Lookup][$lookupFlowLabel] offer preview backfill failed '
                        'after ${offerPreviewStopwatch.elapsedMilliseconds}ms '
                        '(phone=$phone): $e',
                      );
                    }
                  }());
                }

                final quickBills =
                    (quickData?['totalBills'] as num?)?.toInt() ?? 0;
                final quickAmount = readMoney(quickData?['totalAmount']);
                if (quickBills <= 0 && quickAmount <= 0) {
                  unawaited(() async {
                    final summaryLookupStopwatch = Stopwatch()..start();
                    try {
                      final summaryData = await cartProvider
                          .fetchCustomerLookupPreview(
                            phone,
                            limit: 1,
                            useHeavyFallback: true,
                            includeGlobalLookup: true,
                          );
                      summaryLookupStopwatch.stop();
                      debugPrint(
                        '⏱️ [Customer Lookup][$lookupFlowLabel] history summary backfill: '
                        '${summaryLookupStopwatch.elapsedMilliseconds}ms (phone=$phone)',
                      );
                      if (summaryData == null) return;

                      final latestPhoneForSummary = normalizePhone(
                        phoneCtrl.text,
                      );
                      if (!isDialogActive ||
                          latestPhoneForSummary != phone ||
                          requestId != lookupSequence) {
                        return;
                      }

                      final existing = customerLookupData;
                      final existingBills =
                          (existing?['totalBills'] as num?)?.toInt() ?? 0;
                      final existingAmount = readMoney(
                        existing?['totalAmount'],
                      );
                      final summaryBills =
                          (summaryData['totalBills'] as num?)?.toInt() ?? 0;
                      final summaryAmount = readMoney(
                        summaryData['totalAmount'],
                      );
                      final existingName =
                          existing?['name']?.toString().trim() ?? '';
                      final summaryName =
                          summaryData['name']?.toString().trim() ?? '';

                      final shouldUseSummary =
                          summaryBills > existingBills ||
                          summaryAmount > existingAmount ||
                          (existingName.isEmpty && summaryName.isNotEmpty);
                      if (!shouldUseSummary) return;

                      final mergedSummaryData = mergeOfferPreviewData(
                        baseData: summaryData,
                        offerData: existing,
                      );
                      final summaryOfferData = readOfferData(mergedSummaryData);
                      final summaryEligible =
                          enableCustomerLookup &&
                          summaryOfferData?['enabled'] == true &&
                          (summaryOfferData?['isOfferEligible'] == true ||
                              summaryOfferData?['historyBasedEligible'] ==
                                  true);

                      setDialogState(() {
                        customerLookupData = mergedSummaryData;
                        applyCustomerOffer = summaryEligible;
                        lookupError = null;
                      });
                      autoSubmitIfReady(mergedSummaryData);
                    } catch (e) {
                      summaryLookupStopwatch.stop();
                      debugPrint(
                        '⚠️ [Customer Lookup][$lookupFlowLabel] history summary backfill failed '
                        'after ${summaryLookupStopwatch.elapsedMilliseconds}ms '
                        '(phone=$phone): $e',
                      );
                    }
                  }());
                }
                return;
              }
              final latestPhone = normalizePhone(phoneCtrl.text);
              if (!isDialogActive ||
                  latestPhone != phone ||
                  requestId != lookupSequence) {
                return;
              }

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
                    enableCustomerLookup &&
                    offerData?['enabled'] == true &&
                    (offerData?['isOfferEligible'] == true ||
                        offerData?['historyBasedEligible'] == true);
                applyCustomerOffer = eligible;
              });
              autoSubmitIfReady(data);
            } catch (_) {
              final latestPhone = normalizePhone(phoneCtrl.text);
              if (!isDialogActive ||
                  latestPhone != phone ||
                  requestId != lookupSequence) {
                return;
              }
              setDialogState(() {
                customerLookupData = null;
                isLookupInProgress = false;
                lookupError = enableCustomerLookup
                    ? 'Unable to fetch customer details'
                    : null;
                applyCustomerOffer = false;
              });
            }
          }

          return StatefulBuilder(
            builder: (context, setDialogState) {
              void closeDialogSafely(Map<String, dynamic>? value) {
                if (didCloseDialog) return;
                didCloseDialog = true;
                setDialogState(() {
                  isDialogSubmitting = true;
                });
                isDialogActive = false;
                lookupSequence += 1;
                quickLookupDebounceTimer?.cancel();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  final nav = Navigator.of(context);
                  if (nav.canPop()) {
                    nav.pop(value);
                  }
                });
              }

              if (!didAutoLookup) {
                didAutoLookup = true;
                if (enableCustomerLookup) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!isDialogActive) return;
                    lookupSequence += 1;
                    lookupCustomer(
                      phoneCtrl.text,
                      setDialogState,
                      lookupSequence,
                    );
                  });
                }
              }

              final offerData = readOfferData(customerLookupData);
              final hasOfferPhoneInput = phoneCtrl.text.trim().isNotEmpty;
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
                  hasOfferPhoneInput &&
                  offerEligible &&
                  !hasEligibleItemLevelOffer;
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
                            final maxUsagePerCustomer = readMoney(
                              match['maxUsagePerCustomer'],
                            );
                            final customerUsageCount = readMoney(
                              match['customerUsageCount'],
                            );
                            final customerUsageRemaining = readMoney(
                              match['customerUsageRemaining'],
                            );
                            final offerWorth = freeQtyStep * freeUnitPrice;
                            final triggerCount = buyQtyStep > 0
                                ? (buyQtyInCart / buyQtyStep).floorToDouble()
                                : 0.0;
                            final statusMessage = blockedForNewCustomer
                                ? (nextBillMessage ??
                                      'This offer will be available from next bill after customer is created.')
                                : blockedWithoutCustomer
                                ? 'Customer is required for this offer.'
                                : globalLimitReached
                                ? 'Offer limit reached.'
                                : customerLimitReached
                                ? 'Customer limit reached.'
                                : usageLimitReached
                                ? 'Usage limit reached for this customer.'
                                : isEligible
                                ? 'Eligible now. Est. discount ₹${estimatedDiscount.toStringAsFixed(2)}'
                                : 'Need ${formatQty(remainingQty)} more $buyProductName';
                            final statusColor = blockedForNewCustomer
                                ? Colors.orangeAccent
                                : blockedWithoutCustomer ||
                                      globalLimitReached ||
                                      customerLimitReached ||
                                      usageLimitReached
                                ? Colors.redAccent
                                : isEligible
                                ? const Color(0xFF2EBF3B)
                                : Colors.orangeAccent;

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
                                    'A: $buyProductName x${formatQty(buyQtyStep)}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    'B: $freeProductName x${formatQty(freeQtyStep)} FREE',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    'Offer worth: ₹${offerWorth.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                      color: Color(0xFF2EBF3B),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    'Counts: A in cart ${formatQty(buyQtyInCart)} | Trigger ${formatQty(triggerCount)} | B free ${formatQty(freeQtyApplied)}',
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
                                    statusMessage,
                                    style: TextStyle(
                                      color: statusColor,
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
                        ],
                      ),
                    ),
                  ),
                if (productPriceOfferEnabled &&
                    productPriceOfferMatches.isNotEmpty)
                  Builder(
                    builder: (context) {
                      final match = productPriceOfferMatches.first;
                      final productName =
                          match['productName']?.toString() ?? 'Product';
                      final quantityInCart = readMoney(match['quantityInCart']);
                      final baseUnitPrice = readMoney(match['baseUnitPrice']);
                      final discountPerUnit = readMoney(
                        match['discountPerUnit'],
                      );
                      final offerUnitPrice = readMoney(match['offerUnitPrice']);
                      final predictedAppliedUnits = readMoney(
                        match['predictedAppliedUnits'],
                      );
                      final predictedDiscountTotal = readMoney(
                        match['predictedDiscountTotal'],
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
                      final regularUnits =
                          (quantityInCart - predictedAppliedUnits).clamp(
                            0.0,
                            double.infinity,
                          );
                      final statusMessage = blockedForNewCustomer
                          ? (nextBillMessage ??
                                'This offer will be available from next bill after customer is created.')
                          : blockedWithoutCustomer
                          ? 'Customer is required for this offer.'
                          : globalLimitReached
                          ? 'Offer limit reached.'
                          : customerLimitReached
                          ? 'Customer limit reached.'
                          : usageLimitReached
                          ? 'Usage limit reached for this customer.'
                          : isEligible
                          ? 'Eligible now. Est. discount ₹${predictedDiscountTotal.toStringAsFixed(2)}'
                          : 'No eligible discounted units in cart.';
                      final statusColor = blockedForNewCustomer
                          ? Colors.orangeAccent
                          : blockedWithoutCustomer ||
                                globalLimitReached ||
                                customerLimitReached ||
                                usageLimitReached
                          ? Colors.redAccent
                          : isEligible
                          ? const Color(0xFF2EBF3B)
                          : Colors.orangeAccent;
                      final extraMatchCount =
                          (productPriceOfferMatches.length - 1).clamp(
                            0,
                            productPriceOfferMatches.length,
                          );

                      return Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A1912),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: const Color(
                              0xFFFF9F0A,
                            ).withValues(alpha: 0.45),
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.max,
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Product Price Offer',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '$productName x${formatQty(quantityInCart)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '₹${baseUnitPrice.toStringAsFixed(2)} -> ₹${offerUnitPrice.toStringAsFixed(2)} | Worth ₹${discountPerUnit.toStringAsFixed(2)}/unit',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11.5,
                              ),
                            ),
                            Text(
                              'Counts: In ${formatQty(quantityInCart)} | Disc ${formatQty(predictedAppliedUnits)} | Reg ${formatQty(regularUnits)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11.5,
                              ),
                            ),
                            if (usageLimitEnabled)
                              Text(
                                'Usage: ${formatQty(customerUsageCount)} / ${formatQty(maxUsagePerCustomer)}'
                                '${customerUsageRemaining > 0 ? ' | Left ${formatQty(customerUsageRemaining)}' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11.5,
                                ),
                              ),
                            const SizedBox(height: 3),
                            Text(
                              statusMessage,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: statusColor,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (extraMatchCount > 0)
                              Text(
                                '+$extraMatchCount more product offer${extraMatchCount > 1 ? 's' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                if (customerEntryPercentageOfferEnabled)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF132323),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: const Color(0xFF26C6DA).withValues(alpha: 0.45),
                      ),
                    ),
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
                          mainAxisSize: MainAxisSize.max,
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            const Text(
                              'Customer Entry Percentage Offer',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${discountPercent.toStringAsFixed(2)}% OFF',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Color(0xFF26C6DA),
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.2,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              scheduleMatched
                                  ? 'Auto-applies from backend'
                                  : 'Not active now (time window).',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: scheduleMatched
                                    ? Colors.white70
                                    : Colors.orangeAccent,
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              scheduleBlocked
                                  ? 'Check schedule in settings.'
                                  : customerEntryPercentagePreviewEligible
                                  ? 'Eligible now.'
                                  : 'Eligibility is backend-validated.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: scheduleBlocked
                                    ? Colors.orangeAccent
                                    : customerEntryPercentagePreviewEligible
                                    ? const Color(0xFF2EBF3B)
                                    : Colors.white70,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        );
                      },
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
              final normalizedPhoneForHistory = phoneCtrl.text.replaceAll(
                RegExp(r'\D'),
                '',
              );
              final lookupTotalBills =
                  (customerLookupData?['totalBills'] as num?)?.toInt() ?? 0;
              final lookupTotalAmount = readMoney(
                customerLookupData?['totalAmount'],
              );
              final lookupCustomerName =
                  customerLookupData?['name']?.toString().trim() ?? '';
              final isExistingCustomerForHistory =
                  customerLookupData != null &&
                  customerLookupData?['isNewCustomer'] != true &&
                  (lookupTotalBills > 0 ||
                      lookupTotalAmount > 0 ||
                      lookupCustomerName.isNotEmpty);
              final canOpenCustomerHistory =
                  showCustomerHistoryByCms &&
                  isExistingCustomerForHistory &&
                  !isDialogSubmitting &&
                  normalizedPhoneForHistory.length >= 10;
              Map<String, dynamic> buildDialogSubmitPayload(
                String customerName,
                String customerPhone,
              ) {
                return <String, dynamic>{
                  'name': customerName,
                  'phone': customerPhone,
                  'applyCustomerOffer': effectiveApplyCustomerOffer,
                  'hasProductOfferMatch': hasEligibleProductOffer,
                  'hasProductPriceOfferMatch': hasEligibleProductPriceOffer,
                  'hasTotalPercentageOfferEnabled': totalPercentageOfferEnabled,
                  'hasCustomerEntryPercentageOfferEnabled':
                      customerEntryPercentageOfferEnabled,
                  'hasRandomOfferMatch': hasEligibleRandomOffer,
                };
              }

              void submitDialogFromCurrentInput({
                required bool requirePhoneAndNameForDoneShortcut,
              }) {
                if (isDialogSubmitting) return;
                final customerName = nameCtrl.text.trim();
                final customerPhone = phoneCtrl.text.trim();
                final normalizedPhone = customerPhone.replaceAll(
                  RegExp(r'\D'),
                  '',
                );

                if (requirePhoneAndNameForDoneShortcut) {
                  final canShortcutSubmit =
                      normalizedPhone.length >= 10 && customerName.isNotEmpty;
                  if (!canShortcutSubmit) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Enter 10-digit phone and customer name, then press Done',
                        ),
                      ),
                    );
                    return;
                  }
                }

                if (customerName.isEmpty && customerPhone.isEmpty) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        allowSkipCustomerDetailsByCms
                            ? "Please enter customer name or phone number, or use $skipActionLabel"
                            : "Please enter customer name or phone number",
                      ),
                    ),
                  );
                  return;
                }
                closeDialogSafely(
                  buildDialogSubmitPayload(customerName, customerPhone),
                );
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
                              Row(
                                children: [
                                  const Expanded(
                                    child: Center(
                                      child: Text(
                                        "Customer Details",
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 20,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
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
                                  enabled: !isDialogSubmitting,
                                  autofocus: true,
                                  keyboardType: TextInputType.phone,
                                  textInputAction: TextInputAction.done,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                    LengthLimitingTextInputFormatter(10),
                                  ],
                                  style: const TextStyle(color: Colors.white),
                                  onSubmitted: (_) {
                                    if (autoSubmitCustomerDetailsByCms) {
                                      submitDialogFromCurrentInput(
                                        requirePhoneAndNameForDoneShortcut:
                                            true,
                                      );
                                    } else {
                                      FocusScope.of(context).nextFocus();
                                    }
                                  },
                                  onChanged: (val) {
                                    if (isDialogSubmitting) return;
                                    if (!isDialogActive) return;
                                    setDialogState(() {});
                                    quickLookupDebounceTimer?.cancel();
                                    lookupSequence += 1;
                                    final normalizedPhone = val.replaceAll(
                                      RegExp(r'\D'),
                                      '',
                                    );
                                    if (normalizedPhone.length < 10) {
                                      setDialogState(() {
                                        customerLookupData = null;
                                        lookupError = null;
                                        isLookupInProgress = false;
                                        applyCustomerOffer = false;
                                      });
                                      return;
                                    }
                                    final requestId = lookupSequence;
                                    if (enableCustomerLookup) {
                                      setDialogState(() {
                                        lookupError = null;
                                        isLookupInProgress = true;
                                      });
                                    }
                                    quickLookupDebounceTimer = Timer(
                                      const Duration(milliseconds: 300),
                                      () => lookupCustomer(
                                        val,
                                        setDialogState,
                                        requestId,
                                      ),
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
                              if (enableCustomerLookup &&
                                  isLookupInProgress) ...[
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
                              if (enableCustomerLookup &&
                                  lookupError != null) ...[
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
                                  enabled: !isDialogSubmitting,
                                  textInputAction: TextInputAction.done,
                                  style: const TextStyle(color: Colors.white),
                                  onSubmitted: (_) {
                                    submitDialogFromCurrentInput(
                                      requirePhoneAndNameForDoneShortcut: false,
                                    );
                                  },
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
                              if (showCustomerHistoryByCms &&
                                  isExistingCustomerForHistory &&
                                  normalizedPhoneForHistory.length >= 10) ...[
                                const SizedBox(height: 14),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton.icon(
                                    onPressed: canOpenCustomerHistory
                                        ? () async {
                                            await showCustomerHistoryDialog(
                                              context,
                                              phoneNumber: phoneCtrl.text,
                                            );
                                          }
                                        : null,
                                    icon: const Icon(
                                      Icons.history_rounded,
                                      color: Colors.white,
                                    ),
                                    label: const Text(
                                      'CUSTOMER HISTORY',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.3,
                                      ),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF16A34A),
                                      foregroundColor: Colors.white,
                                      disabledBackgroundColor: const Color(
                                        0xFF2C3A2F,
                                      ),
                                      disabledForegroundColor: Colors.white54,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 13,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                              if (!isTableOrderFlow &&
                                  phoneCtrl.text.trim().isEmpty) ...[
                                const SizedBox(height: 12),
                                const Text(
                                  'Enter customer phone number to apply offers',
                                  style: TextStyle(
                                    color: Colors.orangeAccent,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                              if (!isTableOrderFlow &&
                                  normalizedPhoneForHistory.length >= 10 &&
                                  offerCards.isNotEmpty) ...[
                                const SizedBox(height: 12),
                                offerCards[offerPageIndex],
                                if (offerCards.length > 1) ...[
                                  const SizedBox(height: 8),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      IconButton(
                                        onPressed: isDialogSubmitting
                                            ? null
                                            : () {
                                                setDialogState(() {
                                                  offerPageIndex =
                                                      (offerPageIndex - 1) %
                                                      offerCards.length;
                                                  if (offerPageIndex < 0) {
                                                    offerPageIndex =
                                                        offerCards.length - 1;
                                                  }
                                                });
                                              },
                                        icon: const Icon(
                                          Icons.chevron_left_rounded,
                                          color: Colors.white70,
                                        ),
                                      ),
                                      Text(
                                        '${offerPageIndex + 1}/${offerCards.length}',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      IconButton(
                                        onPressed: isDialogSubmitting
                                            ? null
                                            : () {
                                                setDialogState(() {
                                                  offerPageIndex =
                                                      (offerPageIndex + 1) %
                                                      offerCards.length;
                                                });
                                              },
                                        icon: const Icon(
                                          Icons.chevron_right_rounded,
                                          color: Colors.white70,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                              const SizedBox(height: 20),
                              if (allowSkipCustomerDetailsByCms)
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton(
                                        onPressed: isDialogSubmitting
                                            ? null
                                            : () {
                                                closeDialogSafely(
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
                                        child: Text(skipActionLabel),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: ElevatedButton(
                                        onPressed: isDialogSubmitting
                                            ? null
                                            : () => submitDialogFromCurrentInput(
                                                requirePhoneAndNameForDoneShortcut:
                                                    false,
                                              ),
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
                                        child: Text(
                                          isDialogSubmitting
                                              ? "Submitting..."
                                              : submitActionLabel,
                                          style: const TextStyle(
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
                                    onPressed: isDialogSubmitting
                                        ? null
                                        : () => submitDialogFromCurrentInput(
                                            requirePhoneAndNameForDoneShortcut:
                                                false,
                                          ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF0A84FF),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                    child: Text(
                                      isDialogSubmitting
                                          ? "Submitting..."
                                          : submitActionLabel,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        right: 8,
                        top: 8,
                        child: IconButton(
                          icon: const Icon(Icons.close, color: Colors.white54),
                          onPressed: isDialogSubmitting
                              ? null
                              : () => closeDialogSafely(null),
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
      isDialogActive = false;
      lookupSequence += 1;
      quickLookupDebounceTimer?.cancel();

      if (customerDetails == null) {
        setState(() => _isBillingInProgress = false);
        return;
      }
    } else {
      // Dialog disabled by CMS for this order type; use saved details.
      customerDetails = {
        'name': existingCustomerName,
        'phone': existingCustomerPhone,
      };
    }

    if (shouldShowCustomerDetailsDialog) {
      userInputMs = stopwatch.elapsedMilliseconds;
    }
    // Reset stage timer so pre-api/api/post reflect processing time only.
    stopwatch
      ..reset()
      ..start();

    final shouldApplyCustomerOffer =
        status == 'completed' &&
        (customerDetails['applyCustomerOffer'] == true);
    final fastKotModeForThisBill = _fastKotMode && status == 'pending';
    final fastModeForThisBill = _fastBillingMode && status == 'completed';
    final ultraFastModeForThisBill =
        _ultraFastBillingMode && status == 'completed';
    final hasProductOfferMatch =
        customerDetails['hasProductOfferMatch'] == true;
    final hasProductPriceOfferMatch =
        customerDetails['hasProductPriceOfferMatch'] == true;
    final hasTotalPercentageOfferEnabled =
        customerDetails['hasTotalPercentageOfferEnabled'] == true;
    final hasCustomerEntryPercentageOfferEnabled =
        customerDetails['hasCustomerEntryPercentageOfferEnabled'] == true;
    final hasRandomOfferMatch = customerDetails['hasRandomOfferMatch'] == true;
    String billingCustomerName =
        (customerDetails['name'] ?? cartProvider.customerName ?? '')
            .toString()
            .trim();
    String billingCustomerPhone =
        (customerDetails['phone'] ?? cartProvider.customerPhone ?? '')
            .toString()
            .trim();
    final normalizedBillingCustomerPhone = billingCustomerPhone.replaceAll(
      RegExp(r'\D'),
      '',
    );
    final shouldSendCustomerUpfrontForBilling =
        status == 'completed' &&
        cartProvider.currentType != CartType.table &&
        normalizedBillingCustomerPhone.length >= 10;
    final shouldForceSkipCustomerOffer =
        (fastModeForThisBill || ultraFastModeForThisBill) &&
        !shouldSendCustomerUpfrontForBilling;
    final effectiveApplyCustomerOffer = shouldForceSkipCustomerOffer
        ? false
        : shouldApplyCustomerOffer;
    final requiresPhoneForOffer =
        !shouldForceSkipCustomerOffer &&
        status == 'completed' &&
        (shouldApplyCustomerOffer ||
            hasProductOfferMatch ||
            hasProductPriceOfferMatch ||
            hasTotalPercentageOfferEnabled ||
            hasRandomOfferMatch);

    String? tableNumberForSubmit = cartProvider.selectedTable;
    String? sectionForSubmit = cartProvider.selectedSection;
    bool shouldResolveSharedTarget = false;

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
      shouldResolveSharedTarget = true;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) {
        setState(() => _isBillingInProgress = false);
        return;
      }

      await _ensureBillingIdentifiers(cartProvider: cartProvider, prefs: prefs);
      if (_branchId == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to resolve branch. Please retry.'),
          ),
        );
        setState(() => _isBillingInProgress = false);
        return;
      }

      if (shouldResolveSharedTarget &&
          tableNumberForSubmit?.trim().isNotEmpty == true) {
        final target = await _resolveSharedInputTarget(
          tableNumberInput: tableNumberForSubmit!,
          branchId: _branchId!,
          token: token,
          preferredSection: cartProvider.selectedSection,
        );
        tableNumberForSubmit = target['tableNumber']?.toString().trim();
        sectionForSubmit = target['section']?.toString().trim();
        final hasResolvedTable =
            tableNumberForSubmit != null && tableNumberForSubmit.isNotEmpty;
        final hasResolvedSection =
            sectionForSubmit != null && sectionForSubmit.isNotEmpty;
        if (!hasResolvedTable || !hasResolvedSection) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Unable to resolve table. Please try again.'),
            ),
          );
          setState(() => _isBillingInProgress = false);
          return;
        }
        if (cartProvider.selectedTable != tableNumberForSubmit ||
            cartProvider.selectedSection != sectionForSubmit) {
          cartProvider.setSelectedTableMetadata(
            tableNumberForSubmit,
            sectionForSubmit,
          );
        }
      }

      debugPrint('📦 ID Resolution: ${stopwatch.elapsedMilliseconds}ms');

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
          final trimmedNote = noteValue.toString().trim();
          payload['specialNote'] = trimmedNote;
          payload['notes'] = trimmedNote;
          payload['note'] = trimmedNote;
          payload['instructions'] = trimmedNote;
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

      Map<String, dynamic>? toUltraFastCartItemPayload(CartItem item) {
        if (item.isOfferFreeItem || item.isRandomCustomerOfferItem) {
          return null;
        }
        if (item.id.trim().isEmpty) {
          return null;
        }

        final safeQty = item.quantity > 0 ? item.quantity : 1.0;
        final safeUnitPrice = item.price < 0 ? 0.0 : item.price;
        final safeSubtotal =
            item.lineSubtotal != null && item.lineSubtotal! >= 0
            ? item.lineSubtotal!
            : (safeQty * safeUnitPrice);

        final payload = <String, dynamic>{
          if (item.billingItemId?.trim().isNotEmpty == true)
            'id': item.billingItemId!.trim(),
          'product': item.id,
          'name': item.name,
          'quantity': safeQty,
          'unitPrice': safeUnitPrice,
          'subtotal': safeSubtotal,
        };

        final statusValue = item.status?.trim();
        if (statusValue != null && statusValue.isNotEmpty) {
          payload['status'] = statusValue;
        }
        final noteValue = item.specialNote?.trim();
        if (noteValue != null && noteValue.isNotEmpty) {
          payload['specialNote'] = noteValue;
          payload['notes'] = noteValue;
          payload['note'] = noteValue;
          payload['instructions'] = noteValue;
        }
        final unitValue = item.unit?.trim();
        if (unitValue != null && unitValue.isNotEmpty) {
          payload['unit'] = unitValue;
        }

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
      final shouldSkipBlockingTableLookup =
          _fastKotMode &&
          status == 'pending' &&
          isTableOrderForSubmit &&
          billId == null;
      final List<Map<String, dynamic>> existingServerItemsPayload = [];
      // 2. Parallel ID & Table Lookup
      final List<Future<void>> preFlightTasks = [];

      if (isTableOrderForSubmit &&
          billId == null &&
          hasTableNumberForSubmit &&
          hasSectionForSubmit &&
          !shouldSkipBlockingTableLookup) {
        preFlightTasks.add(() async {
          final lStart = stopwatch.elapsedMilliseconds;
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
            'limit': '1',
            'sort': '-updatedAt',
            'depth': '0',
          };
          if (_branchId != null)
            lookupParams['where[branch][equals]'] = _branchId!;

          try {
            final lookupResponse = await http.get(
              Uri.https(
                'blackforest.vseyal.com',
                '/api/billings',
                lookupParams,
              ),
              headers: {'Authorization': 'Bearer $token'},
            );
            if (lookupResponse.statusCode == 200) {
              final lookupRaw = jsonDecode(lookupResponse.body);
              // ... processing existing items ...
              final docsRaw = lookupRaw['docs'] as List?;
              if (docsRaw != null && docsRaw.isNotEmpty) {
                final doc = Map<String, dynamic>.from(docsRaw.first);
                billId = parseAnyId(doc['id']) ?? parseAnyId(doc['_id']);
                debugPrint('📦 Found Existing Table Bill: $billId');
              }
            }
          } catch (e) {
            debugPrint('📦 Lookup Error: $e');
          }
          debugPrint(
            '⏱️ Table Lookup took: ${stopwatch.elapsedMilliseconds - lStart}ms',
          );
        }());
      } else if (shouldSkipBlockingTableLookup) {
        debugPrint(
          '⚡ Fast KOT mode: skipping blocking table lookup, sending KOT immediately',
        );
      }

      if (preFlightTasks.isNotEmpty) {
        await Future.wait(preFlightTasks);
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
      cartProvider.setCustomerDetails(
        name: billingCustomerName,
        phone: billingCustomerPhone,
      );
      final deferCustomerSyncForUltraFast =
          ultraFastModeForThisBill &&
          !shouldSendCustomerUpfrontForBilling &&
          (billingCustomerName.isNotEmpty || billingCustomerPhone.isNotEmpty);
      final requestCustomerName =
          (deferCustomerSyncForUltraFast ||
              (fastModeForThisBill && !shouldSendCustomerUpfrontForBilling))
          ? ''
          : billingCustomerName;
      final requestCustomerPhone =
          ((fastModeForThisBill && !shouldSendCustomerUpfrontForBilling) ||
              deferCustomerSyncForUltraFast)
          ? ''
          : billingCustomerPhone;

      final itemNotes = cartProvider.cartItems
          .where(
            (item) => item.specialNote != null && item.specialNote!.isNotEmpty,
          )
          .map((item) => '${item.name}: ${item.specialNote}')
          .join(', ');

      String billingNotes = (ultraFastModeForThisBill || fastKotModeForThisBill)
          ? ''
          : itemNotes;
      if (fastModeForThisBill &&
          !shouldSendCustomerUpfrontForBilling &&
          (billingCustomerName.isNotEmpty || billingCustomerPhone.isNotEmpty)) {
        final fastCustomerMeta =
            'customer(name:${billingCustomerName.isEmpty ? '-' : billingCustomerName},phone:${billingCustomerPhone.isEmpty ? '-' : billingCustomerPhone})';
        billingNotes = billingNotes.isEmpty
            ? fastCustomerMeta
            : '$billingNotes | $fastCustomerMeta';
      }

      final payloadItems = <Map<String, dynamic>>[];
      if (existingServerItemsPayload.isNotEmpty) {
        payloadItems.addAll(existingServerItemsPayload);
      }
      final itemsToAppend = existingServerItemsPayload.isNotEmpty
          ? cartProvider.cartItems
          : mergedItems;
      final useLeanItemPayload =
          ultraFastModeForThisBill || fastKotModeForThisBill;
      for (final item in itemsToAppend) {
        final mapped = useLeanItemPayload
            ? toUltraFastCartItemPayload(item)
            : toPurchasedCartItemPayload(item);
        if (mapped != null) {
          payloadItems.add(mapped);
        }
      }

      final billingData = <String, dynamic>{
        'items': payloadItems,
        'totalAmount': cartProvider.total,
        'branch': _branchId,
        'recalledBillId': billId, // PASS RESOLVED BILL ID
        'customerDetails': {
          'name': requestCustomerName,
          'phoneNumber': requestCustomerPhone,
          'address': '', // Placeholder as shown in schema
        },
        'paymentMethod': _selectedPaymentMethod,
        'isReminder': isReminder,
        if (billingNotes.isNotEmpty || !ultraFastModeForThisBill)
          'notes': billingNotes,
        'applyCustomerOffer': effectiveApplyCustomerOffer,
        'status': status,
      };
      if (_companyId != null && _companyId!.isNotEmpty) {
        billingData['company'] = _companyId;
      }
      if (isTableOrderForSubmit) {
        billingData['tableDetails'] = {
          'section': sectionForSubmit,
          'tableNumber': tableNumberForSubmit,
        };
      }

      if (ultraFastModeForThisBill) {
        final payloadBytes = utf8.encode(jsonEncode(billingData)).length;
        debugPrint(
          '⚡ Ultra Fast Billing mode ON: $payloadItems.length items | $payloadBytes bytes payload',
        );
        if (deferCustomerSyncForUltraFast) {
          debugPrint(
            '⚡ Ultra Fast Billing mode: deferring customer save to post-bill sync',
          );
        } else if (shouldSendCustomerUpfrontForBilling) {
          debugPrint(
            '⚡ Ultra Fast Billing mode: sending customer in initial bill request',
          );
        }
      }
      if (fastKotModeForThisBill) {
        final payloadBytes = utf8.encode(jsonEncode(billingData)).length;
        debugPrint(
          '⚡ Fast KOT payload mode ON: $payloadItems.length items | $payloadBytes bytes payload',
        );
      }

      final url = billId != null
          ? Uri.parse(
              'https://blackforest.vseyal.com/api/billings/$billId?depth=0',
            )
          : Uri.parse('https://blackforest.vseyal.com/api/billings?depth=0');

      billApiStartMs = stopwatch.elapsedMilliseconds;
      debugPrint(
        '📦 BILL API START: ${url.host}${url.path} at ${billApiStartMs}ms',
      );
      const billingWriteTimeout = Duration(seconds: 45);
      Future<http.Response> sendBillingRequestWithTimeout(
        Duration timeout,
      ) async {
        if (billId != null) {
          return http.patch(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(billingData),
            timeout: timeout,
          );
        }
        return http.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode(billingData),
          timeout: timeout,
        );
      }

      http.Response response;
      try {
        response = await sendBillingRequestWithTimeout(billingWriteTimeout);
      } on TimeoutException catch (error) {
        if (billId == null) rethrow;
        debugPrint(
          '📦 BILL API TIMEOUT on PATCH after ${billingWriteTimeout.inSeconds}s. Retrying once with 60s timeout. Error: $error',
        );
        response = await sendBillingRequestWithTimeout(
          const Duration(seconds: 60),
        );
      }
      billApiDurationMs = stopwatch.elapsedMilliseconds - billApiStartMs;

      debugPrint('📦 METHOD: ${billId != null ? "PATCH" : "POST"}');
      if (_verboseBillingLogs) {
        debugPrint('📦 PAYLOAD JSON: ${jsonEncode(billingData)}');
      }

      final billingResponse = jsonDecode(response.body);
      debugPrint(
        '📦 BILL RESPONSE RECEIVED (API Call: ${stopwatch.elapsedMilliseconds - billApiStartMs}ms)',
      );
      if (_verboseBillingLogs) {
        debugPrint('📦 BILL RESPONSE: $billingResponse');
      }

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

      // Redundant refetch removed. We now use ?depth=3 in the primary POST/PATCH.

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
      final shouldHydrateServerItems =
          status == 'pending' || !ultraFastModeForThisBill;
      if (shouldHydrateServerItems && responseItems is List) {
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
          final productGstPercent = CartItem.extractEffectiveGstPercent(
            productMap,
            branchId: _branchId,
          );
          final gstPercent = productGstPercent > 0
              ? productGstPercent
              : (fallback?.gstPercent ??
                    CartItem.parsePercent(item['gstPercent']));

          return CartItem(
            id: productId ?? fallback?.id ?? '',
            billingItemId: item['id']?.toString() ?? fallback?.billingItemId,
            name: itemName,
            price: isReadOnlyOfferItem ? 0.0 : unitPrice,
            gstPercent: gstPercent,
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

      final shouldApplyCustomerOfferInDeferredFinalize =
          status == 'completed' &&
          !isTableOrderForSubmit &&
          !shouldSendCustomerUpfrontForBilling &&
          normalizedBillingCustomerPhone.length >= 10 &&
          (shouldApplyCustomerOffer ||
              effectiveApplyCustomerOffer ||
              hasProductOfferMatch ||
              hasProductPriceOfferMatch ||
              hasTotalPercentageOfferEnabled ||
              hasCustomerEntryPercentageOfferEnabled ||
              hasRandomOfferMatch ||
              fastModeForThisBill ||
              ultraFastModeForThisBill);
      final expectsOfferSyncForDeferred =
          shouldApplyCustomerOfferInDeferredFinalize;
      final deferredFinalizeBillId = (savedBillId ?? billId ?? '').trim();
      final shouldRunDeferredOfferFinalize =
          status == 'completed' &&
          !isTableOrderForSubmit &&
          (fastModeForThisBill || deferCustomerSyncForUltraFast) &&
          deferredFinalizeBillId.isNotEmpty &&
          expectsOfferSyncForDeferred;
      if (shouldRunDeferredOfferFinalize) {
        debugPrint(
          '⚡ Deferred offer finalize armed: bill=$deferredFinalizeBillId phone=$normalizedBillingCustomerPhone',
        );
      }

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
        final printMessenger = ScaffoldMessenger.of(context);

        if (status == 'pending') {
          // Identify newly added/updated items from the server response
          final setExistingIds = cartProvider.recalledItems
              .map((i) => i.billingItemId)
              .where((id) => id != null)
              .toSet();

          // We use the server-returned items (finalServerItems) because they include
          // auto-added offer items (Type 2, Type 4, etc.) from the backend.
          // Filtering by !setExistingIds identifies what was just created in this request.
          final List<CartItem> kotItems = finalServerItems
              .where((i) => !setExistingIds.contains(i.billingItemId))
              .where((i) => i.status != 'cancelled')
              .toList();

          // Per user request, for product-based offers (2 & 4), ensure the trigger product
          // is present in the KOT as a reference, even if it was previously ordered.
          final Set<String> addedTriggerIds = {};
          final List<CartItem> referenceItems = [];
          for (final item in kotItems) {
            final triggerId = item.offerTriggerProductId;
            if (triggerId != null && triggerId.isNotEmpty) {
              // Check if trigger is already in this KOT batch to avoid duplicates
              final existsInBatch = kotItems.any((i) => i.id == triggerId);
              if (!existsInBatch && !addedTriggerIds.contains(triggerId)) {
                try {
                  final triggerItem = finalServerItems.firstWhere(
                    (i) => i.id == triggerId,
                  );
                  addedTriggerIds.add(triggerId);
                  referenceItems.add(
                    CartItem(
                      id: triggerItem.id,
                      name: triggerItem.name,
                      price: triggerItem.price,
                      gstPercent: triggerItem.gstPercent,
                      imageUrl: triggerItem.imageUrl,
                      quantity: triggerItem.quantity,
                      unit: triggerItem.unit,
                      department: triggerItem.department,
                      categoryId: triggerItem.categoryId,
                      specialNote:
                          "[OFFER TRIGGER REF]", // Clearly mark it's a reference
                      status: triggerItem.status,
                      isOfferFreeItem: triggerItem.isOfferFreeItem,
                    ),
                  );
                } catch (_) {}
              }
            }
          }
          kotItems.addAll(referenceItems);

          final submittedBillId = (savedBillId ?? billId ?? '').trim();
          if (submittedBillId.isNotEmpty && kotItems.isNotEmpty) {
            unawaited(
              KotAutoPrintService.acknowledgeSubmittedKotItems(
                billId: submittedBillId,
                items: kotItems,
              ),
            );
          }

          _handleKOTPrinting(
            items: kotItems,
            billingResponse: billingResponse,
            customerDetails: customerDetails,
            messenger: printMessenger,
          );
        } else {
          var receiptPrinterIp = (cartProvider.printerIp ?? '').trim();
          var receiptPrinterPort = cartProvider.printerPort;
          var receiptPrinterProtocol =
              cartProvider.printerProtocol ?? 'esc_pos';

          if (receiptPrinterIp.isEmpty) {
            final fallbackPrinter = _resolveFirstKotPrinterTarget();
            if (fallbackPrinter != null) {
              receiptPrinterIp = fallbackPrinter.key;
              receiptPrinterPort = fallbackPrinter.value;
              receiptPrinterProtocol = 'esc_pos';
              debugPrint(
                '⚡ Receipt printer fallback: using KOT printer $receiptPrinterIp:$receiptPrinterPort',
              );
            }
          }

          if (shouldRunDeferredOfferFinalize) {
            debugPrint(
              '⚡ Deferred offer finalize: syncing customer+offer for bill $deferredFinalizeBillId',
            );
            unawaited(
              _finalizeHybridOfferAndPrint(
                token: token,
                billId: deferredFinalizeBillId,
                customerName: billingCustomerName,
                customerPhone: billingCustomerPhone,
                applyCustomerOffer: shouldApplyCustomerOfferInDeferredFinalize,
                expectOfferSync: expectsOfferSyncForDeferred,
                items: finalServerItems,
                customerDetails: customerDetails,
                paymentMethod: _selectedPaymentMethod!,
                initialBillingResponse: finalBillDoc,
                initialTotalAmount: billedTotal,
                initialGrossAmount: billedGrossAmount,
                messenger: printMessenger,
                printerIp: receiptPrinterIp,
                printerPort: receiptPrinterPort,
                printerProtocol: receiptPrinterProtocol,
              ),
            );
          } else if (receiptPrinterIp.isEmpty) {
            debugPrint('⚠️ No receipt printer configured. Skipping print.');
            _showPrintStatusSnack(
              printMessenger,
              message:
                  'Bill saved, but receipt not printed (printer not configured).',
              isSuccess: false,
            );
          } else {
            _printReceipt(
              items: finalServerItems,
              totalAmount: billedTotal,
              grossAmount: billedGrossAmount,
              printerIp: receiptPrinterIp,
              printerPort: receiptPrinterPort,
              printerProtocol: receiptPrinterProtocol,
              billingResponse: finalBillDoc,
              customerDetails: customerDetails,
              paymentMethod: _selectedPaymentMethod!,
              messenger: printMessenger,
            );
          }
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
          final completedBillId = (savedBillId ?? billId ?? '').trim();
          if (completedBillId.isNotEmpty) {
            unawaited(
              KotAutoPrintService.acknowledgeCompletedBill(
                billId: completedBillId,
              ),
            );
          }
          cartProvider.clearCart();
        }

        final customerSyncBillId = (savedBillId ?? billId ?? '').trim();
        final shouldSyncCustomerAfterBill =
            !shouldRunDeferredOfferFinalize &&
            (fastModeForThisBill || deferCustomerSyncForUltraFast) &&
            customerSyncBillId.isNotEmpty &&
            (billingCustomerName.isNotEmpty || billingCustomerPhone.isNotEmpty);
        if (shouldSyncCustomerAfterBill) {
          unawaited(
            _syncCustomerDetailsForFastMode(
              token: token,
              billId: customerSyncBillId,
              customerName: billingCustomerName,
              customerPhone: billingCustomerPhone,
              applyCustomerOffer: shouldApplyCustomerOfferInDeferredFinalize,
            ),
          );
        }
        final totalSavedAmount = (billedGrossAmount - billedTotal)
            .clamp(0.0, double.infinity)
            .toDouble();
        final successMessage = status == 'pending'
            ? 'KOT SENT SUCCESSFULLY'
            : shouldRunDeferredOfferFinalize
            ? 'Billing submitted. Finalizing offer...'
            : totalSavedAmount > 0.0001
            ? 'Billing submitted. Payable: ₹${billedTotal.toStringAsFixed(2)} (Saved ₹${totalSavedAmount.toStringAsFixed(2)})'
            : 'Billing submitted. Payable: ₹${billedTotal.toStringAsFixed(2)}';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successMessage)));
        FocusManager.instance.primaryFocus?.unfocus();
        if (!mounted) return;
        if (status == 'pending' && cartProvider.currentType == CartType.table) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (context) => const TablePage()),
            (route) => false,
          );
        } else {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  const CategoriesPage(sourcePage: PageType.billing),
            ),
            (route) => false,
          );
        }
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: ${response.statusCode}')),
        );
      }
    } catch (e) {
      final processingMs = stopwatch.elapsedMilliseconds;
      final totalMs = userInputMs + processingMs;
      final apiStart = billApiStartMs;
      final apiMs = apiStart == null ? null : (processingMs - apiStart);
      if (apiMs == null) {
        debugPrint(
          '📦 BILL ERROR after ${processingMs}ms processing (total ${totalMs}ms): $e',
        );
      } else {
        debugPrint(
          '📦 BILL ERROR (API Call: ${apiMs}ms) after ${processingMs}ms processing (total ${totalMs}ms): $e',
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      stopwatch.stop();
      final processingMs = stopwatch.elapsedMilliseconds;
      final totalMs = userInputMs + processingMs;
      final apiStart = billApiStartMs;
      if (apiStart == null) {
        debugPrint(
          '⏱️ [FINISH] _submitBilling Total: ${totalMs}ms (input: ${userInputMs}ms, processing: ${processingMs}ms)',
        );
      } else {
        final preApiMs = apiStart;
        final apiMs = billApiDurationMs ?? max(0, processingMs - apiStart);
        final postMs = max(0, processingMs - preApiMs - apiMs);
        debugPrint(
          '⏱️ [FINISH] _submitBilling Total: ${totalMs}ms (input: ${userInputMs}ms, pre-api: ${preApiMs}ms, api: ${apiMs}ms, post: ${postMs}ms)',
        );
      }
      if (mounted) {
        setState(() => _isBillingInProgress = false);
      }
    }
  }

  bool _isQrOrWebsiteOrder(dynamic rawBill) {
    Map<String, dynamic> asMap(dynamic value) => value is Map
        ? Map<String, dynamic>.from(value)
        : const <String, dynamic>{};

    bool isTruthy(dynamic value) {
      if (value is bool) return value;
      final normalized = value?.toString().trim().toLowerCase() ?? '';
      return normalized == 'true' || normalized == '1' || normalized == 'yes';
    }

    bool hasSourceHint(dynamic value) {
      final normalized = value?.toString().trim().toLowerCase() ?? '';
      if (normalized.isEmpty) return false;
      return normalized.contains('qr') ||
          normalized.contains('website') ||
          normalized.contains('web') ||
          normalized.contains('online');
    }

    bool containsQrHints(Map<String, dynamic> bill) {
      const boolKeys = <String>[
        'isQrOrder',
        'isQRorder',
        'isQR',
        'qrOrder',
        'isWebsiteOrder',
        'websiteOrder',
        'isWebOrder',
        'isOnlineOrder',
      ];
      const sourceKeys = <String>[
        'source',
        'orderSource',
        'sourceType',
        'orderChannel',
        'channel',
        'origin',
        'platform',
        'placedVia',
        'createdFrom',
        'mode',
      ];

      for (final key in boolKeys) {
        if (bill.containsKey(key) && isTruthy(bill[key])) {
          return true;
        }
      }
      for (final key in sourceKeys) {
        if (bill.containsKey(key) && hasSourceHint(bill[key])) {
          return true;
        }
      }
      return false;
    }

    final bill = asMap(rawBill);
    if (containsQrHints(bill)) return true;

    final doc = asMap(bill['doc']);
    if (containsQrHints(doc)) return true;

    return false;
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
    required ScaffoldMessengerState messenger,
  }) async {
    if (printerProtocol != 'esc_pos') {
      _showPrintStatusSnack(
        messenger,
        message:
            'Bill saved, but receipt not printed (unsupported printer setup).',
        isSuccess: false,
      );
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

    String formatReceiptMoney(double value) {
      final rounded = double.parse(value.toStringAsFixed(2));
      if ((rounded - rounded.truncateToDouble()).abs() < 0.001) {
        return rounded.toStringAsFixed(0);
      }
      return rounded.toStringAsFixed(2);
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

    if (_isQrOrWebsiteOrder(billingResponse)) {
      // For QR/website-origin orders, display customer name when present.
      String? custName;

      if (customerDetails['name'] != null &&
          customerDetails['name'].toString().trim().isNotEmpty) {
        custName = customerDetails['name'].toString().trim();
      }

      if (custName == null) {
        final dynamic doc = billingResponse['doc'] ?? billingResponse;
        final dynamic details = doc['customerDetails'];

        if (details is Map &&
            details['name'] != null &&
            details['name'].toString().trim().isNotEmpty) {
          custName = details['name'].toString().trim();
        } else if (doc['customerName'] != null &&
            doc['customerName'].toString().trim().isNotEmpty) {
          custName = doc['customerName'].toString().trim();
        } else if (doc['name'] != null &&
            doc['name'].toString().trim().isNotEmpty &&
            (doc['name'] != _branchName)) {
          // Only use top-level name when it's not branch name.
          custName = doc['name'].toString().trim();
        }
      }

      if (custName != null && custName.isNotEmpty && custName != 'Unknown') {
        waiterName = custName;
      }
    }

    try {
      const PaperSize paper = PaperSize.mm80;
      final profile = await CapabilityProfile.load();
      final prefs = await SharedPreferences.getInstance();
      final prefsPort = int.tryParse(
        (prefs.getString('printerPort') ?? '').trim(),
      );
      final candidatePorts = <int>[
        printerPort,
        if (prefsPort != null) prefsPort,
        9100,
        9101,
      ].toSet().toList(growable: false);

      final printer = await UnifiedPrinter.connect(
        printerIp: printerIp,
        candidatePorts: candidatePorts,
        paperSize: paper,
        profile: profile,
        jobType: PrintJobType.billing,
      );

      if (printer != null) {
        debugPrint('🖨️ Receipt printing started');
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
              bold: true,
            ), // Confirmed Left Align
          ),
          PosColumn(
            text: 'BILL NO - $billNo',
            width: 6,
            styles: const PosStyles(align: PosAlign.right, bold: true),
          ),
        ]);

        // Check if it's a table order to decide whether to show KOT Number
        final dynamic tableData =
            billingResponse['tableDetails'] ??
            billingResponse['doc']?['tableDetails'];
        final bool isTableOrder =
            tableData != null &&
            tableData['tableNumber'] != null &&
            tableData['tableNumber'].toString().trim().isNotEmpty;

        if (isTableOrder) {
          final String tableNum = tableData['tableNumber'].toString().trim();
          final String displayTable = tableNum.length == 1
              ? '0$tableNum'
              : tableNum;
          final String section = tableData['section']?.toString().trim() ?? '';
          final String tableText = section.isNotEmpty
              ? 'Table: $displayTable ($section)'
              : 'Table: $displayTable';

          printer.row([
            PosColumn(
              text: 'Assigned by: ${waiterName ?? 'Unknown'}',
              width: 7,
              styles: const PosStyles(align: PosAlign.left, bold: true),
            ),
            PosColumn(
              text: tableText,
              width: 5,
              styles: const PosStyles(align: PosAlign.right, bold: true),
            ),
          ]);
        } else {
          printer.text(
            'Assigned by: ${waiterName ?? 'Unknown'}',
            styles: const PosStyles(align: PosAlign.left, bold: true),
          );
        }

        printer.hr(ch: '=');
        final gstScale = grossAmount > 0.0001 && totalAmount < grossAmount
            ? (totalAmount / grossAmount).clamp(0.0, 1.0)
            : 1.0;
        final cgstBreakdownPaise = <double, int>{};
        final sgstBreakdownPaise = <double, int>{};
        int receiptTaxableSubtotalPaise = 0;
        printer.row([
          PosColumn(
            text: 'Item',
            width: 4,
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
            text: 'Tax',
            width: 2,
            styles: const PosStyles(bold: true, align: PosAlign.right),
          ),
          PosColumn(
            text: 'Amt',
            width: 2,
            styles: const PosStyles(bold: true, align: PosAlign.right),
          ),
        ]);
        printer.hr(ch: '-');
        const itemRowLeftStyles = PosStyles(
          bold: true,
          fontType: PosFontType.fontA,
          height: PosTextSize.size1,
          width: PosTextSize.size1,
        );
        const itemRowCenterStyles = PosStyles(
          bold: true,
          fontType: PosFontType.fontA,
          height: PosTextSize.size1,
          align: PosAlign.center,
        );
        const itemRowRightStyles = PosStyles(
          bold: true,
          fontType: PosFontType.fontA,
          height: PosTextSize.size1,
          width: PosTextSize.size1,
          align: PosAlign.right,
        );

        for (var index = 0; index < items.length; index++) {
          final item = items[index];
          final qtyStr = item.quantity % 1 == 0
              ? item.quantity.toStringAsFixed(0)
              : item.quantity.toStringAsFixed(2);
          final unitPriceToPrint = item.effectiveUnitPrice ?? item.price;
          final lineAmount = item.lineTotal;
          final taxableAmount = (lineAmount * gstScale).clamp(
            0.0,
            double.infinity,
          );
          final taxablePaise = (taxableAmount * 100).round();
          receiptTaxableSubtotalPaise += taxablePaise;
          final lineTaxPaise = item.gstPercent > 0
              ? ((taxablePaise * item.gstPercent) / 100).round()
              : 0;
          final lineTaxAmount = lineTaxPaise / 100.0;
          if (!item.isOfferFreeItem &&
              !item.isRandomCustomerOfferItem &&
              item.gstPercent > 0 &&
              lineTaxPaise > 0) {
            final halfRate = double.parse(
              (item.gstPercent / 2).toStringAsFixed(2),
            );
            final cgstPaise = lineTaxPaise ~/ 2;
            final sgstPaise = lineTaxPaise - cgstPaise;
            cgstBreakdownPaise.update(
              halfRate,
              (current) => current + cgstPaise,
              ifAbsent: () => cgstPaise,
            );
            sgstBreakdownPaise.update(
              halfRate,
              (current) => current + sgstPaise,
              ifAbsent: () => sgstPaise,
            );
          }
          printer.row([
            PosColumn(text: item.name, width: 4, styles: itemRowLeftStyles),
            PosColumn(text: qtyStr, width: 2, styles: itemRowCenterStyles),
            PosColumn(
              text: formatReceiptMoney(unitPriceToPrint),
              width: 2,
              styles: itemRowRightStyles,
            ),
            PosColumn(
              text: formatReceiptMoney(lineTaxAmount),
              width: 2,
              styles: itemRowRightStyles,
            ),
            PosColumn(
              text: formatReceiptMoney(lineAmount),
              width: 2,
              styles: itemRowRightStyles,
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
          if (index < items.length - 1) {
            printer.smallRowGap(dots: 8);
          }
        }

        printer.hr(ch: '-');
        final billDiscount = (grossAmount - totalAmount)
            .clamp(0.0, double.infinity)
            .toDouble();
        final totalCgstPaise = cgstBreakdownPaise.values.fold<int>(
          0,
          (sum, taxPart) => sum + taxPart,
        );
        final totalSgstPaise = sgstBreakdownPaise.values.fold<int>(
          0,
          (sum, taxPart) => sum + taxPart,
        );
        final receiptGstPaise = totalCgstPaise + totalSgstPaise;
        final hasReceiptGst = receiptGstPaise > 0;
        final receiptSubTotalPaise = hasReceiptGst
            ? receiptTaxableSubtotalPaise
            : (totalAmount * 100).round();
        final receiptTotalPaise = receiptSubTotalPaise + receiptGstPaise;
        final roundedGrandTotalPaise = ((receiptTotalPaise + 99) ~/ 100) * 100;
        final roundOffPaise = roundedGrandTotalPaise - receiptTotalPaise;
        final receiptGstAmount = receiptGstPaise / 100.0;
        final receiptSubTotalAmount = receiptSubTotalPaise / 100.0;
        final roundedGrandTotal = roundedGrandTotalPaise / 100.0;
        final roundOffAmount = roundOffPaise / 100.0;
        final explainedBillDiscount =
            customerOfferDiscountFromServer +
            totalPercentageOfferDiscountFromServer +
            customerEntryPercentageOfferDiscountFromServer;
        final remainingBillDiscount = (billDiscount - explainedBillDiscount)
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
          if (remainingBillDiscount > 0.009) {
            printer.row([
              PosColumn(
                text:
                    'OTHER DISCOUNT RS ${remainingBillDiscount.toStringAsFixed(2)}',
                width: 12,
                styles: const PosStyles(align: PosAlign.right),
              ),
            ]);
          }
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
        if (receiptGstAmount > 0.0001) {
          printer.row([
            PosColumn(
              text: 'SUB TOTAL RS ${formatReceiptMoney(receiptSubTotalAmount)}',
              width: 12,
              styles: const PosStyles(
                align: PosAlign.right,
                bold: true,
                height: PosTextSize.size1,
                width: PosTextSize.size1,
              ),
            ),
          ]);
          if (totalCgstPaise > 0) {
            printer.row([
              PosColumn(
                text: 'CGST RS ${formatReceiptMoney(totalCgstPaise / 100.0)}',
                width: 12,
                styles: const PosStyles(align: PosAlign.right),
              ),
            ]);
          }
          if (totalSgstPaise > 0) {
            printer.row([
              PosColumn(
                text: 'SGST RS ${formatReceiptMoney(totalSgstPaise / 100.0)}',
                width: 12,
                styles: const PosStyles(align: PosAlign.right),
              ),
            ]);
          }
          printer.hr(ch: '-');
          printer.row([
            PosColumn(
              text:
                  'Round off ${roundOffAmount >= 0 ? '+' : '-'}${roundOffAmount.abs().toStringAsFixed(2)}',
              width: 12,
              styles: const PosStyles(align: PosAlign.right),
            ),
          ]);
          printer.row([
            PosColumn(
              text: 'PAID BY: ${paymentMethod.toUpperCase()}',
              width: 5,
              styles: const PosStyles(align: PosAlign.left, bold: true),
            ),
            PosColumn(
              text: 'GRAND TOTAL RS ${formatReceiptMoney(roundedGrandTotal)}',
              width: 7,
              styles: const PosStyles(
                align: PosAlign.right,
                bold: true,
                fontType: PosFontType.fontA,
                height: PosTextSize.size2,
                width: PosTextSize.size1,
              ),
            ),
          ]);
        } else {
          printer.row([
            PosColumn(
              text: 'SUB TOTAL RS ${formatReceiptMoney(receiptSubTotalAmount)}',
              width: 12,
              styles: const PosStyles(
                align: PosAlign.right,
                bold: true,
                height: PosTextSize.size1,
                width: PosTextSize.size1,
              ),
            ),
          ]);
          printer.row([
            PosColumn(
              text:
                  'Round off ${roundOffAmount >= 0 ? '+' : '-'}${roundOffAmount.abs().toStringAsFixed(2)}',
              width: 12,
              styles: const PosStyles(align: PosAlign.right),
            ),
          ]);
          printer.row([
            PosColumn(
              text: 'PAID BY: ${paymentMethod.toUpperCase()}',
              width: 5,
              styles: const PosStyles(align: PosAlign.left, bold: true),
            ),
            PosColumn(
              text: 'GRAND TOTAL RS ${formatReceiptMoney(roundedGrandTotal)}',
              width: 7,
              styles: const PosStyles(
                align: PosAlign.right,
                bold: true,
                fontType: PosFontType.fontA,
                height: PosTextSize.size2,
                width: PosTextSize.size1,
              ),
            ),
          ]);
        }
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
        shouldShowFeedback =
            shouldShowFeedback && isThermalReviewPrintEnabled(prefs);
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
        await printer.disconnectAndPrint();

        _showPrintStatusSnack(
          messenger,
          message: 'Bill printed successfully',
          isSuccess: true,
        );
      } else {
        debugPrint(
          '⚠️ Receipt connect failed for $printerIp on ports ${candidatePorts.join(", ")}.',
        );
        _showPrintStatusSnack(
          messenger,
          message: 'Bill saved, but receipt not printed. Check printer.',
          isSuccess: false,
        );
        return;
      }
    } catch (e) {
      debugPrint('🖨️ Receipt print error: $e');
      _showPrintStatusSnack(
        messenger,
        message: 'Bill saved, but receipt not printed. Check printer.',
        isSuccess: false,
      );
    }
  }

  // -------------------------
  // ---------- KOT PRINTING LOGIC ----------
  // -------------------------

  Future<void> _handleKOTPrinting({
    required List<CartItem> items,
    required dynamic billingResponse,
    required Map<String, dynamic> customerDetails,
    required ScaffoldMessengerState messenger,
  }) async {
    if (_kotPrinters == null || _kotPrinters!.isEmpty) {
      debugPrint('ℹ️ No KOT printers configured for this branch.');
      _showPrintStatusSnack(
        messenger,
        message: 'KOT saved, but not printed (no KOT printer configured).',
        isSuccess: false,
      );
      return;
    }

    final groupedKots = <String, List<CartItem>>{}; // Printer IP -> Items
    final printerPortsByIp = <String, int>{};
    final kitchenToPrinterMap = <String, String>{};

    // 1. Build printer maps from configuration
    for (final printerConfig in _kotPrinters!) {
      final ip = _extractPrinterIp(printerConfig);
      if (ip == null || ip.isEmpty) continue;
      printerPortsByIp[ip] = _extractPrinterPort(printerConfig);

      if (printerConfig is! Map) continue;
      final configMap = Map<String, dynamic>.from(printerConfig);
      final kitchens = configMap['kitchens'] as List?;
      if (kitchens == null) continue;

      for (final kitchen in kitchens) {
        final kitchenId = (kitchen is Map)
            ? (kitchen['id'] ?? kitchen['_id'] ?? kitchen[r'$oid'])?.toString()
            : kitchen?.toString();
        if (kitchenId == null || kitchenId.isEmpty) continue;
        kitchenToPrinterMap[kitchenId] = ip;
      }
    }

    if (printerPortsByIp.isEmpty) {
      debugPrint('⚠️ KOT printers configured but no valid printer IP found.');
      _showPrintStatusSnack(
        messenger,
        message: 'KOT saved, but not printed (printer IP not configured).',
        isSuccess: false,
      );
      return;
    }

    // 2. Route items to printers based on Category -> Kitchen -> Printer
    final unmatchedItems = <CartItem>[];
    for (final item in items) {
      final catId = item.categoryId;
      if (catId == null || catId.isEmpty) {
        debugPrint('⚠️ Item ${item.name} has no category ID');
        unmatchedItems.add(item);
        continue;
      }

      final kitchenId = _categoryToKitchenMap[catId];
      if (kitchenId == null || kitchenId.isEmpty) {
        debugPrint('⚠️ No kitchen found for category: $catId');
        unmatchedItems.add(item);
        continue;
      }

      final ip = kitchenToPrinterMap[kitchenId];
      if (ip == null || ip.isEmpty) {
        debugPrint('⚠️ No printer found for kitchen: $kitchenId');
        unmatchedItems.add(item);
        continue;
      }
      groupedKots.putIfAbsent(ip, () => []).add(item);
    }

    final fallbackPrinterIp = printerPortsByIp.keys.first;
    if (groupedKots.isEmpty) {
      // No kitchen mapping available: route everything to first configured KOT printer.
      groupedKots[fallbackPrinterIp] = List<CartItem>.from(items);
      debugPrint(
        '⚡ KOT fallback route: no category mapping, sent all ${items.length} item(s) to $fallbackPrinterIp',
      );
    } else if (unmatchedItems.isNotEmpty) {
      groupedKots
          .putIfAbsent(fallbackPrinterIp, () => [])
          .addAll(unmatchedItems);
      debugPrint(
        '⚡ KOT fallback route: sent ${unmatchedItems.length} unmapped item(s) to $fallbackPrinterIp',
      );
    }

    // 3. Launch all print jobs in parallel
    final List<Future<PosPrintResult>> printFutures = [];
    final List<String> entryKeys = [];

    for (var entry in groupedKots.entries) {
      debugPrint(
        '🖨️ Launching KOT print to ${entry.key} (${entry.value.length} items)',
      );
      entryKeys.add(entry.key);
      printFutures.add(
        _printKOTReceipt(
          entry.value,
          entry.key,
          printerPortsByIp[entry.key] ?? 9100,
          billingResponse,
          customerDetails,
        ).timeout(
          const Duration(seconds: 10),
          onTimeout: () => PosPrintResult.timeout,
        ),
      );
    }

    final results = await Future.wait(printFutures);
    List<String> failedIps = [];
    for (int i = 0; i < results.length; i++) {
      if (results[i] != PosPrintResult.success) {
        failedIps.add(entryKeys[i]);
      }
    }
    debugPrint(
      '🖨️ KOT print results: ${results.map(_posPrintResultLabel).join(", ")}',
    );

    if (failedIps.isNotEmpty) {
      final successCount = results
          .where((r) => r == PosPrintResult.success)
          .length;
      debugPrint('⚠️ KOT print failed for: ${failedIps.join(", ")}');
      final message = successCount == 0
          ? 'KOT saved, but not printed. Check KOT printer.'
          : 'KOT partially printed ($successCount/${results.length}). Failed: ${failedIps.join(", ")}';
      _showPrintStatusSnack(messenger, message: message, isSuccess: false);
    } else {
      debugPrint('✅ KOT print succeeded for all targets');
      _showPrintStatusSnack(
        messenger,
        message: 'KOT printed successfully',
        isSuccess: true,
      );
    }
  }

  Future<PosPrintResult> _printKOTReceipt(
    List<CartItem> items,
    String printerIp,
    int printerPort,
    dynamic billingResponse,
    Map<String, dynamic> customerDetails,
  ) async {
    final prefs = await SharedPreferences.getInstance();
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
      final prefsPort = int.tryParse(
        (prefs.getString('printerPort') ?? '').trim(),
      );
      final candidatePorts = <int>[
        printerPort,
        if (prefsPort != null) prefsPort,
        9100,
        9101,
      ].toSet().toList(growable: false);

      final printer = await UnifiedPrinter.connect(
        printerIp: printerIp,
        candidatePorts: candidatePorts,
        paperSize: paper,
        profile: profile,
        jobType: PrintJobType.kot,
      );

      if (printer != null) {
        debugPrint('🖨️ KOT printing started');
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
            width: 10,
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
          final itemNote = (item.specialNote ?? '').trim();
          final qtyStr = item.quantity % 1 == 0
              ? item.quantity.toStringAsFixed(0)
              : item.quantity.toStringAsFixed(2);

          printer.row([
            PosColumn(
              text:
                  '${i + 1}. ${item.name.toUpperCase()}${item.isOfferFreeItem ? " (FREE)" : ""}',
              width: 10,
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
              styles: const PosStyles(bold: true, align: PosAlign.right),
            ),
          ]);

          if (itemNote.isNotEmpty) {
            printer.text(
              '   Note - $itemNote',
              styles: const PosStyles(align: PosAlign.left),
            );
          }

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
        await printer.disconnectAndPrint();
        return PosPrintResult.success;
      }
      debugPrint(
        '⚠️ KOT connect failed for $printerIp on ports ${candidatePorts.join(", ")}.',
      );
      return PosPrintResult.timeout;
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

  Widget _buildPaymentChips({bool lightMode = false}) {
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
          activeColor: const Color(0xFF1BA672),
          chipBg: lightMode ? Colors.white : _chipBg,
          activeBackgroundColor: lightMode
              ? const Color(0xFFEAF7F1)
              : const Color(0xFF1BA672).withValues(alpha: 0.18),
          inactiveBorderColor: lightMode
              ? const Color(0xFFDADDE5)
              : Colors.transparent,
          inactiveForegroundColor: lightMode
              ? const Color(0xFF5F6775)
              : Colors.white70,
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
          activeColor: const Color(0xFF0A84FF),
          chipBg: lightMode ? Colors.white : _chipBg,
          activeBackgroundColor: lightMode
              ? const Color(0xFFEAF3FF)
              : const Color(0xFF0A84FF).withValues(alpha: 0.18),
          inactiveBorderColor: lightMode
              ? const Color(0xFFDADDE5)
              : Colors.transparent,
          inactiveForegroundColor: lightMode
              ? const Color(0xFF5F6775)
              : Colors.white70,
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
          activeColor: const Color(0xFFFF9F0A),
          chipBg: lightMode ? Colors.white : _chipBg,
          activeBackgroundColor: lightMode
              ? const Color(0xFFFFF4E5)
              : const Color(0xFFFF9F0A).withValues(alpha: 0.18),
          inactiveBorderColor: lightMode
              ? const Color(0xFFDADDE5)
              : Colors.transparent,
          inactiveForegroundColor: lightMode
              ? const Color(0xFF5F6775)
              : Colors.white70,
          width: 95,
        ),
      ],
    );
  }

  Future<void> _openTableAddItems() async {
    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    final useHomeCategoriesUi =
        cartProvider.isSharedTableOrder &&
        cartProvider.preferHomeCategoriesUiForCurrentDraft;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CategoriesPage(
          sourcePage: useHomeCategoriesUi ? PageType.home : PageType.table,
          initialHomeTopCategories: useHomeCategoriesUi
              ? cartProvider.homeTopCategoriesSeedForCurrentDraft
              : const <Map<String, dynamic>>[],
        ),
      ),
    );
    if (!mounted) return;
    setState(() {});
  }

  double _calculateKotSavings(Iterable<CartItem> items) {
    double originalTotal = 0.0;
    double payableTotal = 0.0;
    for (final item in items) {
      if (item.quantity <= 0) continue;
      originalTotal += item.price * item.quantity;
      payableTotal += item.lineTotal;
    }
    final saved = originalTotal - payableTotal;
    return saved > 0.001 ? saved : 0.0;
  }

  Widget _buildKotEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: const Color(0xFFEAF7F1),
                borderRadius: BorderRadius.circular(28),
              ),
              child: const Icon(
                Icons.restaurant_menu_rounded,
                color: Color(0xFF1BA672),
                size: 46,
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'No items in this KOT yet',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFF1F2430),
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Add products from categories and send the KOT from here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFF6E7583),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _openTableAddItems,
                icon: const Icon(
                  Icons.add_rounded,
                  color: Colors.white,
                  size: 20,
                ),
                label: const Text(
                  'Add More Items',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  backgroundColor: const Color(0xFF16A34A),
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKotOrderBar({
    required List<CartItem> cartItems,
    required double totalQty,
    required VoidCallback? onTap,
  }) {
    const barColor = Color(0xFFEF4F5F);

    return Opacity(
      opacity: onTap == null ? 0.6 : 1,
      child: Material(
        color: barColor,
        borderRadius: BorderRadius.circular(18),
        elevation: 2,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            alignment: Alignment.center,
            child: const Text(
              'ORDER',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 21,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.4,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKotModeBody({
    required CartProvider cartProvider,
    required List<CartItem> items,
    required bool showSharedTableInput,
  }) {
    final hasAnyItems =
        items.isNotEmpty || cartProvider.recalledItems.isNotEmpty;
    final activeCartItems = cartProvider.cartItems
        .where((item) => item.quantity > 0)
        .toList(growable: false);
    final showBillButton =
        cartProvider.recalledBillId != null && cartProvider.cartItems.isEmpty;
    final showKotButton =
        cartProvider.recalledBillId == null ||
        cartProvider.cartItems.isNotEmpty;
    final allVisibleItems = <CartItem>[...cartProvider.recalledItems, ...items];
    final overallItemQuantity = allVisibleItems.fold<double>(
      0,
      (sum, item) => sum + item.quantity,
    );
    final overallItemsDisplay = _formatCartQuantityValue(overallItemQuantity);
    final overallItemLabel = overallItemQuantity == 1 ? 'item' : 'items';
    final overallSubtotalWithoutGst = allVisibleItems.fold<double>(
      0,
      (sum, item) => sum + item.lineTotal,
    );
    final overallGstAmount = allVisibleItems.fold<double>(
      0,
      (sum, item) => sum + _cartItemTaxAmount(item),
    );
    final overallTotalWithGst = overallSubtotalWithoutGst + overallGstAmount;
    final overallGrandTotal = overallTotalWithGst.ceilToDouble();
    final overallRoundOff = (overallGrandTotal - overallTotalWithGst).clamp(
      0.0,
      double.infinity,
    );
    final totalQuantity = cartProvider.cartItems.fold<double>(
      0,
      (sum, item) => sum + item.quantity,
    );
    final savedAmount = _calculateKotSavings(cartProvider.cartItems);
    final tableName = cartProvider.selectedTable?.trim() ?? '';
    final sectionName = cartProvider.selectedSection?.trim() ?? '';
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final footerHeight = showSharedTableInput
        ? 214.0
        : (showBillButton ? 206.0 : 152.0);

    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFFF8F2EC), Color(0xFFF4EFE8)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
        ),
        if (!hasAnyItems)
          Padding(
            padding: EdgeInsets.only(bottom: footerHeight + bottomInset),
            child: _buildKotEmptyState(),
          )
        else
          ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              footerHeight + bottomInset + 12,
            ),
            children: [
              if (savedAmount > 0.0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDDF4E8),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: const Color(0xFFB8E7CC)),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.auto_awesome_rounded,
                        color: Color(0xFF1BA672),
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '₹${savedAmount.toStringAsFixed(0)} saved on this order',
                          style: const TextStyle(
                            color: Color(0xFF187C57),
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (tableName.isNotEmpty || sectionName.isNotEmpty) ...[
                SizedBox(height: savedAmount > 0.0 ? 12 : 0),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (tableName.isNotEmpty)
                      _KotMetaChip(
                        icon: Icons.table_restaurant_rounded,
                        label: sectionName.isNotEmpty
                            ? 'Table $tableName ($sectionName)'
                            : 'Table $tableName',
                      )
                    else if (sectionName.isNotEmpty)
                      _KotMetaChip(
                        icon: Icons.place_outlined,
                        label: sectionName,
                      ),
                    _KotHistoryButton(
                      onPressed: () =>
                          _openCustomerHistoryFromTableCart(cartProvider),
                    ),
                    if (totalQuantity > 0)
                      _KotMetaChip(
                        icon: Icons.shopping_bag_outlined,
                        label:
                            '${_formatCartQuantityValue(totalQuantity)} item${totalQuantity == 1 ? '' : 's'}',
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFB8A998).withValues(alpha: 0.16),
                      blurRadius: 22,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    if (items.isNotEmpty) ...[
                      const _KotSectionTitle(label: 'Current Order'),
                      const SizedBox(height: 10),
                      ...items.asMap().entries.map((entry) {
                        final index = entry.key;
                        final item = entry.value;
                        return _KotEditableItemRow(
                          key: ValueKey(
                            'kot_${item.billingItemId ?? item.id}_${index}_${item.quantity}_${item.specialNote}',
                          ),
                          item: item,
                          showNoteIcon: true,
                          onRemove: () => cartProvider.removeItem(item.id),
                          onQuantityChange: (q) =>
                              cartProvider.updateQuantity(item.id, q),
                          onNoteChange: (note) =>
                              cartProvider.updateNote(item.id, note),
                        );
                      }),
                    ],
                    if (cartProvider.recalledItems.isNotEmpty) ...[
                      if (items.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        const Divider(height: 24, color: Color(0xFFE9E2D8)),
                      ],
                      const _KotSectionTitle(label: 'Previous Orders'),
                      const SizedBox(height: 10),
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
                        final status = item.status?.toLowerCase() ?? 'ordered';

                        String? nextStatus;
                        Color statusColor = const Color(0xFFE0A100);
                        String displayStatus = status.toUpperCase();

                        switch (status) {
                          case 'ordered':
                            nextStatus = null;
                            statusColor = const Color(0xFFE0A100);
                            break;
                          case 'confirmed':
                            nextStatus = null;
                            statusColor = const Color(0xFF0A84FF);
                            break;
                          case 'prepared':
                            nextStatus = 'delivered';
                            statusColor = const Color(0xFF2EBF3B);
                            break;
                          case 'delivered':
                            nextStatus = null;
                            statusColor = const Color(0xFFEF4F5F);
                            break;
                          default:
                            nextStatus = null;
                        }

                        return GestureDetector(
                          onDoubleTap: isReadOnlyOfferItem || nextStatus == null
                              ? null
                              : () => cartProvider.updateRecalledItemStatus(
                                  context,
                                  index,
                                  nextStatus!,
                                ),
                          onLongPress: () {
                            if (isReadOnlyOfferItem) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Offer items are read-only'),
                                  duration: Duration(seconds: 1),
                                ),
                              );
                              return;
                            }
                            if (status == 'ordered' || status == 'confirmed') {
                              _showCancelDialog(
                                context,
                                cartProvider,
                                index,
                                item.name,
                              );
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '${status.toUpperCase()} items cannot be cancelled',
                                  ),
                                  backgroundColor: Colors.red,
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            }
                          },
                          child: _KotReadOnlyItemRow(
                            item: item,
                            statusLabel: displayStatus,
                            statusColor: statusColor,
                          ),
                        );
                      }),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 176,
                          child: ElevatedButton.icon(
                            onPressed: _openTableAddItems,
                            icon: const Icon(
                              Icons.add_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                            label: const Text(
                              'Add More Items',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              minimumSize: const Size.fromHeight(42),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                              elevation: 0,
                              backgroundColor: const Color(0xFF16A34A),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            ],
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: EdgeInsets.fromLTRB(16, 14, 16, bottomInset + 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 24,
                  offset: const Offset(0, -6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showSharedTableInput) ...[
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8F7F5),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE2DDD6)),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: TextField(
                      controller: _sharedTableController,
                      style: const TextStyle(
                        color: Color(0xFF1F2430),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      textInputAction: TextInputAction.done,
                      onTapOutside: (_) =>
                          FocusManager.instance.primaryFocus?.unfocus(),
                      onEditingComplete: () =>
                          FocusManager.instance.primaryFocus?.unfocus(),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'[a-zA-Z0-9\- ]'),
                        ),
                      ],
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Enter shared table number',
                        hintStyle: TextStyle(
                          color: Color(0xFF9CA3AF),
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ],
                if (showKotButton) ...[
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            RichText(
                              text: TextSpan(
                                style: const TextStyle(
                                  color: Color(0xFF1F2430),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                ),
                                children: [
                                  TextSpan(
                                    text:
                                        'Total: ₹${_formatCartMoneyCompact(overallSubtotalWithoutGst)} + ₹${_formatCartMoneyCompact(overallGstAmount)} GST  ',
                                  ),
                                  TextSpan(
                                    text:
                                        '$overallItemsDisplay $overallItemLabel',
                                    style: const TextStyle(
                                      color: Color(0xFFC27803),
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'Grand Total: ₹${_formatCartMoneyCompact(overallGrandTotal)} (Rof +₹${_formatCartMoneyCompact(overallRoundOff)})',
                              style: const TextStyle(
                                color: Color(0xFF1BA672),
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildKotOrderBar(
                    cartItems: activeCartItems,
                    totalQty: totalQuantity,
                    onTap:
                        _isBillingInProgress || cartProvider.cartItems.isEmpty
                        ? null
                        : () async {
                            if (!mounted) return;
                            await _submitBillingFromTap(
                              status: 'pending',
                              isReminder: cartProvider.recalledBillId != null,
                            );
                          },
                  ),
                ],
                if (showBillButton) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Total: ₹${_formatCartMoneyCompact(overallSubtotalWithoutGst)} + ₹${_formatCartMoneyCompact(overallGstAmount)} GST  $overallItemsDisplay $overallItemLabel',
                      style: const TextStyle(
                        color: Color(0xFF1F2430),
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Grand Total: ₹${_formatCartMoneyCompact(overallGrandTotal)} (Rof +₹${_formatCartMoneyCompact(overallRoundOff)})',
                      style: const TextStyle(
                        color: Color(0xFF1BA672),
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildPaymentChips(lightMode: true),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isBillingInProgress
                          ? null
                          : () => _submitBillingFromTap(status: 'completed'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                        backgroundColor: const Color(0xFF2EBF3B),
                        disabledBackgroundColor: const Color(0xFF2EBF3B),
                        disabledForegroundColor: Colors.white,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                        elevation: 0,
                      ),
                      child: const Text(
                        'BILL',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cartProvider = Provider.of<CartProvider>(context);
    return CommonScaffold(
      title: cartProvider.currentType == CartType.table
          ? ((_branchName?.trim().isNotEmpty ?? false)
                ? _branchName!.trim()
                : 'Table Order')
          : 'Cart',
      pageType: cartProvider.currentType == CartType.billing
          ? PageType.billing
          : PageType.table,
      showBackButtonInAppBar: cartProvider.currentType == CartType.table,
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
            if (showSharedTableInput &&
                _sharedTableController.text.trim().isEmpty &&
                (cartProvider.selectedTable?.trim().isNotEmpty ?? false)) {
              final selectedTable = cartProvider.selectedTable!.trim();
              _sharedTableController.value = TextEditingValue(
                text: selectedTable,
                selection: TextSelection.collapsed(
                  offset: selectedTable.length,
                ),
              );
            }

            final allVisibleItems = <CartItem>[
              ...cartProvider.recalledItems,
              ...cartProvider.cartItems,
            ];
            final totalQuantity = allVisibleItems.fold<double>(
              0,
              (sum, item) => sum + item.quantity,
            );
            final totalItemsDisplay = _formatCartQuantityValue(totalQuantity);
            final totalItemLabel = totalQuantity == 1 ? 'item' : 'items';
            final subtotalWithoutGst = allVisibleItems.fold<double>(
              0,
              (sum, item) => sum + item.lineTotal,
            );
            final totalGstAmount = allVisibleItems.fold<double>(
              0,
              (sum, item) => sum + _cartItemTaxAmount(item),
            );
            final totalWithGst = subtotalWithoutGst + totalGstAmount;
            final roundedGrandTotal = totalWithGst.ceilToDouble();
            final roundOffAmount = (roundedGrandTotal - totalWithGst).clamp(
              0.0,
              double.infinity,
            );
            final hasCustomerHistoryPhoneInBilling =
                (cartProvider.customerPhone ?? '')
                    .replaceAll(RegExp(r'\D'), '')
                    .length >=
                10;

            if (cartProvider.currentType == CartType.table) {
              return SafeArea(
                child: Stack(
                  children: [
                    _buildKotModeBody(
                      cartProvider: cartProvider,
                      items: items,
                      showSharedTableInput: showSharedTableInput,
                    ),
                    if (_isBillingInProgress)
                      Positioned.fill(
                        child: AbsorbPointer(
                          child: Container(
                            color: Colors.black.withValues(alpha: 0.35),
                            alignment: Alignment.center,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 14,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.14),
                                    blurRadius: 20,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.2,
                                      color: Color(0xFF0A84FF),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    _billingProgressLabel,
                                    style: const TextStyle(
                                      color: Color(0xFF1F2430),
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            }

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
                                  child: Row(
                                    children: [
                                      Text(
                                        "NEW ITEMS",
                                        style: TextStyle(
                                          color: _accent,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                          letterSpacing: 1.2,
                                        ),
                                      ),
                                      if (hasCustomerHistoryPhoneInBilling) ...[
                                        const Spacer(),
                                        Material(
                                          color: const Color(0xFF16A34A),
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                          child: InkWell(
                                            onTap: () =>
                                                _openCustomerHistoryFromBillingCart(
                                                  cartProvider,
                                                ),
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                            child: const Padding(
                                              padding: EdgeInsets.symmetric(
                                                horizontal: 10,
                                                vertical: 7,
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.history_rounded,
                                                    size: 14,
                                                    color: Colors.white,
                                                  ),
                                                  SizedBox(width: 6),
                                                  Text(
                                                    'CUSTOMER HISTORY',
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 10.5,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      letterSpacing: 0.2,
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
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      RichText(
                                        text: TextSpan(
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w800,
                                          ),
                                          children: [
                                            TextSpan(
                                              text:
                                                  'Total: ₹${_formatCartMoneyCompact(subtotalWithoutGst)} + ₹${_formatCartMoneyCompact(totalGstAmount)} GST  ',
                                            ),
                                            TextSpan(
                                              text:
                                                  '$totalItemsDisplay $totalItemLabel',
                                              style: const TextStyle(
                                                color: Colors.yellow,
                                                fontSize: 14,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Grand Total: ₹${_formatCartMoneyCompact(roundedGrandTotal)} (Rof +₹${_formatCartMoneyCompact(roundOffAmount)})',
                                        style: const TextStyle(
                                          color: Color(0xFFA7F3D0),
                                          fontSize: 17,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Switch(
                                  value:
                                      cartProvider.currentType == CartType.table
                                      ? _customerDetailsVisibilityConfig
                                            .showCustomerDetailsForTableOrders
                                      : _customerDetailsVisibilityConfig
                                            .showCustomerDetailsForBillingOrders,
                                  onChanged: null,
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
                                          : () => _submitBillingFromTap(
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
                                              if (!mounted) return;
                                              await _submitBillingFromTap(
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
                  if (_isBillingInProgress)
                    Positioned.fill(
                      child: AbsorbPointer(
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.55),
                          alignment: Alignment.center,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 14,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E1E1E),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.18),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    color: Color(0xFF0A84FF),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  _billingProgressLabel,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
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
    final lineSubtotal = widget.item.lineTotal.clamp(0.0, double.infinity);
    final lineTaxAmount = _cartItemTaxAmount(widget.item);
    final lineTotalWithGst = lineSubtotal + lineTaxAmount;

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
                  if (lineTaxAmount > 0.0001)
                    SizedBox(
                      width: double.infinity,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Sub: ₹${_formatCartMoneyCompact(lineSubtotal)} + ₹${_formatCartMoneyCompact(lineTaxAmount)} (${_formatCartMoneyCompact(widget.item.gstPercent)}%) = ₹${_formatCartMoneyCompact(lineTotalWithGst)}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    )
                  else
                    Text(
                      'Sub: ₹${_formatCartMoneyCompact(lineSubtotal)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
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

String _formatCartQuantityValue(double qty) {
  if (qty % 1 == 0) return qty.toInt().toString();
  final roundedOneDecimal = double.parse(qty.toStringAsFixed(1));
  if ((qty - roundedOneDecimal).abs() < 0.001) {
    return roundedOneDecimal.toStringAsFixed(1);
  }
  return qty.toStringAsFixed(2);
}

String _formatCartMoneyCompact(double value) {
  final rounded = double.parse(value.toStringAsFixed(2));
  if ((rounded - rounded.roundToDouble()).abs() < 0.001) {
    return rounded.toStringAsFixed(0);
  }
  return rounded.toStringAsFixed(2);
}

double _cartItemTaxAmount(CartItem item) {
  if (item.isOfferFreeItem || item.isRandomCustomerOfferItem) {
    return 0.0;
  }
  if (item.gstPercent <= 0) {
    return 0.0;
  }
  final taxableAmount = item.lineTotal.clamp(0.0, double.infinity);
  return taxableAmount * item.gstPercent / 100;
}

double _cartQuantityStep(double qty) {
  if (qty == 0) return 0.25;
  int a = (qty * 100).round().abs();
  int b = 100;
  while (b != 0) {
    final temp = b;
    b = a % b;
    a = temp;
  }
  return a / 100.0;
}

bool _cartItemIsVeg(CartItem item) {
  final department = item.department?.trim().toLowerCase() ?? '';
  if (department.contains('non') && department.contains('veg')) {
    return false;
  }
  if (department.contains('veg')) {
    return true;
  }
  return false;
}

String _formatKotMoney(double value) {
  if (value == value.roundToDouble()) {
    return '₹${value.toInt()}';
  }
  return '₹${value.toStringAsFixed(2)}';
}

String _kotDisplayName(String name) {
  final cleaned = name.replaceFirst(
    RegExp(
      r'\s*\((?:rs\.?|inr|₹)\s*\d+(?:\.\d{1,2})?\)\s*$',
      caseSensitive: false,
    ),
    '',
  );
  return cleaned.trim().isEmpty ? name : cleaned.trim();
}

class _KotMetaChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _KotMetaChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2DBD3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: const Color(0xFF6E7583)),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF1F2430),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _KotHistoryButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _KotHistoryButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF16A34A),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(14),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.history_rounded, size: 16, color: Colors.white),
              SizedBox(width: 8),
              Text(
                'CUSTOMER HISTORY',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KotSectionTitle extends StatelessWidget {
  final String label;

  const _KotSectionTitle({required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF1F2430),
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Divider(color: Color(0xFFE9E2D8), thickness: 1, height: 1),
        ),
      ],
    );
  }
}

class _KotEditableItemRow extends StatelessWidget {
  final CartItem item;
  final bool showNoteIcon;
  final VoidCallback onRemove;
  final ValueChanged<double> onQuantityChange;
  final ValueChanged<String> onNoteChange;

  const _KotEditableItemRow({
    super.key,
    required this.item,
    required this.showNoteIcon,
    required this.onRemove,
    required this.onQuantityChange,
    required this.onNoteChange,
  });

  Future<void> _showNoteDialog(BuildContext context) async {
    final ctrl = TextEditingController(text: item.specialNote ?? '');
    final note = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text(
          'Special Note',
          style: TextStyle(
            color: Color(0xFF1F2430),
            fontWeight: FontWeight.w700,
          ),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Color(0xFF1F2430)),
          decoration: const InputDecoration(
            hintText: 'Enter instructions...',
            hintStyle: TextStyle(color: Color(0xFF9CA3AF)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (note != null) {
      onNoteChange(note);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isFreeOfferItem = item.isOfferFreeItem;
    final isRandomOfferItem = item.isRandomCustomerOfferItem;
    final isReadOnlyOfferItem = isFreeOfferItem || isRandomOfferItem;
    final isPriceOfferItem = item.isPriceOfferApplied;
    final qty = item.quantity;
    final step = _cartQuantityStep(qty);
    final currentLineTotal = item.lineTotal;
    final lineSubtotal = currentLineTotal.clamp(0.0, double.infinity);
    final lineTaxAmount = _cartItemTaxAmount(item);
    final lineTotalWithGst = lineSubtotal + lineTaxAmount;
    final originalLineTotal = item.price * qty;
    final showOldLineTotal =
        !isReadOnlyOfferItem && originalLineTotal > currentLineTotal + 0.001;
    final note = item.specialNote?.trim() ?? '';
    final displayName = _kotDisplayName(item.name);

    String? chipLabel;
    Color? chipTextColor;
    Color? chipBgColor;
    Color? chipBorderColor;
    if (isRandomOfferItem) {
      chipLabel = 'RANDOM FREE ITEM';
      chipTextColor = const Color(0xFFFF9F0A);
      chipBgColor = const Color(0xFFFFF4E5);
      chipBorderColor = const Color(0xFFFFD18A);
    } else if (isFreeOfferItem) {
      chipLabel = 'FREE ITEM OFFER';
      chipTextColor = const Color(0xFF1BA672);
      chipBgColor = const Color(0xFFEAF7F1);
      chipBorderColor = const Color(0xFFBDE8D3);
    } else if (isPriceOfferItem) {
      chipLabel = 'PRICE OFFER';
      chipTextColor = const Color(0xFF0A84FF);
      chipBgColor = const Color(0xFFEAF3FF);
      chipBorderColor = const Color(0xFFBDD7FF);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onRemove,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: _KotDietBadge(isVeg: _cartItemIsVeg(item)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 3),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF1F2430),
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                    ),
                    if (showNoteIcon && !isReadOnlyOfferItem)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => _showNoteDialog(context),
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: Icon(
                              note.isNotEmpty
                                  ? Icons.note_alt_rounded
                                  : Icons.note_add_outlined,
                              size: 18,
                              color: note.isNotEmpty
                                  ? const Color(0xFF0A84FF)
                                  : const Color(0xFF7B8494),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                if (chipLabel != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: chipBgColor,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: chipBorderColor!),
                    ),
                    child: Text(
                      chipLabel,
                      style: TextStyle(
                        color: chipTextColor,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ],
                if (note.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    note,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF727A88),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                if (lineTaxAmount > 0.0001)
                  SizedBox(
                    width: double.infinity,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Sub: ₹${_formatCartMoneyCompact(lineSubtotal)} + ₹${_formatCartMoneyCompact(lineTaxAmount)} (${_formatCartMoneyCompact(item.gstPercent)}%) = ₹${_formatCartMoneyCompact(lineTotalWithGst)}',
                        style: const TextStyle(
                          color: Color(0xFF1F2430),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  )
                else
                  Text(
                    'Sub: ₹${_formatCartMoneyCompact(lineSubtotal)}',
                    style: const TextStyle(
                      color: Color(0xFF1F2430),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              isReadOnlyOfferItem
                  ? _KotLockedQtyPill(quantity: qty)
                  : _KotQtyStepper(
                      quantity: qty,
                      onDecrease: () => onQuantityChange(
                        (qty - step).clamp(0.0, double.infinity),
                      ),
                      onIncrease: () => onQuantityChange(
                        (qty + step).clamp(0.0, double.infinity),
                      ),
                    ),
              const SizedBox(height: 6),
              if (showOldLineTotal)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formatKotMoney(originalLineTotal),
                      style: const TextStyle(
                        color: Color(0xFF9CA3AF),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.lineThrough,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _formatKotMoney(currentLineTotal),
                      style: const TextStyle(
                        color: Color(0xFF1F2430),
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                )
              else
                Text(
                  _formatKotMoney(currentLineTotal),
                  style: const TextStyle(
                    color: Color(0xFF1F2430),
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _KotReadOnlyItemRow extends StatelessWidget {
  final CartItem item;
  final String statusLabel;
  final Color statusColor;

  const _KotReadOnlyItemRow({
    required this.item,
    required this.statusLabel,
    required this.statusColor,
  });

  @override
  Widget build(BuildContext context) {
    final note = item.specialNote?.trim() ?? '';
    final displayName = _kotDisplayName(item.name);
    final lineSubtotal = item.lineTotal.clamp(0.0, double.infinity);
    final lineTaxAmount = _cartItemTaxAmount(item);
    final lineTotalWithGst = lineSubtotal + lineTaxAmount;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _KotDietBadge(isVeg: _cartItemIsVeg(item)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 3),
                Text(
                  displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF1F2430),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                if (note.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    note,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF727A88),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                if (lineTaxAmount > 0.0001)
                  SizedBox(
                    width: double.infinity,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Sub: ₹${_formatCartMoneyCompact(lineSubtotal)} + ₹${_formatCartMoneyCompact(lineTaxAmount)} (${_formatCartMoneyCompact(item.gstPercent)}%) = ₹${_formatCartMoneyCompact(lineTotalWithGst)}',
                        style: const TextStyle(
                          color: Color(0xFF1F2430),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  )
                else
                  Text(
                    'Sub: ₹${_formatCartMoneyCompact(lineSubtotal)}',
                    style: const TextStyle(
                      color: Color(0xFF1F2430),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    statusLabel,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _KotLockedQtyPill(quantity: item.quantity),
              const SizedBox(height: 6),
              Text(
                _formatKotMoney(item.lineTotal),
                style: const TextStyle(
                  color: Color(0xFF1F2430),
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _KotDietBadge extends StatelessWidget {
  final bool isVeg;

  const _KotDietBadge({required this.isVeg});

  @override
  Widget build(BuildContext context) {
    final markerColor = isVeg
        ? const Color(0xFF1E9D55)
        : const Color(0xFFE53935);
    return Container(
      width: 15,
      height: 15,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: markerColor, width: 0.9),
      ),
      child: Center(
        child: isVeg
            ? Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: markerColor,
                  shape: BoxShape.circle,
                ),
              )
            : Icon(Icons.change_history_rounded, size: 8, color: markerColor),
      ),
    );
  }
}

class _KotQtyStepper extends StatelessWidget {
  final double quantity;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;

  const _KotQtyStepper({
    required this.quantity,
    required this.onDecrease,
    required this.onIncrease,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 68,
      height: 28,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(0xFFE0DBD3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          _KotQtyAction(symbol: '−', onTap: onDecrease),
          Expanded(
            child: Center(
              child: Text(
                _formatCartQuantityValue(quantity),
                style: const TextStyle(
                  color: Color(0xFF1F2430),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          _KotQtyAction(symbol: '+', onTap: onIncrease),
        ],
      ),
    );
  }
}

class _KotQtyAction extends StatelessWidget {
  final String symbol;
  final VoidCallback onTap;

  const _KotQtyAction({required this.symbol, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: SizedBox(
        width: 19,
        height: double.infinity,
        child: Center(
          child: Text(
            symbol,
            style: const TextStyle(
              color: Color(0xFF1BA672),
              fontSize: 15,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _KotLockedQtyPill extends StatelessWidget {
  final double quantity;

  const _KotLockedQtyPill({required this.quantity});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 68,
      height: 28,
      decoration: BoxDecoration(
        color: const Color(0xFFF5F4F2),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(0xFFE0DBD3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            _formatCartQuantityValue(quantity),
            style: const TextStyle(
              color: Color(0xFF1F2430),
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _PaymentChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final Color activeColor;
  final Color chipBg;
  final Color activeBackgroundColor;
  final Color inactiveBorderColor;
  final Color inactiveForegroundColor;
  final double width;

  const _PaymentChip({
    Key? key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    required this.activeColor,
    required this.chipBg,
    required this.activeBackgroundColor,
    required this.inactiveBorderColor,
    required this.inactiveForegroundColor,
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
          color: selected ? activeBackgroundColor : chipBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? activeColor : inactiveBorderColor,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: selected ? activeColor : inactiveForegroundColor,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: selected ? activeColor : inactiveForegroundColor,
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
