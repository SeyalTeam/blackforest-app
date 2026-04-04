import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/cart_provider.dart';

bool _isCustomerHistoryDialogOpen = false;

Future<void> showCustomerHistoryDialog(
  BuildContext context, {
  required String phoneNumber,
}) async {
  final normalizedPhone = phoneNumber.replaceAll(RegExp(r'\D'), '');
  if (normalizedPhone.length < 10) return;
  if (_isCustomerHistoryDialogOpen) return;

  _isCustomerHistoryDialogOpen = true;
  FocusManager.instance.primaryFocus?.unfocus();
  final navigator = Navigator.of(context, rootNavigator: true);
  try {
    await navigator.push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (ctx) =>
            _CustomerHistoryRouteScreen(phoneNumber: normalizedPhone),
      ),
    );
  } finally {
    _isCustomerHistoryDialogOpen = false;
  }
}

class _CustomerHistoryRouteScreen extends StatelessWidget {
  final String phoneNumber;
  const _CustomerHistoryRouteScreen({required this.phoneNumber});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xCC000000),
      body: SafeArea(
        child: Center(child: CustomerHistoryDialog(phoneNumber: phoneNumber)),
      ),
    );
  }
}

class CustomerHistoryDialog extends StatefulWidget {
  final String phoneNumber;
  const CustomerHistoryDialog({super.key, required this.phoneNumber});

  @override
  State<CustomerHistoryDialog> createState() => _CustomerHistoryDialogState();
}

class _BillPageResult {
  final List<Map<String, dynamic>> bills;
  final int? totalDocs;
  final String? phoneField;

  const _BillPageResult({
    this.bills = const [],
    this.totalDocs,
    this.phoneField,
  });
}

class _HistorySummaryResult {
  final int? totalBills;
  final double? totalAmount;
  final List<Map<String, dynamic>> bills;

  const _HistorySummaryResult({
    this.totalBills,
    this.totalAmount,
    this.bills = const [],
  });
}

