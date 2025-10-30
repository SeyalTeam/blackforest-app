// lib/return_provider.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ReturnItem {
  final String id;
  final String name;
  final double price;
  final int quantity;
  final double subtotal;

  ReturnItem({
    required this.id,
    required this.name,
    required this.price,
    required this.quantity,
  }) : subtotal = price * quantity;
}

class ReturnProvider with ChangeNotifier {
  List<ReturnItem> _items = [];

  List<ReturnItem> get returnItems => List.unmodifiable(_items);

  double get total => _items.fold(0.0, (sum, item) => sum + item.subtotal);

  void addOrUpdateItem(String id, String name, int quantity, double price) {
    if (quantity <= 0) {
      removeItem(id);
      return;
    }

    final index = _items.indexWhere((item) => item.id == id);
    if (index != -1) {
      _items[index] = ReturnItem(id: id, name: name, price: price, quantity: quantity);
    } else {
      _items.add(ReturnItem(id: id, name: name, price: price, quantity: quantity));
    }
    notifyListeners();
  }

  void removeItem(String id) {
    _items.removeWhere((item) => item.id == id);
    notifyListeners();
  }

  void clearReturns() {
    _items.clear();
    notifyListeners();
  }

  Future<void> submitReturn(BuildContext context, String? branchId) async {
    if (_items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No items selected for return')),
      );
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No token found. Please login again.')),
        );
        return;
      }

      final returnData = {
        'items': _items
            .map((item) => {
          'product': item.id,
          'name': item.name,
          'quantity': item.quantity,
          'unitPrice': item.price,
          'subtotal': item.subtotal,
        })
            .toList(),
        'totalAmount': total,
        'branch': branchId,
        'status': 'returned',
        'notes': '',
      };

      final response = await http.post(
        Uri.parse('https://admin.theblackforestcakes.com/api/return-orders'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode(returnData),
      );

      if (response.statusCode == 201) {
        clearReturns();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Return order submitted successfully')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to submit return order: ${response.statusCode}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error: Check your internet')),
      );
    }
  }
}