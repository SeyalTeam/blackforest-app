import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:blackforest_app/notification_service.dart';
import 'package:blackforest_app/cart_page.dart';

class CartItem {
  final String id;
  final String? billingItemId; // Billing sub-item id from server
  final String name;
  final double price;
  final String? imageUrl;
  double quantity; // ✅ changed from int → double
  final String? unit; // ✅ optional, e.g. "pcs" or "kg"
  final String? department; // ✅ New field
  final String? categoryId; // ✅ For KOT routing
  String? specialNote; // ✅ Optional note for KOT
  final String? status; // ✅ New field for item status
  final bool isOfferFreeItem;
  final String? offerRuleKey;
  final String? offerTriggerProductId;
  final bool isRandomCustomerOfferItem;
  final String? randomCustomerOfferCampaignCode;
  final bool isPriceOfferApplied;
  final String? priceOfferRuleKey;
  final double priceOfferDiscountPerUnit;
  final double priceOfferAppliedUnits;
  final double? effectiveUnitPrice;
  final double? lineSubtotal;

  CartItem({
    required this.id,
    this.billingItemId,
    required this.name,
    required this.price,
    this.imageUrl,
    required this.quantity,
    this.unit,
    this.department,
    this.categoryId,
    this.specialNote,
    this.status,
    this.isOfferFreeItem = false,
    this.offerRuleKey,
    this.offerTriggerProductId,
    this.isRandomCustomerOfferItem = false,
    this.randomCustomerOfferCampaignCode,
    this.isPriceOfferApplied = false,
    this.priceOfferRuleKey,
    this.priceOfferDiscountPerUnit = 0,
    this.priceOfferAppliedUnits = 0,
    this.effectiveUnitPrice,
    this.lineSubtotal,
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
      isOfferFreeItem: false,
      offerRuleKey: null,
      offerTriggerProductId: null,
      isRandomCustomerOfferItem: false,
      randomCustomerOfferCampaignCode: null,
      isPriceOfferApplied: false,
      priceOfferRuleKey: null,
      priceOfferDiscountPerUnit: 0,
      priceOfferAppliedUnits: 0,
      effectiveUnitPrice: null,
      lineSubtotal: null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'billingItemId': billingItemId,
      'name': name,
      'price': price,
      'imageUrl': imageUrl,
      'quantity': quantity,
      'unit': unit,
      'department': department,
      'categoryId': categoryId,
      'specialNote': specialNote,
      'status': status,
      'isOfferFreeItem': isOfferFreeItem,
      'offerRuleKey': offerRuleKey,
      'offerTriggerProductId': offerTriggerProductId,
      'isRandomCustomerOfferItem': isRandomCustomerOfferItem,
      'randomCustomerOfferCampaignCode': randomCustomerOfferCampaignCode,
      'isPriceOfferApplied': isPriceOfferApplied,
      'priceOfferRuleKey': priceOfferRuleKey,
      'priceOfferDiscountPerUnit': priceOfferDiscountPerUnit,
      'priceOfferAppliedUnits': priceOfferAppliedUnits,
      'effectiveUnitPrice': effectiveUnitPrice,
      'lineSubtotal': lineSubtotal,
    };
  }

  factory CartItem.fromJson(Map<String, dynamic> json) {
    double toSafeDouble(dynamic value) {
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value) ?? 0.0;
      return 0.0;
    }

    double? toSafeNullableDouble(dynamic value) {
      if (value == null) return null;
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value);
      return null;
    }

    return CartItem(
      id: json['id'],
      billingItemId: json['billingItemId']?.toString(),
      name: json['name'],
      price: toSafeDouble(json['price']),
      imageUrl: json['imageUrl'],
      quantity: toSafeDouble(json['quantity']),
      unit: json['unit'],
      department: json['department'],
      categoryId: json['categoryId'],
      specialNote: json['specialNote'],
      status: json['status'],
      isOfferFreeItem: json['isOfferFreeItem'] == true,
      offerRuleKey: json['offerRuleKey']?.toString(),
      offerTriggerProductId: json['offerTriggerProductId']?.toString(),
      isRandomCustomerOfferItem: json['isRandomCustomerOfferItem'] == true,
      randomCustomerOfferCampaignCode: json['randomCustomerOfferCampaignCode']
          ?.toString(),
      isPriceOfferApplied: json['isPriceOfferApplied'] == true,
      priceOfferRuleKey: json['priceOfferRuleKey']?.toString(),
      priceOfferDiscountPerUnit: toSafeDouble(
        json['priceOfferDiscountPerUnit'],
      ),
      priceOfferAppliedUnits: toSafeDouble(json['priceOfferAppliedUnits']),
      effectiveUnitPrice: toSafeNullableDouble(json['effectiveUnitPrice']),
      lineSubtotal: toSafeNullableDouble(json['lineSubtotal']),
    );
  }

  Map<String, dynamic> toBillingPayload({
    bool includeSubtotal = true,
    bool includeBranchOverride = false,
    bool branchOverrideValue = false,
  }) {
    final isForcedRandomOfferItem = isRandomCustomerOfferItem;
    final payloadQuantity = isForcedRandomOfferItem ? 1.0 : quantity;
    final payloadUnitPrice = isForcedRandomOfferItem ? 0.0 : price;
    final payloadSubtotal = isForcedRandomOfferItem
        ? 0.0
        : (lineSubtotal ?? (price * quantity));

    final payload = <String, dynamic>{
      'product': id,
      'name': name,
      'quantity': payloadQuantity,
      'unitPrice': payloadUnitPrice,
      'status': status,
      'specialNote': specialNote,
    };

    if (billingItemId != null && billingItemId!.isNotEmpty) {
      payload['id'] = billingItemId;
    }

    if (includeSubtotal) {
      payload['subtotal'] = payloadSubtotal;
    }

    if (includeBranchOverride) {
      payload['branchOverride'] = branchOverrideValue;
    }

    if (unit != null && unit!.isNotEmpty) {
      payload['unit'] = unit;
    }

    if (isOfferFreeItem) {
      payload['isOfferFreeItem'] = true;
    }

    if (offerRuleKey != null && offerRuleKey!.isNotEmpty) {
      payload['offerRuleKey'] = offerRuleKey;
    }

    if (offerTriggerProductId != null && offerTriggerProductId!.isNotEmpty) {
      payload['offerTriggerProduct'] = offerTriggerProductId;
    }

    if (isRandomCustomerOfferItem) {
      payload['isRandomCustomerOfferItem'] = true;
      payload['quantity'] = 1.0;
      payload['unitPrice'] = 0.0;
      if (includeSubtotal) {
        payload['subtotal'] = 0.0;
      }
      payload['effectiveUnitPrice'] = 0.0;
    }

    if (randomCustomerOfferCampaignCode != null &&
        randomCustomerOfferCampaignCode!.isNotEmpty) {
      payload['randomCustomerOfferCampaignCode'] =
          randomCustomerOfferCampaignCode;
    }

    if (isPriceOfferApplied) {
      payload['isPriceOfferApplied'] = true;
    }

    if (priceOfferRuleKey != null && priceOfferRuleKey!.isNotEmpty) {
      payload['priceOfferRuleKey'] = priceOfferRuleKey;
    }

    if (priceOfferDiscountPerUnit > 0) {
      payload['priceOfferDiscountPerUnit'] = priceOfferDiscountPerUnit;
    }

    if (priceOfferAppliedUnits > 0) {
      payload['priceOfferAppliedUnits'] = priceOfferAppliedUnits;
    }

    if (effectiveUnitPrice != null) {
      payload['effectiveUnitPrice'] = effectiveUnitPrice;
    }

    return payload;
  }

  double get lineTotal => lineSubtotal ?? (price * quantity);
}

enum CartType { billing, table }

