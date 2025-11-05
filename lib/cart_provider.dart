import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class CartItem {
  final String id;
  final String name;
  final double price;
  final String? imageUrl;
  final int quantity;

  CartItem({
    required this.id,
    required this.name,
    required this.price,
    this.imageUrl,
    required this.quantity,
  });

  factory CartItem.fromProduct(dynamic product, int quantity, {double? branchPrice}) {
    String? imageUrl;
    if (product['images'] != null &&
        product['images'].isNotEmpty &&
        product['images'][0]['image'] != null &&
        product['images'][0]['image']['url'] != null) {
      imageUrl = product['images'][0]['image']['url'];
      if (imageUrl != null && imageUrl.startsWith('/')) {
        imageUrl = 'https://admin.theblackforestcakes.com$imageUrl';
      }
    }
    double price =
        branchPrice ?? (product['defaultPriceDetails']?['price']?.toDouble() ?? 0.0);
    return CartItem(
      id: product['id'],
      name: product['name'] ?? 'Unknown',
      price: price,
      imageUrl: imageUrl,
      quantity: quantity,
    );
  }
}

class CartProvider extends ChangeNotifier {
  List<CartItem> _cartItems = [];
  String? _branchId;
  String? _printerIp;
  int _printerPort = 9100;
  String? _printerProtocol = 'esc_pos';

  List<CartItem> get cartItems => _cartItems;
  double get total =>
      _cartItems.fold(0.0, (sum, item) => sum + (item.price * item.quantity));
  String? get printerIp => _printerIp;
  int get printerPort => _printerPort;
  String? get printerProtocol => _printerProtocol;

  void addOrUpdateItem(CartItem item) {
    final index = _cartItems.indexWhere((i) => i.id == item.id);
    if (index != -1) {
      _cartItems[index] = CartItem(
        id: item.id,
        name: item.name,
        price: item.price,
        imageUrl: item.imageUrl,
        quantity: _cartItems[index].quantity + item.quantity,
      );
    } else {
      _cartItems.add(item);
    }
    notifyListeners();
  }

  void updateQuantity(String id, int newQuantity) {
    final index = _cartItems.indexWhere((i) => i.id == id);
    if (index != -1 && newQuantity > 0) {
      _cartItems[index] = CartItem(
        id: _cartItems[index].id,
        name: _cartItems[index].name,
        price: _cartItems[index].price,
        imageUrl: _cartItems[index].imageUrl,
        quantity: newQuantity,
      );
      notifyListeners();
    } else if (newQuantity <= 0) {
      removeItem(id);
    }
  }

  void removeItem(String id) {
    _cartItems.removeWhere((i) => i.id == id);
    notifyListeners();
  }

  void clearCart() {
    _cartItems.clear();
    notifyListeners();
  }

  void setBranchId(String? branchId) {
    _branchId = branchId;
  }

  void setPrinterDetails(String? printerIp, int? printerPort, String? printerProtocol) {
    _printerIp = printerIp;
    if (printerPort != null) _printerPort = printerPort;
    if (printerProtocol != null && printerProtocol.isNotEmpty) {
      _printerProtocol = printerProtocol;
    }
    notifyListeners();
  }

  /// 🧾 Submits billing and returns the generated invoice number
  Future<String?> submitBilling(BuildContext context) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) throw Exception('No token found. Please login again.');

      final items = _cartItems.map((item) => {
        'product': item.id,
        'quantity': item.quantity,
        'price': item.price,
      }).toList();

      final body = jsonEncode({
        'branch': _branchId,
        'items': items,
        'totalAmount': total,
      });

      final response = await http.post(
        Uri.parse('https://admin.theblackforestcakes.com/api/billings'),
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
          SnackBar(content: Text('✅ Billing Successful — Invoice: $invoiceNumber')),
        );

        return invoiceNumber;
      } else {
        throw Exception('Failed to submit billing: ${response.body}');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error submitting billing: $e')),
      );
      return null;
    }
  }
}
