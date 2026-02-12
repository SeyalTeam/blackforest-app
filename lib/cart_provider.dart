import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:blackforest_app/notification_service.dart';
import 'package:blackforest_app/cart_page.dart';

class CartItem {
  final String id;
  final String name;
  final double price;
  final String? imageUrl;
  double quantity; // ✅ changed from int → double
  final String? unit; // ✅ optional, e.g. "pcs" or "kg"
  final String? department; // ✅ New field
  final String? categoryId; // ✅ For KOT routing
  String? specialNote; // ✅ Optional note for KOT
  final String? status; // ✅ New field for item status

  CartItem({
    required this.id,
    required this.name,
    required this.price,
    this.imageUrl,
    required this.quantity,
    this.unit,
    this.department,
    this.categoryId,
    this.specialNote,
    this.status,
  });

  factory CartItem.fromProduct(
    dynamic product,
    double quantity, {
    double? branchPrice,
  }) {
    String? imageUrl;
    if (product['images'] != null &&
        product['images'].isNotEmpty &&
        product['images'][0]['image'] != null &&
        product['images'][0]['image']['url'] != null) {
      imageUrl = product['images'][0]['image']['url'];
      if (imageUrl != null && imageUrl.startsWith('/')) {
        imageUrl = 'https://blackforest.vseyal.com$imageUrl';
      }
    }

    double price =
        branchPrice ??
        (product['defaultPriceDetails']?['price']?.toDouble() ?? 0.0);

    // ✅ read unit from product (default to 'pcs' if missing)
    String? unit = product['unit']?.toString().toLowerCase() ?? 'pcs';

    // ✅ Extract department
    String? dept;
    if (product['department'] != null) {
      dept = (product['department'] is Map)
          ? product['department']['name']
          : product['department'].toString();
    } else if (product['category'] != null &&
        product['category'] is Map &&
        product['category']['department'] != null) {
      var catDept = product['category']['department'];
      dept = (catDept is Map) ? catDept['name'] : catDept.toString();
    }

    String? categoryId;
    if (product['category'] != null) {
      categoryId = (product['category'] is Map)
          ? product['category']['id']?.toString()
          : product['category'].toString();
    }

    return CartItem(
      id: product['id'],
      name: product['name'] ?? 'Unknown',
      price: price,
      imageUrl: imageUrl,
      quantity: quantity,
      unit: unit,
      department: dept,
      categoryId: categoryId,
      specialNote: null,
      status: null, // New items carry no status until submitted
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'price': price,
      'imageUrl': imageUrl,
      'quantity': quantity,
      'unit': unit,
      'department': department,
      'categoryId': categoryId,
      'specialNote': specialNote,
      'status': status,
    };
  }

  factory CartItem.fromJson(Map<String, dynamic> json) {
    return CartItem(
      id: json['id'],
      name: json['name'],
      price: json['price'],
      imageUrl: json['imageUrl'],
      quantity: json['quantity'],
      unit: json['unit'],
      department: json['department'],
      categoryId: json['categoryId'],
      specialNote: json['specialNote'],
      status: json['status'],
    );
  }
}

enum CartType { billing, table }

class CartProvider extends ChangeNotifier {
  CartType _currentType = CartType.billing;

  // New Items (Draft)
  final Map<CartType, List<CartItem>> _itemsMap = {
    CartType.billing: [],
    CartType.table: [],
  };

  // Previously ordered items (Drafting Mode)
  final Map<CartType, List<CartItem>> _recalledItemsMap = {
    CartType.billing: [],
    CartType.table: [],
  };
  final Map<CartType, String?> _recalledBillIdMap = {
    CartType.billing: null,
    CartType.table: null,
  };
  final Map<CartType, String?> _selectedKitchenIdMap = {
    CartType.billing: null,
    CartType.table: null,
  };
  final Map<CartType, String?> _selectedKitchenNameMap = {
    CartType.billing: null,
    CartType.table: null,
  };
  final Map<CartType, String?> _customerNameMap = {
    CartType.billing: null,
    CartType.table: null,
  };
  final Map<CartType, String?> _customerPhoneMap = {
    CartType.billing: null,
    CartType.table: null,
  };
  final Map<CartType, String?> _selectedTableMap = {
    CartType.billing: null,
    CartType.table: null,
  };
  final Map<CartType, String?> _selectedSectionMap = {
    CartType.billing: null,
    CartType.table: null,
  };