class CartProvider extends ChangeNotifier {
  static const String sharedTablesSectionName = 'Shared Tables';
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
    (sum, item) => sum + item.lineTotal,
  );

  String? get recalledBillId => _recalledBillIdMap[_currentType];
  String? get selectedKitchenId => _selectedKitchenIdMap[_currentType];
  String? get selectedKitchenName => _selectedKitchenNameMap[_currentType];
  String? get customerName => _customerNameMap[_currentType];
  String? get customerPhone => _customerPhoneMap[_currentType];
  String? get selectedTable => _selectedTableMap[_currentType];
  String? get selectedSection => _selectedSectionMap[_currentType];
  bool get isSharedTableOrder =>
      _isSharedTablesSection(_selectedSectionMap[_currentType]);

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

  bool _isSharedTablesSection(String? section) {
    return (section ?? '').trim().toLowerCase() ==
        sharedTablesSectionName.toLowerCase();
  }

  void startSharedTableOrder() {
    _itemsMap[_currentType]!.clear();
    _recalledItemsMap[_currentType]!.clear();
    _clearMetadata(_currentType);
    _selectedSectionMap[_currentType] = sharedTablesSectionName;
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

  void setSelectedTableMetadata(String? table, String? section) {
    _selectedTableMap[_currentType] = table;
    _selectedSectionMap[_currentType] = section;
    notifyListeners();
    _saveCurrentCart();
  }

  void setCustomerDetails({String? name, String? phone}) {
    final trimmedName = name?.trim();
    final trimmedPhone = phone?.trim();

    _customerNameMap[_currentType] =
        (trimmedName == null || trimmedName.isEmpty) ? null : trimmedName;
    _customerPhoneMap[_currentType] =
        (trimmedPhone == null || trimmedPhone.isEmpty) ? null : trimmedPhone;

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

      final items = mergedItems.map((item) => item.toBillingPayload()).toList();

      final hasTableDetailsForSubmit =
          _currentType == CartType.table &&
          ((selectedSection?.trim().isNotEmpty ?? false) ||
              (selectedTable?.trim().isNotEmpty ?? false));
      final payload = <String, dynamic>{
        'branch': _branchId,
        'items': items,
        'totalAmount': total,
        'notes': cartItems
            .where(
              (item) =>
                  item.specialNote != null && item.specialNote!.isNotEmpty,
            )
            .map((item) => '${item.name}: ${item.specialNote}')
            .join(', '),
      };
      if (hasTableDetailsForSubmit) {
        payload['tableDetails'] = {
          'section': selectedSection,
          'tableNumber': selectedTable,
        };
      }
      final body = jsonEncode(payload);

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
    if (item.isOfferFreeItem || item.isRandomCustomerOfferItem) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Offer items are read-only'),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }
    final oldStatus = item.status;

    // 1. Optimistic Update
    final updatedItem = CartItem(
      id: item.id,
      billingItemId: item.billingItemId,
      name: item.name,
      price: item.price,
      imageUrl: item.imageUrl,
      quantity: item.quantity,
      unit: item.unit,
      department: item.department,
      categoryId: item.categoryId,
      specialNote: item.specialNote,
      status: newStatus,
      isOfferFreeItem: item.isOfferFreeItem,
      offerRuleKey: item.offerRuleKey,
      offerTriggerProductId: item.offerTriggerProductId,
      isRandomCustomerOfferItem: item.isRandomCustomerOfferItem,
      randomCustomerOfferCampaignCode: item.randomCustomerOfferCampaignCode,
      isPriceOfferApplied: item.isPriceOfferApplied,
      priceOfferRuleKey: item.priceOfferRuleKey,
      priceOfferDiscountPerUnit: item.priceOfferDiscountPerUnit,
      priceOfferAppliedUnits: item.priceOfferAppliedUnits,
      effectiveUnitPrice: item.effectiveUnitPrice,
      lineSubtotal: item.lineSubtotal,
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
      final itemsPayload = list.map((i) => i.toBillingPayload()).toList();

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
        billingItemId: item.billingItemId,
        name: item.name,
        price: item.price,
        imageUrl: item.imageUrl,
        quantity: item.quantity,
        unit: item.unit,
        department: item.department,
        categoryId: item.categoryId,
        specialNote: item.specialNote,
        status: oldStatus,
        isOfferFreeItem: item.isOfferFreeItem,
        offerRuleKey: item.offerRuleKey,
        offerTriggerProductId: item.offerTriggerProductId,
        isRandomCustomerOfferItem: item.isRandomCustomerOfferItem,
        randomCustomerOfferCampaignCode: item.randomCustomerOfferCampaignCode,
        isPriceOfferApplied: item.isPriceOfferApplied,
        priceOfferRuleKey: item.priceOfferRuleKey,
        priceOfferDiscountPerUnit: item.priceOfferDiscountPerUnit,
        priceOfferAppliedUnits: item.priceOfferAppliedUnits,
        effectiveUnitPrice: item.effectiveUnitPrice,
        lineSubtotal: item.lineSubtotal,
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

        double toSafeDouble(dynamic value) {
          if (value is num) return value.toDouble();
          if (value is String) {
            return double.tryParse(value) ?? 0.0;
          }
          return 0.0;
        }

        bool changed = false;
        final Set<int> matchedIndices = {};

        for (var sItem in serverItems) {
          final serverItemID = sItem['id']?.toString();
          final pid = (sItem['product'] is Map)
              ? sItem['product']['id']?.toString()
              : sItem['product']?.toString();
          final sStatus = sItem['status']?.toString().toLowerCase();
          final sIsOfferFreeItem = sItem['isOfferFreeItem'] == true;
          final sNotesValue = (sItem['notes'] ?? sItem['specialNote'] ?? '')
              .toString()
              .trim();
          final sIsRandomCustomerOfferItem =
              sItem['isRandomCustomerOfferItem'] == true ||
              sNotesValue.toUpperCase() == 'RANDOM CUSTOMER OFFER';
          final sRandomCustomerOfferCampaignCode =
              sItem['randomCustomerOfferCampaignCode']?.toString();
          final sIsReadOnlyOfferItem =
              sIsOfferFreeItem || sIsRandomCustomerOfferItem;
          final sOfferRuleKey = sItem['offerRuleKey']?.toString();
          final sOfferTriggerProduct = sItem['offerTriggerProduct'];
          final sOfferTriggerProductId = sOfferTriggerProduct is Map
              ? sOfferTriggerProduct['id']?.toString()
              : sOfferTriggerProduct?.toString();
          final sIsPriceOfferApplied = sItem['isPriceOfferApplied'] == true;
          final sPriceOfferRuleKey = sItem['priceOfferRuleKey']?.toString();
          final sPriceOfferDiscountPerUnit = toSafeDouble(
            sItem['priceOfferDiscountPerUnit'],
          );
          final sPriceOfferAppliedUnits = toSafeDouble(
            sItem['priceOfferAppliedUnits'],
          );
          final hasEffectiveUnitPrice =
              sItem is Map && sItem.containsKey('effectiveUnitPrice');
          final sEffectiveUnitPrice = hasEffectiveUnitPrice
              ? (sIsReadOnlyOfferItem
                    ? 0.0
                    : toSafeDouble(sItem['effectiveUnitPrice']))
              : null;
          final hasSubtotal = sItem is Map && sItem.containsKey('subtotal');
          final sSubtotal = sIsRandomCustomerOfferItem
              ? 0.0
              : hasSubtotal
              ? toSafeDouble(sItem['subtotal'])
              : null;
          final sQuantity = sIsRandomCustomerOfferItem
              ? 1.0
              : toSafeDouble(sItem['quantity']);
          final sPrice = sIsReadOnlyOfferItem
              ? 0.0
              : toSafeDouble(
                  sItem['effectiveUnitPrice'] ??
                      sItem['unitPrice'] ??
                      sItem['price'],
                );

          // Prefer matching by billing sub-item ID, fallback to product ID.
          int idx = -1;
          if (serverItemID != null && serverItemID.isNotEmpty) {
            for (int i = 0; i < localRecalled.length; i++) {
              if (!matchedIndices.contains(i) &&
                  localRecalled[i].billingItemId == serverItemID) {
                idx = i;
                matchedIndices.add(i);
                break;
              }
            }
          }
          if (idx == -1) {
            for (int i = 0; i < localRecalled.length; i++) {
              if (!matchedIndices.contains(i) && localRecalled[i].id == pid) {
                idx = i;
                matchedIndices.add(i);
                break;
              }
            }
          }

          if (idx != -1) {
            final lItem = localRecalled[idx];
            final shouldUpdate =
                lItem.status != sStatus ||
                lItem.isOfferFreeItem != sIsOfferFreeItem ||
                lItem.isRandomCustomerOfferItem != sIsRandomCustomerOfferItem ||
                lItem.randomCustomerOfferCampaignCode !=
                    sRandomCustomerOfferCampaignCode ||
                lItem.offerRuleKey != sOfferRuleKey ||
                lItem.offerTriggerProductId != sOfferTriggerProductId ||
                lItem.isPriceOfferApplied != sIsPriceOfferApplied ||
                lItem.priceOfferRuleKey != sPriceOfferRuleKey ||
                (lItem.priceOfferDiscountPerUnit - sPriceOfferDiscountPerUnit)
                        .abs() >
                    0.001 ||
                (lItem.priceOfferAppliedUnits - sPriceOfferAppliedUnits).abs() >
                    0.001 ||
                (lItem.effectiveUnitPrice ?? -1) !=
                    (sEffectiveUnitPrice ?? -1) ||
                ((lItem.lineSubtotal ?? -1) - (sSubtotal ?? -1)).abs() >
                    0.001 ||
                lItem.billingItemId != serverItemID ||
                (lItem.price - sPrice).abs() > 0.001 ||
                (lItem.quantity - sQuantity).abs() > 0.001;
            if (shouldUpdate) {
              final updatedQuantity = sQuantity > 0
                  ? sQuantity
                  : lItem.quantity;
              final updatedLineSubtotal =
                  sSubtotal ?? (sPrice * updatedQuantity);
              localRecalled[idx] = CartItem(
                id: lItem.id,
                billingItemId: serverItemID ?? lItem.billingItemId,
                name: lItem.name,
                price: sPrice,
                imageUrl: lItem.imageUrl,
                quantity: updatedQuantity,
                unit: lItem.unit,
                department: lItem.department,
                categoryId: lItem.categoryId,
                specialNote: lItem.specialNote,
                status: sStatus,
                isOfferFreeItem: sIsOfferFreeItem,
                offerRuleKey: sOfferRuleKey,
                offerTriggerProductId: sOfferTriggerProductId,
                isRandomCustomerOfferItem: sIsRandomCustomerOfferItem,
                randomCustomerOfferCampaignCode:
                    sRandomCustomerOfferCampaignCode,
                isPriceOfferApplied: sIsPriceOfferApplied,
                priceOfferRuleKey: sPriceOfferRuleKey,
                priceOfferDiscountPerUnit: sPriceOfferDiscountPerUnit,
                priceOfferAppliedUnits: sPriceOfferAppliedUnits,
                effectiveUnitPrice: sEffectiveUnitPrice,
                lineSubtotal: updatedLineSubtotal,
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

      double toSafeDouble(dynamic value) {
        if (value is num) return value.toDouble();
        if (value is String) {
          return double.tryParse(value) ?? 0.0;
        }
        return 0.0;
      }

      List<CartItem> recalledItems = (bill['items'] as List)
          .where((item) => item['status']?.toString() != 'cancelled')
          .map((item) {
            final itemMap = item is Map
                ? Map<String, dynamic>.from(item)
                : <String, dynamic>{};
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

            final isOfferFreeItem = itemMap['isOfferFreeItem'] == true;
            final notesValue =
                (itemMap['notes'] ?? itemMap['specialNote'] ?? '')
                    .toString()
                    .trim();
            final isRandomCustomerOfferItem =
                itemMap['isRandomCustomerOfferItem'] == true ||
                notesValue.toUpperCase() == 'RANDOM CUSTOMER OFFER';
            final isReadOnlyOfferItem =
                isOfferFreeItem || isRandomCustomerOfferItem;
            final hasSubtotal = itemMap.containsKey('subtotal');
            final lineSubtotal = isRandomCustomerOfferItem
                ? 0.0
                : hasSubtotal
                ? toSafeDouble(itemMap['subtotal'])
                : null;
            final hasEffectiveUnitPrice = itemMap.containsKey(
              'effectiveUnitPrice',
            );
            final effectiveUnitPrice = hasEffectiveUnitPrice
                ? (isReadOnlyOfferItem
                      ? 0.0
                      : toSafeDouble(itemMap['effectiveUnitPrice']))
                : null;

            return CartItem(
              id: pid,
              billingItemId: item['id']?.toString(),
              name: item['name'] ?? 'Unknown',
              price: isReadOnlyOfferItem
                  ? 0.0
                  : toSafeDouble(
                      itemMap['effectiveUnitPrice'] ??
                          itemMap['unitPrice'] ??
                          itemMap['price'],
                    ),
              imageUrl: imageUrl,
              quantity: isRandomCustomerOfferItem
                  ? 1.0
                  : toSafeDouble(item['quantity']),
              unit: item['unit']?.toString(),
              department: dept,
              categoryId: cid,
              specialNote: item['specialNote'] ?? item['notes'] ?? item['note'],
              status: item['status']?.toString(),
              isOfferFreeItem: isOfferFreeItem,
              offerRuleKey: item['offerRuleKey']?.toString(),
              offerTriggerProductId: (item['offerTriggerProduct'] is Map)
                  ? item['offerTriggerProduct']['id']?.toString()
                  : item['offerTriggerProduct']?.toString(),
              isRandomCustomerOfferItem: isRandomCustomerOfferItem,
              randomCustomerOfferCampaignCode:
                  itemMap['randomCustomerOfferCampaignCode']?.toString(),
              isPriceOfferApplied: itemMap['isPriceOfferApplied'] == true,
              priceOfferRuleKey: itemMap['priceOfferRuleKey']?.toString(),
              priceOfferDiscountPerUnit: toSafeDouble(
                itemMap['priceOfferDiscountPerUnit'],
              ),
              priceOfferAppliedUnits: toSafeDouble(
                itemMap['priceOfferAppliedUnits'],
              ),
              effectiveUnitPrice: effectiveUnitPrice,
              lineSubtotal: lineSubtotal,
            );
          })
          .toList();

      setCartType(CartType.table);
      loadKOTItems(
        recalledItems,
        billId: billId,
        cName: bill['customerDetails']?['name'] ?? bill['customerName'],
        cPhone:
            bill['customerDetails']?['phoneNumber'] ?? bill['customerPhone'],
        tName: bill['table']?['name'],
        tSection: bill['table']?['section']?['name'],
      );
    } else {
      throw Exception("Failed to load bill: ${response.statusCode}");
    }
  }

  Future<Map<String, dynamic>?> fetchCustomerData(
    String phoneNumber, {
    bool? isTableOrder,
    String? tableSection,
    String? tableNumber,
  }) async {
    try {
      final normalizedPhone = phoneNumber.trim();
      final hasPhoneLookup = normalizedPhone.isNotEmpty;

      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) throw Exception('No token found');

      final headers = {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

      final responses = await Future.wait([
        hasPhoneLookup
            ? http.get(
                Uri.parse(
                  'https://blackforest.vseyal.com/api/billings?where[customerDetails.phoneNumber][equals]=$normalizedPhone&where[status][not_equals]=cancelled&sort=-createdAt&limit=500&depth=4',
                ),
                headers: headers,
              )
            : Future.value(http.Response('{"docs":[],"totalDocs":0}', 200)),
        hasPhoneLookup
            ? http.get(
                Uri.parse(
                  'https://blackforest.vseyal.com/api/customers?where[phoneNumber][equals]=$normalizedPhone&limit=1&depth=0',
                ),
                headers: headers,
              )
            : Future.value(http.Response('{"docs":[],"totalDocs":0}', 200)),
        http.get(
          Uri.parse(
            'https://blackforest.vseyal.com/api/globals/customer-offer-settings',
          ),
          headers: headers,
        ),
      ]);

      final billsResponse = responses[0];
      final customersResponse = responses[1];
      final offerSettingsResponse = responses[2];

      if (billsResponse.statusCode != 200) {
        throw Exception('Failed to fetch metrics: ${billsResponse.statusCode}');
      }

      double toNonNegativeDouble(dynamic value) {
        if (value is num) {
          final parsed = value.toDouble();
          return parsed < 0 ? 0 : parsed;
        }
        return 0;
      }

      final billData = jsonDecode(billsResponse.body);
      final List<dynamic> bills = billData['docs'] ?? [];

      Map<String, dynamic>? customerDoc;
      if (customersResponse.statusCode == 200) {
        final customerData = jsonDecode(customersResponse.body);
        final docs = customerData['docs'];
        if (docs is List && docs.isNotEmpty && docs.first is Map) {
          customerDoc = Map<String, dynamic>.from(docs.first as Map);
        }
      }

      Map<String, dynamic>? offerSettings;
      if (offerSettingsResponse.statusCode == 200) {
        final settingsData = jsonDecode(offerSettingsResponse.body);
        if (settingsData is Map) {
          offerSettings = Map<String, dynamic>.from(settingsData);
        }
      }

      final isNewCustomer = customerDoc == null;

      bool toBoolWithDefault(dynamic value, {bool defaultValue = true}) {
        if (value is bool) return value;
        return defaultValue;
      }

      dynamic readFirstSettingValue(List<String> keys) {
        final settings = offerSettings;
        if (settings == null) return null;
        for (final key in keys) {
          if (!settings.containsKey(key)) continue;
          final value = settings[key];
          if (value != null) return value;
        }
        return null;
      }

      final normalizedSection = (tableSection ?? '').trim();
      final normalizedTableNumber = (tableNumber ?? '').trim();
      final hasRequestTableDetails =
          normalizedSection.isNotEmpty || normalizedTableNumber.isNotEmpty;
      final hasLocalTableDetails =
          (selectedSection?.trim().isNotEmpty ?? false) ||
          (selectedTable?.trim().isNotEmpty ?? false);
      final effectiveIsTableOrder =
          isTableOrder ??
          (hasRequestTableDetails ||
              (_currentType == CartType.table && hasLocalTableDetails));

      bool allowForCurrentOrderType({
        required bool allowOnBillings,
        required bool allowOnTableOrders,
      }) {
        return effectiveIsTableOrder ? allowOnTableOrders : allowOnBillings;
      }

      double totalAmount = 0;
      double bigBill = 0;
      final Map<String, int> productCounts = {};
      final Map<String, double> productAmounts = {};

      for (var bill in bills) {
        final amount = (bill['totalAmount'] as num?)?.toDouble() ?? 0.0;
        totalAmount += amount;
        if (amount > bigBill) bigBill = amount;

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

      final lastBill = bills.isNotEmpty ? bills.first : null;
      final lastBillCustomer = lastBill?['customerDetails'];
      String customerName = isNewCustomer ? '' : normalizedPhone;
      if (customerDoc?['name'] is String &&
          (customerDoc!['name'] as String).trim().isNotEmpty) {
        customerName = (customerDoc['name'] as String).trim();
      } else if (lastBillCustomer is Map &&
          lastBillCustomer['name'] != null &&
          lastBillCustomer['name'].toString().trim().isNotEmpty) {
        customerName = lastBillCustomer['name'].toString().trim();
      }

      final branch = lastBill?['branch'];
      final lastBranch = (branch is Map) ? branch['name'] ?? 'N/A' : 'N/A';

      final rewardPoints = toNonNegativeDouble(customerDoc?['rewardPoints']);
      final rewardProgressAmount = toNonNegativeDouble(
        customerDoc?['rewardProgressAmount'],
      );
      final allowCustomerCreditOfferOnBillings = toBoolWithDefault(
        offerSettings?['allowCustomerCreditOfferOnBillings'],
      );
      final allowCustomerCreditOfferOnTableOrders = toBoolWithDefault(
        offerSettings?['allowCustomerCreditOfferOnTableOrders'],
      );
      final offerEnabled =
          offerSettings?['enabled'] == true &&
          allowForCurrentOrderType(
            allowOnBillings: allowCustomerCreditOfferOnBillings,
            allowOnTableOrders: allowCustomerCreditOfferOnTableOrders,
          );
      final pointsNeededForOffer = toNonNegativeDouble(
        offerSettings?['pointsNeededForOffer'],
      );
      final offerAmount = toNonNegativeDouble(offerSettings?['offerAmount']);
      final spendAmountPerStep = toNonNegativeDouble(
        offerSettings?['spendAmountPerStep'],
      );
      final pointsPerStep = toNonNegativeDouble(
        offerSettings?['pointsPerStep'],
      );
      final resetOnRedeem = offerSettings?['resetOnRedeem'] == true;
      final allowProductToProductOfferOnBillings = toBoolWithDefault(
        offerSettings?['allowProductToProductOfferOnBillings'],
      );
      final allowProductToProductOfferOnTableOrders = toBoolWithDefault(
        offerSettings?['allowProductToProductOfferOnTableOrders'],
      );
      final enableProductToProductOffer =
          offerSettings?['enableProductToProductOffer'] == true &&
          allowForCurrentOrderType(
            allowOnBillings: allowProductToProductOfferOnBillings,
            allowOnTableOrders: allowProductToProductOfferOnTableOrders,
          );
      final rawProductToProductOffers =
          offerSettings?['productToProductOffers'];
      final allowProductPriceOfferOnBillings = toBoolWithDefault(
        offerSettings?['allowProductPriceOfferOnBillings'],
      );
      final allowProductPriceOfferOnTableOrders = toBoolWithDefault(
        offerSettings?['allowProductPriceOfferOnTableOrders'],
      );
      final enableProductPriceOffer =
          offerSettings?['enableProductPriceOffer'] == true &&
          allowForCurrentOrderType(
            allowOnBillings: allowProductPriceOfferOnBillings,
            allowOnTableOrders: allowProductPriceOfferOnTableOrders,
          );
      final rawProductPriceOffers = offerSettings?['productPriceOffers'];
      final allowTotalPercentageOfferOnBillings = toBoolWithDefault(
        offerSettings?['allowTotalPercentageOfferOnBillings'],
      );
      final allowTotalPercentageOfferOnTableOrders = toBoolWithDefault(
        offerSettings?['allowTotalPercentageOfferOnTableOrders'],
      );
      final enableTotalPercentageOffer =
          offerSettings?['enableTotalPercentageOffer'] == true &&
          allowForCurrentOrderType(
            allowOnBillings: allowTotalPercentageOfferOnBillings,
            allowOnTableOrders: allowTotalPercentageOfferOnTableOrders,
          );
      final totalPercentageOfferPercent = toNonNegativeDouble(
        offerSettings?['totalPercentageOfferPercent'],
      );
      final totalPercentageOfferRandomOnly =
          offerSettings?['totalPercentageOfferRandomOnly'] == true;
      final hasTotalPercentageRandomChanceConfig =
          offerSettings?.containsKey(
            'totalPercentageOfferRandomSelectionChancePercent',
          ) ==
          true;
      final totalPercentageOfferRandomSelectionChancePercent =
          toNonNegativeDouble(
            offerSettings?['totalPercentageOfferRandomSelectionChancePercent'],
          );
      final totalPercentageOfferAvailableFromDate = readFirstSettingValue([
        'totalPercentageOfferAvailableFromDate',
        'totalPercentageOfferFromDate',
        'totalPercentageOfferStartDate',
      ]);
      final totalPercentageOfferAvailableToDate = readFirstSettingValue([
        'totalPercentageOfferAvailableToDate',
        'totalPercentageOfferToDate',
        'totalPercentageOfferEndDate',
      ]);
      final totalPercentageOfferDailyStartTime = readFirstSettingValue([
        'totalPercentageOfferDailyStartTime',
        'totalPercentageOfferStartTime',
      ]);
      final totalPercentageOfferDailyEndTime = readFirstSettingValue([
        'totalPercentageOfferDailyEndTime',
        'totalPercentageOfferEndTime',
      ]);
      final totalPercentageOfferMaxOfferCount = toNonNegativeDouble(
        offerSettings?['totalPercentageOfferMaxOfferCount'],
      );
      final totalPercentageOfferMaxCustomerCount = toNonNegativeDouble(
        offerSettings?['totalPercentageOfferMaxCustomerCount'],
      );
      final totalPercentageOfferMaxUsagePerCustomer = toNonNegativeDouble(
        offerSettings?['totalPercentageOfferMaxUsagePerCustomer'],
      );
      final totalPercentageOfferGivenCount = toNonNegativeDouble(
        offerSettings?['totalPercentageOfferGivenCount'],
      );
      final totalPercentageOfferCustomerCount = toNonNegativeDouble(
        offerSettings?['totalPercentageOfferCustomerCount'],
      );
      final rawTotalPercentageOfferCustomers =
          offerSettings?['totalPercentageOfferCustomers'];
      final rawTotalPercentageOfferCustomerUsage =
          offerSettings?['totalPercentageOfferCustomerUsage'];
      final allowCustomerEntryPercentageOfferOnBillings = toBoolWithDefault(
        readFirstSettingValue([
          'allowCustomerEntryPercentageOfferOnBillings',
          'allowCustomerEntryOfferOnBillings',
        ]),
      );
      final allowCustomerEntryPercentageOfferOnTableOrders = toBoolWithDefault(
        readFirstSettingValue([
          'allowCustomerEntryPercentageOfferOnTableOrders',
          'allowCustomerEntryOfferOnTableOrders',
        ]),
      );
      final enableCustomerEntryPercentageOffer =
          readFirstSettingValue([
                'enableCustomerEntryPercentageOffer',
                'customerEntryPercentageOfferEnabled',
              ]) ==
              true &&
          allowForCurrentOrderType(
            allowOnBillings: allowCustomerEntryPercentageOfferOnBillings,
            allowOnTableOrders: allowCustomerEntryPercentageOfferOnTableOrders,
          );
      final customerEntryPercentageOfferPercent = toNonNegativeDouble(
        readFirstSettingValue([
          'customerEntryPercentageOfferPercent',
          'customerEntryOfferPercent',
        ]),
      );
      final customerEntryPercentageOfferAvailableFromDate =
          readFirstSettingValue([
            'customerEntryPercentageOfferAvailableFromDate',
            'customerEntryPercentageOfferFromDate',
            'customerEntryPercentageOfferStartDate',
          ]);
      final customerEntryPercentageOfferAvailableToDate =
          readFirstSettingValue([
            'customerEntryPercentageOfferAvailableToDate',
            'customerEntryPercentageOfferToDate',
            'customerEntryPercentageOfferEndDate',
          ]);
      final customerEntryPercentageOfferDailyStartTime = readFirstSettingValue([
        'customerEntryPercentageOfferDailyStartTime',
        'customerEntryPercentageOfferStartTime',
      ]);
      final customerEntryPercentageOfferDailyEndTime = readFirstSettingValue([
        'customerEntryPercentageOfferDailyEndTime',
        'customerEntryPercentageOfferEndTime',
      ]);
      final allowRandomCustomerProductOfferOnBillings = toBoolWithDefault(
        offerSettings?['allowRandomCustomerProductOfferOnBillings'],
      );
      final allowRandomCustomerProductOfferOnTableOrders = toBoolWithDefault(
        offerSettings?['allowRandomCustomerProductOfferOnTableOrders'],
      );
      final enableRandomCustomerProductOffer =
          offerSettings?['enableRandomCustomerProductOffer'] == true &&
          allowForCurrentOrderType(
            allowOnBillings: allowRandomCustomerProductOfferOnBillings,
            allowOnTableOrders: allowRandomCustomerProductOfferOnTableOrders,
          );
      final randomCustomerOfferCampaignCode =
          offerSettings?['randomCustomerOfferCampaignCode']
              ?.toString()
              .trim() ??
          '';
      final randomCustomerOfferTimezone =
          offerSettings?['randomCustomerOfferTimezone']?.toString().trim() ??
          '';
      final totalPercentageOfferTimezone =
          readFirstSettingValue([
            'totalPercentageOfferTimezone',
            'totalPercentageOfferTimeZone',
          ])?.toString().trim() ??
          randomCustomerOfferTimezone;
      final customerEntryPercentageOfferTimezone =
          readFirstSettingValue([
            'customerEntryPercentageOfferTimezone',
            'customerEntryPercentageOfferTimeZone',
          ])?.toString().trim() ??
          totalPercentageOfferTimezone;
      final rawRandomCustomerOfferProducts =
          offerSettings?['randomCustomerOfferProducts'];
      final lookupPhoneKey = normalizedPhone.replaceAll(RegExp(r'[^0-9]'), '');

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

      String relationName(dynamic value, {String fallback = 'Unknown'}) {
        if (value is Map) {
          final map = Map<String, dynamic>.from(value);
          final name = map['name']?.toString().trim() ?? '';
          if (name.isNotEmpty) return name;
        }
        return fallback;
      }

      List<String> relationIds(dynamic value) {
        if (value == null) return const <String>[];
        if (value is String) {
          return value.trim().isEmpty ? const <String>[] : [value.trim()];
        }
        if (value is num) return [value.toString()];
        if (value is List) {
          final ids = <String>[];
          for (final entry in value) {
            ids.addAll(relationIds(entry));
          }
          return ids.toSet().toList();
        }
        if (value is Map) {
          final map = Map<String, dynamic>.from(value);
          final id = relationId(map);
          if (id != null && id.trim().isNotEmpty) return [id.trim()];
        }
        return const <String>[];
      }

      double relationPrice(dynamic value) {
        if (value is! Map) return 0;
        final map = Map<String, dynamic>.from(value);

        final defaultPrice = map['defaultPriceDetails'];
        if (defaultPrice is Map) {
          final parsed = toNonNegativeDouble(defaultPrice['price']);
          if (parsed > 0) return parsed;
        }

        final branchOverrides = map['branchOverrides'];
        if (branchOverrides is List) {
          for (final raw in branchOverrides) {
            if (raw is! Map) continue;
            final override = Map<String, dynamic>.from(raw);
            final branchId = relationId(override['branch']);
            if (_branchId != null && branchId == _branchId) {
              final branchPrice = toNonNegativeDouble(override['price']);
              if (branchPrice > 0) return branchPrice;
            }
          }
        }

        return 0;
      }

      DateTime? parseDateValue(dynamic value) {
        if (value == null) return null;
        final raw = value.toString().trim();
        if (raw.isEmpty) return null;
        return DateTime.tryParse(raw);
      }

      int? parseMinutesOfDay(dynamic value) {
        if (value == null) return null;
        final raw = value.toString().trim();
        if (raw.isEmpty) return null;
        final parts = raw.split(':');
        if (parts.length < 2) return null;
        final hour = int.tryParse(parts[0]);
        final minute = int.tryParse(parts[1]);
        if (hour == null || minute == null) return null;
        if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
        return hour * 60 + minute;
      }

      int? parseUtcOffsetMinutes(String raw) {
        final value = raw.trim();
        if (value.isEmpty) return null;
        final normalized = value.toUpperCase();
        if (normalized == 'UTC' || normalized == 'GMT') return 0;

        final match = RegExp(r'^([+-])(\d{2}):?(\d{2})$').firstMatch(value);
        if (match == null) return null;
        final sign = match.group(1) == '-' ? -1 : 1;
        final hour = int.tryParse(match.group(2) ?? '');
        final minute = int.tryParse(match.group(3) ?? '');
        if (hour == null || minute == null) return null;
        return sign * (hour * 60 + minute);
      }

      DateTime nowInConfiguredTimezone(String timezoneRaw) {
        final timezone = timezoneRaw.trim();
        if (timezone.isEmpty) return DateTime.now();

        final lower = timezone.toLowerCase();
        const knownOffsets = <String, int>{
          'utc': 0,
          'gmt': 0,
          'asia/kolkata': 330,
          'asia/calcutta': 330,
          'ist': 330,
        };
        final offsetMins =
            knownOffsets[lower] ?? parseUtcOffsetMinutes(timezone);
        if (offsetMins == null) return DateTime.now();

        return DateTime.now().toUtc().add(Duration(minutes: offsetMins));
      }

      bool isNowWithinSchedule({
        required DateTime now,
        dynamic availableFromDate,
        dynamic availableToDate,
        dynamic dailyStartTime,
        dynamic dailyEndTime,
      }) {
        final fromDate = parseDateValue(availableFromDate);
        final toDate = parseDateValue(availableToDate);

        if (fromDate != null && now.isBefore(fromDate)) return false;
        if (toDate != null) {
          final inclusiveEnd = DateTime(
            toDate.year,
            toDate.month,
            toDate.day,
            23,
            59,
            59,
            999,
          );
          if (now.isAfter(inclusiveEnd)) return false;
        }

        final startMins = parseMinutesOfDay(dailyStartTime);
        final endMins = parseMinutesOfDay(dailyEndTime);
        if (startMins == null && endMins == null) return true;

        final nowMins = now.hour * 60 + now.minute;
        if (startMins != null && endMins != null) {
          if (startMins == endMins) return true;
          if (startMins < endMins) {
            return nowMins >= startMins && nowMins <= endMins;
          }
          return nowMins >= startMins || nowMins <= endMins;
        }
        if (startMins != null) return nowMins >= startMins;
        return nowMins <= endMins!;
      }

      int deterministicHash(String seed) {
        var hash = 0;
        for (final codeUnit in seed.codeUnits) {
          hash = (hash * 31 + codeUnit) & 0x7fffffff;
        }
        return hash;
      }

      int deterministicIndex(String seed, int length) {
        if (length <= 0) return -1;
        return deterministicHash(seed) % length;
      }

      bool deterministicChancePass({
        required String seed,
        required double chancePercent,
      }) {
        if (chancePercent >= 100) return true;
        if (chancePercent <= 0) return false;
        final boundedChance = chancePercent.clamp(0, 100).toDouble();
        final randomBucket = (deterministicHash(seed) % 10000) / 100;
        return randomBucket < boundedChance;
      }

      final customerID = relationId(customerDoc);
      final customerRandomOfferCampaignCode =
          customerDoc?['randomCustomerOfferCampaignCode']?.toString().trim() ??
          '';
      final customerRandomOfferRedeemed =
          customerDoc?['randomCustomerOfferRedeemed'] == true;
      final alreadyRedeemedRandomOfferInCampaign =
          customerRandomOfferRedeemed &&
          customerRandomOfferCampaignCode.isNotEmpty &&
          customerRandomOfferCampaignCode == randomCustomerOfferCampaignCode;
      final totalPercentageOfferCustomers = relationIds(
        rawTotalPercentageOfferCustomers,
      );
      final canIdentifyCustomerForPercentage = customerID != null;
      final totalPercentageOfferCustomerUsageRows = <Map<String, dynamic>>[];
      double totalPercentageOfferUsageForCustomer = 0;
      if (rawTotalPercentageOfferCustomerUsage is List) {
        for (final usageRaw in rawTotalPercentageOfferCustomerUsage) {
          if (usageRaw is! Map) continue;
          final usageMap = Map<String, dynamic>.from(usageRaw);
          final usageCustomerId = relationId(usageMap['customer']);
          final usageCount = toNonNegativeDouble(
            usageMap['usageCount'] ??
                usageMap['count'] ??
                usageMap['usedCount'] ??
                usageMap['offerCount'],
          );
          totalPercentageOfferCustomerUsageRows.add({
            'customerId': usageCustomerId,
            'usageCount': usageCount,
          });
          if (customerID != null && usageCustomerId == customerID) {
            totalPercentageOfferUsageForCustomer = usageCount;
          }
        }
      }
      final totalPercentageOfferHasCustomerLimit =
          totalPercentageOfferMaxCustomerCount > 0;
      final totalPercentageOfferHasUsageLimit =
          totalPercentageOfferMaxUsagePerCustomer > 0;
      final totalPercentageOfferRequiresCustomer =
          totalPercentageOfferHasCustomerLimit ||
          totalPercentageOfferHasUsageLimit;
      final totalPercentageOfferBlockedWithoutCustomer =
          totalPercentageOfferRequiresCustomer &&
          !canIdentifyCustomerForPercentage;
      final totalPercentageOfferGlobalRemaining =
          totalPercentageOfferMaxOfferCount > 0
          ? (totalPercentageOfferMaxOfferCount - totalPercentageOfferGivenCount)
                .clamp(0, double.infinity)
                .toDouble()
          : 0.0;
      final totalPercentageOfferCustomerRemaining =
          totalPercentageOfferMaxCustomerCount > 0
          ? (totalPercentageOfferMaxCustomerCount -
                    totalPercentageOfferCustomerCount)
                .clamp(0, double.infinity)
                .toDouble()
          : 0.0;
      final totalPercentageOfferUsageRemaining =
          totalPercentageOfferMaxUsagePerCustomer > 0
          ? (totalPercentageOfferMaxUsagePerCustomer -
                    totalPercentageOfferUsageForCustomer)
                .clamp(0, double.infinity)
                .toDouble()
          : 0.0;
      final totalPercentageOfferGlobalLimitReached =
          totalPercentageOfferMaxOfferCount > 0 &&
          totalPercentageOfferGivenCount >= totalPercentageOfferMaxOfferCount;
      final totalPercentageOfferCustomerLimitReached =
          totalPercentageOfferHasCustomerLimit &&
          totalPercentageOfferCustomerCount >=
              totalPercentageOfferMaxCustomerCount;
      final totalPercentageOfferUsageLimitReached =
          totalPercentageOfferHasUsageLimit &&
          totalPercentageOfferUsageForCustomer >=
              totalPercentageOfferMaxUsagePerCustomer;
      final totalPercentageOfferAlreadyCountedForCustomer =
          customerID != null &&
          totalPercentageOfferCustomers.contains(customerID);
      final nowForRandomOfferPreview = nowInConfiguredTimezone(
        randomCustomerOfferTimezone,
      );
      final nowForTotalPercentagePreview = nowInConfiguredTimezone(
        totalPercentageOfferTimezone,
      );
      final nowForCustomerEntryPercentagePreview = nowInConfiguredTimezone(
        customerEntryPercentageOfferTimezone,
      );
      final totalPercentageOfferScheduleMatched = isNowWithinSchedule(
        now: nowForTotalPercentagePreview,
        availableFromDate: totalPercentageOfferAvailableFromDate,
        availableToDate: totalPercentageOfferAvailableToDate,
        dailyStartTime: totalPercentageOfferDailyStartTime,
        dailyEndTime: totalPercentageOfferDailyEndTime,
      );
      final totalPercentageOfferChancePercent = totalPercentageOfferRandomOnly
          ? (hasTotalPercentageRandomChanceConfig
                ? totalPercentageOfferRandomSelectionChancePercent
                      .clamp(0, 100)
                      .toDouble()
                : 100.0)
          : 100.0;
      final totalPercentageOfferRandomSeed =
          '${lookupPhoneKey.isNotEmpty ? lookupPhoneKey : normalizedPhone}:${randomCustomerOfferCampaignCode.trim()}:total-percentage:${effectiveIsTableOrder ? 'table' : 'billing'}';
      final totalPercentageOfferRandomGatePassed =
          !totalPercentageOfferRandomOnly ||
          deterministicChancePass(
            seed: totalPercentageOfferRandomSeed,
            chancePercent: totalPercentageOfferChancePercent,
          );
      final totalPercentageOfferScheduleBlocked =
          !totalPercentageOfferScheduleMatched;
      final totalPercentageOfferRandomGateBlocked =
          totalPercentageOfferRandomOnly &&
          !totalPercentageOfferRandomGatePassed;
      final totalPercentageOfferPreviewEligible =
          enableTotalPercentageOffer &&
          !totalPercentageOfferBlockedWithoutCustomer &&
          !totalPercentageOfferGlobalLimitReached &&
          !totalPercentageOfferCustomerLimitReached &&
          !totalPercentageOfferUsageLimitReached &&
          !totalPercentageOfferScheduleBlocked &&
          !totalPercentageOfferRandomGateBlocked;
      final hasCustomerEntryForOffer =
          customerName.trim().isNotEmpty || normalizedPhone.trim().isNotEmpty;
      final customerEntryPercentageOfferScheduleMatched = isNowWithinSchedule(
        now: nowForCustomerEntryPercentagePreview,
        availableFromDate: customerEntryPercentageOfferAvailableFromDate,
        availableToDate: customerEntryPercentageOfferAvailableToDate,
        dailyStartTime: customerEntryPercentageOfferDailyStartTime,
        dailyEndTime: customerEntryPercentageOfferDailyEndTime,
      );
      final customerEntryPercentageOfferScheduleBlocked =
          !customerEntryPercentageOfferScheduleMatched;
      final customerEntryPercentageOfferPreviewEligible =
          enableCustomerEntryPercentageOffer &&
          !customerEntryPercentageOfferScheduleBlocked;

      final currentBillItems = [...recalledItems, ...cartItems];
      final Map<String, double> billedQtyByProduct = {};
      final Map<String, double> billedPriceByProduct = {};

      for (final item in currentBillItems) {
        if (item.id.isEmpty ||
            item.isOfferFreeItem ||
            item.isRandomCustomerOfferItem) {
          continue;
        }
        billedQtyByProduct[item.id] =
            (billedQtyByProduct[item.id] ?? 0) + item.quantity;
        billedPriceByProduct[item.id] ??= item.price;
      }

      final List<Map<String, dynamic>> productOfferMatches = [];
      int enabledProductOfferRules = 0;
      if (enableProductToProductOffer && rawProductToProductOffers is List) {
        for (final raw in rawProductToProductOffers) {
          if (raw is! Map) continue;
          final rule = Map<String, dynamic>.from(raw);
          if (rule['enabled'] != true) continue;
          final ruleAllowOnBillings = toBoolWithDefault(
            rule['allowOnBillings'],
          );
          final ruleAllowOnTableOrders = toBoolWithDefault(
            rule['allowOnTableOrders'],
          );
          if (!allowForCurrentOrderType(
            allowOnBillings: ruleAllowOnBillings,
            allowOnTableOrders: ruleAllowOnTableOrders,
          )) {
            continue;
          }
          enabledProductOfferRules += 1;

          final buyProduct = rule['buyProduct'];
          final freeProduct = rule['freeProduct'];

          final buyProductId = relationId(buyProduct);
          final freeProductId = relationId(freeProduct);
          if (buyProductId == null || freeProductId == null) continue;

          final buyQtyStepRaw = toNonNegativeDouble(rule['buyQuantity']);
          final freeQtyStepRaw = toNonNegativeDouble(rule['freeQuantity']);
          final buyQtyStep = buyQtyStepRaw > 0 ? buyQtyStepRaw : 1.0;
          final freeQtyStep = freeQtyStepRaw > 0 ? freeQtyStepRaw : 1.0;
          final maxOfferCount = toNonNegativeDouble(rule['maxOfferCount']);
          final offerGivenCount = toNonNegativeDouble(
            rule['offerGivenCount'] ??
                rule['givenCount'] ??
                rule['appliedCount'] ??
                rule['offerCount'],
          );
          final maxCustomerCount = toNonNegativeDouble(
            rule['maxCustomerCount'],
          );
          final offerCustomers = relationIds(rule['offerCustomers']);
          final offerCustomerCount = toNonNegativeDouble(
            rule['offerCustomerCount'] ??
                rule['customerCount'] ??
                offerCustomers.length,
          );
          final maxUsagePerCustomer = toNonNegativeDouble(
            rule['maxUsagePerCustomer'],
          );
          final hasGlobalLimit = maxOfferCount > 0;
          final globalLimitReached =
              hasGlobalLimit && offerGivenCount >= maxOfferCount;
          final globalRemaining = hasGlobalLimit
              ? (maxOfferCount - offerGivenCount)
                    .clamp(0, double.infinity)
                    .toDouble()
              : 0.0;
          final alreadyCountedForCustomer =
              customerID != null && offerCustomers.contains(customerID);
          final usageLimitEnabled = maxUsagePerCustomer > 0;
          final customerCountLimitEnabled = maxCustomerCount > 0;
          final customerLimitReached =
              customerCountLimitEnabled &&
              offerCustomerCount >= maxCustomerCount &&
              !alreadyCountedForCustomer;
          final customerRemaining = customerCountLimitEnabled
              ? (maxCustomerCount - offerCustomerCount)
                    .clamp(0, double.infinity)
                    .toDouble()
              : 0.0;
          final requiresExistingCustomer =
              usageLimitEnabled || customerCountLimitEnabled;
          const nextBillMessage =
              'This offer will be available from next bill after customer is created.';
          final blockedForNewCustomer =
              isNewCustomer && requiresExistingCustomer;
          final blockedWithoutCustomer =
              (usageLimitEnabled || customerCountLimitEnabled) &&
              customerID == null;
          final rawOfferCustomerUsage = rule['offerCustomerUsage'];
          final List<Map<String, dynamic>> offerCustomerUsage = [];
          double customerUsageCount = 0;

          if (rawOfferCustomerUsage is List) {
            for (final usageRaw in rawOfferCustomerUsage) {
              if (usageRaw is! Map) continue;
              final usageMap = Map<String, dynamic>.from(usageRaw);
              final usageCustomerId = relationId(usageMap['customer']);
              final usageCount = toNonNegativeDouble(
                usageMap['usageCount'] ??
                    usageMap['count'] ??
                    usageMap['usedCount'] ??
                    usageMap['offerCount'],
              );
              offerCustomerUsage.add({
                'customerId': usageCustomerId,
                'usageCount': usageCount,
              });
              if (customerID != null && usageCustomerId == customerID) {
                customerUsageCount = usageCount;
              }
            }
          }

          final usageLimitReached =
              usageLimitEnabled && customerUsageCount >= maxUsagePerCustomer;
          final customerUsageRemaining = usageLimitEnabled
              ? (maxUsagePerCustomer - customerUsageCount)
                    .clamp(0, double.infinity)
                    .toDouble()
              : 0.0;
          final blockedByLimits =
              blockedWithoutCustomer ||
              blockedForNewCustomer ||
              globalLimitReached ||
              customerLimitReached ||
              usageLimitReached;

          final buyQtyInCart = toNonNegativeDouble(
            billedQtyByProduct[buyProductId],
          );
          if (buyQtyInCart <= 0) continue;

          final appliedCycles = (buyQtyInCart / buyQtyStep).floor();
          final predictedFreeQuantity = appliedCycles * freeQtyStep;
          final remainder = buyQtyInCart % buyQtyStep;
          final remainingBuyQuantity = predictedFreeQuantity > 0
              ? 0.0
              : (buyQtyStep - remainder).clamp(0, double.infinity).toDouble();

          final buyName = relationName(buyProduct, fallback: 'Buy Product');
          final freeName = relationName(freeProduct, fallback: 'Free Product');
          final buyUnitPrice =
              billedPriceByProduct[buyProductId] ?? relationPrice(buyProduct);
          final freeUnitPrice = relationPrice(freeProduct);
          final estimatedDiscount = double.parse(
            (predictedFreeQuantity * freeUnitPrice).toStringAsFixed(2),
          );

          productOfferMatches.add({
            'ruleKey':
                relationId(rule['id']) ??
                '$buyProductId:$freeProductId:${buyQtyStep.toStringAsFixed(2)}:${freeQtyStep.toStringAsFixed(2)}',
            'buyProductId': buyProductId,
            'buyProductName': buyName,
            'buyQuantityStep': buyQtyStep,
            'buyQuantityInCart': buyQtyInCart,
            'buyUnitPrice': buyUnitPrice,
            'freeProductId': freeProductId,
            'freeProductName': freeName,
            'freeQuantityStep': freeQtyStep,
            'freeUnitPrice': freeUnitPrice,
            'predictedFreeQuantity': predictedFreeQuantity,
            'estimatedDiscount': estimatedDiscount,
            'remainingBuyQuantity': remainingBuyQuantity,
            'eligible': predictedFreeQuantity > 0 && !blockedByLimits,
            'maxOfferCount': maxOfferCount,
            'offerGivenCount': offerGivenCount,
            'globalLimitReached': globalLimitReached,
            'globalRemaining': globalRemaining,
            'maxCustomerCount': maxCustomerCount,
            'offerCustomerCount': offerCustomerCount,
            'customerLimitReached': customerLimitReached,
            'customerRemaining': customerRemaining,
            'alreadyCountedForCustomer': alreadyCountedForCustomer,
            'maxUsagePerCustomer': maxUsagePerCustomer,
            'customerCountLimitEnabled': customerCountLimitEnabled,
            'requiresExistingCustomer': requiresExistingCustomer,
            'blockedForNewCustomer': blockedForNewCustomer,
            'blockedWithoutCustomer': blockedWithoutCustomer,
            'nextBillMessage': blockedForNewCustomer ? nextBillMessage : null,
            'usageLimitEnabled': usageLimitEnabled,
            'usageLimitReached': usageLimitReached,
            'customerUsageCount': customerUsageCount,
            'customerUsageRemaining': customerUsageRemaining,
            'offerCustomerUsage': offerCustomerUsage,
            'allowOnBillings': ruleAllowOnBillings,
            'allowOnTableOrders': ruleAllowOnTableOrders,
          });
        }
      }

      final List<Map<String, dynamic>> productPriceOfferMatches = [];
      int enabledProductPriceOfferRules = 0;
      if (enableProductPriceOffer && rawProductPriceOffers is List) {
        for (final raw in rawProductPriceOffers) {
          if (raw is! Map) continue;
          final rule = Map<String, dynamic>.from(raw);
          if (rule['enabled'] != true) continue;
          final ruleAllowOnBillings = toBoolWithDefault(
            rule['allowOnBillings'],
          );
          final ruleAllowOnTableOrders = toBoolWithDefault(
            rule['allowOnTableOrders'],
          );
          if (!allowForCurrentOrderType(
            allowOnBillings: ruleAllowOnBillings,
            allowOnTableOrders: ruleAllowOnTableOrders,
          )) {
            continue;
          }
          enabledProductPriceOfferRules += 1;

          final productRef =
              rule['product'] ?? rule['buyProduct'] ?? rule['productId'];
          final productId =
              relationId(productRef) ?? rule['productId']?.toString();
          if (productId == null || productId.isEmpty) continue;

          final quantityInCart = toNonNegativeDouble(
            billedQtyByProduct[productId],
          );
          if (quantityInCart <= 0) continue;

          final productName = relationName(productRef, fallback: 'Product');
          final baseUnitPrice =
              billedPriceByProduct[productId] ?? relationPrice(productRef);

          final explicitDiscount = toNonNegativeDouble(
            rule['discountPerUnit'] ??
                rule['offerAmount'] ??
                rule['discountAmount'] ??
                rule['discount'],
          );
          double offerUnitPrice = toNonNegativeDouble(
            rule['offerPrice'] ??
                rule['priceAfterDiscount'] ??
                rule['effectiveUnitPrice'],
          );
          double discountPerUnit = explicitDiscount;

          if (discountPerUnit <= 0 &&
              baseUnitPrice > 0 &&
              offerUnitPrice > 0 &&
              offerUnitPrice < baseUnitPrice) {
            discountPerUnit = baseUnitPrice - offerUnitPrice;
          }

          if (offerUnitPrice <= 0 && baseUnitPrice > 0 && discountPerUnit > 0) {
            offerUnitPrice = (baseUnitPrice - discountPerUnit)
                .clamp(0, double.infinity)
                .toDouble();
          }

          final maxOfferCount = toNonNegativeDouble(rule['maxOfferCount']);
          final offerGivenCount = toNonNegativeDouble(
            rule['offerGivenCount'] ??
                rule['givenCount'] ??
                rule['appliedCount'] ??
                rule['offerCount'],
          );
          final maxCustomerCount = toNonNegativeDouble(
            rule['maxCustomerCount'],
          );
          final offerCustomers = relationIds(rule['offerCustomers']);
          final offerCustomerCount = toNonNegativeDouble(
            rule['offerCustomerCount'] ??
                rule['customerCount'] ??
                offerCustomers.length,
          );
          final maxUsagePerCustomer = toNonNegativeDouble(
            rule['maxUsagePerCustomer'],
          );
          final hasGlobalLimit = maxOfferCount > 0;
          final globalLimitReached =
              hasGlobalLimit && offerGivenCount >= maxOfferCount;
          final globalRemaining = hasGlobalLimit
              ? (maxOfferCount - offerGivenCount)
                    .clamp(0, double.infinity)
                    .toDouble()
              : 0.0;
          final alreadyCountedForCustomer =
              customerID != null && offerCustomers.contains(customerID);
          final usageLimitEnabled = maxUsagePerCustomer > 0;
          final customerCountLimitEnabled = maxCustomerCount > 0;
          final customerLimitReached =
              customerCountLimitEnabled &&
              offerCustomerCount >= maxCustomerCount &&
              !alreadyCountedForCustomer;
          final customerRemaining = customerCountLimitEnabled
              ? (maxCustomerCount - offerCustomerCount)
                    .clamp(0, double.infinity)
                    .toDouble()
              : 0.0;
          final requiresExistingCustomer =
              usageLimitEnabled || customerCountLimitEnabled;
          const nextBillMessage =
              'This offer will be available from next bill after customer is created.';
          final blockedForNewCustomer =
              isNewCustomer && requiresExistingCustomer;
          final blockedWithoutCustomer =
              (usageLimitEnabled || customerCountLimitEnabled) &&
              customerID == null;
          final rawOfferCustomerUsage = rule['offerCustomerUsage'];
          final List<Map<String, dynamic>> offerCustomerUsage = [];
          double customerUsageCount = 0;

          if (rawOfferCustomerUsage is List) {
            for (final usageRaw in rawOfferCustomerUsage) {
              if (usageRaw is! Map) continue;
              final usageMap = Map<String, dynamic>.from(usageRaw);
              final usageCustomerId = relationId(usageMap['customer']);
              final usageCount = toNonNegativeDouble(
                usageMap['usageCount'] ??
                    usageMap['count'] ??
                    usageMap['usedCount'] ??
                    usageMap['offerCount'],
              );
              offerCustomerUsage.add({
                'customerId': usageCustomerId,
                'usageCount': usageCount,
              });
              if (customerID != null && usageCustomerId == customerID) {
                customerUsageCount = usageCount;
              }
            }
          }

          final usageLimitReached =
              usageLimitEnabled && customerUsageCount >= maxUsagePerCustomer;
          final customerUsageRemaining = usageLimitEnabled
              ? (maxUsagePerCustomer - customerUsageCount)
                    .clamp(0, double.infinity)
                    .toDouble()
              : 0.0;
          final blockedByLimits =
              blockedWithoutCustomer ||
              blockedForNewCustomer ||
              globalLimitReached ||
              customerLimitReached ||
              usageLimitReached;
          final predictedAppliedUnits = usageLimitEnabled
              ? (quantityInCart < customerUsageRemaining
                    ? quantityInCart
                    : customerUsageRemaining)
              : quantityInCart;
          final predictedDiscountTotal =
              predictedAppliedUnits > 0 && discountPerUnit > 0
              ? double.parse(
                  (predictedAppliedUnits * discountPerUnit).toStringAsFixed(2),
                )
              : 0.0;
          final predictedSubtotal = double.parse(
            (baseUnitPrice * quantityInCart - predictedDiscountTotal)
                .clamp(0, double.infinity)
                .toStringAsFixed(2),
          );
          final predictedEffectiveUnitPrice = quantityInCart > 0
              ? double.parse(
                  (predictedSubtotal / quantityInCart).toStringAsFixed(4),
                )
              : baseUnitPrice;

          productPriceOfferMatches.add({
            'ruleKey':
                relationId(rule['id']) ??
                '$productId:${discountPerUnit.toStringAsFixed(2)}',
            'productId': productId,
            'productName': productName,
            'quantityInCart': quantityInCart,
            'baseUnitPrice': baseUnitPrice,
            'discountPerUnit': discountPerUnit,
            'offerUnitPrice': offerUnitPrice,
            'predictedAppliedUnits': predictedAppliedUnits,
            'predictedDiscountTotal': predictedDiscountTotal,
            'predictedSubtotal': predictedSubtotal,
            'predictedEffectiveUnitPrice': predictedEffectiveUnitPrice,
            'maxOfferCount': maxOfferCount,
            'offerGivenCount': offerGivenCount,
            'globalLimitReached': globalLimitReached,
            'globalRemaining': globalRemaining,
            'maxCustomerCount': maxCustomerCount,
            'offerCustomerCount': offerCustomerCount,
            'customerLimitReached': customerLimitReached,
            'customerRemaining': customerRemaining,
            'alreadyCountedForCustomer': alreadyCountedForCustomer,
            'maxUsagePerCustomer': maxUsagePerCustomer,
            'customerCountLimitEnabled': customerCountLimitEnabled,
            'requiresExistingCustomer': requiresExistingCustomer,
            'blockedForNewCustomer': blockedForNewCustomer,
            'blockedWithoutCustomer': blockedWithoutCustomer,
            'nextBillMessage': blockedForNewCustomer ? nextBillMessage : null,
            'usageLimitEnabled': usageLimitEnabled,
            'usageLimitReached': usageLimitReached,
            'customerUsageCount': customerUsageCount,
            'customerUsageRemaining': customerUsageRemaining,
            'offerCustomerUsage': offerCustomerUsage,
            'eligible':
                predictedAppliedUnits > 0 &&
                discountPerUnit > 0 &&
                !blockedByLimits,
            'allowOnBillings': ruleAllowOnBillings,
            'allowOnTableOrders': ruleAllowOnTableOrders,
          });
        }
      }

      final List<Map<String, dynamic>> randomCustomerOfferMatches = [];
      int enabledRandomCustomerOfferRules = 0;
      if (enableRandomCustomerProductOffer &&
          rawRandomCustomerOfferProducts is List) {
        for (final raw in rawRandomCustomerOfferProducts) {
          if (raw is! Map) continue;
          final rule = Map<String, dynamic>.from(raw);
          if (rule['enabled'] != true) continue;
          final ruleAllowOnBillings = toBoolWithDefault(
            rule['allowOnBillings'],
          );
          final ruleAllowOnTableOrders = toBoolWithDefault(
            rule['allowOnTableOrders'],
          );
          if (!allowForCurrentOrderType(
            allowOnBillings: ruleAllowOnBillings,
            allowOnTableOrders: ruleAllowOnTableOrders,
          )) {
            continue;
          }
          enabledRandomCustomerOfferRules += 1;

          final productRef = rule['product'];
          final productId = relationId(productRef);
          final productName = relationName(
            productRef,
            fallback: productId ?? 'Random Offer Product',
          );
          final winnerCount = toNonNegativeDouble(rule['winnerCount']);
          final redeemedCount = toNonNegativeDouble(rule['redeemedCount']);
          final assignedCount = toNonNegativeDouble(rule['assignedCount']);
          final remainingCount = (winnerCount - redeemedCount)
              .clamp(0, double.infinity)
              .toDouble();
          final ruleKey =
              relationId(rule['id']) ?? '$productId:${winnerCount.toInt()}';
          final maxUsagePerCustomer = toNonNegativeDouble(
            rule['maxUsagePerCustomer'],
          );
          final usageLimitEnabled = maxUsagePerCustomer > 0;
          final hasRandomChanceConfig =
              rule.containsKey('randomSelectionChancePercent') &&
              rule['randomSelectionChancePercent'] != null;
          final randomSelectionChancePercent = hasRandomChanceConfig
              ? toNonNegativeDouble(
                  rule['randomSelectionChancePercent'],
                ).clamp(0, 100).toDouble()
              : 100.0;

          double customerUsageCount = 0;
          final rawOfferCustomerUsage = rule['offerCustomerUsage'];
          if (rawOfferCustomerUsage is List) {
            for (final usageRaw in rawOfferCustomerUsage) {
              if (usageRaw is! Map) continue;
              final usageMap = Map<String, dynamic>.from(usageRaw);
              final usageCustomerId = relationId(usageMap['customer']);
              final usageCount = toNonNegativeDouble(
                usageMap['usageCount'] ??
                    usageMap['count'] ??
                    usageMap['usedCount'] ??
                    usageMap['offerCount'],
              );
              if (customerID != null && usageCustomerId == customerID) {
                customerUsageCount = usageCount;
              }
            }
          }

          final usageLimitReached =
              usageLimitEnabled && customerUsageCount >= maxUsagePerCustomer;
          final customerUsageRemaining = usageLimitEnabled
              ? (maxUsagePerCustomer - customerUsageCount)
                    .clamp(0, double.infinity)
                    .toDouble()
              : 0.0;

          final selectedCustomers = relationIds(rule['selectedCustomers']);
          final selectedForCustomer =
              customerID != null && selectedCustomers.contains(customerID);
          final scheduleMatched = isNowWithinSchedule(
            now: nowForRandomOfferPreview,
            availableFromDate: rule['availableFromDate'],
            availableToDate: rule['availableToDate'],
            dailyStartTime: rule['dailyStartTime'],
            dailyEndTime: rule['dailyEndTime'],
          );
          final randomSeed =
              '${lookupPhoneKey.isNotEmpty ? lookupPhoneKey : normalizedPhone}:${randomCustomerOfferCampaignCode.trim()}:$ruleKey:${effectiveIsTableOrder ? 'table' : 'billing'}';
          final randomChancePassed = deterministicChancePass(
            seed: randomSeed,
            chancePercent: randomSelectionChancePercent,
          );
          final eligible =
              remainingCount > 0 &&
              !usageLimitReached &&
              !alreadyRedeemedRandomOfferInCampaign &&
              scheduleMatched &&
              randomChancePassed;

          randomCustomerOfferMatches.add({
            'ruleKey': ruleKey,
            'productId': productId,
            'productName': productName,
            'winnerCount': winnerCount,
            'assignedCount': assignedCount,
            'redeemedCount': redeemedCount,
            'remainingCount': remainingCount,
            'maxUsagePerCustomer': maxUsagePerCustomer,
            'usageLimitEnabled': usageLimitEnabled,
            'usageLimitReached': usageLimitReached,
            'customerUsageCount': customerUsageCount,
            'customerUsageRemaining': customerUsageRemaining,
            'selectedForCustomer': selectedForCustomer,
            'availableFromDate': rule['availableFromDate'],
            'availableToDate': rule['availableToDate'],
            'dailyStartTime': rule['dailyStartTime']?.toString(),
            'dailyEndTime': rule['dailyEndTime']?.toString(),
            'randomSelectionChancePercent': randomSelectionChancePercent,
            'randomChancePassed': randomChancePassed,
            'scheduleMatched': scheduleMatched,
            'eligible': eligible,
            'allowOnBillings': ruleAllowOnBillings,
            'allowOnTableOrders': ruleAllowOnTableOrders,
          });
        }
      }

      final eligibleRandomCustomerOfferMatches = randomCustomerOfferMatches
          .where((match) => match['eligible'] == true)
          .toList();
      Map<String, dynamic>? selectedRandomCustomerOfferMatch;
      if (eligibleRandomCustomerOfferMatches.isNotEmpty) {
        final seed =
            '$lookupPhoneKey:${randomCustomerOfferCampaignCode.trim()}:random-preview';
        final index = deterministicIndex(
          seed,
          eligibleRandomCustomerOfferMatches.length,
        );
        if (index >= 0) {
          selectedRandomCustomerOfferMatch = Map<String, dynamic>.from(
            eligibleRandomCustomerOfferMatches[index],
          );
        }
      }
      final randomCustomerOfferEligible =
          selectedRandomCustomerOfferMatch != null;

      final completedBills =
          bills
              .where(
                (raw) =>
                    raw is Map &&
                    (raw['status']?.toString().toLowerCase() == 'completed'),
              )
              .toList()
            ..sort((a, b) {
              final aDate =
                  DateTime.tryParse(
                    (a is Map ? a['createdAt'] : null)?.toString() ?? '',
                  ) ??
                  DateTime.fromMillisecondsSinceEpoch(0);
              final bDate =
                  DateTime.tryParse(
                    (b is Map ? b['createdAt'] : null)?.toString() ?? '',
                  ) ??
                  DateTime.fromMillisecondsSinceEpoch(0);
              return aDate.compareTo(bDate);
            });

      final completedSpendAmount = completedBills.fold<double>(0.0, (sum, raw) {
        if (raw is! Map) return sum;
        final bill = Map<String, dynamic>.from(raw);
        return sum +
            toNonNegativeDouble(bill['grossAmount'] ?? bill['totalAmount']);
      });

      // History-based reward recompute from completed bills (to align legacy customers).
      double historyDerivedRewardPoints = 0;
      double historyDerivedProgressAmount = 0;
      if (offerEnabled && spendAmountPerStep > 0 && pointsPerStep > 0) {
        for (final raw in completedBills) {
          if (raw is! Map) continue;
          final bill = Map<String, dynamic>.from(raw);

          final grossAmount = toNonNegativeDouble(
            bill['grossAmount'] ?? bill['totalAmount'],
          );
          final offerDiscount = toNonNegativeDouble(
            bill['customerOfferDiscount'],
          );
          final offerWasApplied =
              bill['customerOfferApplied'] == true && offerDiscount > 0;

          if (offerWasApplied && resetOnRedeem) {
            historyDerivedRewardPoints = 0;
            historyDerivedProgressAmount = 0;
            continue;
          }

          final totalProgress = historyDerivedProgressAmount + grossAmount;
          final completedSteps = (totalProgress / spendAmountPerStep).floor();
          final earnedPoints = completedSteps * pointsPerStep;
          final consumedAmount = completedSteps * spendAmountPerStep;

          historyDerivedRewardPoints += earnedPoints;
          historyDerivedProgressAmount = double.parse(
            (totalProgress - consumedAmount)
                .clamp(0, double.infinity)
                .toStringAsFixed(2),
          );
        }
      }

      final historyBasedEligible =
          offerEnabled &&
          !isNewCustomer &&
          pointsNeededForOffer > 0 &&
          historyDerivedRewardPoints >= pointsNeededForOffer;

      // Keep customer lookup read-only. Backend decides and applies final offer.
      const historySyncAttempted = false;
      const historySyncFailed = false;
      const historySyncApplied = false;
      final historySnapshotAhead =
          historyDerivedRewardPoints > rewardPoints ||
          historyDerivedProgressAmount > rewardProgressAmount;
      final useHistorySnapshot = historySnapshotAhead;

      final effectiveRewardPoints = useHistorySnapshot
          ? historyDerivedRewardPoints
          : rewardPoints;
      final effectiveRewardProgressAmount = useHistorySnapshot
          ? historyDerivedProgressAmount
          : rewardProgressAmount;
      final effectiveOfferEligible =
          offerEnabled &&
          !isNewCustomer &&
          (historyBasedEligible ||
              (customerDoc['isOfferEligible'] == true) ||
              (pointsNeededForOffer > 0 &&
                  effectiveRewardPoints >= pointsNeededForOffer));

      final remainingPointsForOffer =
          pointsNeededForOffer > effectiveRewardPoints
          ? pointsNeededForOffer - effectiveRewardPoints
          : 0.0;

      double remainingSpendForOffer = 0;
      if (remainingPointsForOffer > 0 &&
          spendAmountPerStep > 0 &&
          pointsPerStep > 0) {
        final stepsNeeded = (remainingPointsForOffer / pointsPerStep).ceil();
        final progressRemainder =
            effectiveRewardProgressAmount % spendAmountPerStep;

        for (var step = 0; step < stepsNeeded; step++) {
          if (step == 0) {
            final neededForFirstStep = spendAmountPerStep - progressRemainder;
            remainingSpendForOffer += neededForFirstStep > 0
                ? neededForFirstStep
                : 0;
          } else {
            remainingSpendForOffer += spendAmountPerStep;
          }
        }
      }

      return {
        'orderType': effectiveIsTableOrder ? 'table' : 'billing',
        'name': customerName,
        'phoneNumber': normalizedPhone,
        'isNewCustomer': isNewCustomer,
        'totalBills': billData['totalDocs'] ?? bills.length,
        'totalAmount': totalAmount,
        'bigBill': bigBill,
        'favouriteProduct': favouriteProductName,
        'favouriteProductQty': favouriteProductQty,
        'favouriteProductAmount': favouriteProductTotal,
        'lastBillAmount': (lastBill?['totalAmount'] as num?)?.toDouble() ?? 0.0,
        'lastBillDate': lastBill?['createdAt'],
        'lastBranch': lastBranch,
        'bills': bills,
        'offer': {
          'enabled': offerEnabled,
          'allowOnBillings': allowCustomerCreditOfferOnBillings,
          'allowOnTableOrders': allowCustomerCreditOfferOnTableOrders,
          'rewardPoints': effectiveRewardPoints,
          'rewardProgressAmount': effectiveRewardProgressAmount,
          'pointsNeededForOffer': pointsNeededForOffer,
          'remainingPointsForOffer': remainingPointsForOffer,
          'offerAmount': offerAmount,
          'isOfferEligible': effectiveOfferEligible,
          'spendAmountPerStep': spendAmountPerStep,
          'pointsPerStep': pointsPerStep,
          'remainingSpendForOffer': remainingSpendForOffer,
          'completedBillsCount': completedBills.length,
          'completedSpendAmount': completedSpendAmount,
          'allBillsCount': bills.length,
          'allBillsSpendAmount': totalAmount,
          'historyDerivedRewardPoints': historyDerivedRewardPoints,
          'historyDerivedProgressAmount': historyDerivedProgressAmount,
          'historyBasedEligible': historyBasedEligible,
          'historySyncAttempted': historySyncAttempted,
          'historySyncFailed': historySyncFailed,
          'historySyncApplied': historySyncApplied,
          'totalOffersRedeemed': toNonNegativeDouble(
            customerDoc?['totalOffersRedeemed'],
          ).toInt(),
        },
        'productOfferPreview': {
          'enabled': enableProductToProductOffer,
          'allowOnBillings': allowProductToProductOfferOnBillings,
          'allowOnTableOrders': allowProductToProductOfferOnTableOrders,
          'rulesConfigured': enabledProductOfferRules,
          'matches': productOfferMatches,
        },
        'productPriceOfferPreview': {
          'enabled': enableProductPriceOffer,
          'allowOnBillings': allowProductPriceOfferOnBillings,
          'allowOnTableOrders': allowProductPriceOfferOnTableOrders,
          'rulesConfigured': enabledProductPriceOfferRules,
          'matches': productPriceOfferMatches,
        },
        'totalPercentageOfferPreview': {
          'enabled': enableTotalPercentageOffer,
          'allowOnBillings': allowTotalPercentageOfferOnBillings,
          'allowOnTableOrders': allowTotalPercentageOfferOnTableOrders,
          'discountPercent': totalPercentageOfferPercent,
          'timezone': totalPercentageOfferTimezone,
          'randomOnly': totalPercentageOfferRandomOnly,
          'randomSelectionChancePercent': totalPercentageOfferChancePercent,
          'randomGatePassed': totalPercentageOfferRandomGatePassed,
          'randomGateBlocked': totalPercentageOfferRandomGateBlocked,
          'availableFromDate': totalPercentageOfferAvailableFromDate,
          'availableToDate': totalPercentageOfferAvailableToDate,
          'dailyStartTime': totalPercentageOfferDailyStartTime?.toString(),
          'dailyEndTime': totalPercentageOfferDailyEndTime?.toString(),
          'scheduleMatched': totalPercentageOfferScheduleMatched,
          'scheduleBlocked': totalPercentageOfferScheduleBlocked,
          'maxOfferCount': totalPercentageOfferMaxOfferCount,
          'maxCustomerCount': totalPercentageOfferMaxCustomerCount,
          'maxUsagePerCustomer': totalPercentageOfferMaxUsagePerCustomer,
          'givenCount': totalPercentageOfferGivenCount,
          'customerCount': totalPercentageOfferCustomerCount,
          'globalRemaining': totalPercentageOfferGlobalRemaining,
          'customerRemaining': totalPercentageOfferCustomerRemaining,
          'usageForCustomer': totalPercentageOfferUsageForCustomer,
          'usageRemaining': totalPercentageOfferUsageRemaining,
          'requiresCustomer': totalPercentageOfferRequiresCustomer,
          'blockedWithoutCustomer': totalPercentageOfferBlockedWithoutCustomer,
          'globalLimitReached': totalPercentageOfferGlobalLimitReached,
          'customerLimitReached': totalPercentageOfferCustomerLimitReached,
          'usageLimitReached': totalPercentageOfferUsageLimitReached,
          'previewEligible': totalPercentageOfferPreviewEligible,
          'alreadyCountedForCustomer':
              totalPercentageOfferAlreadyCountedForCustomer,
          'customerUsageRows': totalPercentageOfferCustomerUsageRows,
          'finalValidationByServer': true,
        },
        'customerEntryPercentageOfferPreview': {
          'enabled': enableCustomerEntryPercentageOffer,
          'allowOnBillings': allowCustomerEntryPercentageOfferOnBillings,
          'allowOnTableOrders': allowCustomerEntryPercentageOfferOnTableOrders,
          'discountPercent': customerEntryPercentageOfferPercent,
          'timezone': customerEntryPercentageOfferTimezone,
          'availableFromDate': customerEntryPercentageOfferAvailableFromDate,
          'availableToDate': customerEntryPercentageOfferAvailableToDate,
          'dailyStartTime': customerEntryPercentageOfferDailyStartTime
              ?.toString(),
          'dailyEndTime': customerEntryPercentageOfferDailyEndTime?.toString(),
          'requiresCustomerEntry': true,
          'hasCustomerEntry': hasCustomerEntryForOffer,
          'scheduleMatched': customerEntryPercentageOfferScheduleMatched,
          'scheduleBlocked': customerEntryPercentageOfferScheduleBlocked,
          'previewEligible': customerEntryPercentageOfferPreviewEligible,
          'finalValidationByServer': true,
        },
        'randomCustomerOfferPreview': {
          'enabled': enableRandomCustomerProductOffer,
          'allowOnBillings': allowRandomCustomerProductOfferOnBillings,
          'allowOnTableOrders': allowRandomCustomerProductOfferOnTableOrders,
          'rulesConfigured': enabledRandomCustomerOfferRules,
          'campaignCode': randomCustomerOfferCampaignCode,
          'timezone': randomCustomerOfferTimezone,
          'alreadyRedeemedInCampaign': alreadyRedeemedRandomOfferInCampaign,
          'isEligible': randomCustomerOfferEligible,
          'matches': randomCustomerOfferMatches,
          'selectedMatch': selectedRandomCustomerOfferMatch,
          'finalValidationByServer': true,
        },
      };
    } catch (e) {
      debugPrint("Error fetching customer data: $e");
      rethrow;
    }
  }
}
