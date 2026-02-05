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
  List<dynamic> _pendingBills = [];
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
          'https://blackforest.vseyal.com/api/tables?limit=200&depth=1',
        ),
        headers: {'Authorization': 'Bearer $_token'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> allDocs = data['docs'] ?? [];

        // Find the doc that matches OUR branch ID
        final branchDoc = allDocs.firstWhere((doc) {
          final b = doc['branch'];
          String? bId;
          if (b is Map) {
            bId = b['id']?.toString() ?? b['_id']?.toString();
          } else {
            bId = b?.toString();
          }
          return bId == _branchId;
        }, orElse: () => null);

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
        if (mounted) {
          setState(() {
            _pendingBills = data['docs'] ?? [];
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
    if (items == null || items.isEmpty)
      return const Color(0xFFFFF176); // Default to Yellow (Ordered)

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

        final runningBill = _pendingBills.firstWhere((bill) {
          final td = bill['tableDetails'];
          if (td == null) return false;
          return td['tableNumber']?.toString() == tableNumber.toString() &&
              td['section']?.toString() == sectionName;
        }, orElse: () => null);
        final isRunning = runningBill != null;

        return GestureDetector(
          onTap: () => _handleTableTap(
            context,
            runningBill,
            tableNumber,
            sectionName,
            openCart: false,
          ),
          onDoubleTap: () => _handleTableTap(
            context,
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

  void _handleTableTap(
    BuildContext context,
    dynamic runningBill,
    int tableNumber,
    String sectionName, {
    required bool openCart,
  }) {
    final isRunning = runningBill != null;

    if (isRunning) {
      // If running, we should "recall" it
      final cartProvider = Provider.of<CartProvider>(context, listen: false);
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
      final cartProvider = Provider.of<CartProvider>(context, listen: false);
      cartProvider.setSelectedTable(tableNumber.toString(), sectionName);
    }

    if (openCart) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const CartPage()),
      );
    } else {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (context) =>
              const CategoriesPage(sourcePage: PageType.table),
        ),
        (route) => false,
      );
    }
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

    for (final Metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < Metric.length) {
        canvas.drawPath(
          Metric.extractPath(distance, distance + dashWidth),
          paint,
        );
        distance += dashWidth + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