  // Shared state
  String? _branchId;
  String? _printerIp;
  int _printerPort = 9100;
  String? _printerProtocol = 'esc_pos';
  List<Map<String, dynamic>> _kitchenNotifications = [];
  final Set<String> _readNotificationIds = {};
  final _audioPlayer = AudioPlayer();

  // Getters for current cart
  CartType get currentType => _currentType;
  List<CartItem> get cartItems => _itemsMap[_currentType]!;
  List<CartItem> get recalledItems => _recalledItemsMap[_currentType]!;
  List<Map<String, dynamic>> get kitchenNotifications => _kitchenNotifications;

  void markNotificationAsRead(String id) {
    if (!_readNotificationIds.contains(id)) {
      _readNotificationIds.add(id);
      _kitchenNotifications.removeWhere((item) => item['id'] == id);
      notifyListeners();
    }
  }

  void markBillAsRead(String billId) {
    bool changed = false;
    // Find all notifications matching this billId
    final matchedIds = _kitchenNotifications
        .where((item) => item['billId'] == billId)
        .map((item) => item['id'] as String)
        .toList();

    for (var id in matchedIds) {
      if (!_readNotificationIds.contains(id)) {
        _readNotificationIds.add(id);
        changed = true;
      }
    }

    if (changed) {
      _kitchenNotifications.removeWhere((item) => item['billId'] == billId);
      notifyListeners();
    }
  }

  double get total => (cartItems + recalledItems).fold(
    0.0,
    (sum, item) => sum + (item.price * item.quantity),
  );

  String? get recalledBillId => _recalledBillIdMap[_currentType];
  String? get selectedKitchenId => _selectedKitchenIdMap[_currentType];
  String? get selectedKitchenName => _selectedKitchenNameMap[_currentType];
  String? get customerName => _customerNameMap[_currentType];
  String? get customerPhone => _customerPhoneMap[_currentType];
  String? get selectedTable => _selectedTableMap[_currentType];
  String? get selectedSection => _selectedSectionMap[_currentType];

  // Shared getters
  String? get printerIp => _printerIp;
  int get printerPort => _printerPort;
  String? get printerProtocol => _printerProtocol;

  CartProvider() {
    _loadCarts();
  }

  void setCartType(CartType type, {bool notify = true}) {
    if (_currentType == type) return;
    _currentType = type;
    if (notify) notifyListeners();
  }

  void setKitchen(String? id, String? name) {
    _selectedKitchenIdMap[_currentType] = id;
    _selectedKitchenNameMap[_currentType] = name;
    notifyListeners();
    _saveCurrentCart();
  }

  void addOrUpdateItem(CartItem item) {
    final list = _itemsMap[_currentType]!;
    final index = list.indexWhere((i) => i.id == item.id);
    if (index != -1) {
      list[index].quantity += item.quantity;
    } else {
      list.add(item);
    }
    notifyListeners();
    _saveCurrentCart();
  }

  void updateNote(String id, String note) {
    final list = _itemsMap[_currentType]!;
    final index = list.indexWhere((i) => i.id == id);
    if (index != -1) {
      list[index].specialNote = note;
      notifyListeners();
      _saveCurrentCart();
    }
  }

  void updateQuantity(String id, double newQuantity) {
    final list = _itemsMap[_currentType]!;
    final index = list.indexWhere((i) => i.id == id);
    if (index != -1 && newQuantity > 0) {
      list[index].quantity = newQuantity;
      notifyListeners();
      _saveCurrentCart();
    } else if (newQuantity <= 0) {
      removeItem(id);
    }
    if (list.isEmpty && _recalledItemsMap[_currentType]!.isEmpty) {
      _clearMetadata(_currentType);
    }
  }

