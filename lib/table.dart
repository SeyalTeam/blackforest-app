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
import 'package:blackforest_app/waiter_call_range_filter_service.dart';

class TablePage extends StatefulWidget {
  const TablePage({super.key});

  @override
  State<TablePage> createState() => _TablePageState();
}

class _ExistingCustomerSectionTable {
  final String tableNumber;
  final dynamic runningBill;

  const _ExistingCustomerSectionTable({
    required this.tableNumber,
    required this.runningBill,
  });
}

class _TablePageState extends State<TablePage> {
  static final bool _enableCustomerLookup = false; // manual entry mode
  static const String _cachedTablesPrefix = 'cached_tables_';
  static const String _cachedPendingBillsPrefix = 'cached_pending_bills_';
  static const String _cachedExistingCustomersPrefix =
      'cached_existing_customers_';
  static const Duration _tableRefreshInterval = Duration(seconds: 10);
  List<dynamic> _tables = [];
  List<String> _candidateWaiterKeys = [];
  bool _isLoading = true;
  String? _errorMessage;
  String? _branchId;
  String? _branchName;
  String? _token;
  // ignore: unused_field
  String? _currentWaiterName;
  // ignore: unused_field
  TableCustomerDetailsVisibilityConfig _customerDetailsVisibilityConfig =
      TableCustomerDetailsVisibilityConfig.defaultValue;
  final Map<String, dynamic> _pendingBillsByTableKey = {};
  final List<dynamic> _sharedPendingBills = [];
  final Map<String, bool> _existingCustomerByPhone = {};
  final Set<String> _existingCustomerLookupInFlight = <String>{};
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
    _timer = Timer.periodic(_tableRefreshInterval, (timer) {
      if (mounted) {
        setState(() {
          // Keep elapsed-time labels fresh without per-second rebuild churn.
        });
        // Refresh table occupancy every 10s.
        unawaited(_fetchPendingBills());
      }
    });
  }

  String? _branchScopedCacheKey(String prefix) {
    final branchId = _branchId?.trim();
    if (branchId == null || branchId.isEmpty) return null;
    return '$prefix$branchId';
  }

  void _hydrateCachedPendingBills(SharedPreferences prefs) {
    final cacheKey = _branchScopedCacheKey(_cachedPendingBillsPrefix);
    if (cacheKey == null) return;
    final cached = prefs.getString(cacheKey);
    if (cached == null || cached.isEmpty) return;

    try {
      final decoded = jsonDecode(cached);
      if (decoded is! Map) return;
      final map = Map<String, dynamic>.from(decoded);
      final byTableKeyRaw = map['byTableKey'];
      final sharedBillsRaw = map['sharedBills'];

      final hydratedByTableKey = <String, dynamic>{};
      if (byTableKeyRaw is Map) {
        hydratedByTableKey.addAll(Map<String, dynamic>.from(byTableKeyRaw));
      }

      final hydratedSharedBills = <dynamic>[];
      if (sharedBillsRaw is List) {
        hydratedSharedBills.addAll(sharedBillsRaw);
      }

      if (hydratedByTableKey.isEmpty && hydratedSharedBills.isEmpty) return;
      setState(() {
        _pendingBillsByTableKey
          ..clear()
          ..addAll(hydratedByTableKey);
        _sharedPendingBills
          ..clear()
          ..addAll(hydratedSharedBills);
      });
    } catch (e) {
      debugPrint('Error decoding cached pending bills: $e');
    }
  }

  Future<void> _persistPendingBillsCache() async {
    final cacheKey = _branchScopedCacheKey(_cachedPendingBillsPrefix);
    if (cacheKey == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = <String, dynamic>{
        'byTableKey': Map<String, dynamic>.from(_pendingBillsByTableKey),
        'sharedBills': List<dynamic>.from(_sharedPendingBills),
        'cachedAt': DateTime.now().toUtc().toIso8601String(),
      };
      await prefs.setString(cacheKey, jsonEncode(payload));
    } catch (e) {
      debugPrint('Error caching pending bills: $e');
    }
  }

  void _hydrateCachedExistingCustomers(SharedPreferences prefs) {
    final cacheKey = _branchScopedCacheKey(_cachedExistingCustomersPrefix);
    if (cacheKey == null) return;
    final cached = prefs.getString(cacheKey);
    if (cached == null || cached.isEmpty) return;

    bool? parseBool(dynamic value) {
      if (value is bool) return value;
      if (value is num) {
        if (value == 1) return true;
        if (value == 0) return false;
      }
      if (value is String) {
        final normalized = value.trim().toLowerCase();
        if (normalized == 'true' || normalized == '1' || normalized == 'yes') {
          return true;
        }
        if (normalized == 'false' || normalized == '0' || normalized == 'no') {
          return false;
        }
      }
      return null;
    }

    try {
      final decoded = jsonDecode(cached);
      if (decoded is! Map) return;
      final map = Map<String, dynamic>.from(decoded);
      final hydrated = <String, bool>{};
      for (final entry in map.entries) {
        final phone = entry.key.replaceAll(RegExp(r'\D'), '');
        if (phone.length < 10) continue;
        final parsed = parseBool(entry.value);
        if (parsed == null) continue;
        hydrated[phone] = parsed;
      }
      if (hydrated.isEmpty) return;
      setState(() {
        _existingCustomerByPhone
          ..clear()
          ..addAll(hydrated);
      });
    } catch (e) {
      debugPrint('Error decoding cached existing customers: $e');
    }
  }

  Future<void> _persistExistingCustomersCache() async {
    final cacheKey = _branchScopedCacheKey(_cachedExistingCustomersPrefix);
    if (cacheKey == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        cacheKey,
        jsonEncode(Map<String, bool>.from(_existingCustomerByPhone)),
      );
    } catch (e) {
      debugPrint('Error caching existing customers: $e');
    }
  }

  Future<void> _loadInitialData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _token = prefs.getString('token');
      _branchId = prefs.getString('branchId');
      _branchName = prefs.getString('branchName')?.trim();
      _currentWaiterName = prefs.getString('user_name')?.trim();
      _candidateWaiterKeys = WaiterCallRangeFilterService.resolveCandidateUserKeysFromPrefs(prefs);

      // Load cached tables immediately to avoid the spinner
      final cachedTables = prefs.getString(
        '$_cachedTablesPrefix${_branchId ?? ''}',
      );
      if (cachedTables != null) {
        try {
          _tables = jsonDecode(cachedTables);
          _isLoading = false; // We have data, don't show the full-page loader
        } catch (e) {
          debugPrint('Error decoding cached tables: $e');
        }
      }
    });
    _hydrateCachedPendingBills(prefs);
    _hydrateCachedExistingCustomers(prefs);

    if (_token != null && _branchId != null) {
      // Load config and data in parallel to minimize "first-open" latency.
      unawaited(_loadCustomerDetailsVisibilityConfig());
      unawaited(Future.wait([_fetchTables(), _fetchPendingBills()]));
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Session expired or Branch ID not found.';
      });
    }
  }

  Future<void> _loadCustomerDetailsVisibilityConfig() async {
    final token = _token?.trim();
    final branchId = _branchId?.trim();
    if (token == null ||
        token.isEmpty ||
        branchId == null ||
        branchId.isEmpty) {
      return;
    }
    final config =
        await TableCustomerDetailsVisibilityService.getConfigForBranch(
          branchId: branchId,
          token: token,
          forceRefresh: false,
        );
    if (!mounted) return;
    setState(() {
      _customerDetailsVisibilityConfig = config;
    });
  }

  Future<void> _fetchTables() async {
    if (_tables.isEmpty) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final response = await http.get(
        Uri.parse(
          'https://blackforest3.vseyal.com/api/tables?where[branch][equals]=$_branchId&limit=1&depth=1',
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
            // Cache the fresh data
            unawaited(
              SharedPreferences.getInstance().then((prefs) {
                final cacheKey = _branchScopedCacheKey(_cachedTablesPrefix);
                if (cacheKey == null) return;
                prefs.setString(cacheKey, jsonEncode(_tables));
              }),
            );
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
        'https://blackforest3.vseyal.com/api/billings?where[status][in]=pending,ordered,confirmed,prepared,delivered&where[branch][equals]=$_branchId&where[createdAt][greater_than_equal]=$todayStart&limit=100&depth=2',
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
          if (_isSharedTablesSection(section, tableNumber)) {
            nextSharedBills.add(bill);
            continue;
          }
          final key = _tableKey(tableNumber, section);
          final existingBill = nextByTableKey[key];
          if (existingBill == null) {
            nextByTableKey[key] = bill;
          } else {
            // Keep the oldest bill as the primary table. Send newer bills to shared.
            if (_isNewerBill(existingBill, bill)) {
              nextSharedBills.add(existingBill);
              nextByTableKey[key] = bill;
            } else {
              nextSharedBills.add(bill);
            }
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
          unawaited(_persistPendingBillsCache());
        }

        final visibleBills = <dynamic>[
          ...nextByTableKey.values,
          ...filteredShared,
        ];
        unawaited(_resolveExistingCustomerBadgesForBills(visibleBills));
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

    final unallocatedTables = _getUnallocatedOnlineTables();
    if (unallocatedTables.isNotEmpty) {
      return CommonScaffold(
        title: 'Tables',
        pageType: PageType.table,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.amber,
                  size: 64,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Tables Pending Allocation',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'The following table(s) need waiter assignment:\n\n'
                  '${unallocatedTables.join("\n")}\n\n'
                  'Please alert the concern person to assign them. Tapping orders will be enabled after all tables are allocated.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: () {
                    _loadInitialData();
                  },
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Check Assignments'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            ),
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
                  tabs: allTabs
                      .map((cat) => Tab(child: _buildSectionTabLabel(cat)))
                      .toList(),
                ),
                Expanded(
                  child: TabBarView(
                    children: allTabs.map<Widget>((cat) {
                      if (cat == 'All Tables') {
                        return Padding(
                          padding: const EdgeInsets.all(16),
                          child: CustomScrollView(
                            slivers: [
                              ..._tables.expand<Widget>((section) {
                                final sectionName =
                                    section['name']?.toString() ?? 'General';
                                final tableCount =
                                    int.tryParse(
                                      section['tableCount']?.toString() ?? '0',
                                    ) ??
                                    0;
                                return _buildSliverCategorySection(
                                  sectionName,
                                  tableCount,
                                );
                              }),
                              SliverToBoxAdapter(
                                child: _buildSharedTablesSection(),
                              ),
                            ],
                          ),
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
                        shrinkWrap: false,
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

  bool _isTableOffline(String sectionName, int tableNumber) {
    final normalizedSection = _normalizeSectionName(sectionName);
    for (final section in _tables) {
      if (section is! Map) continue;
      final name = _normalizeSectionName(section['name']?.toString() ?? 'General');
      if (name == normalizedSection) {
        final offlineTablesRaw = section['offlineTables'];
        if (offlineTablesRaw is List) {
          for (final val in offlineTablesRaw) {
            if (val.toString().trim() == tableNumber.toString()) {
              return true;
            }
          }
        }
      }
    }
    return false;
  }

  bool _sectionHasAllocations(String sectionName) {
    final normalizedSection = _normalizeSectionName(sectionName);
    for (final section in _tables) {
      if (section is! Map) continue;
      final name = _normalizeSectionName(section['name']?.toString() ?? 'General');
      if (name == normalizedSection) {
        final allocations = section['waiterAllocations'];
        if (allocations is List && allocations.isNotEmpty) {
          return true;
        }
      }
    }
    return false;
  }

  bool _isTableAllocatedToMe(String sectionName, int tableNumber, List<String> candidateKeys) {
    if (candidateKeys.isEmpty) return false;
    final normalizedSection = _normalizeSectionName(sectionName);
    for (final section in _tables) {
      if (section is! Map) continue;
      final name = _normalizeSectionName(section['name']?.toString() ?? 'General');
      if (name == normalizedSection) {
        final allocations = section['waiterAllocations'];
        if (allocations is List) {
          for (final alloc in allocations) {
            if (alloc is! Map) continue;
            final rawNum = alloc['tableNumber']?.toString().trim() ?? '';
            if (rawNum != tableNumber.toString()) continue;

            final waiterVal = alloc['waiter'];
            String waiterId = '';
            String waiterName = '';
            if (waiterVal is String) {
              waiterId = waiterVal;
            } else if (waiterVal is Map) {
              waiterId = (waiterVal['id'] ?? waiterVal['_id'] ?? '').toString().trim();
              waiterName = (waiterVal['name'] ?? waiterVal['username'] ?? '').toString().trim().toLowerCase();
            }

            for (final candidate in candidateKeys) {
              if (candidate.isNotEmpty &&
                  (candidate == waiterId || candidate.toLowerCase() == waiterName)) {
                return true;
              }
            }
          }
        }
      }
    }
    return false;
  }

  String? _getTableAssignedWaiterName(String sectionName, int tableNumber) {
    final normalizedSection = _normalizeSectionName(sectionName);
    for (final section in _tables) {
      if (section is! Map) continue;
      final name = _normalizeSectionName(section['name']?.toString() ?? 'General');
      if (name == normalizedSection) {
        final allocations = section['waiterAllocations'];
        if (allocations is List) {
          for (final alloc in allocations) {
            if (alloc is! Map) continue;
            final rawNum = alloc['tableNumber']?.toString().trim() ?? '';
            if (rawNum != tableNumber.toString()) continue;

            final waiterVal = alloc['waiter'];
            if (waiterVal is Map) {
              final nameVal = waiterVal['name'] ?? waiterVal['username'];
              if (nameVal != null) {
                return nameVal.toString().trim();
              }
            }
          }
        }
      }
    }
    return null;
  }

  List<String> _getUnallocatedOnlineTables() {
    final unallocated = <String>[];
    for (final section in _tables) {
      if (section is! Map) continue;
      final sectionName = section['name']?.toString() ?? 'General';
      final List<int> tableNumbers = _resolveSectionTableNumbers(section);

      final offlineTablesRaw = section['offlineTables'];
      final offlineTableSet = <String>{};
      if (offlineTablesRaw is List) {
        for (final val in offlineTablesRaw) {
          offlineTableSet.add(val.toString().trim());
        }
      }

      final allocations = section['waiterAllocations'];
      final allocatedTableSet = <String>{};
      if (allocations is List) {
        for (final alloc in allocations) {
          if (alloc is! Map) continue;
          final rawNum = alloc['tableNumber']?.toString().trim() ?? '';
          final waiterVal = alloc['waiter'];
          String waiterId = '';
          if (waiterVal is String) {
            waiterId = waiterVal;
          } else if (waiterVal is Map) {
            waiterId = (waiterVal['id'] ?? waiterVal['_id'] ?? '').toString().trim();
          }
          if (rawNum.isNotEmpty && waiterId.isNotEmpty) {
            allocatedTableSet.add(rawNum);
          }
        }
      }

      for (final num in tableNumbers) {
        final numStr = num.toString();
        if (offlineTableSet.contains(numStr)) {
          continue;
        }
        if (!allocatedTableSet.contains(numStr)) {
          unallocated.add('$sectionName - Table $num');
        }
      }
    }
    return unallocated;
  }

  List<int> _resolveSectionTableNumbers(Map section) {
    final fromExplicitRows = _resolveFromExplicitTableNumbers(
      section['tableNumbers'],
    );
    if (fromExplicitRows.isNotEmpty) {
      return fromExplicitRows;
    }

    final fromRangeRows = _resolveFromRangeRows(section['rangeRows']);
    if (fromRangeRows.isNotEmpty) {
      return fromRangeRows;
    }

    final count = int.tryParse(section['tableCount']?.toString() ?? '0') ?? 0;
    if (count <= 0) {
      return const <int>[];
    }
    return List<int>.generate(count, (index) => index + 1, growable: false);
  }

  List<int> _resolveFromExplicitTableNumbers(dynamic rawRows) {
    final numbers = <int>{};
    for (final row in _asMapList(rawRows)) {
      final rawNumber = _readText(row['tableNumber']);
      final parsed = WaiterCallRangeFilterService.parseTableToken(rawNumber);
      if (parsed == null || parsed <= 0) continue;
      numbers.add(parsed);
    }

    final sorted = numbers.toList(growable: true)
      ..sort((a, b) => a.compareTo(b));
    return sorted;
  }

  List<int> _resolveFromRangeRows(dynamic rawRows) {
    final numbers = <int>{};
    for (final row in _asMapList(rawRows)) {
      final rawRange = _readText(row['tableRange']);
      if (rawRange.isEmpty) continue;
      final bounds = _parseRangeBounds(rawRange);
      if (bounds == null) continue;
      for (
        int tableNumber = bounds.start;
        tableNumber <= bounds.end;
        tableNumber++
      ) {
        numbers.add(tableNumber);
      }
    }

    final sorted = numbers.toList(growable: true)
      ..sort((a, b) => a.compareTo(b));
    return sorted;
  }

  _RangeBounds? _parseRangeBounds(String rawRange) {
    final normalized = rawRange.trim();
    if (normalized.isEmpty) return null;

    final hyphenMatch = RegExp(
      r'T?\s*(\d+)\s*[-–—]\s*T?\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (hyphenMatch != null) {
      final start = int.tryParse(_readText(hyphenMatch.group(1)));
      final end = int.tryParse(_readText(hyphenMatch.group(2)));
      if (start == null || end == null || start <= 0 || end <= 0) return null;
      return _RangeBounds(
        start: start <= end ? start : end,
        end: start <= end ? end : start,
      );
    }

    final singleMatch = RegExp(
      r'^T?\s*(\d+)$',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (singleMatch != null) {
      final value = int.tryParse(_readText(singleMatch.group(1)));
      if (value == null || value <= 0) return null;
      return _RangeBounds(start: value, end: value);
    }

    return null;
  }

  List<Map<String, dynamic>> _asMapList(dynamic value) {
    if (value is! List) return const <Map<String, dynamic>>[];
    final rows = <Map<String, dynamic>>[];
    for (final item in value) {
      if (item is Map) {
        rows.add(Map<String, dynamic>.from(item));
      }
    }
    return rows;
  }

  String _readText(dynamic value) {
    return value?.toString().trim() ?? '';
  }

  Color _getTableColor(dynamic runningBill) {
    if (runningBill == null) {
      return const Color(0xFFEEEEEE);
    }

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

  List<Widget> _buildSliverCategorySection(
    String categoryName,
    int tableCount,
  ) {
    final existingCustomerTables = _existingCustomerTablesInSection(
      categoryName,
    );
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            children: [
              Text(
                categoryName.toUpperCase(),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
              if (existingCustomerTables.isNotEmpty) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: existingCustomerTables
                          .map(
                            (table) => Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: _buildExistingCustomerTableBadge(
                                tableNumber: table.tableNumber,
                                onTap: () => _openCustomerHistoryForTableBill(
                                  table.runningBill,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final tableNumber = index + 1;
          final tableNumberText = tableNumber.toString();

          final runningBill = _findRunningBillForGrid(
            tableNumber: tableNumberText,
            sectionName: categoryName,
          );

          final isOffline = _isTableOffline(categoryName, tableNumber);
          final hasAllocations = _sectionHasAllocations(categoryName);
          final isAllocatedToMe = _isTableAllocatedToMe(categoryName, tableNumber, _candidateWaiterKeys);
          final isLocked = hasAllocations && !isAllocatedToMe;
          final assignedWaiterName = _getTableAssignedWaiterName(categoryName, tableNumber);

          return _buildTableTile(
            tableLabel: 'Table $tableNumber',
            runningBill: runningBill,
            isOffline: isOffline,
            isLocked: isLocked,
            assignedWaiterName: assignedWaiterName,
            onTap: () {
              if (isOffline) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('This table is offline')),
                );
                return;
              }
              if (isLocked) {
                final msg = assignedWaiterName != null
                    ? 'Table $tableNumber is allocated to $assignedWaiterName'
                    : 'Table $tableNumber is not allocated to you';
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(msg)),
                );
                return;
              }
              _handleTableTap(
                runningBill,
                tableNumber,
                categoryName,
                openCart: false,
              );
            },
            onDoubleTap: () {
              if (isOffline || isLocked) return;
              _handleTableTap(
                runningBill,
                tableNumber,
                categoryName,
                openCart: true,
              );
            },
          );
        }, childCount: tableCount),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ];
  }

  Widget _buildCategorySection(String categoryName, int tableCount) {
    final existingCustomerTables = _existingCustomerTablesInSection(
      categoryName,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            children: [
              Text(
                categoryName.toUpperCase(),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
              if (existingCustomerTables.isNotEmpty) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: existingCustomerTables
                          .map(
                            (table) => Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: _buildExistingCustomerTableBadge(
                                tableNumber: table.tableNumber,
                                onTap: () => _openCustomerHistoryForTableBill(
                                  table.runningBill,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
              ],
            ],
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
    bool isOffline = false,
    bool isLocked = false,
    String? assignedWaiterName,
  }) {
    final isRunning = runningBill != null;
    final isExistingCustomer = isRunning && _hasExistingCustomer(runningBill);
    final hasBadge = isRunning;
    final badgeHeight = hasBadge ? 14.0 : 0.0;
    final tableLabelFontSize = hasBadge ? 16.0 : 18.0;
    final kotFontSize = hasBadge ? 10.5 : 12.0;
    final waiterFontSize = hasBadge ? 9.0 : 10.0;
    final runningMetaGap = hasBadge ? 2.0 : 4.0;
    final waiterGap = hasBadge ? 1.0 : 2.0;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        borderRadius: BorderRadius.circular(8),
        child: CustomPaint(
          painter: !isRunning && !isOffline && !isLocked && showDashedWhenIdle
              ? DashedBorderPainter()
              : null,
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: isOffline || isLocked ? const Color(0xFFF5F5F5) : _getTableColor(runningBill),
              borderRadius: BorderRadius.circular(8),
              border: isOffline || isLocked
                  ? Border.all(color: const Color(0xFFE0E0E0), width: 1.2)
                  : null,
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
            child: Stack(
              children: [
                Padding(
                  padding: EdgeInsets.only(top: badgeHeight),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 3,
                        vertical: 2,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (isRunning)
                            _buildRunningTimeWidget(
                              runningBill,
                              compact: hasBadge,
                            ),
                          Text(
                            tableLabel,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: tableLabelFontSize,
                              fontWeight: isRunning
                                  ? FontWeight.bold
                                  : FontWeight.w500,
                              color: isOffline || isLocked ? Colors.grey[400] : Colors.black87,
                            ),
                          ),
                          if (isOffline) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Offline',
                              style: TextStyle(
                                fontSize: waiterFontSize,
                                fontWeight: FontWeight.w600,
                                color: Colors.red[300],
                              ),
                            ),
                          ] else if (isLocked) ...[
                            const SizedBox(height: 4),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.lock_outline,
                                  size: 11,
                                  color: Colors.grey[400],
                                ),
                                const SizedBox(width: 2),
                                Flexible(
                                  child: Text(
                                    assignedWaiterName != null ? 'For $assignedWaiterName' : 'Locked',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: waiterFontSize,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.grey[400],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ] else if (isRunning) ...[
                            SizedBox(height: runningMetaGap),
                            Text(
                              _kotLabel(runningBill),
                              style: TextStyle(
                                fontSize: kotFontSize,
                                fontWeight: FontWeight.w600,
                                color: Colors.black.withValues(alpha: 0.62),
                              ),
                            ),
                            SizedBox(height: waiterGap),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: Text(
                                'By: ${_waiterLabel(runningBill)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: waiterFontSize,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.black.withValues(alpha: 0.5),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                if (isRunning)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Container(
                        height: badgeHeight,
                        decoration: BoxDecoration(
                          color: isExistingCustomer
                              ? const Color(0xFF0A84FF)
                              : const Color(0xFFFFCC00),
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(8),
                            topRight: Radius.circular(8),
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          (() {
                            final name = _extractCustomerNameForHistory(runningBill);
                            if (name != null && name.isNotEmpty) {
                              return name.toUpperCase();
                            }
                            return isExistingCustomer ? 'EXISTING CUSTOMER' : 'NEW CUSTOMER';
                          })(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 8,
                            fontWeight: FontWeight.w700,
                            color: isExistingCustomer
                                ? Colors.white
                                : Colors.black,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRunningTimeWidget(dynamic runningBill, {bool compact = false}) {
    final createdAtStr = runningBill['createdAt']?.toString();
    if (createdAtStr == null) return const SizedBox();

    final createdAt = DateTime.tryParse(createdAtStr);
    if (createdAt == null) return const SizedBox();

    final diff = DateTime.now().difference(createdAt);
    if (diff.isNegative) return const SizedBox();

    final minutes = diff.inMinutes.toString().padLeft(2, '0');
    final seconds = (diff.inSeconds % 60).toString().padLeft(2, '0');

    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 2 : 4),
      child: Text(
        '$minutes:$seconds',
        style: TextStyle(
          fontSize: compact ? 13 : 16,
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

  String _waiterLabel(dynamic runningBill) {
    String readText(dynamic value) => value?.toString().trim() ?? '';

    if (runningBill is Map) {
      final bill = Map<String, dynamic>.from(runningBill);
      
      bool hasSourceHint(dynamic value) {
        final normalized = value?.toString().trim().toLowerCase() ?? '';
        if (normalized.isEmpty) return false;
        return normalized.contains('qr') ||
            normalized.contains('website') ||
            normalized.contains('web') ||
            normalized.contains('online');
      }

      bool containsQrHints(Map<String, dynamic> b) {
        const boolKeys = [
          'isQrOrder', 'isQRorder', 'isQR', 'qrOrder',
          'isWebsiteOrder', 'websiteOrder', 'isWebOrder', 'isOnlineOrder',
        ];
        const sourceKeys = [
          'source', 'orderSource', 'sourceType', 'orderChannel',
          'channel', 'origin', 'platform', 'placedVia', 'createdFrom', 'mode',
        ];
        for (final key in boolKeys) {
          final val = b[key];
          if (val == true || val?.toString().toLowerCase() == 'true' || val?.toString() == '1') return true;
        }
        for (final key in sourceKeys) {
          if (hasSourceHint(b[key])) return true;
        }
        return false;
      }

      final doc = bill['doc'] is Map ? Map<String, dynamic>.from(bill['doc']) : <String, dynamic>{};
      
      String? resolvedWaiterName;
      bool isBranchRole = false;
      final createdBy = runningBill['createdBy'];
      if (createdBy is Map) {
        final user = Map<String, dynamic>.from(createdBy);
        isBranchRole = user['role']?.toString().toLowerCase() == 'branch';
        resolvedWaiterName = [
          user['name'],
          user['username'],
          user['fullName'],
          user['displayName'],
        ].map(readText).firstWhere((value) => value.isNotEmpty, orElse: () => '');
        if (resolvedWaiterName.isEmpty) {
          final employee = user['employee'];
          if (employee is Map) {
            resolvedWaiterName = readText(employee['name']);
          }
        }
      }
      if (resolvedWaiterName == null || resolvedWaiterName.isEmpty) {
        resolvedWaiterName = [
          runningBill['createdByName'],
          runningBill['waiterName'],
          runningBill['assignedBy'],
        ].map(readText).firstWhere((value) => value.isNotEmpty, orElse: () => '');
      }

      final isBranchOrder = isBranchRole || (_branchName != null &&
          _branchName!.isNotEmpty &&
          resolvedWaiterName != null &&
          resolvedWaiterName.toLowerCase() == _branchName!.toLowerCase());
          
      final isQrOrder = containsQrHints(bill) || containsQrHints(doc) || isBranchOrder;

      if (isQrOrder) {
        String? custName;
        final customerDetails = bill['customerDetails'] ?? doc['customerDetails'];
        if (customerDetails is Map && customerDetails['name'] != null && customerDetails['name'].toString().trim().isNotEmpty) {
          custName = customerDetails['name'].toString().trim();
        } else if (bill['customerName'] != null && bill['customerName'].toString().trim().isNotEmpty) {
          custName = bill['customerName'].toString().trim();
        } else if (doc['customerName'] != null && doc['customerName'].toString().trim().isNotEmpty) {
          custName = doc['customerName'].toString().trim();
        } else if (doc['name'] != null && doc['name'].toString().trim().isNotEmpty) {
          custName = doc['name'].toString().trim();
        } else if (bill['name'] != null && bill['name'].toString().trim().isNotEmpty) {
          custName = bill['name'].toString().trim();
        }

        if (custName != null && custName.isNotEmpty && custName.toLowerCase() != 'unknown') {
          return custName;
        }
      }
      
      if (resolvedWaiterName != null && resolvedWaiterName.isNotEmpty) {
        return resolvedWaiterName;
      }
    }

    final fallback = [
      runningBill is Map ? runningBill['createdByName'] : null,
      runningBill is Map ? runningBill['waiterName'] : null,
      runningBill is Map ? runningBill['assignedBy'] : null,
    ].map(readText).firstWhere((value) => value.isNotEmpty, orElse: () => '');

    return fallback.isNotEmpty ? fallback : 'N/A';
  }

  bool _hasExistingCustomer(dynamic runningBill) {
    if (runningBill is! Map) return false;

    final bill = Map<String, dynamic>.from(runningBill);

    Map<String, dynamic>? asMap(dynamic value) {
      if (value is Map) {
        return Map<String, dynamic>.from(value);
      }
      return null;
    }

    bool? parseBool(dynamic value) {
      if (value is bool) return value;
      if (value is num) {
        if (value == 1) return true;
        if (value == 0) return false;
      }
      if (value is String) {
        final normalized = value.trim().toLowerCase();
        if (normalized.isEmpty) return null;
        if (normalized == 'true' ||
            normalized == '1' ||
            normalized == 'yes' ||
            normalized == 'on' ||
            normalized == 'enabled') {
          return true;
        }
        if (normalized == 'false' ||
            normalized == '0' ||
            normalized == 'no' ||
            normalized == 'off' ||
            normalized == 'disabled') {
          return false;
        }
      }
      return null;
    }

    int parseInt(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value.trim()) ?? 0;
      return 0;
    }

    final customer = asMap(bill['customerDetails']);

    final explicitExisting =
        parseBool(bill['isExistingCustomer']) ??
        parseBool(customer?['isExistingCustomer']) ??
        parseBool(bill['existingCustomer']) ??
        parseBool(customer?['existingCustomer']);
    if (explicitExisting == true) return true;

    final explicitNew =
        parseBool(bill['isNewCustomer']) ??
        parseBool(customer?['isNewCustomer']) ??
        parseBool(bill['newCustomer']) ??
        parseBool(customer?['newCustomer']);
    if (explicitNew == true) return false;
    if (explicitNew == false) return true;

    // Do not treat "has customer id" as existing. First running bill can still
    // have a customer object/id, but should remain new when there is no
    // previous history.
    final completedOrHistoryCount =
        parseInt(customer?['historyCount']) +
        parseInt(customer?['completedBills']) +
        parseInt(bill['historyCount']) +
        parseInt(bill['completedBills']);
    if (completedOrHistoryCount > 0) return true;

    final normalizedPhone = _extractNormalizedCustomerPhone(bill);
    final totalBillsHint = [
      parseInt(customer?['totalBills']),
      parseInt(bill['totalBills']),
    ].fold<int>(0, (maxSoFar, value) => value > maxSoFar ? value : maxSoFar);

    // If bill-level counters already show more than one bill, we can mark as
    // existing immediately without waiting for lookup.
    if (totalBillsHint > 1) return true;

    // Without phone we cannot verify previous bills precisely, so keep a
    // conservative fallback using total bills hint.
    if (normalizedPhone == null || normalizedPhone.isEmpty) {
      return totalBillsHint > 0;
    }

    final cachedExisting = _existingCustomerByPhone[normalizedPhone];
    if (cachedExisting != null) {
      return cachedExisting;
    }

    return false;
  }

  List<_ExistingCustomerSectionTable> _existingCustomerTablesInSection(
    String sectionName,
  ) {
    final normalizedSection = _normalizeSectionName(sectionName);
    final existingTables = <_ExistingCustomerSectionTable>[];
    final seenTableNumbers = <String>{};
    for (final bill in _pendingBillsByTableKey.values) {
      if (bill is! Map) continue;
      final details = bill['tableDetails'];
      if (details is! Map) continue;
      final billSection = _normalizeSectionName(
        details['section']?.toString() ?? '',
      );
      if (billSection != normalizedSection) continue;
      if (!_hasExistingCustomer(bill)) continue;
      final tableNumber = details['tableNumber']?.toString().trim();
      if (tableNumber == null || tableNumber.isEmpty) continue;
      if (seenTableNumbers.contains(tableNumber)) continue;
      seenTableNumbers.add(tableNumber);
      existingTables.add(
        _ExistingCustomerSectionTable(
          tableNumber: tableNumber,
          runningBill: bill,
        ),
      );
    }
    existingTables.sort((a, b) {
      final aNum = int.tryParse(a.tableNumber);
      final bNum = int.tryParse(b.tableNumber);
      if (aNum != null && bNum != null) return aNum.compareTo(bNum);
      if (aNum != null) return -1;
      if (bNum != null) return 1;
      return a.tableNumber.compareTo(b.tableNumber);
    });
    return existingTables;
  }

  Widget _buildExistingCustomerTableBadge({
    required String tableNumber,
    required VoidCallback onTap,
  }) {
    final numberFontSize = tableNumber.length >= 3 ? 13.0 : 15.0;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          width: 34,
          height: 34,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                center: Alignment(-0.25, -0.35),
                radius: 0.95,
                colors: <Color>[
                  Color(0xFFF5F7FA),
                  Color(0xFFD5DBE3),
                  Color(0xFFAFB8C4),
                ],
                stops: <double>[0.05, 0.56, 1.0],
              ),
              border: Border.all(color: const Color(0xFF8F99A7), width: 1.4),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x334A5563),
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Center(
              child: Text(
                tableNumber,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: numberFontSize,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF3F4752),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openCustomerHistoryForTableBill(dynamic runningBill) async {
    final normalizedPhone = _extractNormalizedCustomerPhone(runningBill);
    if (normalizedPhone == null || normalizedPhone.length < 10) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Customer phone is not available for this table.'),
        ),
      );
      return;
    }
    await showCustomerHistoryDialog(
      context,
      phoneNumber: normalizedPhone,
      customerName: _extractCustomerNameForHistory(runningBill),
    );
  }

  Widget _buildSectionTabLabel(String categoryName) {
    return Row(mainAxisSize: MainAxisSize.min, children: [Text(categoryName)]);
  }

  String? _extractNormalizedCustomerPhone(dynamic rawBill) {
    if (rawBill is! Map) return null;
    final bill = Map<String, dynamic>.from(rawBill);
    final customerDetails = bill['customerDetails'];
    final customer = customerDetails is Map
        ? Map<String, dynamic>.from(customerDetails)
        : null;

    final candidates = <dynamic>[
      customer?['phoneNumber'],
      customer?['phone'],
      bill['customerPhone'],
      bill['phoneNumber'],
    ];
    for (final value in candidates) {
      final normalized = value?.toString().replaceAll(RegExp(r'\D'), '') ?? '';
      if (normalized.length >= 10) {
        return normalized;
      }
    }
    return null;
  }

  String? _extractCustomerNameForHistory(dynamic rawBill) {
    if (rawBill is! Map) return null;
    final bill = Map<String, dynamic>.from(rawBill);
    final customerDetails = bill['customerDetails'];
    if (customerDetails is Map) {
      final fromCustomerDetails = customerDetails['name']?.toString().trim();
      if (fromCustomerDetails != null && fromCustomerDetails.isNotEmpty) {
        return fromCustomerDetails;
      }
    }
    final fromBill = bill['customerName']?.toString().trim();
    if (fromBill != null && fromBill.isNotEmpty) return fromBill;
    return null;
  }

  Future<void> _resolveExistingCustomerBadgesForBills(
    Iterable<dynamic> bills,
  ) async {
    if (!mounted) return;

    final phonesToLookup = <String>{};
    final runningBillIdsByPhone = <String, Set<String>>{};

    String? extractEntityId(dynamic raw) {
      if (raw == null) return null;
      if (raw is String) {
        final trimmed = raw.trim();
        return trimmed.isEmpty ? null : trimmed;
      }
      if (raw is num) return raw.toString();
      if (raw is Map) {
        final map = Map<String, dynamic>.from(raw);
        return extractEntityId(map['id']) ??
            extractEntityId(map['_id']) ??
            extractEntityId(map[r'$oid']) ??
            extractEntityId(map['value']);
      }
      return null;
    }

    int parseInt(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value.trim()) ?? 0;
      return 0;
    }

    for (final bill in bills) {
      final phone = _extractNormalizedCustomerPhone(bill);
      if (phone == null || phone.isEmpty) continue;
      final billId = extractEntityId(bill);
      if (billId != null) {
        runningBillIdsByPhone.putIfAbsent(phone, () => <String>{}).add(billId);
      }
      if (_existingCustomerByPhone.containsKey(phone)) continue;
      if (_existingCustomerLookupInFlight.contains(phone)) continue;
      phonesToLookup.add(phone);
    }

    if (phonesToLookup.isEmpty) return;
    final cartProvider = Provider.of<CartProvider>(context, listen: false);

    bool? classifyLookupPreview(
      Map<String, dynamic>? preview,
      Set<String> runningIds, {
      required bool allowUnknown,
    }) {
      if (preview == null) return null;
      final totalBills = (preview['totalBills'] as num?)?.toInt() ?? 0;
      final completedOrHistoryCount =
          parseInt(preview['historyCount']) +
          parseInt(preview['completedBills']) +
          parseInt(preview['completedBillsCount']);
      final isNew = preview['isNewCustomer'] == true;
      final previewBills = preview['bills'] is List
          ? List<dynamic>.from(preview['bills'] as List)
          : const <dynamic>[];
      final previewBillIds = previewBills
          .map(extractEntityId)
          .whereType<String>()
          .toSet();
      final includesRunningBill = previewBillIds.any(runningIds.contains);
      final nonRunningBillCount = previewBillIds
          .where((id) => !runningIds.contains(id))
          .length;
      final countBasedHistory = includesRunningBill
          ? totalBills > runningIds.length
          : totalBills > 0;
      final hasVerifiedHistory =
          !isNew &&
          (completedOrHistoryCount > 0 ||
              nonRunningBillCount > 0 ||
              countBasedHistory);
      if (hasVerifiedHistory) return true;

      final hasVerifiedNoHistory =
          isNew &&
          completedOrHistoryCount <= 0 &&
          nonRunningBillCount <= 0 &&
          totalBills <= runningIds.length;
      if (hasVerifiedNoHistory) return false;

      if (allowUnknown) return null;
      return false;
    }

    for (final phone in phonesToLookup) {
      _existingCustomerLookupInFlight.add(phone);
      unawaited(() async {
        bool? isExisting;
        final runningIds = runningBillIdsByPhone[phone] ?? const <String>{};
        try {
          final fastPreview = await cartProvider.fetchCustomerLookupPreview(
            phone,
            limit: 5,
            includeCancelled: false,
            useHeavyFallback: false,
            includeGlobalLookup: true,
          );
          isExisting = classifyLookupPreview(
            fastPreview,
            runningIds,
            allowUnknown: true,
          );

          if (isExisting != true) {
            final heavyPreview = await cartProvider.fetchCustomerLookupPreview(
              phone,
              limit: 15,
              includeCancelled: false,
              useHeavyFallback: true,
              includeGlobalLookup: true,
            );
            isExisting = classifyLookupPreview(
              heavyPreview,
              runningIds,
              allowUnknown: false,
            );
          }
        } catch (_) {
          isExisting = null;
        } finally {
          _existingCustomerLookupInFlight.remove(phone);
        }

        if (!mounted || isExisting == null) return;
        setState(() {
          _existingCustomerByPhone[phone] = isExisting!;
        });
        unawaited(_persistExistingCustomersCache());
      }());
    }
  }

  Widget _buildSharedTablesSection() {
    final visibleSharedBills = _sharedPendingBills.where((runningBill) {
      final tableDetails = runningBill['tableDetails'] ?? {};
      final rawTableNumber = tableDetails['tableNumber']?.toString() ?? '';
      final tableNumberStr = rawTableNumber.split('-S-').first;
      final tableNumberInt = int.tryParse(tableNumberStr) ?? 0;
      final sectionName = tableDetails['section']?.toString() ?? CartProvider.sharedTablesSectionName;

      final hasAllocations = _sectionHasAllocations(sectionName);
      if (!hasAllocations) return true;

      return _isTableAllocatedToMe(sectionName, tableNumberInt, _candidateWaiterKeys);
    }).toList();

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
        if (visibleSharedBills.isEmpty)
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
            itemCount: visibleSharedBills.length,
            itemBuilder: (context, index) {
              final runningBill = visibleSharedBills[index];
              final tableDetails = runningBill['tableDetails'] ?? {};
              final rawTableNumber =
                  tableDetails['tableNumber']?.toString() ?? 'N/A';
              final tableNumber = rawTableNumber.split('-S-').first;
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
        final tableNumberText = tableNumber.toString();

        final runningBill = _findRunningBillForGrid(
          tableNumber: tableNumberText,
          sectionName: sectionName,
        );

          final isOffline = _isTableOffline(sectionName, tableNumber);
          final hasAllocations = _sectionHasAllocations(sectionName);
          final isAllocatedToMe = _isTableAllocatedToMe(sectionName, tableNumber, _candidateWaiterKeys);
          final isLocked = hasAllocations && !isAllocatedToMe;
          final assignedWaiterName = _getTableAssignedWaiterName(sectionName, tableNumber);

          return _buildTableTile(
            tableLabel: 'Table $tableNumber',
            runningBill: runningBill,
            isOffline: isOffline,
            isLocked: isLocked,
            assignedWaiterName: assignedWaiterName,
            onTap: () {
              if (isOffline) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('This table is offline')),
                );
                return;
              }
              if (isLocked) {
                final msg = assignedWaiterName != null
                    ? 'Table $tableNumber is allocated to $assignedWaiterName'
                    : 'Table $tableNumber is not allocated to you';
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(msg)),
                );
                return;
              }
              _handleTableTap(
                runningBill,
                tableNumber,
                sectionName,
                openCart: false,
              );
            },
            onDoubleTap: () {
              if (isOffline || isLocked) return;
              _handleTableTap(
                runningBill,
                tableNumber,
                sectionName,
                openCart: true,
              );
            },
          );
      },
    );
  }

  // ignore: unused_element
  Future<Map<String, dynamic>?> _showCustomerDetailsDialog(
    CartProvider cartProvider, {
    bool allowSkip = true,
    bool showHistory = true,
    bool enableAutoSubmit = true,
    bool requireCompleteDetails = false,
  }) async {
    final enableCustomerLookup = _enableCustomerLookup;
    final nameCtrl = TextEditingController(
      text: cartProvider.customerName ?? '',
    );
    final phoneCtrl = TextEditingController(
      text: cartProvider.customerPhone ?? '',
    );
    Timer? debounceTimer;
    bool isDialogActive = true;
    bool isDialogSubmitting = false;
    bool didCloseDialog = false;
    String latestLookupPhone = '';
    int lookupSequence = 0;
    Map<String, dynamic>? customerLookupData;
    bool isLookupInProgress = false;
    String? lookupError;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            void closeDialogSafely(Map<String, dynamic>? value) {
              if (didCloseDialog) return;
              didCloseDialog = true;
              setDialogState(() {
                isDialogSubmitting = true;
              });
              isDialogActive = false;
              lookupSequence += 1;
              debounceTimer?.cancel();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                final nav = Navigator.of(dialogContext);
                if (nav.canPop()) {
                  nav.pop(value);
                }
              });
            }

            int offerPageIndex = 0;
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

            String normalizePhone(String value) =>
                value.replaceAll(RegExp(r'\D'), '');
            Map<String, dynamic> buildDialogSubmitPayload(
              String customerName,
              String customerPhone,
            ) {
              return <String, dynamic>{
                'name': customerName,
                'phone': customerPhone,
              };
            }

            String? validateCustomerDetailsForSubmit() {
              final normalizedPhone = normalizePhone(phoneCtrl.text);
              final customerName = nameCtrl.text.trim();

              if (!requireCompleteDetails) {
                if (phoneCtrl.text.trim().isEmpty && customerName.isEmpty) {
                  return allowSkip
                      ? 'Please enter customer name or phone number, or use Skip'
                      : 'Please enter customer name or phone number';
                }
                return null;
              }

              if (normalizedPhone.length < 10 && customerName.isEmpty) {
                return 'Please enter customer name and a valid 10-digit phone number';
              }
              if (normalizedPhone.length < 10) {
                return 'Please enter a valid 10-digit customer phone number';
              }
              if (customerName.isEmpty) {
                return 'Please enter customer name';
              }
              return null;
            }

            bool autoSubmitIfReady(Map<String, dynamic>? lookupData) {
              if (!enableAutoSubmit) return false;
              if (!isDialogActive || isDialogSubmitting || didCloseDialog) {
                return false;
              }
              final normalizedPhone = normalizePhone(phoneCtrl.text);
              final lookupName = lookupData?['name']?.toString().trim() ?? '';
              final customerName = nameCtrl.text.trim();
              if (normalizedPhone.length < 10 ||
                  lookupName.isEmpty ||
                  customerName.isEmpty) {
                return false;
              }
              closeDialogSafely(
                buildDialogSubmitPayload(customerName, phoneCtrl.text.trim()),
              );
              return true;
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
            final customerEntryPercentageOfferData = readMap(
              customerLookupData?['customerEntryPercentageOfferPreview'],
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
            final totalPercentageOfferPreviewEligible =
                totalPercentageOfferData?['previewEligible'] == true;
            final customerEntryPercentageOfferEnabled =
                customerEntryPercentageOfferData?['enabled'] == true;
            final customerEntryPercentageOfferPreviewEligible =
                customerEntryPercentageOfferData?['previewEligible'] == true;

            final scheduleMatched =
                customerEntryPercentageOfferData?['scheduleMatched'] == true;
            final scheduleBlocked =
                customerEntryPercentageOfferData?['scheduleBlocked'] == true;

            final offerCards = <Widget>[
              if (customerEntryPercentageOfferEnabled)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF132323),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: const Color(0xFF26C6DA).withValues(alpha: 0.45),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: Builder(
                      builder: (context) {
                        final discountPercent = readMoney(
                          customerEntryPercentageOfferData?['discountPercent'],
                        );
                        return Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            const Text(
                              'Customer Entry Percentage Offer',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${discountPercent.toStringAsFixed(2)}% OFF',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Color(0xFF26C6DA),
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.2,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              scheduleMatched
                                  ? 'Auto-applies from backend'
                                  : 'Not active now (time window).',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: scheduleMatched
                                    ? Colors.white70
                                    : Colors.orangeAccent,
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              scheduleBlocked
                                  ? 'Check schedule in settings.'
                                  : customerEntryPercentageOfferPreviewEligible
                                  ? 'Eligible now.'
                                  : 'Eligibility is backend-validated.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: scheduleBlocked
                                    ? Colors.orangeAccent
                                    : customerEntryPercentageOfferPreviewEligible
                                    ? const Color(0xFF2EBF3B)
                                    : Colors.white70,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              if (eligibleProductOfferMatches.isNotEmpty)
                ...eligibleProductOfferMatches.map((match) {
                  final freeName =
                      match['freeProductName']?.toString().trim().isNotEmpty ==
                          true
                      ? match['freeProductName'].toString().trim()
                      : 'Free Product';
                  final freeQty = readMoney(match['predictedFreeQuantity']);
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121729),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: const Color(0xFF0A84FF).withValues(alpha: 0.45),
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Product to Product Offer',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '$freeName FREE x${formatQty(freeQty)}',
                            style: const TextStyle(
                              color: Color(0xFF0A84FF),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Text(
                            'Applied by backend for this table order.',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              if (eligibleProductPriceOfferMatches.isNotEmpty)
                ...eligibleProductPriceOfferMatches.map((match) {
                  final productName =
                      match['productName']?.toString().trim().isNotEmpty == true
                      ? match['productName'].toString().trim()
                      : 'Product';
                  final discountPerUnit = readMoney(match['discountPerUnit']);
                  final discountedUnits = readMoney(
                    match['predictedAppliedUnits'],
                  );
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF221A10),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: const Color(0xFFF7A400).withValues(alpha: 0.45),
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Product Price Offer',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '$productName discount ₹${discountPerUnit.toStringAsFixed(2)} x ${formatQty(discountedUnits)} unit(s)',
                            style: const TextStyle(
                              color: Color(0xFFF7A400),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Text(
                            'Applied by backend for this table order.',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              if (eligibleRandomOfferMatches.isNotEmpty)
                ...eligibleRandomOfferMatches.map((match) {
                  final productName =
                      match['productName']?.toString().trim().isNotEmpty == true
                      ? match['productName'].toString().trim()
                      : 'Random Product';
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF102123),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: const Color(0xFF00B8D9).withValues(alpha: 0.45),
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Random Product Offer',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '$productName (FREE x1)',
                            style: const TextStyle(
                              color: Color(0xFF00B8D9),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Text(
                            'Applied by backend for this table order.',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              if (creditOfferEligible)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF111E13),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: const Color(0xFF2EBF3B).withValues(alpha: 0.45),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Customer Credit Offer',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Eligible discount: ₹${readMoney(offerData?['offerAmount']).toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: Color(0xFF2EBF3B),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Text(
                          'Used in final billing submit (backend validation).',
                          style: TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
              if (totalPercentageOfferEnabled &&
                  totalPercentageOfferPreviewEligible)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1F172B),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: const Color(0xFF9B7DFF).withValues(alpha: 0.45),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Total Percentage Offer',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${readMoney(totalPercentageOfferData?['discountPercent']).toStringAsFixed(2)}% on final payable amount',
                          style: const TextStyle(
                            color: Color(0xFF9B7DFF),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Text(
                          'Applied by backend if higher-priority offers are not used.',
                          style: TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
            ];
            final normalizedPhoneForHistory = normalizePhone(phoneCtrl.text);
            final lookupTotalBills =
                (customerLookupData?['totalBills'] as num?)?.toInt() ?? 0;
            final lookupTotalAmount = readMoney(
              customerLookupData?['totalAmount'],
            );
            final lookupCustomerName =
                customerLookupData?['name']?.toString().trim() ?? '';
            final isExistingCustomerForHistory =
                customerLookupData != null &&
                customerLookupData?['isNewCustomer'] != true &&
                (lookupTotalBills > 0 ||
                    lookupTotalAmount > 0 ||
                    lookupCustomerName.isNotEmpty);
            final canOpenCustomerHistory =
                showHistory &&
                isExistingCustomerForHistory &&
                !isDialogSubmitting &&
                normalizedPhoneForHistory.length >= 10;

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
                          Row(
                            children: [
                              const Expanded(
                                child: Center(
                                  child: Text(
                                    "Customer Details",
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ],
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
                              textInputAction: enableAutoSubmit
                                  ? TextInputAction.done
                                  : TextInputAction.next,
                              style: const TextStyle(color: Colors.white),
                              onSubmitted: (_) {
                                if (autoSubmitIfReady(customerLookupData)) {
                                  return;
                                }
                                FocusScope.of(dialogContext).nextFocus();
                              },
                              onChanged: (val) {
                                if (!isDialogActive || isDialogSubmitting) {
                                  return;
                                }
                                setDialogState(() {});
                                final normalizedPhone = normalizePhone(val);
                                latestLookupPhone = normalizedPhone;
                                lookupSequence += 1;
                                if (normalizedPhone.length < 10) {
                                  debounceTimer?.cancel();
                                  setDialogState(() {
                                    customerLookupData = null;
                                    lookupError = null;
                                    isLookupInProgress = false;
                                  });
                                  return;
                                }
                                setDialogState(() {
                                  lookupError = null;
                                  isLookupInProgress = true;
                                });
                                debounceTimer?.cancel();
                                final requestId = lookupSequence;
                                debounceTimer = Timer(
                                  const Duration(milliseconds: 350),
                                  () async {
                                    if (!isDialogActive ||
                                        normalizedPhone != latestLookupPhone) {
                                      return;
                                    }

                                    try {
                                      final activeTableNumber =
                                          cartProvider.selectedTable?.trim() ??
                                          '';
                                      final activeSection =
                                          cartProvider.selectedSection
                                              ?.trim() ??
                                          '';
                                      const lookupFlowLabel = 'table';
                                      Map<String, dynamic>? data;
                                      if (enableCustomerLookup) {
                                        final combinedLookupStopwatch =
                                            Stopwatch()..start();
                                        data = await cartProvider
                                            .fetchCustomerData(
                                              normalizedPhone,
                                              isTableOrder: true,
                                              tableSection: activeSection,
                                              tableNumber: activeTableNumber,
                                            );
                                        combinedLookupStopwatch.stop();
                                        debugPrint(
                                          '⏱️ [Customer Lookup][$lookupFlowLabel] combined lookup: '
                                          '${combinedLookupStopwatch.elapsedMilliseconds}ms '
                                          '(phone=$normalizedPhone)',
                                        );
                                        final latestPhone = normalizePhone(
                                          phoneCtrl.text,
                                        );
                                        if (!isDialogActive ||
                                            !mounted ||
                                            latestPhone != normalizedPhone ||
                                            requestId != lookupSequence) {
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
                                        if (autoSubmitIfReady(data)) return;
                                      } else {
                                        final nameLookupStopwatch = Stopwatch()
                                          ..start();
                                        final quickData = await cartProvider
                                            .fetchCustomerLookupPreview(
                                              normalizedPhone,
                                              limit: 1,
                                              useHeavyFallback: false,
                                              includeGlobalLookup: false,
                                            );
                                        nameLookupStopwatch.stop();
                                        debugPrint(
                                          '⏱️ [Customer Lookup][$lookupFlowLabel] name lookup: '
                                          '${nameLookupStopwatch.elapsedMilliseconds}ms '
                                          '(phone=$normalizedPhone)',
                                        );
                                        final latestPhone = normalizePhone(
                                          phoneCtrl.text,
                                        );
                                        if (!isDialogActive ||
                                            !mounted ||
                                            latestPhone != normalizedPhone ||
                                            requestId != lookupSequence) {
                                          return;
                                        }

                                        final quickName =
                                            quickData?['name']
                                                ?.toString()
                                                .trim() ??
                                            '';
                                        final quickIsNewCustomer =
                                            quickData?['isNewCustomer'] == true;
                                        if (!quickIsNewCustomer &&
                                            quickName.isNotEmpty &&
                                            nameCtrl.text.trim().isEmpty) {
                                          nameCtrl.text = quickName;
                                        }

                                        setDialogState(() {
                                          customerLookupData = quickData;
                                          isLookupInProgress = false;
                                          lookupError = null;
                                        });
                                        if (autoSubmitIfReady(quickData)) {
                                          return;
                                        }

                                        final quickBills =
                                            (quickData?['totalBills'] as num?)
                                                ?.toInt() ??
                                            0;
                                        final quickAmount = readMoney(
                                          quickData?['totalAmount'],
                                        );
                                        if (quickBills <= 0 &&
                                            quickAmount <= 0) {
                                          unawaited(() async {
                                            final summaryLookupStopwatch =
                                                Stopwatch()..start();
                                            try {
                                              final summaryData =
                                                  await cartProvider
                                                      .fetchCustomerLookupPreview(
                                                        normalizedPhone,
                                                        limit: 1,
                                                        useHeavyFallback: true,
                                                        includeGlobalLookup:
                                                            true,
                                                      );
                                              summaryLookupStopwatch.stop();
                                              debugPrint(
                                                '⏱️ [Customer Lookup][$lookupFlowLabel] history summary backfill: '
                                                '${summaryLookupStopwatch.elapsedMilliseconds}ms '
                                                '(phone=$normalizedPhone)',
                                              );
                                              if (summaryData == null) return;

                                              final latestPhone =
                                                  normalizePhone(
                                                    phoneCtrl.text,
                                                  );
                                              if (!isDialogActive ||
                                                  !mounted ||
                                                  latestPhone !=
                                                      normalizedPhone ||
                                                  requestId != lookupSequence) {
                                                return;
                                              }

                                              final existing =
                                                  customerLookupData;
                                              final existingBills =
                                                  (existing?['totalBills']
                                                          as num?)
                                                      ?.toInt() ??
                                                  0;
                                              final existingAmount = readMoney(
                                                existing?['totalAmount'],
                                              );
                                              final summaryBills =
                                                  (summaryData['totalBills']
                                                          as num?)
                                                      ?.toInt() ??
                                                  0;
                                              final summaryAmount = readMoney(
                                                summaryData['totalAmount'],
                                              );
                                              final existingName =
                                                  existing?['name']
                                                      ?.toString()
                                                      .trim() ??
                                                  '';
                                              final summaryName =
                                                  summaryData['name']
                                                      ?.toString()
                                                      .trim() ??
                                                  '';

                                              final shouldUseSummary =
                                                  summaryBills >
                                                      existingBills ||
                                                  summaryAmount >
                                                      existingAmount ||
                                                  (existingName.isEmpty &&
                                                      summaryName.isNotEmpty);
                                              if (!shouldUseSummary) return;

                                              setDialogState(() {
                                                customerLookupData =
                                                    summaryData;
                                                lookupError = null;
                                              });
                                              autoSubmitIfReady(summaryData);
                                            } catch (e) {
                                              summaryLookupStopwatch.stop();
                                              debugPrint(
                                                '⚠️ [Customer Lookup][$lookupFlowLabel] history summary backfill failed '
                                                'after ${summaryLookupStopwatch.elapsedMilliseconds}ms '
                                                '(phone=$normalizedPhone): $e',
                                              );
                                            }
                                          }());
                                        }
                                      }
                                    } catch (e) {
                                      debugPrint("Lookup failed: $e");
                                      final latestPhone = normalizePhone(
                                        phoneCtrl.text,
                                      );
                                      if (!isDialogActive ||
                                          !mounted ||
                                          latestPhone != normalizedPhone ||
                                          requestId != lookupSequence) {
                                        return;
                                      }
                                      setDialogState(() {
                                        customerLookupData = null;
                                        isLookupInProgress = false;
                                        lookupError = enableCustomerLookup
                                            ? 'Unable to fetch customer details'
                                            : null;
                                      });
                                    }
                                  },
                                );
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
                          if (enableCustomerLookup && lookupError != null) ...[
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
                              textInputAction: TextInputAction.done,
                              style: const TextStyle(color: Colors.white),
                              onSubmitted: (_) {
                                if (autoSubmitIfReady(customerLookupData)) {
                                  return;
                                }
                                FocusScope.of(dialogContext).unfocus();
                              },
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
                          if (showHistory &&
                              isExistingCustomerForHistory &&
                              normalizedPhoneForHistory.length >= 10) ...[
                            const SizedBox(height: 14),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: canOpenCustomerHistory
                                    ? () async {
                                        await showCustomerHistoryDialog(
                                          dialogContext,
                                          phoneNumber: phoneCtrl.text,
                                          customerName: nameCtrl.text,
                                        );
                                      }
                                    : null,
                                icon: const Icon(
                                  Icons.history_rounded,
                                  color: Colors.white,
                                ),
                                label: const Text(
                                  'CUSTOMER HISTORY',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.3,
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF16A34A),
                                  foregroundColor: Colors.white,
                                  disabledBackgroundColor: const Color(
                                    0xFF2C3A2F,
                                  ),
                                  disabledForegroundColor: Colors.white54,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 13,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                            ),
                          ],
                          if (phoneCtrl.text.trim().isEmpty) ...[
                            const SizedBox(height: 12),
                            const Text(
                              'Enter customer phone number to apply offers',
                              style: TextStyle(
                                color: Colors.orangeAccent,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          if (customerLookupData != null &&
                              offerCards.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            const Text(
                              'Up to 2 offers per bill: Customer Entry Percentage + one backend-selected offer path.',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              height:
                                  130, // Slightly shorter for dialog density
                              child: PageView.builder(
                                reverse: false,
                                itemCount: offerCards.length,
                                onPageChanged: (index) {
                                  setDialogState(() {
                                    offerPageIndex = index;
                                  });
                                },
                                itemBuilder: (context, index) {
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 2,
                                    ),
                                    child: SizedBox.expand(
                                      child: offerCards[index],
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: List.generate(offerCards.length, (
                                index,
                              ) {
                                final isActive = index == offerPageIndex;
                                return AnimatedContainer(
                                  duration: const Duration(milliseconds: 180),
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 3,
                                  ),
                                  width: isActive ? 9 : 6,
                                  height: isActive ? 9 : 6,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: isActive
                                        ? const Color(0xFF0A84FF)
                                        : Colors.white24,
                                  ),
                                );
                              }),
                            ),
                          ],
                          const SizedBox(height: 28),
                          if (allowSkip)
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: isDialogSubmitting
                                        ? null
                                        : () {
                                            closeDialogSafely(
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
                                    onPressed: isDialogSubmitting
                                        ? null
                                        : () {
                                            final validationMessage =
                                                validateCustomerDetailsForSubmit();
                                            if (validationMessage != null) {
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    validationMessage,
                                                  ),
                                                ),
                                              );
                                              return;
                                            }

                                            closeDialogSafely(
                                              buildDialogSubmitPayload(
                                                nameCtrl.text.trim(),
                                                phoneCtrl.text.trim(),
                                              ),
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
                                onPressed: isDialogSubmitting
                                    ? null
                                    : () {
                                        final validationMessage =
                                            validateCustomerDetailsForSubmit();
                                        if (validationMessage != null) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(validationMessage),
                                            ),
                                          );
                                          return;
                                        }

                                        closeDialogSafely(
                                          buildDialogSubmitPayload(
                                            nameCtrl.text.trim(),
                                            phoneCtrl.text.trim(),
                                          ),
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
                    ),
                  ),
                  Positioned(
                    right: 8,
                    top: 8,
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: isDialogSubmitting
                          ? null
                          : () => closeDialogSafely(null),
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
    lookupSequence += 1;
    debounceTimer?.cancel();
    return result;
  }

  Timer? _tapTimer;

  void _handleTableTap(
    dynamic runningBill,
    int tableNumber,
    String sectionName, {
    required bool openCart,
  }) {
    // If we're already navigating or doing heavy work, ignore.
    // However, for double-tap to work, we need to allow the second tap to "override" or cancel the first one's timer.

    if (openCart) {
      // Double tap - cancel any pending single tap
      _tapTimer?.cancel();
      _tapTimer = null;
      _executeTableTap(runningBill, tableNumber, sectionName, openCart: true);
    } else {
      // Single tap - wait a bit to see if it's a double tap
      _tapTimer?.cancel();
      _tapTimer = Timer(const Duration(milliseconds: 250), () {
        _tapTimer = null;
        _executeTableTap(
          runningBill,
          tableNumber,
          sectionName,
          openCart: false,
        );
      });
    }
  }

  void _executeTableTap(
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

          double? readOptionalMoney(
            Map<String, dynamic> source,
            List<String> keys,
          ) {
            for (final key in keys) {
              if (!source.containsKey(key)) continue;
              final value = source[key];
              if (value == null) continue;
              if (value is num) return value.toDouble();
              if (value is String) {
                final parsed = double.tryParse(value);
                if (parsed != null) return parsed;
              }
            }
            return null;
          }

          final itemMap = item;
          final prod = item['product'];
          String? cid;
          final String pid = (prod is Map)
              ? (prod['id']?.toString() ??
                    prod['_id']?.toString() ??
                    prod[r'$oid']?.toString() ??
                    'unknown_product')
              : (prod?.toString() ?? 'unknown_product');
          final imageUrl = CartItem.resolveImageUrlFromProduct(
            prod,
            itemMap: itemMap,
          );
          String? dept;
          if (prod is Map) {
            // Get department
            final prodDept = prod['department'];
            if (prodDept is Map) {
              dept = prodDept['name']?.toString();
            } else if (prodDept is List &&
                prodDept.isNotEmpty &&
                prodDept.first is Map) {
              dept = prodDept.first['name']?.toString();
            } else if (prodDept != null) {
              dept = prodDept.toString();
            } else {
              // Try category department
              final cat = prod['category'];
              if (cat is Map) {
                final catDept = cat['department'];
                if (catDept is Map) {
                  dept = catDept['name']?.toString();
                } else if (catDept is List &&
                    catDept.isNotEmpty &&
                    catDept.first is Map) {
                  dept = catDept.first['name']?.toString();
                } else if (catDept != null) {
                  dept = catDept.toString();
                }
              }
            }
          }

          if (prod is Map) {
            final cat = prod['category'];
            if (cat is Map) {
              cid = (cat['id'] ?? cat['_id'] ?? cat[r'$oid'])?.toString();
            } else if (cat != null) {
              cid = cat.toString();
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
          final quantity = isRandomCustomerOfferItem
              ? 1.0
              : toSafeDouble(item['quantity']);
          final unitPrice = isReadOnlyOfferItem
              ? 0.0
              : toSafeDouble(
                  itemMap['effectiveUnitPrice'] ??
                      itemMap['unitPrice'] ??
                      itemMap['price'],
                );
          final expectedLineTotalFromPrice = (unitPrice * quantity) < 0
              ? 0.0
              : (unitPrice * quantity);
          final explicitLineTotal = readOptionalMoney(itemMap, [
            'finalLineTotal',
            'lineTotalInclusive',
            'lineTotal',
            'finalAmount',
            'amount',
          ]);
          final subtotalValue = hasSubtotal
              ? toSafeDouble(itemMap['subtotal'])
              : null;
          final taxableValue = readOptionalMoney(itemMap, [
            'taxableAmount',
            'taxable',
            'subTotal',
            'sub_total',
          ]);

          final productGstPercent = CartItem.extractEffectiveGstPercent(
            prod,
            branchId: _branchId,
          );
          final gstPercent = productGstPercent > 0
              ? productGstPercent
              : CartItem.parsePercent(
                  itemMap['gstRate'] ??
                  itemMap['gstPercent'] ??
                  itemMap['gst'] ??
                  itemMap['taxPercent'],
                );
          final lineSubtotal = isRandomCustomerOfferItem
              ? 0.0
              : subtotalValue != null
              ? subtotalValue
              : taxableValue != null
              ? taxableValue
              : explicitLineTotal != null && explicitLineTotal > 0
              ? (gstPercent > 0 ? (explicitLineTotal * 100) / (100 + gstPercent) : explicitLineTotal)
              : expectedLineTotalFromPrice > 0
              ? expectedLineTotalFromPrice
              : subtotalValue;

          return CartItem(
            id: pid,
            billingItemId: item['id']?.toString(),
            name: item['name'] ?? 'Unknown',
            price: isReadOnlyOfferItem ? 0.0 : unitPrice,
            gstPercent: gstPercent,
            imageUrl: imageUrl,
            quantity: quantity,
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

        final customerRaw = runningBill['customerDetails'];
        final Map<String, dynamic> customer = (customerRaw is Map)
            ? Map<String, dynamic>.from(customerRaw)
            : (customerRaw is List &&
                  customerRaw.isNotEmpty &&
                  customerRaw.first is Map)
            ? Map<String, dynamic>.from(customerRaw.first)
            : {};

        final tableDetailsRaw = runningBill['tableDetails'];
        final Map<String, dynamic> tableDetails = (tableDetailsRaw is Map)
            ? Map<String, dynamic>.from(tableDetailsRaw)
            : (tableDetailsRaw is List &&
                  tableDetailsRaw.isNotEmpty &&
                  tableDetailsRaw.first is Map)
            ? Map<String, dynamic>.from(tableDetailsRaw.first)
            : {};

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

        final hasExistingDraftForSameTable = cartProvider
            .hasDraftForTableSelection(
              table: targetTable,
              section: sectionName,
            );

        if (hasExistingDraftForSameTable) {
          debugPrint('🪑 Reopening table draft: $targetTable / $sectionName');
          cartProvider.setSelectedTableMetadata(targetTable, sectionName);
        } else if (currentTable == targetTable &&
            currentSection == targetSection) {
          cartProvider.clearCart();
          cartProvider.setSelectedTableMetadata(targetTable, sectionName);
          cartProvider.setCustomerDetails();
        } else {
          cartProvider.setSelectedTable(targetTable, sectionName);
          cartProvider.setCustomerDetails();
        }

        final hasCustomerDetailsAfterSelection =
            (cartProvider.customerName?.trim().isNotEmpty ?? false) ||
            (cartProvider.customerPhone?.trim().isNotEmpty ?? false);
        final shouldShowCustomerDetailsDialog =
            _customerDetailsVisibilityConfig
                .showCustomerDetailsForTableOrders &&
            !hasCustomerDetailsAfterSelection;

        if (shouldShowCustomerDetailsDialog) {
          final customerDetails = await _showCustomerDetailsDialog(
            cartProvider,
            allowSkip: _customerDetailsVisibilityConfig
                .allowSkipCustomerDetailsForTableOrders,
            showHistory: _customerDetailsVisibilityConfig
                .showCustomerHistoryForTableOrders,
            enableAutoSubmit: _customerDetailsVisibilityConfig
                .autoSubmitCustomerDetailsForTableOrders,
          );

          if (customerDetails == null) {
            return;
          }

          final customerName = customerDetails['name']?.toString().trim();
          final customerPhone = customerDetails['phone']?.toString().trim();
          cartProvider.setCustomerDetails(
            name: (customerName == null || customerName.isEmpty)
                ? null
                : customerName,
            phone: (customerPhone == null || customerPhone.isEmpty)
                ? null
                : customerPhone,
          );
        }
      }

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
      if (mounted) {
        unawaited(_fetchPendingBills());
      }
    } catch (e, stack) {
      debugPrint("Error in _executeTableTap: $e\n$stack");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${e.toString()}'),
            backgroundColor: Colors.red,
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

      final shouldShowCustomerDetailsDialog =
          _customerDetailsVisibilityConfig.showCustomerDetailsForTableOrders;

      if (shouldShowCustomerDetailsDialog) {
        final customerDetails = await _showCustomerDetailsDialog(
          cartProvider,
          allowSkip: _customerDetailsVisibilityConfig
              .allowSkipCustomerDetailsForTableOrders,
          showHistory: _customerDetailsVisibilityConfig
              .showCustomerHistoryForTableOrders,
          enableAutoSubmit: _customerDetailsVisibilityConfig
              .autoSubmitCustomerDetailsForTableOrders,
        );

        if (customerDetails == null) {
          cartProvider.clearCart();
          return;
        }

        final customerName = customerDetails['name']?.toString().trim();
        final customerPhone = customerDetails['phone']?.toString().trim();
        cartProvider.setCustomerDetails(
          name: (customerName == null || customerName.isEmpty)
              ? null
              : customerName,
          phone: (customerPhone == null || customerPhone.isEmpty)
              ? null
              : customerPhone,
        );
      }

      if (!mounted) return;
      FocusManager.instance.primaryFocus?.unfocus();

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) =>
              const CategoriesPage(sourcePage: PageType.table),
        ),
      );
      if (mounted) {
        unawaited(_fetchPendingBills());
      }
    } finally {
      _isHandlingTableTap = false;
    }
  }

  bool _isSharedTablesSection(String? section, String? tableNumber) {
    if (section == null) return false;
    if ((tableNumber ?? '').contains('-S-')) return true;
    return _normalizeSectionName(section) ==
        _normalizeSectionName(CartProvider.sharedTablesSectionName);
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

class _RangeBounds {
  const _RangeBounds({required this.start, required this.end});

  final int start;
  final int end;
}
