import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:blackforest_app/cart_provider.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class CustomerSearchPage extends StatefulWidget {
  const CustomerSearchPage({super.key});

  @override
  State<CustomerSearchPage> createState() => _CustomerSearchPageState();
}

class _CustomerSearchPageState extends State<CustomerSearchPage> {
  final TextEditingController _phoneController = TextEditingController();
  bool _isLoading = false;
  Map<String, dynamic>? _customerData;
  String? _error;

  Future<void> _searchCustomer() async {
    final phone = _phoneController.text.trim();
    if (phone.isEmpty) {
      setState(() => _error = 'Please enter a phone number');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _customerData = null;
    });

    try {
      final cartProvider = Provider.of<CartProvider>(context, listen: false);
      final data = await cartProvider.fetchCustomerData(phone);
      setState(() {
        if (data == null) {
          _error = 'Customer not found';
        } else {
          _customerData = data;
        }
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Customer Search',
      pageType: PageType.home, // Reuse home page type for highlighting in nav
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Search Customer by Phone',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _phoneController,
                    decoration: InputDecoration(
                      labelText: 'Phone Number',
                      hintText: 'e.g. 9876543210',
                      prefixIcon: const Icon(Icons.phone),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      filled: true,
                      fillColor: Colors.grey.shade50,
                    ),
                    keyboardType: TextInputType.phone,
                    onSubmitted: (_) => _searchCustomer(),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  height: 56,
                  width: 56,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _searchCustomer,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.search),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
            if (_customerData != null) ...[
              const SizedBox(height: 30),
              _buildCustomerCard(),
              const SizedBox(height: 30),
              const Text(
                'Recent Bills',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 15),
              _buildBillList(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCustomerCard() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.grey.withOpacity(0.1),
                spreadRadius: 2,
                blurRadius: 15,
                offset: const Offset(0, 5),
              ),
            ],
            border: Border.all(color: Colors.grey.shade100),
          ),
          child: Column(
            children: [
              CircleAvatar(
                radius: 40,
                backgroundColor: Colors.blue.shade50,
                child: const Icon(Icons.person, size: 50, color: Colors.blue),
              ),
              const SizedBox(height: 15),
              Text(
                _customerData!['name'],
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              Text(
                _customerData!['phoneNumber'],
                style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
              ),
              const Divider(height: 40),
              _buildMetricGrid(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMetricGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _buildMetricItem(
                    'Total Bills',
                    _customerData!['totalBills'].toString(),
                    Icons.shopping_bag_outlined,
                    Colors.orange,
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: _buildMetricItem(
                    'Total Amount',
                    '₹${_customerData!['totalAmount'].toStringAsFixed(2)}',
                    Icons.account_balance_wallet_outlined,
                    Colors.green,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 15),
            Row(
              children: [
                Expanded(
                  child: _buildMetricItem(
                    'Last Bill Amount',
                    '₹${_customerData!['lastBillAmount'].toStringAsFixed(2)}',
                    Icons.history,
                    Colors.blue,
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: _buildMetricItem(
                    'Last Bill Date',
                    _formatDate(_customerData!['lastBillDate']),
                    Icons.calendar_today,
                    Colors.purple,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 15),
            Row(
              children: [
                Expanded(
                  child: _buildMetricItem(
                    'Big Bill',
                    '₹${_customerData!['bigBill'].toStringAsFixed(2)}',
                    Icons.star_outline,
                    Colors.red,
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: _buildMetricItem(
                    'Last Branch',
                    _customerData!['lastBranch'],
                    Icons.storefront,
                    Colors.teal,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 15),
            Row(
              children: [
                Expanded(
                  child: _buildMetricItem(
                    'Favourite',
                    _customerData!['favouriteProduct'],
                    Icons.favorite_border,
                    Colors.pink,
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: _buildMetricItem(
                    'Fav spent',
                    '₹${_customerData!['favouriteProductAmount'].toStringAsFixed(2)} (${_customerData!['favouriteProductQty']})',
                    Icons.shopping_cart_outlined,
                    Colors.pink,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null) return 'N/A';
    try {
      final date = DateTime.parse(dateStr);
      return "${date.day}/${date.month}/${date.year}";
    } catch (e) {
      return dateStr.split('T')[0];
    }
  }

  Widget _buildMetricItem(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: color.withOpacity(0.05),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: color.withOpacity(0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 10),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _buildBillList() {
    final List bills = _customerData!['bills'] ?? [];
    final double bigBillAmount = _customerData!['bigBill'] ?? 0.0;

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: bills.length,
      itemBuilder: (context, index) {
        final bill = bills[index];
        final double amount = (bill['totalAmount'] as num?)?.toDouble() ?? 0.0;
        final bool isBigBill = amount == bigBillAmount && amount > 0;
        final String date = _formatDate(bill['createdAt']);
        final String branch = bill['branch']?['name'] ?? 'N/A';

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: isBigBill ? Colors.red.shade50 : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isBigBill ? Colors.red.shade200 : Colors.grey.shade200,
            ),
          ),
          child: ListTile(
            onTap: () => _showBillDetail(bill),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
            leading: CircleAvatar(
              backgroundColor: isBigBill
                  ? Colors.red.shade100
                  : Colors.blue.shade50,
              child: Icon(
                isBigBill ? Icons.star : Icons.receipt_long,
                color: isBigBill ? Colors.red : Colors.blue,
              ),
            ),
            title: Row(
              children: [
                Text(
                  '₹${amount.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                    color: isBigBill ? Colors.red.shade900 : Colors.black87,
                  ),
                ),
                if (isBigBill) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'BIG BILL',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text('Date: $date'),
                Text('Branch: $branch'),
              ],
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
          ),
        );
      },
    );
  }

  Future<void> _showBillDetail(Map<String, dynamic> bill) async {
    // Determine the waiter name, fetching it if it's just an ID
    final waiter = bill['createdBy'];
    String? finalWaiterName;

    if (waiter is Map) {
      final name = waiter['name'] ?? waiter['email'];
      final employee = waiter['employee'];
      final employeeName = (employee is Map) ? employee['name'] : null;
      finalWaiterName = (name ?? employeeName ?? 'Unknown').toString();
    } else if (waiter is String) {
      finalWaiterName = await _fetchWaiterName(waiter);
    } else {
      finalWaiterName = 'N/A';
    }

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        final items = bill['items'] as List? ?? [];
        final branch = bill['branch'];
        final branchName = (branch is Map) ? branch['name'] ?? 'N/A' : 'N/A';
        final waiterName = finalWaiterName!;
        final paymentMethod = (bill['paymentMethod'] as String? ?? 'N/A')
            .toUpperCase();
        final invoiceNumber = bill['invoiceNumber'] ?? 'N/A';
        final totalAmount = (bill['totalAmount'] as num?)?.toDouble() ?? 0.0;
        final date = DateTime.parse(bill['createdAt']).toLocal();
        final formattedDate =
            "${_getMonth(date.month)} ${date.day}, ${date.year}";
        final formattedTime =
            "${date.hour % 12 == 0 ? 12 : date.hour % 12}:${date.minute.toString().padLeft(2, '0')} ${date.hour >= 12 ? 'PM' : 'AM'}";

        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          backgroundColor: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
                const Icon(Icons.receipt_long, size: 40, color: Colors.blue),
                const SizedBox(height: 10),
                const Text(
                  'BlackForest Cakes',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                Text(
                  branchName,
                  style: const TextStyle(fontSize: 16, color: Colors.grey),
                ),
                const SizedBox(height: 15),
                const Divider(),
                const SizedBox(height: 10),
                Text(
                  'Invoice: $invoiceNumber',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text('$formattedDate - $formattedTime'),
                const SizedBox(height: 15),
                const Divider(),
                const SizedBox(height: 10),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        ...items.map((item) {
                          final name = item['name'] ?? 'Unknown';
                          final qty = item['quantity'] ?? 0;
                          final price = item['unitPrice'] ?? 0;
                          final subtotal = item['subtotal'] ?? 0;
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Text(
                                    name.toUpperCase(),
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                Text(
                                  '$qty x $price = $subtotal',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
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
                const SizedBox(height: 15),
                const Divider(),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Payment'),
                    Text(
                      paymentMethod,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Waiter'),
                    Text(
                      waiterName.toUpperCase(),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 15),
                const Divider(thickness: 2),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Total Amount',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '₹${totalAmount.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.green,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 25),
                const Text(
                  'Thank you for visiting!',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                const Text(
                  'Powered by VSeyal POS',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _getMonth(int month) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return months[month - 1];
  }

  Future<String> _fetchWaiterName(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) return userId;

      final response = await http.get(
        Uri.parse('https://blackforest.vseyal.com/api/users/$userId?depth=2'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final user = jsonDecode(response.body);
        final name = user['name'] ?? user['email'];
        final employee = user['employee'];
        final employeeName = (employee is Map) ? employee['name'] : null;
        return (name ?? employeeName ?? userId).toString();
      }
    } catch (e) {
      debugPrint("Error fetching waiter name: $e");
    }
    return userId;
  }
}