  void removeItem(String id) {
    final list = _itemsMap[_currentType]!;
    list.removeWhere((i) => i.id == id);
    if (list.isEmpty && _recalledItemsMap[_currentType]!.isEmpty) {
      _clearMetadata(_currentType);
    }
    notifyListeners();
    _saveCurrentCart();
  }

  void _clearMetadata(CartType type) {
    _recalledBillIdMap[type] = null;
    _selectedKitchenIdMap[type] = null;
    _selectedKitchenNameMap[type] = null;
    _customerNameMap[type] = null;
    _customerPhoneMap[type] = null;
    _selectedTableMap[type] = null;
    _selectedSectionMap[type] = null;
  }

  void clearCart() {
    _itemsMap[_currentType]!.clear();
    _recalledItemsMap[_currentType]!.clear();
    _clearMetadata(_currentType);
    notifyListeners();
    _saveCurrentCart();
  }

  void setSelectedTable(String? table, String? section) {
    // If switching tables or starting a new selection, clear existing cart data for that type
    if (_selectedTableMap[_currentType] != table ||
        _selectedSectionMap[_currentType] != section) {
      _itemsMap[_currentType]!.clear();
      _recalledItemsMap[_currentType]!.clear();
      _clearMetadata(_currentType);
    }

    _selectedTableMap[_currentType] = table;
    _selectedSectionMap[_currentType] = section;
    notifyListeners();
    _saveCurrentCart();
  }

  void loadKOTItems(
    List<CartItem> items, {
    String? billId,
    String? cName,
    String? cPhone,
    String? tName,
    String? tSection,
    String? kitchenId,
    String? kitchenName,
  }) {
    // Drafting Mode: Move existing items to recalledItems and clear active items
    _recalledItemsMap[_currentType] = List.from(items);
    _itemsMap[_currentType] = [];

    _recalledBillIdMap[_currentType] = billId;
    _customerNameMap[_currentType] = cName;
    _customerPhoneMap[_currentType] = cPhone;
    _selectedTableMap[_currentType] = tName;
    _selectedSectionMap[_currentType] = tSection;
    if (kitchenId != null) {
      _selectedKitchenIdMap[_currentType] = kitchenId;
    }
    if (kitchenName != null) {
      _selectedKitchenNameMap[_currentType] = kitchenName;
    }
    notifyListeners();
    _saveCurrentCart();
  }

  void setBranchId(String? branchId) {
    _branchId = branchId;
  }

  void setPrinterDetails(
    String? printerIp,
    int? printerPort,
    String? printerProtocol,
  ) {
    _printerIp = printerIp;
    if (printerPort != null) _printerPort = printerPort;
    if (printerProtocol != null && printerProtocol.isNotEmpty) {
      _printerProtocol = printerProtocol;
    }
    notifyListeners();
  }

  String _key(CartType type, String base) => '${type.name}_$base';

  Future<void> _saveCurrentCart() async {
    final prefs = await SharedPreferences.getInstance();
    final type = _currentType;

    // Save active draft
    final cartList = _itemsMap[type]!;
    final cartJson = cartList.map((item) => item.toJson()).toList();
    await prefs.setString(_key(type, 'cart'), jsonEncode(cartJson));

    // Save recalled items
    final recalledList = _recalledItemsMap[type]!;
    final recalledJson = recalledList.map((item) => item.toJson()).toList();
    await prefs.setString(
      _key(type, 'recalledItems'),
      jsonEncode(recalledJson),
    );

    final recalledId = _recalledBillIdMap[type];
    if (recalledId != null &&
        (cartList.isNotEmpty || recalledList.isNotEmpty)) {
      await prefs.setString(_key(type, 'recalledBillId'), recalledId);
    } else {
      await prefs.remove(_key(type, 'recalledBillId'));
    }

    void saveOrRemove(String base, String? value) async {
      if (value != null) {
        await prefs.setString(_key(type, base), value);
      } else {
        await prefs.remove(_key(type, base));
      }
    }

    saveOrRemove('customerName', _customerNameMap[type]);
    saveOrRemove('customerPhone', _customerPhoneMap[type]);
    saveOrRemove('selectedTable', _selectedTableMap[type]);
    saveOrRemove('selectedSection', _selectedSectionMap[type]);
    saveOrRemove('selectedKitchenId', _selectedKitchenIdMap[type]);
    saveOrRemove('selectedKitchenName', _selectedKitchenNameMap[type]);
  }

