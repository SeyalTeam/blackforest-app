import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/cart_provider.dart';
import 'package:blackforest_app/cart_page.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class KotBillsPage extends StatefulWidget {
  const KotBillsPage({super.key});

  @override
  State<KotBillsPage> createState() => _KotBillsPageState();
}

class _KotBillsPageState extends State<KotBillsPage> {
  List<dynamic> _pendingBills = [];
  bool _isLoading = true;
  String? _errorMessage;
  String? _expandedBillId;

  @override
  void initState() {
    super.initState();
    _fetchPendingBills();
  }

  Future<void> _fetchPendingBills() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      final userId = prefs.getString('user_id');
      final branchId = prefs.getString('branchId');

      if (token == null || userId == null) {
        setState(() {
          _errorMessage = "Authentication error. Please login again.";
          _isLoading = false;
        });
        return;
      }

      // Filter by status=pending AND createdBy=userId AND branch=branchId
      // AND createdAt >= start of today
      final now = DateTime.now();
      final todayStart = DateTime(
        now.year,
        now.month,
        now.day,
      ).toIso8601String();

      String urlString =
          'https://blackforest.vseyal.com/api/billings?where[status][in]=pending,ordered&where[createdBy][equals]=$userId&where[createdAt][greater_than_equal]=$todayStart&limit=100&sort=-createdAt&depth=3';

      if (branchId != null) {
        urlString += '&where[branch][equals]=$branchId';
      }

      final url = Uri.parse(urlString);

