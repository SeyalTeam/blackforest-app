import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:provider/provider.dart';
import 'package:blackforest_app/cart_provider.dart';
import 'package:blackforest_app/categories_page.dart';
import 'package:blackforest_app/cart_page.dart';
import 'package:blackforest_app/customer_history_dialog.dart';

class TablePage extends StatefulWidget {
  const TablePage({super.key});

  @override
  State<TablePage> createState() => _TablePageState();
}

class _TablePageState extends State<TablePage> {
  List<dynamic> _tables = [];
  bool _isLoading = true;
  String? _errorMessage;
  String? _branchId;
  String? _token;
  final Map<String, dynamic> _pendingBillsByTableKey = {};
  bool _isHandlingTableTap = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          // Trigger rebuild to update times
        });
      }
    });
  }

  Future<void> _loadInitialData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _token = prefs.getString('token');
      _branchId = prefs.getString('branchId');
    });

    if (_token != null && _branchId != null) {
      _fetchTables();
      _fetchPendingBills();
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Session expired or Branch ID not found.';
      });
    }
  }

  Future<void> _fetchTables() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/tables?where[branch][equals]=$_branchId&limit=1&depth=1',
        ),
        headers: {'Authorization': 'Bearer $_token'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> allDocs = data['docs'] ?? [];
        final dynamic branchDoc = allDocs.isNotEmpty ? allDocs.first : null;

        setState(() {
          if (branchDoc != null) {
            _tables = branchDoc['sections'] ?? [];
          } else {
            _tables = [];
          }
          _isLoading = false;
        });
      } else {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to fetch tables: ${response.statusCode}';
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Network error. Please try again.';
      });
    }
  }

  Future<void> _fetchPendingBills() async {
    if (_token == null || _branchId == null) return;

    try {
      final now = DateTime.now();
      final todayStart = DateTime(
        now.year,
        now.month,
        now.day,
      ).toIso8601String();

      final url = Uri.parse(
        'https://blackforest.vseyal.com/api/billings?where[status][in]=pending,ordered&where[branch][equals]=$_branchId&where[createdAt][greater_than_equal]=$todayStart&limit=100&depth=3',
      );

      final response = await http.get(
        url,
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final docs = List<dynamic>.from(data['docs'] ?? []);
        final nextByTableKey = <String, dynamic>{};
        for (final bill in docs) {
          final details = bill['tableDetails'];
          if (details == null) continue;
          final tableNumber = details['tableNumber']?.toString();
          final section = details['section']?.toString();
          if (tableNumber == null || section == null) continue;
          nextByTableKey[_tableKey(tableNumber, section)] = bill;
        }
        if (mounted) {
          setState(() {
            _pendingBillsByTableKey
              ..clear()
              ..addAll(nextByTableKey);
          });
        }
      }
    } catch (e) {
      debugPrint("Error fetching pending bills: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return CommonScaffold(
        title: 'Tables',
        pageType: PageType.table,
        body: const Center(
          child: CircularProgressIndicator(color: Colors.black),
        ),
      );
    }

    if (_errorMessage != null) {
      return CommonScaffold(
        title: 'Tables',
        pageType: PageType.table,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_errorMessage!, style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _fetchTables,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_tables.isEmpty) {
      return CommonScaffold(
        title: 'Tables',
        pageType: PageType.table,
        body: const Center(
          child: Text(
            'No tables found for this branch.',
            style: TextStyle(fontSize: 16),
          ),
        ),
      );
    }

    // _tables here are actually the sections
    final categories = _tables
        .map((s) => s['name']?.toString() ?? 'General')
        .toList();

    final allTabs = ['All Tables', ...categories];

    return DefaultTabController(
      length: allTabs.length,
      child: CommonScaffold(
        title: 'Tables',
        pageType: PageType.table,
        body: Column(
          children: [
            TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelColor: Colors.black,
              unselectedLabelColor: Colors.grey,
              indicatorColor: Colors.black,
              indicatorWeight: 3,
              tabs: allTabs.map((cat) => Tab(text: cat)).toList(),
            ),
            Expanded(
              child: TabBarView(
                children: allTabs.map((cat) {
                  if (cat == 'All Tables') {
                    // Show all sections
                    return ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _tables.length,
                      itemBuilder: (context, index) {
                        final section = _tables[index];
                        final sectionName =
                            section['name']?.toString() ?? 'General';
                        final tableCount =
                            int.tryParse(
                              section['tableCount']?.toString() ?? '0',
                            ) ??
                            0;
                        return _buildCategorySection(sectionName, tableCount);
                      },
                    );
                  } else {
                    final section = _tables.firstWhere(
                      (s) => (s['name']?.toString() ?? 'General') == cat,
                    );
                    final tableCount =
                        int.tryParse(
                          section['tableCount']?.toString() ?? '0',
                        ) ??
                        0;
                    final sectionName =
                        section['name']?.toString() ?? 'General';
                    return _buildTableGrid(
                      tableCount,
                      sectionName: sectionName,
                    );
                  }
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getTableColor(dynamic runningBill) {
    if (runningBill == null) return const Color(0xFFEEEEEE);

    final items = runningBill['items'] as List?;
    if (items == null || items.isEmpty) {
      return const Color(0xFFFFF176); // Default to Yellow (Ordered)
    }

    // Map statuses to priority (1 = lowest, 4 = highest)
    int lowestPriority = 4;

    for (var item in items) {
      final status = item['status']?.toString().toLowerCase() ?? 'ordered';
      int priority;
      switch (status) {
        case 'ordered':
          priority = 1;
          break;
        case 'confirmed':
          priority = 2;
          break;
        case 'prepared':
          priority = 3;
          break;
        case 'delivered':
          priority = 4;
          break;
        default:
          priority = 1;
      }
      if (priority < lowestPriority) {
        lowestPriority = priority;
      }
    }

    switch (lowestPriority) {
      case 1:
        return const Color(0xFFFFF176); // Yellow (Ordered)
      case 2:
        return const Color(0xFF81D4FA); // Sky Blue (Confirmed)
      case 3:
        return const Color(0xFFA5D6A7); // Light Green (Prepared)
      case 4:
        return const Color(0xFFF48FB1); // Light Pink (Delivered)
      default:
        return const Color(0xFFEEEEEE); // Default grey
    }
  }

  Widget _buildCategorySection(String categoryName, int tableCount) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            categoryName.toUpperCase(),
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
          ),
        ),
        _buildTableGrid(
          tableCount,
          shrinkWrap: true,
          sectionName: categoryName,
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildTableGrid(
    int tableCount, {
    bool shrinkWrap = false,
    required String sectionName,
  }) {
    return GridView.builder(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap
          ? const NeverScrollableScrollPhysics()
          : const AlwaysScrollableScrollPhysics(),
      padding: shrinkWrap ? EdgeInsets.zero : const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1,
      ),
      itemCount: tableCount,
      itemBuilder: (context, index) {
        final tableNumber = index + 1;

        final runningBill =
            _pendingBillsByTableKey[_tableKey(
              tableNumber.toString(),
              sectionName,
            )];
        final isRunning = runningBill != null;

        return GestureDetector(
          onTap: () => _handleTableTap(
            runningBill,
            tableNumber,
            sectionName,
            openCart: false,
          ),
          onDoubleTap: () => _handleTableTap(
            runningBill,
            tableNumber,
            sectionName,
            openCart: true,
          ),
          child: CustomPaint(
            painter: isRunning ? null : DashedBorderPainter(),
            child: Container(
              decoration: BoxDecoration(
                color: _getTableColor(runningBill),
                borderRadius: BorderRadius.circular(8),
                boxShadow: isRunning
                    ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (isRunning) ...[
                      Builder(
                        builder: (context) {
                          // Calculate running time
                          final createdAtStr = runningBill['createdAt']
                              ?.toString();
                          if (createdAtStr == null) return const SizedBox();

                          final createdAt = DateTime.tryParse(createdAtStr);
                          if (createdAt == null) return const SizedBox();

                          final diff = DateTime.now().difference(createdAt);
                          if (diff.isNegative) return const SizedBox();

                          // Check priority to hide if Prepared/Delivered
                          // Status logic copied from _getTableColor
                          final items = runningBill['items'] as List?;
                          if (items == null || items.isEmpty) {
                            // Default ordered
                          } else {
                            int lowestPriority = 4;
                            for (var item in items) {
                              final status =
                                  item['status']?.toString().toLowerCase() ??
                                  'ordered';
                              int priority;
                              switch (status) {
                                case 'ordered':
                                  priority = 1;
                                  break;
                                case 'confirmed':
                                  priority = 2;
                                  break;
                                case 'prepared':
                                  priority = 3;
                                  break;
                                case 'delivered':
                                  priority = 4;
                                  break;
                                default:
                                  priority = 1;
                              }
                              if (priority < lowestPriority) {
                                lowestPriority = priority;
                              }
                            }
                            // If prepared (3) or delivered (4), hide timer
                            if (lowestPriority >= 3) {
                              return const SizedBox();
                            }
                          }

                          final minutes = diff.inMinutes.toString().padLeft(
                            2,
                            '0',
                          );
                          final seconds = (diff.inSeconds % 60)
                              .toString()
                              .padLeft(2, '0');

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              '$minutes:$seconds',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.red,
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                    Text(
                      'Table $tableNumber',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: isRunning
                            ? FontWeight.bold
                            : FontWeight.w500,
                      ),
                    ),
                    if (isRunning) ...[
                      const SizedBox(height: 4),
                      Text(
                        () {
                          String inv = runningBill['invoiceNumber'] ?? '';
                          if (inv.contains('-')) {
                            return 'KOT-${inv.split('-').last.replaceAll('KOT', '')}';
                          }
                          return inv;
                        }(),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<Map<String, dynamic>?> _showCustomerDetailsDialog(
    CartProvider cartProvider,
  ) async {
    final nameCtrl = TextEditingController(
      text: cartProvider.customerName ?? '',
    );
    final phoneCtrl = TextEditingController(
      text: cartProvider.customerPhone ?? '',
    );
    Timer? debounceTimer;
    bool isDialogActive = true;
    String latestLookupPhone = '';

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return Dialog(
              backgroundColor: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              insetPadding: const EdgeInsets.symmetric(horizontal: 28),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight:
                          MediaQuery.of(dialogContext).size.height * 0.78,
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Center(
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
                          const Text(
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
                                if (val.length >= 10) {
                                  final lookupPhone = val.trim();
                                  latestLookupPhone = lookupPhone;
                                  debounceTimer?.cancel();
                                  debounceTimer = Timer(
                                    const Duration(milliseconds: 600),
                                    () async {
                                      if (!isDialogActive ||
                                          lookupPhone != latestLookupPhone ||
                                          nameCtrl.text.trim().isNotEmpty) {
                                        return;
                                      }

                                      try {
                                        final data = await cartProvider
                                            .fetchCustomerData(lookupPhone);
                                        if (!isDialogActive ||
                                            !mounted ||
                                            lookupPhone !=
                                                phoneCtrl.text.trim() ||
                                            nameCtrl.text.trim().isNotEmpty) {
                                          return;
                                        }
                                        if (data != null &&
                                            data['name'] != null) {
                                          nameCtrl.text = data['name']
                                              .toString();
                                        }
                                      } catch (e) {
                                        debugPrint("Lookup failed: $e");
                                      }
                                    },
                                  );
                                } else {
                                  latestLookupPhone = '';
                                  debounceTimer?.cancel();
                                }
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
                          const SizedBox(height: 18),
                          const Text(
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
                          const SizedBox(height: 28),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () {
                                    isDialogActive = false;
                                    debounceTimer?.cancel();
                                    Navigator.pop(
                                      dialogContext,
                                      <String, dynamic>{},
                                    );
                                  },
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white70,
                                    side: const BorderSide(
                                      color: Colors.white24,
                                    ),
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
                                    if (phoneCtrl.text.trim().isEmpty ||
                                        nameCtrl.text.trim().isEmpty) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            "Please enter phone and customer name or use Skip",
                                          ),
                                        ),
                                      );
                                      return;
                                    }

                                    isDialogActive = false;
                                    debounceTimer?.cancel();
                                    Navigator.pop(
                                      dialogContext,
                                      <String, dynamic>{
                                        'name': nameCtrl.text.trim(),
                                        'phone': phoneCtrl.text.trim(),
                                      },
                                    );
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
                          if (phoneCtrl.text.length >= 10) ...[
                            const SizedBox(height: 20),
                            Center(
                              child: InkWell(
                                onTap: () {
                                  if (!dialogContext.mounted) return;
                                  showDialog(
                                    context: dialogContext,
                                    builder: (context) => CustomerHistoryDialog(
                                      phoneNumber: phoneCtrl.text.trim(),
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
                                      SizedBox(width: 8),
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
                        isDialogActive = false;
                        debounceTimer?.cancel();
                        Navigator.pop(dialogContext, null);
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    isDialogActive = false;
    debounceTimer?.cancel();
    nameCtrl.dispose();
    phoneCtrl.dispose();
    return result;
  }

  void _handleTableTap(
    dynamic runningBill,
    int tableNumber,
    String sectionName, {
    required bool openCart,
  }) async {
    if (_isHandlingTableTap) return;
    _isHandlingTableTap = true;

    final isRunning = runningBill != null;
    final cartProvider = Provider.of<CartProvider>(context, listen: false);

    try {
      if (isRunning) {
        // If running, we should "recall" it
        final itemsList = (runningBill['items'] as List)
            .where((item) => item['status']?.toString() != 'cancelled')
            .toList();
        final List<CartItem> recalledItems = itemsList.map((item) {
          final prod = item['product'];
          String? cid;
          final String pid = (prod is Map)
              ? (prod['id'] ?? prod['_id'] ?? prod[r'$oid']).toString()
              : prod.toString();
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

          if (prod is Map && prod['category'] != null) {
            final cat = prod['category'];
            cid = (cat is Map)
                ? (cat['id'] ?? cat['_id'] ?? cat[r'$oid']).toString()
                : cat.toString();
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
            specialNote: item['specialNote'] ?? item['note'] ?? item['notes'],
            status: item['status']?.toString(),
          );
        }).toList();

        final customer = runningBill['customerDetails'] ?? {};
        final tableDetails = runningBill['tableDetails'] ?? {};

        cartProvider.loadKOTItems(
          recalledItems,
          billId: runningBill['id'],
          cName: customer['name'],
          cPhone: customer['phoneNumber'],
          tName: tableDetails['tableNumber']?.toString(),
          tSection: tableDetails['section']?.toString(),
        );

        // Clear notifications for this bill since we are opening its cart
        cartProvider.markBillAsRead(runningBill['id']);
      } else {
        cartProvider.setSelectedTable(tableNumber.toString(), sectionName);

        if (!openCart) {
          final customerDetails = await _showCustomerDetailsDialog(
            cartProvider,
          );
          if (!mounted) return;
          if (customerDetails == null) return;

          if (customerDetails.isEmpty) {
            cartProvider.setCustomerDetails();
          } else {
            cartProvider.setCustomerDetails(
              name: customerDetails['name']?.toString(),
              phone: customerDetails['phone']?.toString(),
            );
          }
        }
      }

      if (!mounted) return;
      // Let dialog overlay fully dispose before route push.
      await Future<void>.delayed(const Duration(milliseconds: 16));
      if (!mounted) return;

      if (openCart) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const CartPage()),
        );
      } else {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                const CategoriesPage(sourcePage: PageType.table),
          ),
        );
      }
    } finally {
      _isHandlingTableTap = false;
    }
  }

  String _tableKey(String tableNumber, String sectionName) {
    return '$tableNumber|$sectionName';
  }
}

class DashedBorderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.grey[400]!
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    const dashWidth = 5.0;
    const dashSpace = 3.0;
    final borderRadius = Radius.circular(8);

    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width, size.height),
          borderRadius,
        ),
      );

    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        canvas.drawPath(
          metric.extractPath(distance, distance + dashWidth),
          paint,
        );
        distance += dashWidth + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