  Future<void> _loadCarts() async {
    final prefs = await SharedPreferences.getInstance();
    for (var type in CartType.values) {
      // Load active draft
      final cartString = prefs.getString(_key(type, 'cart'));
      if (cartString != null) {
        final List<dynamic> cartJson = jsonDecode(cartString);
        _itemsMap[type] = cartJson
            .map((json) => CartItem.fromJson(json))
            .toList();
      }

      // Load recalled items
      final recalledString = prefs.getString(_key(type, 'recalledItems'));
      if (recalledString != null) {
        final List<dynamic> recalledJson = jsonDecode(recalledString);
        _recalledItemsMap[type] = recalledJson
            .map((json) => CartItem.fromJson(json))
            .toList();
      }

      _recalledBillIdMap[type] = prefs.getString(_key(type, 'recalledBillId'));
      _customerNameMap[type] = prefs.getString(_key(type, 'customerName'));
      _customerPhoneMap[type] = prefs.getString(_key(type, 'customerPhone'));
      _selectedTableMap[type] = prefs.getString(_key(type, 'selectedTable'));
      _selectedSectionMap[type] = prefs.getString(
        _key(type, 'selectedSection'),
      );
      _selectedKitchenIdMap[type] = prefs.getString(
        _key(type, 'selectedKitchenId'),
      );
      _selectedKitchenNameMap[type] = prefs.getString(
        _key(type, 'selectedKitchenName'),
      );
    }
    notifyListeners();
  }