class _CustomerHistoryDialogState extends State<CustomerHistoryDialog> {
  static const Duration _historyLoadTimeout = Duration(seconds: 12);
  static const int _initialBillLimit = 2;
  static const int _loadMoreBillLimit = 1;
  static const int _lookupPreviewBillLimit = 15;
  static const List<String> _possiblePhoneFields = [
    'customerDetails.phoneNumber',
    'customerDetails.phone',
    'customerPhone',
    'phoneNumber',
  ];

  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = false;
  List<Map<String, dynamic>> _bills = [];
  String? _error;
  String _normalizedPhone = '';
  String? _resolvedPhoneField;
  int? _knownTotalBills;
  int _nextSingleItemPage = _initialBillLimit + 1;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _fetchHistory();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 180) {
      _loadMoreHistory();
    }
  }

  Future<void> _fetchHistory() async {
    final normalizedPhone = widget.phoneNumber.replaceAll(RegExp(r'\D'), '');
    if (normalizedPhone.length < 10) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _bills = [];
        _error = "Enter a valid 10-digit phone number";
      });
      return;
    }

    _normalizedPhone = normalizedPhone;
    _resolvedPhoneField = null;
    _knownTotalBills = null;
    _nextSingleItemPage = _initialBillLimit + 1;

    if (mounted) {
      setState(() {
        _isLoading = true;
        _isLoadingMore = false;
        _hasMore = false;
        _error = null;
        _bills = [];
      });
    }

    try {
      final quickSummaryFuture = _fetchHistorySummary(
        normalizedPhone,
        useHeavyFallback: false,
      ).timeout(_historyLoadTimeout);
      final firstPage = await _fetchBillsPage(
        normalizedPhone: normalizedPhone,
        page: 1,
        limit: _initialBillLimit,
      ).timeout(_historyLoadTimeout);

      _resolvedPhoneField = firstPage.phoneField;
      _knownTotalBills = firstPage.totalDocs;

      final fastBills = _sortBillsByDate(firstPage.bills);
      if (fastBills.isNotEmpty) {
        _nextSingleItemPage = fastBills.length + 1;
        final hasMore = (_knownTotalBills != null && _knownTotalBills! > 0)
            ? fastBills.length < _knownTotalBills!
            : firstPage.bills.length >= _initialBillLimit;
        if (mounted) {
          setState(() {
            _bills = fastBills;
            _isLoading = false;
            _isLoadingMore = false;
            _hasMore = hasMore;
            _error = null;
          });
        }
        unawaited(
          _mergeSummaryInBackground(
            normalizedPhone: normalizedPhone,
            summaryFuture: quickSummaryFuture,
          ),
        );
        return;
      }

      final quickSummary = await quickSummaryFuture;
      var mergedInitialBills = _sortBillsByDate(
        _mergeUniqueBills([firstPage.bills, quickSummary.bills]),
      );
      var totalBillsHint = quickSummary.totalBills ?? firstPage.totalDocs;

      if (mergedInitialBills.isEmpty) {
        final heavySummary = await _fetchHistorySummary(
          normalizedPhone,
          useHeavyFallback: true,
        ).timeout(_historyLoadTimeout);
        mergedInitialBills = _sortBillsByDate(
          _mergeUniqueBills([mergedInitialBills, heavySummary.bills]),
        );
        totalBillsHint ??= heavySummary.totalBills;
      }

      _knownTotalBills = totalBillsHint;
      _nextSingleItemPage = mergedInitialBills.length + 1;
      final canLoadMore = (_knownTotalBills != null && _knownTotalBills! > 0)
          ? mergedInitialBills.length < _knownTotalBills!
          : firstPage.bills.length >= _initialBillLimit;
      final hasMore = mergedInitialBills.isNotEmpty && canLoadMore;
      if (mounted) {
        setState(() {
          _bills = mergedInitialBills;
          _isLoading = false;
          _isLoadingMore = false;
          _hasMore = hasMore;
          _error = null;
        });
      }
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _error = "History request timed out. Tap retry.";
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = "Unable to load customer history. Tap retry.";
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _mergeSummaryInBackground({
    required String normalizedPhone,
    required Future<_HistorySummaryResult> summaryFuture,
  }) async {
    try {
      final summary = await summaryFuture;
      if (!mounted || _normalizedPhone != normalizedPhone) return;

      final mergedBills = _sortBillsByDate(
        _mergeUniqueBills([_bills, summary.bills]),
      );
      final totalBillsHint = summary.totalBills ?? _knownTotalBills;
      final hasMore = (totalBillsHint != null && totalBillsHint > 0)
          ? mergedBills.length < totalBillsHint
          : _hasMore;

      if (!mounted) return;
      setState(() {
        _bills = mergedBills;
        _knownTotalBills = totalBillsHint;
        _hasMore = hasMore;
        if (_nextSingleItemPage <= mergedBills.length) {
          _nextSingleItemPage = mergedBills.length + 1;
        }
      });
    } catch (_) {}
  }

  Future<void> _loadMoreHistory() async {
    if (_isLoading || _isLoadingMore || !_hasMore || _normalizedPhone.isEmpty) {
      return;
    }

    if (mounted) {
      setState(() => _isLoadingMore = true);
    }

    try {
      final nextPage = await _fetchBillsPage(
        normalizedPhone: _normalizedPhone,
        page: _nextSingleItemPage,
        limit: _loadMoreBillLimit,
        phoneField: _resolvedPhoneField,
      ).timeout(_historyLoadTimeout);

      final incomingBills = _sortBillsByDate(nextPage.bills);
      final updatedBills = List<Map<String, dynamic>>.from(_bills);
      final seenKeys = updatedBills
          .map(_billKey)
          .where((k) => k.isNotEmpty)
          .toSet();

      for (final bill in incomingBills) {
        final key = _billKey(bill);
        if (key.isNotEmpty && seenKeys.contains(key)) continue;
        if (key.isNotEmpty) {
          seenKeys.add(key);
        }
        updatedBills.add(bill);
      }

      if (_resolvedPhoneField == null && nextPage.phoneField != null) {
        _resolvedPhoneField = nextPage.phoneField;
      }
      if (nextPage.totalDocs != null && nextPage.totalDocs! > 0) {
        _knownTotalBills = nextPage.totalDocs;
      }

      var hasMore = _hasMore;
      if (incomingBills.isEmpty) {
        hasMore = false;
      } else if (_knownTotalBills != null && _knownTotalBills! > 0) {
        hasMore = updatedBills.length < _knownTotalBills!;
      }

      if (incomingBills.isNotEmpty) {
        _nextSingleItemPage += incomingBills.length;
      } else {
        _nextSingleItemPage += 1;
      }

      if (mounted) {
        setState(() {
          _bills = updatedBills;
          _isLoadingMore = false;
          _hasMore = hasMore;
        });
      }
    } on TimeoutException {
      if (mounted) {
        setState(() => _isLoadingMore = false);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoadingMore = false);
      }
    }
  }

  String _billKey(Map<String, dynamic> bill) {
    return (bill['id'] ??
            bill['_id'] ??
            bill[r'$oid'] ??
            bill['invoiceNumber'] ??
            bill['kotNumber'] ??
            '')
        .toString();
  }

  List<Map<String, dynamic>> _sortBillsByDate(
    List<Map<String, dynamic>> bills,
  ) {
    final sorted = List<Map<String, dynamic>>.from(bills);
    sorted.sort((a, b) {
      final aDate =
          DateTime.tryParse(a['createdAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bDate =
          DateTime.tryParse(b['createdAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return bDate.compareTo(aDate);
    });
    return sorted;
  }

  List<String> _phoneCandidates(String normalizedPhone) {
    final candidates = <String>{};
    final trimmed = normalizedPhone.trim();
    if (trimmed.isNotEmpty) candidates.add(trimmed);
    if (trimmed.length > 10) {
      candidates.add(trimmed.substring(trimmed.length - 10));
    }
    return candidates.toList();
  }

  List<Map<String, dynamic>> _mergeUniqueBills(
    Iterable<List<Map<String, dynamic>>> billGroups,
  ) {
    final merged = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (final group in billGroups) {
      for (final bill in group) {
        final key = _billKey(bill);
        if (key.isNotEmpty && seen.contains(key)) continue;
        if (key.isNotEmpty) seen.add(key);
        merged.add(bill);
      }
    }
    return merged;
  }

  Future<_BillPageResult> _fetchBillsPage({
    required String normalizedPhone,
    required int page,
    required int limit,
    String? phoneField,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null || token.isEmpty) return const _BillPageResult();

      final headers = {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

      final fieldsToTry = phoneField == null
          ? _possiblePhoneFields
          : <String>[phoneField];
      final phoneValues = _phoneCandidates(normalizedPhone);

      for (final field in fieldsToTry) {
        for (final phoneValue in phoneValues) {
          final uri = Uri.parse('https://blackforest.vseyal.com/api/billings')
              .replace(
                queryParameters: {
                  'sort': '-createdAt',
                  'page': page.toString(),
                  'limit': limit.toString(),
                  'depth': '4',
                  'where[$field][equals]': phoneValue,
                  'where[status][not_equals]': 'cancelled',
                },
              );
          final response = await http
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 8));
          if (response.statusCode != 200) continue;

          final decoded = jsonDecode(response.body);
          final docs = _extractBillsFromPayload(decoded);
          final totalDocs = _extractTotalDocs(decoded);
          if (docs.isNotEmpty || (totalDocs != null && totalDocs > 0)) {
            return _BillPageResult(
              bills: docs,
              totalDocs: totalDocs,
              phoneField: field,
            );
          }
        }
      }
    } catch (_) {}
    return const _BillPageResult();
  }

  Future<_HistorySummaryResult> _fetchHistorySummary(
    String normalizedPhone, {
    bool useHeavyFallback = false,
  }) async {
    try {
      final cartProvider = Provider.of<CartProvider>(context, listen: false);
      final accurateData = await cartProvider.fetchCustomerLookupPreview(
        normalizedPhone,
        limit: _lookupPreviewBillLimit,
        includeCancelled: false,
        useHeavyFallback: useHeavyFallback,
      );
      if (accurateData != null) {
        final accurateBills = _extractBillsFromPayload(accurateData);
        final accurateTotalBills = _extractSummaryTotalBills(accurateData);
        final accurateAmount = _extractSummaryTotalAmount(accurateData);
        if (accurateTotalBills != null ||
            accurateAmount != null ||
            accurateBills.isNotEmpty) {
          return _HistorySummaryResult(
            totalBills: accurateTotalBills,
            totalAmount: accurateAmount,
            bills: accurateBills,
          );
        }
      }

      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null || token.isEmpty) return const _HistorySummaryResult();

      final headers = {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };
      final uri =
          Uri.parse(
            'https://blackforest.vseyal.com/api/billing/customer-lookup',
          ).replace(
            queryParameters: {
              'phoneNumber': normalizedPhone,
              'limit': '1',
              'includeCancelled': 'false',
            },
          );
      final response = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return const _HistorySummaryResult();

      final decoded = jsonDecode(response.body);
      final fallbackBills = _extractBillsFromPayload(decoded);
      return _HistorySummaryResult(
        totalBills: _extractSummaryTotalBills(decoded),
        totalAmount: _extractSummaryTotalAmount(decoded),
        bills: fallbackBills,
      );
    } catch (_) {
      return const _HistorySummaryResult();
    }
  }

  List<Map<String, dynamic>> _extractBillsFromPayload(dynamic payload) {
    if (payload is! Map) return const [];
    final map = Map<String, dynamic>.from(payload);
    final nestedData = map['data'] is Map
        ? Map<String, dynamic>.from(map['data'] as Map)
        : null;
    final nestedResult = map['result'] is Map
        ? Map<String, dynamic>.from(map['result'] as Map)
        : null;

    final candidates = <dynamic>[
      map['docs'],
      map['bills'],
      map['billings'],
      map['history'],
      nestedData?['docs'],
      nestedData?['bills'],
      nestedData?['billings'],
      nestedData?['history'],
      nestedResult?['docs'],
      nestedResult?['bills'],
      nestedResult?['billings'],
      nestedResult?['history'],
    ];

    for (final candidate in candidates) {
      if (candidate is! List || candidate.isEmpty) continue;
      final docs = <Map<String, dynamic>>[];
      for (final entry in candidate) {
        if (entry is Map) {
          docs.add(Map<String, dynamic>.from(entry));
        }
      }
      if (docs.isNotEmpty) return docs;
    }

    return const [];
  }

  int? _extractTotalDocs(dynamic payload) {
    int? asInt(dynamic value) {
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value);
      return null;
    }

    Map<String, dynamic>? asMap(dynamic value) {
      if (value is Map) return Map<String, dynamic>.from(value);
      return null;
    }

    if (payload is! Map) return null;
    final map = Map<String, dynamic>.from(payload);
    final data = asMap(map['data']);
    final result = asMap(map['result']);
    final meta = asMap(map['meta']);
    final pagination = asMap(map['pagination']);
    final dataMeta = asMap(data?['meta']);
    final dataPagination = asMap(data?['pagination']);
    final resultMeta = asMap(result?['meta']);
    final resultPagination = asMap(result?['pagination']);

    final candidates = <dynamic>[
      map['totalDocs'],
      map['total'],
      map['count'],
      map['totalBills'],
      data?['totalDocs'],
      data?['total'],
      data?['count'],
      data?['totalBills'],
      result?['totalDocs'],
      result?['total'],
      result?['count'],
      result?['totalBills'],
      meta?['totalDocs'],
      meta?['total'],
      meta?['count'],
      pagination?['totalDocs'],
      pagination?['total'],
      dataMeta?['totalDocs'],
      dataMeta?['total'],
      dataMeta?['count'],
      dataPagination?['totalDocs'],
      dataPagination?['total'],
      resultMeta?['totalDocs'],
      resultMeta?['total'],
      resultMeta?['count'],
      resultPagination?['totalDocs'],
      resultPagination?['total'],
    ];

    for (final candidate in candidates) {
      final parsed = asInt(candidate);
      if (parsed != null && parsed >= 0) return parsed;
    }
    return null;
  }

  int? _extractSummaryTotalBills(dynamic payload) {
    final map = _asMap(payload);
    if (map == null) return null;
    final data = _asMap(map['data']);
    final result = _asMap(map['result']);
    final summary = _asMap(map['summary']);
    final stats = _asMap(map['stats']);
    final history = _asMap(map['history']);
    final pagination = _asMap(map['pagination']);
    final meta = _asMap(map['meta']);

    final candidates = <dynamic>[
      map['totalBills'],
      map['billCount'],
      map['count'],
      map['historyCount'],
      map['totalDocs'],
      data?['totalBills'],
      data?['billCount'],
      data?['count'],
      data?['historyCount'],
      data?['totalDocs'],
      result?['totalBills'],
      result?['billCount'],
      result?['count'],
      result?['historyCount'],
      result?['totalDocs'],
      summary?['totalBills'],
      summary?['billCount'],
      summary?['count'],
      summary?['historyCount'],
      summary?['totalDocs'],
      stats?['totalBills'],
      stats?['billCount'],
      stats?['count'],
      stats?['historyCount'],
      stats?['totalDocs'],
      history?['totalBills'],
      history?['billCount'],
      history?['count'],
      history?['historyCount'],
      history?['totalDocs'],
      pagination?['total'],
      pagination?['totalDocs'],
      meta?['total'],
      meta?['totalDocs'],
    ];
    for (final candidate in candidates) {
      final parsed = _asInt(candidate);
      if (parsed != null && parsed >= 0) return parsed;
    }
    return null;
  }

  double? _extractSummaryTotalAmount(dynamic payload) {
    final map = _asMap(payload);
    if (map == null) return null;
    final data = _asMap(map['data']);
    final result = _asMap(map['result']);
    final summary = _asMap(map['summary']);
    final stats = _asMap(map['stats']);
    final history = _asMap(map['history']);

    final candidates = <dynamic>[
      map['totalAmount'],
      map['totalSpent'],
      map['totalSpend'],
      map['spentAmount'],
      map['spent'],
      map['lifetimeSpend'],
      map['customerSpend'],
      data?['totalAmount'],
      data?['totalSpent'],
      data?['totalSpend'],
      data?['spentAmount'],
      data?['spent'],
      data?['lifetimeSpend'],
      data?['customerSpend'],
      result?['totalAmount'],
      result?['totalSpent'],
      result?['totalSpend'],
      result?['spentAmount'],
      result?['spent'],
      result?['lifetimeSpend'],
      result?['customerSpend'],
      summary?['totalAmount'],
      summary?['totalSpent'],
      summary?['totalSpend'],
      summary?['spentAmount'],
      summary?['spent'],
      summary?['lifetimeSpend'],
      summary?['customerSpend'],
      stats?['totalAmount'],
      stats?['totalSpent'],
      stats?['totalSpend'],
      stats?['spentAmount'],
      stats?['spent'],
      stats?['lifetimeSpend'],
      stats?['customerSpend'],
      history?['totalAmount'],
      history?['totalSpent'],
      history?['totalSpend'],
      history?['spentAmount'],
      history?['spent'],
      history?['lifetimeSpend'],
      history?['customerSpend'],
    ];
    for (final candidate in candidates) {
      final parsed = _asDouble(candidate);
      if (parsed != null && parsed >= 0) return parsed;
    }
    return null;
  }

  Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  int? _asInt(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  double? _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
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
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.red),
                          ),
                          const SizedBox(height: 12),
                          ElevatedButton(
                            onPressed: _fetchHistory,
                            child: const Text("Retry"),
                          ),
                        ],
                      ),
                    )
                  : _bills.isEmpty
                  ? const Center(
                      child: Text(
                        "No history found",
                        style: TextStyle(color: Colors.white70),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount: _bills.length + (_isLoadingMore ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index >= _bills.length) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 20),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 320),
                              child: _ThermalReceiptCard(
                                child: ReceiptContent(bill: _bills[index]),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThermalReceiptCard extends StatelessWidget {
  final Widget child;

  const _ThermalReceiptCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return PhysicalShape(
      clipper: const _ReceiptPaperClipper(),
      color: const Color(0xFFFFFCF5),
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.28),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFFFFFEFB),
                  Color(0xFFF6F0E3),
                  Color(0xFFFFFCF4),
                ],
                stops: [0, 0.55, 1],
              ),
            ),
            child: child,
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.black.withValues(alpha: 0.08),
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.08),
                    ],
                    stops: const [0, 0.08, 1],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReceiptPaperClipper extends CustomClipper<Path> {
  static const double _toothWidth = 12;
  static const double _toothDepth = 7;

  const _ReceiptPaperClipper();

  @override
  Path getClip(Size size) {
    final path = Path()..moveTo(0, _toothDepth);

    var currentX = 0.0;
    while (currentX < size.width) {
      final midX = (currentX + (_toothWidth / 2)).clamp(0.0, size.width);
      final nextX = (currentX + _toothWidth).clamp(0.0, size.width);
      path.lineTo(midX, 0);
      path.lineTo(nextX, _toothDepth);
      currentX += _toothWidth;
    }

    path.lineTo(size.width, size.height - _toothDepth);

    currentX = size.width;
    while (currentX > 0) {
      final midX = (currentX - (_toothWidth / 2)).clamp(0.0, size.width);
      final nextX = (currentX - _toothWidth).clamp(0.0, size.width);
      path.lineTo(midX, size.height);
      path.lineTo(nextX, size.height - _toothDepth);
      currentX -= _toothWidth;
    }

    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class ReceiptContent extends StatefulWidget {
  final dynamic bill;
  const ReceiptContent({super.key, required this.bill});

  @override
  State<ReceiptContent> createState() => _ReceiptContentState();
}

class _ReceiptContentState extends State<ReceiptContent> {
  Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  String _textOrEmpty(dynamic value) => value?.toString().trim() ?? '';

  String _textOf(dynamic value, {String fallback = 'N/A'}) {
    final text = _textOrEmpty(value);
    return text.isEmpty ? fallback : text;
  }

  double _moneyOf(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  double _positiveMoney(dynamic value) {
    final amount = _moneyOf(value);
    if (amount.isNaN || amount.isInfinite) return 0.0;
    return amount < 0 ? 0.0 : amount;
  }

  double _qtyOf(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  String _formatQty(double quantity) {
    if (quantity % 1 == 0) return quantity.toStringAsFixed(0);
    return quantity.toStringAsFixed(2);
  }

  String _formatReceiptMoney(double value) {
    final fixed = value.toStringAsFixed(2);
    if (fixed.endsWith('.00')) return fixed.substring(0, fixed.length - 3);
    if (fixed.endsWith('0')) return fixed.substring(0, fixed.length - 1);
    return fixed;
  }

  double? _moneyOrNull(dynamic value) {
    if (value == null) return null;
    if (value is num) {
      final parsed = value.toDouble();
      if (parsed.isNaN || parsed.isInfinite) return null;
      return parsed;
    }
    if (value is String) {
      final sanitized = value.replaceAll(RegExp(r'[^0-9\.\-+]'), '');
      if (sanitized.isEmpty) return null;
      return double.tryParse(sanitized);
    }
    return null;
  }

  String _formatDateForPrint(DateTime date) {
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final year = date.year.toString();
    var hour = date.hour;
    final ampm = hour >= 12 ? 'PM' : 'AM';
    hour = hour % 12;
    if (hour == 0) hour = 12;
    final minute = date.minute.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute$ampm';
  }

  Widget _separator(String character, TextStyle style) {
    return Text(
      List<String>.filled(52, character).join(),
      maxLines: 1,
      overflow: TextOverflow.clip,
      style: style,
    );
  }

  Widget _rightLine(String text, TextStyle style) {
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(text, style: style, textAlign: TextAlign.right),
      ),
    );
  }

  Widget _itemRow({
    required String item,
    required String qty,
    required String price,
    required String tax,
    required String amount,
    required TextStyle style,
    bool header = false,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: header ? 0 : 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              item,
              maxLines: header ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          SizedBox(
            width: 36,
            child: Text(qty, textAlign: TextAlign.right, style: style),
          ),
          SizedBox(
            width: 50,
            child: Text(price, textAlign: TextAlign.right, style: style),
          ),
          SizedBox(
            width: 50,
            child: Text(tax, textAlign: TextAlign.right, style: style),
          ),
          SizedBox(
            width: 52,
            child: Text(amount, textAlign: TextAlign.right, style: style),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bill = widget.bill is Map<String, dynamic>
        ? Map<String, dynamic>.from(widget.bill as Map<String, dynamic>)
        : <String, dynamic>{};
    final rawItems = bill['items'] is List
        ? List<dynamic>.from(bill['items'])
        : const <dynamic>[];

    final branch = _asMap(bill['branch']);
    final branchCompany = _asMap(branch?['company']);
    final directCompany = _asMap(bill['company']);
    final companyName = _textOf(
      branchCompany?['name'] ??
          directCompany?['name'] ??
          bill['companyName'] ??
          'BlackForest Cakes',
      fallback: 'BlackForest Cakes',
    );
    final branchName = _textOrEmpty(branch?['name'] ?? bill['branchName']);
    final branchGst = _textOrEmpty(
      branch?['gst'] ?? bill['branchGst'] ?? bill['gst'],
    );
    final branchMobile = _textOrEmpty(
      branch?['phone'] ?? bill['branchMobile'] ?? bill['mobile'],
    );

    final updatedAtText = _textOrEmpty(bill['updatedAt']);
    final createdAtText = _textOrEmpty(bill['createdAt']);
    final parsedDate = DateTime.tryParse(
      updatedAtText.isNotEmpty ? updatedAtText : createdAtText,
    )?.toLocal();
    final dateText = parsedDate == null
        ? 'N/A'
        : _formatDateForPrint(parsedDate);

    final rawInvoiceNumber = _textOrEmpty(bill['invoiceNumber']);
    final rawKotNumber = _textOrEmpty(bill['kotNumber']);
    final billNo = rawInvoiceNumber.isNotEmpty
        ? rawInvoiceNumber.split('-').last.trim()
        : (rawKotNumber.isNotEmpty
              ? rawKotNumber.split('-KOT').first.trim()
              : _textOf(bill['id'] ?? bill['_id']));

    final createdBy = _asMap(bill['createdBy']);
    final assignedBy = _textOf(
      createdBy?['name'] ?? bill['assignedBy'] ?? bill['waiterName'],
      fallback: 'Unknown',
    );

    final tableDetails = _asMap(bill['tableDetails']);
    final tableInfo = _asMap(bill['table']);
    final tableNumber = _textOrEmpty(
      tableDetails?['tableNumber'] ??
          tableInfo?['tableNumber'] ??
          bill['tableNumber'] ??
          bill['tName'],
    );
    final sectionName = _textOrEmpty(tableDetails?['section']);
    final tableLabel = tableNumber.isEmpty
        ? ''
        : (sectionName.isEmpty
              ? 'Table :$tableNumber'
              : 'Table :$tableNumber ($sectionName)');

    final paymentMethod = _textOf(
      bill['paymentMethod'],
      fallback: 'N/A',
    ).toUpperCase();

    final customerDetails = _asMap(bill['customerDetails']);
    final customerName = _textOrEmpty(customerDetails?['name']);
    final customerPhone = _textOrEmpty(
      customerDetails?['phone'] ?? customerDetails?['phoneNumber'],
    );

    final lineItems = <Map<String, dynamic>>[];
    var lineAmountTotal = 0.0;
    var lineTaxTotal = 0.0;
    for (final rawItem in rawItems) {
      if (rawItem is! Map) continue;
      final item = Map<String, dynamic>.from(rawItem);
      if (_textOrEmpty(item['status']).toLowerCase() == 'cancelled') continue;

      final product = _asMap(item['product']);
      final itemName = _textOf(
        item['name'] ?? product?['name'] ?? item['productName'],
        fallback: 'ITEM',
      ).toUpperCase();
      final quantity = _qtyOf(item['quantity']);
      if (quantity <= 0) continue;

      var unitPrice = _positiveMoney(
        item['effectiveUnitPrice'] ??
            item['unitPrice'] ??
            item['price'] ??
            product?['price'] ??
            product?['unitPrice'],
      );

      var amount = _positiveMoney(
        item['lineTotal'] ??
            item['subtotal'] ??
            item['total'] ??
            item['amount'],
      );
      if (amount <= 0 && unitPrice > 0) {
        amount = unitPrice * quantity;
      }
      if (unitPrice <= 0 && quantity > 0 && amount > 0) {
        unitPrice = amount / quantity;
      }

      var tax = _positiveMoney(
        item['taxAmount'] ??
            item['gstAmount'] ??
            item['tax'] ??
            item['lineTaxAmount'],
      );
      if (tax <= 0 && amount > 0) {
        final gstPercent = _positiveMoney(
          item['gstPercent'] ?? item['gst'] ?? item['taxPercent'],
        );
        if (gstPercent > 0) {
          tax = (amount * gstPercent) / 100;
        }
      }

      lineItems.add({
        'name': itemName,
        'qty': quantity,
        'unitPrice': unitPrice,
        'tax': tax,
        'amount': amount,
      });
      lineAmountTotal += amount;
      lineTaxTotal += tax;
    }

    var grossAmount = _positiveMoney(bill['grossAmount']);
    var totalAmount = _positiveMoney(
      bill['totalAmount'] ?? bill['finalAmount'] ?? bill['payableAmount'],
    );
    if (totalAmount <= 0) totalAmount = lineAmountTotal;
    if (grossAmount <= 0) {
      grossAmount = _positiveMoney(
        bill['subTotal'] ?? bill['subtotal'] ?? bill['itemsTotal'],
      );
    }
    if (grossAmount <= 0) grossAmount = lineAmountTotal;

    final billDiscount = (grossAmount - totalAmount)
        .clamp(0.0, double.infinity)
        .toDouble();
    final customerOfferDiscount = _positiveMoney(bill['customerOfferDiscount']);
    final totalPercentageOfferDiscount = _positiveMoney(
      bill['totalPercentageOfferDiscount'],
    );
    final customerEntryPercentageOfferDiscount = _positiveMoney(
      bill['customerEntryPercentageOfferDiscount'],
    );
    final explainedDiscount =
        customerOfferDiscount +
        totalPercentageOfferDiscount +
        customerEntryPercentageOfferDiscount;
    final otherDiscount = (billDiscount - explainedDiscount)
        .clamp(0.0, double.infinity)
        .toDouble();

    var subTotalAmount = _positiveMoney(
      bill['subTotal'] ?? bill['subtotal'] ?? bill['itemsTotal'],
    );
    if (subTotalAmount <= 0) {
      subTotalAmount = billDiscount > 0
          ? grossAmount - billDiscount
          : lineAmountTotal;
    }

    var cgstAmount = _positiveMoney(bill['cgstAmount'] ?? bill['cgst']);
    var sgstAmount = _positiveMoney(bill['sgstAmount'] ?? bill['sgst']);
    final gstAmount = _positiveMoney(
      bill['gstAmount'] ?? bill['taxAmount'] ?? bill['tax'],
    );
    if (cgstAmount <= 0 && sgstAmount <= 0) {
      if (gstAmount > 0) {
        cgstAmount = gstAmount / 2;
        sgstAmount = gstAmount / 2;
      } else if (lineTaxTotal > 0) {
        cgstAmount = lineTaxTotal / 2;
        sgstAmount = lineTaxTotal / 2;
      }
    }

    final storedRoundOff = _moneyOrNull(
      bill['roundOffAmount'] ??
          bill['roundOff'] ??
          bill['roundoff'] ??
          bill['round_off'] ??
          bill['roundingOff'],
    );
    final storedRoundedGrandTotal = _moneyOrNull(
      bill['roundedGrandTotal'] ??
          bill['roundedTotal'] ??
          bill['grandTotal'] ??
          bill['finalGrandTotal'],
    );

    final computedPreRoundTotal = () {
      final summedTax = (cgstAmount + sgstAmount);
      if (subTotalAmount > 0 && summedTax > 0) {
        return subTotalAmount + summedTax;
      }
      if (subTotalAmount > 0 && gstAmount > 0) {
        return subTotalAmount + gstAmount;
      }
      return totalAmount;
    }();

    final derivedRoundOff =
        (computedPreRoundTotal.ceilToDouble() - computedPreRoundTotal)
            .clamp(0.0, double.infinity)
            .toDouble();

    final rawRoundOff = storedRoundOff ?? derivedRoundOff;
    final roundOffAmount = double.parse(rawRoundOff.toStringAsFixed(2));
    final roundedGrandTotal =
        storedRoundedGrandTotal ??
        double.parse(
          (computedPreRoundTotal + roundOffAmount).toStringAsFixed(2),
        );
    final roundOffSign = roundOffAmount >= 0 ? '+' : '-';

    const printInk = Color(0xFF1F1B17);
    const fadedPrintInk = Color(0xFF686158);
    final basePrintStyle = const TextStyle(
      color: printInk,
      fontFamily: 'monospace',
      fontSize: 12.2,
      height: 1.3,
      letterSpacing: 0.05,
    );
    final strongPrintStyle = basePrintStyle.copyWith(
      fontWeight: FontWeight.w700,
    );
    final titlePrintStyle = basePrintStyle.copyWith(
      fontSize: 19,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.4,
    );
    final fadedPrintStyle = basePrintStyle.copyWith(
      color: fadedPrintInk,
      fontWeight: FontWeight.w600,
    );
    const rightHeaderColumnWidth = 132.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 24),
      child: DefaultTextStyle(
        style: basePrintStyle,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              companyName,
              textAlign: TextAlign.center,
              style: titlePrintStyle,
            ),
            if (branchName.isNotEmpty)
              Text(
                'Branch: $branchName',
                textAlign: TextAlign.center,
                style: fadedPrintStyle,
              ),
            if (branchGst.isNotEmpty)
              Text(
                'GST: $branchGst',
                textAlign: TextAlign.center,
                style: fadedPrintStyle,
              ),
            if (branchMobile.isNotEmpty)
              Text(
                'Mobile: $branchMobile',
                textAlign: TextAlign.center,
                style: fadedPrintStyle,
              ),
            const SizedBox(height: 8),
            _separator('=', fadedPrintStyle),
            const SizedBox(height: 5),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Date: $dateText',
                      maxLines: 1,
                      softWrap: false,
                      style: strongPrintStyle,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: rightHeaderColumnWidth,
                  child: Text(
                    'BILL NO - $billNo',
                    maxLines: 2,
                    style: strongPrintStyle,
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    'Assigned by: $assignedBy',
                    maxLines: 2,
                    style: strongPrintStyle,
                  ),
                ),
                if (tableLabel.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: rightHeaderColumnWidth,
                    child: Text(
                      tableLabel,
                      maxLines: 2,
                      style: strongPrintStyle,
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            _separator('=', fadedPrintStyle),
            const SizedBox(height: 6),
            _itemRow(
              item: 'Item',
              qty: 'Qty',
              price: 'Price',
              tax: 'Tax',
              amount: 'Amt',
              style: strongPrintStyle,
              header: true,
            ),
            const SizedBox(height: 4),
            _separator('-', fadedPrintStyle),
            const SizedBox(height: 4),
            if (lineItems.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  'NO ITEMS',
                  textAlign: TextAlign.center,
                  style: strongPrintStyle,
                ),
              ),
            ...lineItems.map((entry) {
              return _itemRow(
                item: entry['name']?.toString() ?? 'ITEM',
                qty: _formatQty(entry['qty'] as double),
                price: _formatReceiptMoney(entry['unitPrice'] as double),
                tax: _formatReceiptMoney(entry['tax'] as double),
                amount: _formatReceiptMoney(entry['amount'] as double),
                style: strongPrintStyle,
              );
            }),
            const SizedBox(height: 6),
            _separator('-', fadedPrintStyle),
            const SizedBox(height: 4),
            if (billDiscount > 0.0001) ...[
              _rightLine(
                'GROSS RS ${grossAmount.toStringAsFixed(2)}',
                strongPrintStyle,
              ),
              if (otherDiscount > 0.009)
                _rightLine(
                  'OTHER DISCOUNT RS ${otherDiscount.toStringAsFixed(2)}',
                  strongPrintStyle,
                ),
              if (customerOfferDiscount > 0.0001)
                _rightLine(
                  'CREDIT OFFER RS ${customerOfferDiscount.toStringAsFixed(2)}',
                  strongPrintStyle,
                ),
              if (totalPercentageOfferDiscount > 0.0001)
                _rightLine(
                  'PERCENT OFFER RS ${totalPercentageOfferDiscount.toStringAsFixed(2)}',
                  strongPrintStyle,
                ),
              if (customerEntryPercentageOfferDiscount > 0.0001)
                _rightLine(
                  'ENTRY PERCENT OFFER RS ${customerEntryPercentageOfferDiscount.toStringAsFixed(2)}',
                  strongPrintStyle,
                ),
            ],
            _rightLine(
              'SUB TOTAL RS ${subTotalAmount.toStringAsFixed(2)}',
              strongPrintStyle,
            ),
            if (cgstAmount > 0.0001)
              _rightLine(
                'CGST RS ${cgstAmount.toStringAsFixed(2)}',
                strongPrintStyle,
              ),
            if (sgstAmount > 0.0001)
              _rightLine(
                'SGST RS ${sgstAmount.toStringAsFixed(2)}',
                strongPrintStyle,
              ),
            const SizedBox(height: 4),
            _separator('-', fadedPrintStyle),
            const SizedBox(height: 4),
            _rightLine(
              'Round off $roundOffSign${roundOffAmount.abs().toStringAsFixed(2)}',
              strongPrintStyle,
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'PAID BY: $paymentMethod',
                    style: strongPrintStyle.copyWith(fontSize: 13.2),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      'GRAND TOTAL RS ${_formatReceiptMoney(roundedGrandTotal)}',
                      maxLines: 1,
                      softWrap: false,
                      textAlign: TextAlign.right,
                      style: strongPrintStyle.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            _separator('=', fadedPrintStyle),
            if (customerName.isNotEmpty || customerPhone.isNotEmpty) ...[
              const SizedBox(height: 8),
              if (customerName.isNotEmpty)
                Text('Customer: $customerName', style: strongPrintStyle),
              if (customerPhone.isNotEmpty)
                Text('Phone: $customerPhone', style: strongPrintStyle),
            ],
          ],
        ),
      ),
    );
  }
}