      final response = await http.get(
        url,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _pendingBills = data['docs'] ?? [];
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = "Failed to fetch bills: ${response.statusCode}";
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = "Network error: Check your internet";
        _isLoading = false;
      });
    }
  }

  Future<void> _loadBillIntoCart(Map<String, dynamic> bill) async {
    final cartProvider = Provider.of<CartProvider>(context, listen: false);

    // --- Kitchen Selection Logic ---
    String? selectedKitchenId;
    String? selectedKitchenName;

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      final branchId = prefs.getString('branchId');

      if (token != null && branchId != null) {
        // Show loading
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) =>
              const Center(child: CircularProgressIndicator()),
        );

        final response = await http.get(
          Uri.parse(
            'https://blackforest.vseyal.com/api/kitchens?where[branches][contains]=$branchId&limit=100',
          ),
          headers: {'Authorization': 'Bearer $token'},
        );

        if (mounted) Navigator.pop(context); // pop loading

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final List<dynamic> kitchens = data['docs'] ?? [];

          if (kitchens.isNotEmpty) {
            if (kitchens.length == 1) {
              selectedKitchenId = kitchens[0]['id'].toString();
              selectedKitchenName = kitchens[0]['name'].toString();
            } else {
              final selected = await showDialog<dynamic>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Select Kitchen'),
                  content: SizedBox(
                    width: double.maxFinite,
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: kitchens.length,
                      itemBuilder: (context, index) {
                        final kitchen = kitchens[index];
                        return ListTile(
                          title: Text(kitchen['name'] ?? 'Unknown'),
                          onTap: () => Navigator.pop(context, kitchen),
                        );
                      },
                    ),
                  ),
                ),
              );

              if (selected != null) {
                selectedKitchenId = selected['id'].toString();
                selectedKitchenName = selected['name'].toString();
              } else {
                return; // User cancelled
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint("Error fetching kitchens: $e");
    }

    // Maps billing items to CartItems
    List<CartItem> recalledItems = (bill['items'] as List)
        .where((item) => item['status']?.toString() != 'cancelled')
        .map((item) {
          double toSafeDouble(dynamic value) {
            if (value is num) return value.toDouble();
            if (value is String) return double.tryParse(value) ?? 0.0;
            return 0.0;
          }

          final itemMap = item is Map
              ? Map<String, dynamic>.from(item)
              : <String, dynamic>{};
          final prod = item['product'];
          String? cid;
          final String pid = (prod is Map)
              ? (prod['id'] ?? prod['_id'] ?? prod[r'$oid']).toString()
              : prod.toString();

          final cat = prod['category'];
          cid = (cat is Map)
              ? (cat['id'] ?? cat['_id'] ?? cat[r'$oid']).toString()
              : cat.toString();
          String? imageUrl;
          String? dept;
          if (prod is Map) {
            if (prod['images'] != null && (prod['images'] as List).isNotEmpty) {
              final img = prod['images'][0]['image'];
              if (img != null && img['url'] != null) {
                imageUrl = img['url'];
                if (imageUrl != null && imageUrl.startsWith('/')) {
                  imageUrl = 'https://blackforest.vseyal.com$imageUrl';
                }
              }
            }

            // Get department
            if (prod['department'] != null) {
              dept = (prod['department'] is Map)
                  ? prod['department']['name']?.toString()
                  : prod['department'].toString();
            } else if (prod['category'] != null &&
                prod['category'] is Map &&
                prod['category']['department'] != null) {
              var catDept = prod['category']['department'];
              dept = (catDept is Map)
                  ? catDept['name']?.toString()
                  : catDept.toString();
            }
          }

          final isOfferFreeItem = itemMap['isOfferFreeItem'] == true;
          final notesValue = (itemMap['notes'] ?? itemMap['specialNote'] ?? '')
              .toString()
              .trim();
          final isRandomCustomerOfferItem =
              itemMap['isRandomCustomerOfferItem'] == true ||
              notesValue.toUpperCase() == 'RANDOM CUSTOMER OFFER';
          final isReadOnlyOfferItem =
              isOfferFreeItem || isRandomCustomerOfferItem;
          final hasEffectiveUnitPrice = itemMap.containsKey(
            'effectiveUnitPrice',
          );
          final effectiveUnitPrice = hasEffectiveUnitPrice
              ? (isReadOnlyOfferItem
                    ? 0.0
                    : toSafeDouble(itemMap['effectiveUnitPrice']))
              : null;
          final hasSubtotal = itemMap.containsKey('subtotal');
          final lineSubtotal = isRandomCustomerOfferItem
              ? 0.0
              : hasSubtotal
              ? toSafeDouble(itemMap['subtotal'])
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
            categoryId: cid, // Needed for KOT printer routing
            specialNote: item['specialNote'] ?? item['note'] ?? item['notes'],
            status: item['status']?.toString(), // Preserve status
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

    final customer = bill['customerDetails'] ?? {};
    final tableDetails = bill['tableDetails'] ?? {};
    cartProvider.loadKOTItems(
      recalledItems,
      billId: bill['id'],
      cName: customer['name'],
      cPhone: customer['phoneNumber'],
      tName: tableDetails['tableNumber']?.toString(),
      tSection: tableDetails['section']?.toString(),
      kitchenId: selectedKitchenId,
      kitchenName: selectedKitchenName,
    );

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const CartPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'KOT BILLS',
      pageType: PageType.billsheet,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.black))
          : _errorMessage != null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.red),
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton(
                    onPressed: _fetchPendingBills,
                    child: const Text("Retry"),
                  ),
                ],
              ),
            )
          : _pendingBills.isEmpty
          ? const Center(child: Text("No pending KOTs found."))
          : RefreshIndicator(
              onRefresh: _fetchPendingBills,
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: (_pendingBills.length / 4).ceil(),
                itemBuilder: (context, rowIndex) {
                  final startIndex = rowIndex * 4;
                  final endIndex = (startIndex + 4 < _pendingBills.length)
                      ? startIndex + 4
                      : _pendingBills.length;
                  final rowBills = _pendingBills.sublist(startIndex, endIndex);

                  // Check if any bill in this row is expanded
                  Map<String, dynamic>? expandedBill;
                  for (final bill in rowBills) {
                    final id = bill['id'] ?? bill['_id'] ?? bill[r'$oid'];
                    if (id.toString() == _expandedBillId) {
                      expandedBill = bill;
                      break;
                    }
                  }

                  return Column(
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (int i = 0; i < 4; i++)
                            if (i < rowBills.length)
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                    right: 12, // Gap between items
                                    bottom:
                                        12, // Gap between rows (if no expansion)
                                  ),
                                  child: _buildKotToken(rowBills[i]),
                                ),
                              )
                            else
                              const Expanded(
                                child: SizedBox(),
                              ), // Spacer for empty slots
                        ],
                      ),
                      if (expandedBill != null)
                        Container(
                          margin: const EdgeInsets.only(bottom: 20),
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            border: Border.all(color: Colors.black12),
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: _buildBillReceiptPanel(expandedBill),
                        ),
                    ],
                  );
                },
              ),
            ),
    );
  }

  Widget _buildKotToken(Map<String, dynamic> bill) {
    String invoiceNumber = bill['invoiceNumber'] ?? 'N/A';
    String kotDigits = 'N/A';
    if (invoiceNumber.contains('-')) {
      String lastPart = invoiceNumber.split('-').last;
      kotDigits = lastPart.replaceAll('KOT', '');
    }

    final id = bill['id'] ?? bill['_id'] ?? bill[r'$oid'];
    final bool isExpanded = id.toString() == _expandedBillId;

    return GestureDetector(
      onTap: () {
        setState(() {
          if (isExpanded) {
            _expandedBillId = null;
          } else {
            _expandedBillId = id.toString();
          }
        });
      },
      child: Container(
        height:
            (MediaQuery.of(context).size.width - 32 - (12 * 3)) /
            4, // Approx aspect ratio 1
        decoration: BoxDecoration(
          color: isExpanded ? Colors.grey[900] : Colors.black,
          borderRadius: BorderRadius.circular(12),
          border: isExpanded ? Border.all(color: Colors.white, width: 2) : null,
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'KOT',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 14,
                fontWeight: FontWeight.normal,
              ),
            ),
            Text(
              kotDigits,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBillReceiptPanel(Map<String, dynamic> bill) {
    String invoiceNumber = bill['invoiceNumber'] ?? 'N/A';
    String kotDigits = 'N/A';
    if (invoiceNumber.contains('-')) {
      String lastPart = invoiceNumber.split('-').last;
      kotDigits = lastPart.replaceAll('KOT', '');
    }

    final tableDetails = bill['tableDetails'] ?? {};
    final tableName = tableDetails['tableNumber']?.toString() ?? 'N/A';
    final section = tableDetails['section']?.toString() ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'KOT BILL',
            style: TextStyle(
              color: Colors.black,
              fontSize: 18,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'KOT: $kotDigits | Table: $tableName',
            style: const TextStyle(
              color: Colors.black87,
              fontSize: 14,
              fontFamily: 'monospace',
            ),
          ),
          if (section.isNotEmpty)
            Text(
              'Section: $section',
              style: const TextStyle(
                color: Colors.black87,
                fontSize: 14,
                fontFamily: 'monospace',
              ),
            ),
          const SizedBox(height: 12),
          const Text(
            '--------------------------------',
            style: TextStyle(color: Colors.black26),
          ),
          const SizedBox(height: 8),
          Column(
            children: (bill['items'] as List).map((item) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        item['name'] ?? 'Unknown',
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'x${(item['quantity'] ?? 0).toString()}',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          const Text(
            '--------------------------------',
            style: TextStyle(color: Colors.black26),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                _loadBillIntoCart(bill);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              child: const Text('LOAD INTO CART'),
            ),
          ),
        ],
      ),
    );
  }
}