  /// 🧾 Submits billing and returns the generated invoice number
  Future<String?> submitBilling(BuildContext context) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) throw Exception('No token found. Please login again.');

      // Merge items for submission
      final mergedItems = [...recalledItems, ...cartItems];

      final items = mergedItems
          .map(
            (item) => {
              'product': item.id,
              'quantity': item.quantity,
              'price': item.price,
              'unit': item.unit,
              'specialNote': item.specialNote,
              'status': item.status,
            },
          )
          .toList();

      final body = jsonEncode({
        'branch': _branchId,
        'tableDetails': {
          'section': selectedSection,
          'tableNumber': selectedTable,
        },
        'items': items,
        'totalAmount': total,
        'notes': cartItems
            .where(
              (item) =>
                  item.specialNote != null && item.specialNote!.isNotEmpty,
            )
            .map((item) => '${item.name}: ${item.specialNote}')
            .join(', '),
      });

      final response = await http.post(
        Uri.parse('https://blackforest.vseyal.com/api/billings'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: body,
      );

      if (response.statusCode == 201 || response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final invoiceNumber = data['invoiceNumber'] ?? 'N/A';
        clearCart();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Billing Successful — Invoice: $invoiceNumber'),
          ),
        );
        return invoiceNumber;
      } else {
        throw Exception('Failed to submit billing: ${response.body}');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error: Check your internet')),
      );
      return null;
    }
  }

  Future<void> updateRecalledItemStatus(
    BuildContext context,
    int index,
    String newStatus,
  ) async {
    final list = _recalledItemsMap[_currentType]!;
    if (index < 0 || index >= list.length) return;

    final item = list[index];
    final oldStatus = item.status;

    // 1. Optimistic Update
    final updatedItem = CartItem(
      id: item.id,
      name: item.name,
      price: item.price,
      imageUrl: item.imageUrl,
      quantity: item.quantity,
      unit: item.unit,
      department: item.department,
      categoryId: item.categoryId,
      specialNote: item.specialNote,
      status: newStatus,
    );
    list[index] = updatedItem;
    notifyListeners();

    // 2. API Call
    try {
      final billId = recalledBillId;
      if (billId == null) throw Exception("No bill ID found");

      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) throw Exception('No token found');

      // Construct the full updated items list for the PATCH request
      // We must map ALL recalled items back to the API format
      final itemsPayload = list
          .map(
            (i) => {
              'product': i.id,
              'name': i.name, // ✅ Required by server
              'quantity': i.quantity,
              'price': i.price,
              'unitPrice': i.price, // ✅ Required by server
              'unit': i.unit,
              'specialNote': i.specialNote,
              'status': i.status, // use the updated status
            },
          )
          .toList();

      final response = await http.patch(
        Uri.parse('https://blackforest.vseyal.com/api/billings/$billId'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'items': itemsPayload}),
      );

      if (response.statusCode != 200) {
        throw Exception('Failed to update status: ${response.statusCode}');
      }

      // If cancelled, remove from local list to hide from UI
      if (newStatus == 'cancelled') {
        list.removeAt(index);
      }
      notifyListeners();
      _saveCurrentCart();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Item marked as $newStatus'),
          backgroundColor: newStatus == 'cancelled'
              ? Colors.orange
              : Colors.green,
          duration: const Duration(seconds: 1),
        ),
      );
    } catch (e) {
      // 3. Revert on Failure
      list[index] = CartItem(
        id: item.id,
        name: item.name,
        price: item.price,
        imageUrl: item.imageUrl,
        quantity: item.quantity,
        unit: item.unit,
        department: item.department,
        categoryId: item.categoryId,
        specialNote: item.specialNote,
        status: oldStatus,
      );
      notifyListeners();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Network error: Check your internet'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> refreshRecalledBill() async {
    final billId = recalledBillId;
    if (billId == null) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) return;

      final response = await http.get(
        Uri.parse('https://blackforest.vseyal.com/api/billings/$billId'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> serverItems = data['items'] ?? [];
        final localRecalled = _recalledItemsMap[_currentType]!;

        bool changed = false;
        final Set<int> matchedIndices = {};

        for (var sItem in serverItems) {
          final pid = (sItem['product'] is Map)
              ? sItem['product']['id']
              : sItem['product'];
          final sStatus = sItem['status']?.toString().toLowerCase();

          // Find matching local item by product id that hasn't been matched yet
          // This correctly handles multiple entries of "Tea" with different statuses
          int idx = -1;
          for (int i = 0; i < localRecalled.length; i++) {
            if (!matchedIndices.contains(i) && localRecalled[i].id == pid) {
              idx = i;
              matchedIndices.add(i);
              break;
            }
          }

          if (idx != -1) {
            final lItem = localRecalled[idx];
            if (lItem.status != sStatus) {
              localRecalled[idx] = CartItem(
                id: lItem.id,
                name: lItem.name,
                price: lItem.price,
                imageUrl: lItem.imageUrl,
                quantity: lItem.quantity,
                unit: lItem.unit,
                department: lItem.department,
                categoryId: lItem.categoryId,
                specialNote: lItem.specialNote,
                status: sStatus,
              );
              changed = true;
            }
          }
        }

        if (changed) {
          notifyListeners();
          _saveCurrentCart();
        }
      }
    } catch (e) {
      debugPrint("Error refreshing bill: $e");
    }
  }

  Future<void> syncKitchenNotifications() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      final userId = prefs.getString('user_id');
      final branchId = prefs.getString('branchId');

      if (token == null || userId == null) return;

      final now = DateTime.now();
      final todayStart = DateTime(
        now.year,
        now.month,
        now.day,
      ).toIso8601String();

      // Fetch pending/ordered bills for today
      String urlString =
          'https://blackforest.vseyal.com/api/billings?where[status][in]=pending,ordered&where[createdBy][equals]=$userId&where[createdAt][greater_than_equal]=$todayStart&limit=100&sort=-createdAt&depth=1';

      if (branchId != null) {
        urlString += '&where[branch][equals]=$branchId';
      }

      final response = await http.get(
        Uri.parse(urlString),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> bills = data['docs'] ?? [];
        List<Map<String, dynamic>> readyItems = [];

        for (var bill in bills) {
          final items = bill['items'] as List?;
          if (items == null) continue;

          for (var item in items) {
            final status = item['status']?.toString().toLowerCase();
            final String itemId =
                '${bill['id']}_${item['name']}_${status}_${item['updatedAt']}';
            if (_readNotificationIds.contains(itemId)) continue;

            if (status == 'prepared' || status == 'confirmed') {
              readyItems.add({
                'id': itemId,
                'billId': bill['id'],
                'kotNumber': bill['kotNumber']?.toString() ?? 'N/A',
                'tableName': bill['table']?['name'] ?? 'Kitchen',
                'sectionName': bill['table']?['section']?['name'],
                'productName': item['name'],
                'quantity': item['quantity'],
                'unit': item['unit'],
                'status': status,
                'preparedAt': item['updatedAt'],
              });
            }
          }
        }

        if (readyItems.length != _kitchenNotifications.length ||
            readyItems.toString() != _kitchenNotifications.toString()) {
          // Check if there are genuinely NEW notification IDs to play sound
          final existingIds = _kitchenNotifications
              .map((n) => n['id'] as String)
              .toSet();
          final hasNewItems = readyItems.any(
            (n) => !existingIds.contains(n['id'] as String),
          );

          if (hasNewItems) {
            _audioPlayer.play(AssetSource('sounds/order.wav'));

            // Show visual notification for new items
            final newItems = readyItems
                .where((n) => !existingIds.contains(n['id'] as String))
                .toList();

            if (newItems.isNotEmpty) {
              String bodyText;
              if (newItems.length == 1) {
                final item = newItems.first;
                bodyText =
                    "${item['quantity']} ${item['productName']} is ready";
              } else {
                final names = newItems
                    .take(2)
                    .map((n) => "${n['quantity']} ${n['productName']}")
                    .join(", ");
                bodyText =
                    "$names${newItems.length > 2 ? ' +${newItems.length - 2} more' : ''} ready";
              }

              NotificationService().showNotification(
                id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
                title: 'Kitchen Ready',
                body: bodyText,
                payload: newItems.first['billId'],
              );
            }
          }

          _kitchenNotifications = readyItems;
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint("Error syncing kitchen notifications: $e");
    }
  }

  Future<void> openBillAndNavigate(BuildContext context, String billId) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      await loadBillFromServer(billId);

      if (!context.mounted) return;
      Navigator.pop(context); // Close loading

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const CartPage()),
      );
    } catch (e) {
      if (context.mounted) {
        if (Navigator.canPop(context)) Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> loadBillFromServer(String billId) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    if (token == null) throw Exception("No token");

    final response = await http.get(
      Uri.parse('https://blackforest.vseyal.com/api/billings/$billId?depth=3'),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (response.statusCode == 200) {
      markBillAsRead(billId);
      final bill = jsonDecode(response.body);

      List<CartItem> recalledItems = (bill['items'] as List)
          .where((item) => item['status']?.toString() != 'cancelled')
          .map((item) {
            final prod = item['product'];
            final String pid = (prod is Map)
                ? (prod['id'] ?? prod['_id'] ?? prod[r'$oid']).toString()
                : prod.toString();

            String? imageUrl;
            String? dept;
            String? cid;

            if (prod is Map) {
              if (prod['images'] != null &&
                  (prod['images'] as List).isNotEmpty) {
                final img = prod['images'][0]['image'];
                if (img != null && img['url'] != null) {
                  imageUrl = img['url'];
                  if (imageUrl != null && imageUrl.startsWith('/')) {
                    imageUrl = 'https://blackforest.vseyal.com$imageUrl';
                  }
                }
              }
              if (prod['department'] != null) {
                dept = (prod['department'] is Map)
                    ? prod['department']['name']
                    : prod['department'];
              }
              if (prod['category'] != null) {
                cid = (prod['category'] is Map)
                    ? prod['category']['id']
                    : prod['category'];
              }
            }

            return CartItem(
              id: pid,
              name: item['name'] ?? 'Unknown',
              price: (item['unitPrice'] ?? item['price'] ?? 0.0).toDouble(),
              imageUrl: imageUrl,
              quantity: (item['quantity'] ?? 0.0).toDouble(),
              unit: item['unit']?.toString(),
              department: dept,
              categoryId: cid,
              specialNote: item['specialNote'],
              status: item['status']?.toString(),
            );
          })
          .toList();

      setCartType(CartType.table);
      loadKOTItems(
        recalledItems,
        billId: billId,
        cName: bill['customerName'],
        cPhone: bill['customerPhone'],
        tName: bill['table']?['name'],
        tSection: bill['table']?['section']?['name'],
      );
    } else {
      throw Exception("Failed to load bill: ${response.statusCode}");
    }
  }

  Future<Map<String, dynamic>?> fetchCustomerData(String phoneNumber) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) throw Exception('No token found');

      // 1. Fetch Billings for this customer directly for robust metrics
      final response = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/billings?where[customerDetails.phoneNumber][equals]=$phoneNumber&where[status][not_equals]=cancelled&sort=-createdAt&limit=500&depth=4',
        ),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> bills = data['docs'] ?? [];
        if (bills.isEmpty) return null;

        double totalAmount = 0;
        double bigBill = 0;
        Map<String, int> productCounts = {};
        Map<String, double> productAmounts = {};

        for (var bill in bills) {
          final amount = (bill['totalAmount'] as num?)?.toDouble() ?? 0.0;
          totalAmount += amount;
          if (amount > bigBill) bigBill = amount;

          // Count products for "Favourite" logic
          final items = bill['items'] as List? ?? [];
          for (var item in items) {
            final productName = item['name'] ?? 'Unknown';
            final quantity = (item['quantity'] as num?)?.toInt() ?? 0;
            final itemAmount = (item['subtotal'] as num?)?.toDouble() ?? 0.0;

            productCounts[productName] =
                (productCounts[productName] ?? 0) + quantity;
            productAmounts[productName] =
                (productAmounts[productName] ?? 0) + itemAmount;
          }
        }

        // Find favourite product
        String favouriteProductName = 'N/A';
        int favouriteProductQty = 0;
        double favouriteProductTotal = 0.0;

        if (productCounts.isNotEmpty) {
          final sortedProducts = productCounts.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));
          favouriteProductName = sortedProducts.first.key;
          favouriteProductQty = sortedProducts.first.value;
          favouriteProductTotal = productAmounts[favouriteProductName] ?? 0.0;
        }

        final lastBill = bills.first; // Sorted by -createdAt
        final customerDetails = lastBill['customerDetails'];
        final customerName = (customerDetails is Map)
            ? (customerDetails['name'] ??
                  customerDetails['phoneNumber'] ??
                  'Unknown')
            : 'Unknown';
        final branch = lastBill['branch'];
        final lastBranch = (branch is Map) ? branch['name'] ?? 'N/A' : 'N/A';

        return {
          'name': customerName,
          'phoneNumber': phoneNumber,
          'totalBills': data['totalDocs'] ?? bills.length,
          'totalAmount': totalAmount,
          'bigBill': bigBill,
          'favouriteProduct': favouriteProductName,
          'favouriteProductQty': favouriteProductQty,
          'favouriteProductAmount': favouriteProductTotal,
          'lastBillAmount':
              (lastBill['totalAmount'] as num?)?.toDouble() ?? 0.0,
          'lastBillDate': lastBill['createdAt'],
          'lastBranch': lastBranch,
          'bills': bills,
        };
      } else {
        throw Exception('Failed to fetch metrics: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint("Error fetching customer data: $e");
      rethrow;
    }
  }
}
