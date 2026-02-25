import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:provider/provider.dart';
import 'package:blackforest_app/cart_provider.dart';
import 'package:blackforest_app/categories_page.dart';
import 'package:blackforest_app/cart_page.dart';
import 'package:blackforest_app/customer_history_dialog.dart';
import 'package:blackforest_app/table_customer_details_visibility_service.dart';

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
  final List<dynamic> _sharedPendingBills = [];
  bool _isHandlingTableTap = false;
  bool _isFetchingPendingBills = false;
  Timer? _timer;

  List<Map<String, dynamic>> _activeItemsFromBill(dynamic bill) {
    if (bill is! Map) return const <Map<String, dynamic>>[];
    final items = bill['items'];
    if (items is! List || items.isEmpty) {
      return const <Map<String, dynamic>>[];
    }

    final activeItems = <Map<String, dynamic>>[];
    for (final rawItem in items) {
      if (rawItem is! Map) continue;
      final item = Map<String, dynamic>.from(rawItem);
      final status = item['status']?.toString().toLowerCase().trim() ?? '';
      if (status == 'cancelled') continue;
      activeItems.add(item);
    }
    return activeItems;
  }

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
        if (timer.tick % 5 == 0) {
          unawaited(_fetchPendingBills());
        }
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
      unawaited(
        TableCustomerDetailsVisibilityService.shouldShowForBranch(
          branchId: _branchId,
          token: _token,
        ),
      );
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
    if (_token == null || _branchId == null || _isFetchingPendingBills) return;
    _isFetchingPendingBills = true;

    try {
      final now = DateTime.now();
      final localDayStart = DateTime(now.year, now.month, now.day);
      // Convert local-day boundary to UTC so backend date filter includes
      // bills created after local midnight (e.g. 00:xx local time).
      final todayStart = localDayStart.toUtc().toIso8601String();

      final url = Uri.parse(
        'https://blackforest.vseyal.com/api/billings?where[status][in]=pending,ordered,confirmed,prepared,delivered&where[branch][equals]=$_branchId&where[createdAt][greater_than_equal]=$todayStart&limit=100&depth=3',
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
        final nextSharedBills = <dynamic>[];
        for (final bill in docs) {
          if (_activeItemsFromBill(bill).isEmpty) {
            continue;
          }
          final details = bill['tableDetails'];
          if (details == null) continue;
          final tableNumber = details['tableNumber']?.toString();
          final section = details['section']?.toString();
          if (tableNumber == null || section == null) continue;
          if (_isSharedTablesSection(section)) {
            nextSharedBills.add(bill);
            continue;
          }
          final key = _tableKey(tableNumber, section);
          final existingBill = nextByTableKey[key];
          if (existingBill == null || _isNewerBill(bill, existingBill)) {
            nextByTableKey[key] = bill;
          }
        }

        nextSharedBills.sort((a, b) {
          final aTime = DateTime.tryParse(a['createdAt']?.toString() ?? '');
          final bTime = DateTime.tryParse(b['createdAt']?.toString() ?? '');
          if (aTime == null && bTime == null) return 0;
          if (aTime == null) return 1;
          if (bTime == null) return -1;
          return bTime.compareTo(aTime);
        });

        final uniqueShared = <String>{};
        final filteredShared = <dynamic>[];
        for (final bill in nextSharedBills) {
          final id =
              bill['id']?.toString() ??
              bill['_id']?.toString() ??
              bill[r'$oid']?.toString();
          if (id == null || uniqueShared.contains(id)) continue;
          uniqueShared.add(id);
          filteredShared.add(bill);
        }

        if (mounted) {
          setState(() {
            _pendingBillsByTableKey
              ..clear()
              ..addAll(nextByTableKey);
            _sharedPendingBills
              ..clear()
              ..addAll(filteredShared);
          });
        }
      }
    } catch (e) {
      debugPrint("Error fetching pending bills: $e");
    } finally {
      _isFetchingPendingBills = false;
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
        body: Stack(
          children: [
            Column(
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
                        return ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            ..._tables.map((section) {
                              final sectionName =
                                  section['name']?.toString() ?? 'General';
                              final tableCount =
                                  int.tryParse(
                                    section['tableCount']?.toString() ?? '0',
                                  ) ??
                                  0;
                              return _buildCategorySection(
                                sectionName,
                                tableCount,
                              );
                            }),
                            _buildSharedTablesSection(),
                          ],
                        );
                      }
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
                    }).toList(),
                  ),
                ),
              ],
            ),
            Positioned(
              right: 16,
              bottom: 10,
              child: FloatingActionButton(
                heroTag: 'shared_table_fab',
                onPressed: _startSharedTableOrder,
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                child: const Icon(Icons.add),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getTableColor(dynamic runningBill) {
    if (runningBill == null) return const Color(0xFFEEEEEE);

    final items = _activeItemsFromBill(runningBill);
    if (items.isEmpty) {
      return const Color(0xFFEEEEEE);
    }

    // Map statuses to priority (1 = lowest, 4 = highest)
    int lowestPriority = 4;

    for (final item in items) {
      final priority = _statusPriority(item['status']);
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

  Widget _buildTableTile({
    required String tableLabel,
    required dynamic runningBill,
    required VoidCallback onTap,
    required VoidCallback onDoubleTap,
    bool showDashedWhenIdle = true,
  }) {
    final isRunning = runningBill != null;

    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      child: CustomPaint(
        painter: !isRunning && showDashedWhenIdle
            ? DashedBorderPainter()
            : null,
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
                if (isRunning) _buildRunningTimeWidget(runningBill),
                Text(
                  tableLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: isRunning ? FontWeight.bold : FontWeight.w500,
                  ),
                ),
                if (isRunning) ...[
                  const SizedBox(height: 4),
                  Text(
                    _kotLabel(runningBill),
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
  }

  Widget _buildRunningTimeWidget(dynamic runningBill) {
    final createdAtStr = runningBill['createdAt']?.toString();
    if (createdAtStr == null) return const SizedBox();

    final createdAt = DateTime.tryParse(createdAtStr);
    if (createdAt == null) return const SizedBox();

    final diff = DateTime.now().difference(createdAt);
    if (diff.isNegative) return const SizedBox();

    final items = _activeItemsFromBill(runningBill);
    if (items.isNotEmpty) {
      int lowestPriority = 4;
      for (final item in items) {
        final priority = _statusPriority(item['status']);
        if (priority < lowestPriority) {
          lowestPriority = priority;
        }
      }
      if (lowestPriority >= 3) {
        return const SizedBox();
      }
    }

    final minutes = diff.inMinutes.toString().padLeft(2, '0');
    final seconds = (diff.inSeconds % 60).toString().padLeft(2, '0');

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
  }

  int _statusPriority(dynamic rawStatus) {
    final status = rawStatus?.toString().toLowerCase().trim() ?? '';
    switch (status) {
      case 'cancelled':
        return 99;
      case 'pending':
      case 'ordered':
        return 1;
      case 'confirmed':
        return 2;
      case 'prepared':
        return 3;
      case 'delivered':
        return 4;
      default:
        return 1;
    }
  }

  String _kotLabel(dynamic runningBill) {
    String readText(dynamic value) => value?.toString().trim() ?? '';

    final invoiceNumber = readText(runningBill['invoiceNumber']);
    if (invoiceNumber.isNotEmpty) {
      if (invoiceNumber.contains('-')) {
        final suffix = invoiceNumber.split('-').last.trim();
        final cleanedSuffix = suffix
            .replaceFirst(RegExp(r'^kot(?:-|\s)*', caseSensitive: false), '')
            .trim();
        if (cleanedSuffix.isNotEmpty) {
          return 'KOT-$cleanedSuffix';
        }
      }
      return invoiceNumber;
    }

    final kotNumberRaw = readText(runningBill['kotNumber']);
    if (kotNumberRaw.isEmpty) {
      return 'KOT';
    }

    final digitsOnly = kotNumberRaw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digitsOnly.isNotEmpty) {
      return 'KOT-$digitsOnly';
    }
    if (kotNumberRaw.toUpperCase().startsWith('KOT')) {
      return kotNumberRaw.toUpperCase();
    }
    return 'KOT-$kotNumberRaw';
  }

  Widget _buildSharedTablesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            CartProvider.sharedTablesSectionName.toUpperCase(),
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
          ),
        ),
        if (_sharedPendingBills.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE0E0E0)),
            ),
            child: const Text(
              'No running shared-table orders',
              style: TextStyle(color: Colors.black54),
            ),
          )
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1,
            ),
            itemCount: _sharedPendingBills.length,
            itemBuilder: (context, index) {
              final runningBill = _sharedPendingBills[index];
              final tableDetails = runningBill['tableDetails'] ?? {};
              final tableNumber =
                  tableDetails['tableNumber']?.toString() ?? 'N/A';
              final sectionName =
                  tableDetails['section']?.toString() ??
                  CartProvider.sharedTablesSectionName;

              return _buildTableTile(
                tableLabel: 'Table $tableNumber',
                runningBill: runningBill,
                onTap: () => _handleTableTap(
                  runningBill,
                  int.tryParse(tableNumber) ?? 0,
                  sectionName,
                  openCart: false,
                ),
                onDoubleTap: () => _handleTableTap(
                  runningBill,
                  int.tryParse(tableNumber) ?? 0,
                  sectionName,
                  openCart: true,
                ),
                showDashedWhenIdle: false,
              );
            },
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

        final runningBill = _findRunningBillForGrid(
          tableNumber: tableNumber.toString(),
          sectionName: sectionName,
        );

        return _buildTableTile(
          tableLabel: 'Table $tableNumber',
          runningBill: runningBill,
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
        );
      },
    );
  }

  Future<Map<String, dynamic>?> _showCustomerDetailsDialog(
    CartProvider cartProvider, {
    bool allowSkip = true,
  }) async {
    final nameCtrl = TextEditingController(
      text: cartProvider.customerName ?? '',
    );
    final phoneCtrl = TextEditingController(
      text: cartProvider.customerPhone ?? '',
    );
    Timer? debounceTimer;
    bool isDialogActive = true;
    String latestLookupPhone = '';
    Map<String, dynamic>? customerLookupData;
    bool isLookupInProgress = false;
    String? lookupError;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            double readMoney(dynamic value) {
              if (value is num) return value.toDouble();
              if (value is String) return double.tryParse(value) ?? 0.0;
              return 0.0;
            }

            Map<String, dynamic>? readMap(dynamic raw) {
              if (raw is Map) return Map<String, dynamic>.from(raw);
              return null;
            }

            List<Map<String, dynamic>> readMapList(dynamic raw) {
              if (raw is! List) return const <Map<String, dynamic>>[];
              return raw
                  .whereType<Map>()
                  .map((entry) => Map<String, dynamic>.from(entry))
                  .toList();
            }

            String formatQty(double value) {
              if (value % 1 == 0) {
                return value.toInt().toString();
              }
              return value.toStringAsFixed(2);
            }

            final offerData = readMap(customerLookupData?['offer']);
            final productOfferData = readMap(
              customerLookupData?['productOfferPreview'],
            );
            final productPriceOfferData = readMap(
              customerLookupData?['productPriceOfferPreview'],
            );
            final randomOfferData = readMap(
              customerLookupData?['randomCustomerOfferPreview'],
            );
            final totalPercentageOfferData = readMap(
              customerLookupData?['totalPercentageOfferPreview'],
            );

            final productOfferMatches = readMapList(
              productOfferData?['matches'],
            );
            final productPriceOfferMatches = readMapList(
              productPriceOfferData?['matches'],
            );
            final randomOfferMatches = readMapList(randomOfferData?['matches']);

            final eligibleProductOfferMatches = productOfferMatches
                .where((entry) => entry['eligible'] == true)
                .toList();
            final eligibleProductPriceOfferMatches = productPriceOfferMatches
                .where((entry) => entry['eligible'] == true)
                .toList();
            final eligibleRandomOfferMatches = randomOfferMatches
                .where((entry) => entry['eligible'] == true)
                .toList();

            final creditOfferEligible =
                offerData?['enabled'] == true &&
                (offerData?['isOfferEligible'] == true ||
                    offerData?['historyBasedEligible'] == true);
            final totalPercentageOfferEnabled =
                totalPercentageOfferData?['enabled'] == true;

            String? activeOfferTitle;
            List<String> activeOfferLines = const <String>[];
            Color activeOfferBorderColor = const Color(0xFF2EBF3B);

            if (eligibleProductOfferMatches.isNotEmpty) {
              final match = eligibleProductOfferMatches.first;
              final freeName =
                  match['freeProductName']?.toString().trim().isNotEmpty == true
                  ? match['freeProductName'].toString().trim()
                  : 'Free Product';
              final freeQty = readMoney(match['predictedFreeQuantity']);
              activeOfferTitle = 'Product to Product Offer';
              activeOfferLines = [
                '$freeName FREE x${formatQty(freeQty)}',
                'Applied by backend for this table order.',
              ];
              activeOfferBorderColor = const Color(0xFF0A84FF);
            } else if (eligibleProductPriceOfferMatches.isNotEmpty) {
              final match = eligibleProductPriceOfferMatches.first;
              final productName =
                  match['productName']?.toString().trim().isNotEmpty == true
                  ? match['productName'].toString().trim()
                  : 'Product';
              final discountPerUnit = readMoney(match['discountPerUnit']);
              final discountedUnits = readMoney(match['predictedAppliedUnits']);
              activeOfferTitle = 'Product Price Offer';
              activeOfferLines = [
                '$productName discount ₹${discountPerUnit.toStringAsFixed(2)} x ${formatQty(discountedUnits)} unit(s)',
                'Applied by backend for this table order.',
              ];
              activeOfferBorderColor = const Color(0xFFF7A400);
            } else if (eligibleRandomOfferMatches.isNotEmpty) {
              final selectedMatchRaw = randomOfferData?['selectedMatch'];
              Map<String, dynamic>? selectedMatch;
              if (selectedMatchRaw is Map) {
                selectedMatch = Map<String, dynamic>.from(selectedMatchRaw);
              } else {
                selectedMatch = eligibleRandomOfferMatches.first;
              }
              final productName =
                  selectedMatch['productName']?.toString().trim().isNotEmpty ==
                      true
                  ? selectedMatch['productName'].toString().trim()
                  : 'Random Product';
              activeOfferTitle = 'Random Product Offer';
              activeOfferLines = [
                '$productName (FREE x1)',
                'Applied by backend for this table order.',
              ];
              activeOfferBorderColor = const Color(0xFF00B8D9);
            } else if (creditOfferEligible) {
              final offerAmount = readMoney(offerData?['offerAmount']);
              activeOfferTitle = 'Customer Credit Offer';
              activeOfferLines = [
                'Eligible discount: ₹${offerAmount.toStringAsFixed(2)}',
                'Used in final billing submit (backend validation).',
              ];
              activeOfferBorderColor = const Color(0xFF2EBF3B);
            } else if (totalPercentageOfferEnabled) {
              final percent = readMoney(
                totalPercentageOfferData?['discountPercent'],
              );
              activeOfferTitle = 'Total Percentage Offer';
              activeOfferLines = [
                '${percent.toStringAsFixed(2)}% on final payable amount',
                'Applied by backend if higher-priority offers are not used.',
              ];
              activeOfferBorderColor = const Color(0xFF9B7DFF);
            }

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
                                  setDialogState(() {
                                    lookupError = null;
                                    isLookupInProgress = true;
                                  });
                                  debounceTimer?.cancel();
                                  debounceTimer = Timer(
                                    const Duration(milliseconds: 600),
                                    () async {
                                      if (!isDialogActive ||
                                          lookupPhone != latestLookupPhone) {
                                        return;
                                      }

                                      try {
                                        final activeTableNumber =
                                            cartProvider.selectedTable
                                                ?.trim() ??
                                            '';
                                        final activeSection =
                                            cartProvider.selectedSection
                                                ?.trim() ??
                                            '';
                                        final data = await cartProvider
                                            .fetchCustomerData(
                                              lookupPhone,
                                              isTableOrder: true,
                                              tableSection: activeSection,
                                              tableNumber: activeTableNumber,
                                            );
                                        if (!isDialogActive ||
                                            !mounted ||
                                            lookupPhone !=
                                                phoneCtrl.text.trim()) {
                                          return;
                                        }
                                        setDialogState(() {
                                          customerLookupData = data;
                                          isLookupInProgress = false;
                                          lookupError = null;
                                        });
                                        final fetchedName =
                                            data?['name']?.toString().trim() ??
                                            '';
                                        final isNewCustomerLookup =
                                            data?['isNewCustomer'] == true;
                                        if (!isNewCustomerLookup &&
                                            fetchedName.isNotEmpty &&
                                            nameCtrl.text.trim().isEmpty) {
                                          nameCtrl.text = fetchedName;
                                        }
                                      } catch (e) {
                                        debugPrint("Lookup failed: $e");
                                        if (!isDialogActive ||
                                            !mounted ||
                                            lookupPhone !=
                                                phoneCtrl.text.trim()) {
                                          return;
                                        }
                                        setDialogState(() {
                                          customerLookupData = null;
                                          isLookupInProgress = false;
                                          lookupError =
                                              'Unable to fetch customer details';
                                        });
                                      }
                                    },
                                  );
                                } else {
                                  latestLookupPhone = '';
                                  debounceTimer?.cancel();
                                  setDialogState(() {
                                    customerLookupData = null;
                                    lookupError = null;
                                    isLookupInProgress = false;
                                  });
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
                          if (isLookupInProgress) ...[
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
                          if (lookupError != null) ...[
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
                          if (customerLookupData != null) ...[
                            const SizedBox(height: 14),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF121212),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.12),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'History: ${customerLookupData!['totalBills'] ?? 0} bills | ₹${readMoney(customerLookupData!['totalAmount']).toStringAsFixed(2)} spent',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Order type: ${(customerLookupData!['orderType'] ?? 'table').toString().toUpperCase()}',
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          if (customerLookupData != null) ...[
                            const SizedBox(height: 10),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF102229),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: activeOfferTitle != null
                                      ? activeOfferBorderColor.withValues(
                                          alpha: 0.55,
                                        )
                                      : Colors.white24,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    activeOfferTitle ?? 'Offer Status',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  if (activeOfferLines.isNotEmpty)
                                    ...activeOfferLines.map(
                                      (line) => Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 3,
                                        ),
                                        child: Text(
                                          line,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    )
                                  else
                                    const Text(
                                      'No eligible offer for this table order right now.',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 28),
                          if (allowSkip)
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
                            )
                          else
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: () {
                                  if (phoneCtrl.text.trim().isEmpty ||
                                      nameCtrl.text.trim().isEmpty) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          "Please enter phone and customer name",
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

    final activeItems = _activeItemsFromBill(runningBill);
    final isRunning = runningBill != null && activeItems.isNotEmpty;
    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    cartProvider.setCartType(CartType.table, notify: false);

    try {
      if (isRunning) {
        // If running, we should "recall" it
        final List<CartItem> recalledItems = activeItems.map((item) {
          double toSafeDouble(dynamic value) {
            if (value is num) return value.toDouble();
            if (value is String) return double.tryParse(value) ?? 0.0;
            return 0.0;
          }

          final itemMap = item;
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
            categoryId: cid,
            specialNote: item['specialNote'] ?? item['note'] ?? item['notes'],
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
        final targetTable = tableNumber.toString();
        final targetSection = sectionName.trim().toLowerCase();
        final currentTable = cartProvider.selectedTable?.trim();
        final currentSection = (cartProvider.selectedSection ?? '')
            .trim()
            .toLowerCase();

        // Reopening a non-running table must always start fresh, even if
        // it's the same table selected earlier.
        if (currentTable == targetTable && currentSection == targetSection) {
          cartProvider.clearCart();
          cartProvider.setSelectedTableMetadata(targetTable, sectionName);
        } else {
          cartProvider.setSelectedTable(targetTable, sectionName);
        }
        // Non-running table should always start with fresh customer info.
        cartProvider.setCustomerDetails();

        if (!openCart) {
          final customerDetailsVisibilityConfig =
              await TableCustomerDetailsVisibilityService.getConfigForBranch(
                branchId: _branchId,
                token: _token,
              );
          if (!mounted) return;

          if (!customerDetailsVisibilityConfig
              .showCustomerDetailsForTableOrders) {
            cartProvider.setCustomerDetails();
          } else {
            final customerDetails = await _showCustomerDetailsDialog(
              cartProvider,
              allowSkip: customerDetailsVisibilityConfig
                  .allowSkipCustomerDetailsForTableOrders,
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
      }

      if (!mounted) return;
      // Let dialog overlay fully dispose before route push.
      await Future<void>.delayed(const Duration(milliseconds: 16));
      if (!mounted) return;
      FocusManager.instance.primaryFocus?.unfocus();

      if (openCart) {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const CartPage()),
        );
      } else {
        await Navigator.push(
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

  Future<void> _startSharedTableOrder() async {
    if (_isHandlingTableTap) return;
    _isHandlingTableTap = true;

    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    try {
      cartProvider.setCartType(CartType.table, notify: false);
      cartProvider.startSharedTableOrder();
      if (!mounted) return;
      FocusManager.instance.primaryFocus?.unfocus();

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) =>
              const CategoriesPage(sourcePage: PageType.table),
        ),
      );
    } finally {
      _isHandlingTableTap = false;
    }
  }

  bool _isSharedTablesSection(String? section) {
    return (section ?? '').trim().toLowerCase() ==
        CartProvider.sharedTablesSectionName.toLowerCase();
  }

  bool _isNewerBill(dynamic left, dynamic right) {
    final leftTime = DateTime.tryParse(left['createdAt']?.toString() ?? '');
    final rightTime = DateTime.tryParse(right['createdAt']?.toString() ?? '');
    if (leftTime == null && rightTime == null) return false;
    if (leftTime == null) return false;
    if (rightTime == null) return true;
    return leftTime.isAfter(rightTime);
  }

  dynamic _findRunningBillForGrid({
    required String tableNumber,
    required String sectionName,
  }) {
    final exactKey = _tableKey(tableNumber, sectionName);
    final exact = _pendingBillsByTableKey[exactKey];
    if (exact != null) return exact;

    final normalizedTable = _normalizeTableToken(tableNumber);
    final normalizedSection = _normalizeSectionName(sectionName);

    for (final bill in _pendingBillsByTableKey.values) {
      final details = bill['tableDetails'];
      if (details == null) continue;

      final billTable = _normalizeTableToken(
        details['tableNumber']?.toString() ?? '',
      );
      if (billTable != normalizedTable) continue;

      final billSection = _normalizeSectionName(
        details['section']?.toString() ?? '',
      );
      if (billSection == normalizedSection) {
        return bill;
      }
    }

    return null;
  }

  String _normalizeSectionName(String section) {
    return section.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }

  String _normalizeTableToken(String raw) {
    final trimmed = raw.trim();
    final parsed = int.tryParse(trimmed);
    if (parsed != null) return parsed.toString();

    final withoutPrefix = trimmed.replaceFirst(
      RegExp(r'^table[\s\-_:]*', caseSensitive: false),
      '',
    );
    final parsedWithoutPrefix = int.tryParse(withoutPrefix);
    if (parsedWithoutPrefix != null) return parsedWithoutPrefix.toString();

    return trimmed.toLowerCase();
  }

  String _tableKey(String tableNumber, String sectionName) {
    final normalizedSection = _normalizeSectionName(sectionName);
    final normalizedTable = _normalizeTableToken(tableNumber);
    return '$normalizedTable|$normalizedSection';
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
