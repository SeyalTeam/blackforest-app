import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/cart_provider.dart';

class CustomerHistoryDialog extends StatefulWidget {
  final String phoneNumber;
  const CustomerHistoryDialog({super.key, required this.phoneNumber});

  @override
  State<CustomerHistoryDialog> createState() => _CustomerHistoryDialogState();
}

class _CustomerHistoryDialogState extends State<CustomerHistoryDialog> {
  bool _isLoading = true;
  List<dynamic> _bills = [];
  double _overallTotal = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchHistory();
  }

  Future<void> _fetchHistory() async {
    try {
      final cartProvider = Provider.of<CartProvider>(context, listen: false);
      final data = await cartProvider.fetchCustomerData(widget.phoneNumber);
      if (mounted) {
        setState(() {
          _bills = data?['bills'] ?? [];
          _overallTotal = (data?['totalAmount'] as num?)?.toDouble() ?? 0.0;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1E1E1E),
      insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.95,
        height: MediaQuery.of(context).size.height * 0.9,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "Customer History",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const Divider(color: Colors.white24),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    )
                  : _bills.isEmpty
                  ? const Center(
                      child: Text(
                        "No history found",
                        style: TextStyle(color: Colors.white70),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _bills.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 20),
                      itemBuilder: (context, index) {
                        return Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 400),
                            child: Card(
                              color: Colors.white,
                              elevation: 4,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: ReceiptContent(bill: _bills[index]),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (!_isLoading && _bills.isNotEmpty) ...[
              const Divider(color: Colors.white24, height: 32),
              Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 8,
                  horizontal: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.green.withOpacity(0.2)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "Overall Total Spent",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      "₹${_overallTotal.toStringAsFixed(2)}",
                      style: const TextStyle(
                        color: Colors.green,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class ReceiptContent extends StatefulWidget {
  final dynamic bill;
  const ReceiptContent({super.key, required this.bill});

  @override
  State<ReceiptContent> createState() => _ReceiptContentState();
}

class _ReceiptContentState extends State<ReceiptContent> {
  Map<String, dynamic>? _reviewData;
  bool _isLoadingReview = true;

  @override
  void initState() {
    super.initState();
    _fetchReview();
  }

  Future<void> _fetchReview() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      final billId = widget.bill['id'];

      final res = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/reviews?where[bill][equals]=$billId&limit=1',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['docs'] != null && data['docs'].isNotEmpty) {
          if (mounted) setState(() => _reviewData = data['docs'][0]);
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _isLoadingReview = false);
  }

  @override
  Widget build(BuildContext context) {
    final bill = widget.bill;
    final items = bill['items'] as List? ?? [];
    final date = DateTime.parse(bill['createdAt']).toLocal();
    final formattedDate =
        "${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year.toString().substring(2)}";
    final formattedTime =
        "${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}";

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            "BlackForest Cakes",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
          ),
          const Text(
            "VSeyal",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.black54),
          ),
          const SizedBox(height: 12),
          const Text(
            "----------------------------------------------------------------",
            textAlign: TextAlign.center,
            overflow: TextOverflow.clip,
            style: TextStyle(color: Colors.black26),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            runSpacing: 4,
            spacing: 8,
            children: [
              Text(
                "Bill No: ${bill['kotNumber']?.split('-KOT')[0] ?? bill['kotNumber'] ?? bill['invoiceNumber']?.split('-')?.last ?? bill['invoiceNumber']}",
                style: const TextStyle(
                  color: Colors.black87,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                "Date: $formattedDate",
                style: const TextStyle(color: Colors.black87, fontSize: 13),
              ),
              Text(
                "Time: $formattedTime",
                style: const TextStyle(color: Colors.black87, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Assigned By: ${bill['createdBy']?['name'] ?? 'N/A'}",
                style: const TextStyle(color: Colors.black87, fontSize: 13),
              ),
              Text(
                "Pay Mode: ${(bill['paymentMethod'] ?? 'N/A').toString().toUpperCase()}",
                style: const TextStyle(color: Colors.black87, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Customer: ${bill['customerDetails']?['name'] ?? 'N/A'}",
                style: const TextStyle(color: Colors.black87, fontSize: 13),
              ),
              Text(
                "Ph: ${bill['customerDetails']?['phoneNumber'] ?? 'N/A'}",
                style: const TextStyle(color: Colors.black87, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Item",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: Colors.black,
                ),
              ),
              Row(
                children: [
                  SizedBox(
                    width: 40,
                    child: Text(
                      "Qty",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: Colors.black,
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                  SizedBox(
                    width: 60,
                    child: Text(
                      "Amt",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: Colors.black,
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const Text(
            "---------------------------------------------------------------",
            textAlign: TextAlign.center,
            overflow: TextOverflow.clip,
            style: TextStyle(color: Colors.black26),
          ),
          ...items.map((item) {
            final productId = (item['product'] is Map)
                ? item['product']['id']
                : item['product'];
            Map<String, dynamic>? reviewItem;
            if (_reviewData != null && _reviewData!['items'] != null) {
              reviewItem = (_reviewData!['items'] as List).firstWhere(
                (ri) =>
                    ((ri['product'] is Map)
                        ? ri['product']['id']
                        : ri['product']) ==
                    productId,
                orElse: () => null,
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          item['name'].toString().toUpperCase(),
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          SizedBox(
                            width: 50,
                            child: Text(
                              "${item['quantity']} x ${item['unitPrice']}",
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.black87,
                              ),
                              textAlign: TextAlign.right,
                            ),
                          ),
                          SizedBox(
                            width: 60,
                            child: Text(
                              (item['subtotal'] as num).toStringAsFixed(2),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: Colors.black,
                              ),
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (_isLoadingReview)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: SizedBox(
                      height: 10,
                      width: 10,
                      child: CircularProgressIndicator(strokeWidth: 1),
                    ),
                  ),
                if (reviewItem != null && reviewItem['rating'] != null) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4, top: 4),
                    child: Text(
                      "Thanks For Your Rating: ${"★" * (reviewItem['rating'] as int)}${"☆" * (5 - (reviewItem['rating'] as int))}",
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (reviewItem['feedback'] != null &&
                      reviewItem['feedback'].toString().isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.grey.shade100),
                      ),
                      child: Text(
                        reviewItem['feedback'],
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade700,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                ],
                const Divider(height: 1, color: Colors.black12),
              ],
            );
          }),
          const SizedBox(height: 12),
          const Text(
            "----------------------------------------------------------------",
            textAlign: TextAlign.center,
            overflow: TextOverflow.clip,
            style: TextStyle(color: Colors.black26),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Total Items:",
                style: TextStyle(fontSize: 14, color: Colors.black54),
              ),
              Text(
                "${items.length}",
                style: const TextStyle(fontSize: 14, color: Colors.black),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Grand Total:",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
              Text(
                (bill['totalAmount'] as num).toStringAsFixed(2),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
