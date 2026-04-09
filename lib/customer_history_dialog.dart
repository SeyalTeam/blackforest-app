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

class _ProductInsightCardData {
  final String key;
  final String name;
  final String? imageUrl;
  final double totalSpend;
  final double totalQuantity;
  final DateTime? lastEatenAt;
  final bool hasReview;
  final String? lastReviewMessage;

  const _ProductInsightCardData({
    required this.key,
    required this.name,
    required this.imageUrl,
    required this.totalSpend,
    required this.totalQuantity,
    required this.lastEatenAt,
    required this.hasReview,
    this.lastReviewMessage,
  });
}

class _ReviewedProductsLookupResult {
  final Set<String> keys;
  final Map<String, String> messagesByProductKey;
  final Map<String, String> messagesByBillProductKey;
  final Map<String, String> messagesByBillTimeProductKey;

  const _ReviewedProductsLookupResult({
    this.keys = const <String>{},
    this.messagesByProductKey = const <String, String>{},
    this.messagesByBillProductKey = const <String, String>{},
    this.messagesByBillTimeProductKey = const <String, String>{},
  });
}

class _ProductVisitEntry {
  final DateTime? visitedAt;
  final double count;
  final String? reviewMessage;

  const _ProductVisitEntry({
    required this.visitedAt,
    required this.count,
    this.reviewMessage,
  });
}

class _CustomerHistoryDialogState extends State<CustomerHistoryDialog> {
  static const Duration _historyLoadTimeout = Duration(seconds: 12);
  static const int _initialBillLimit = 2;
  static const int _loadMoreBillLimit = 1;
  static const int _lookupPreviewBillLimit = 15;
  static const int _insightPageLimit = 100;
  static const int _insightMaxPages = 25;
  static const Color _insightGreen = Color(0xFF1B8F3D);
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
  double? _knownTotalAmount;
  int _nextSingleItemPage = _initialBillLimit + 1;
  bool _showProductInsights = true;
  bool _isLoadingProductInsights = false;
  String? _productInsightsError;
  List<Map<String, dynamic>> _insightBills = [];
  Set<String> _reviewedProductKeys = <String>{};
  Map<String, String> _reviewMessageByProductKey = <String, String>{};
  Map<String, String> _reviewMessageByBillProductKey = <String, String>{};
  Map<String, String> _reviewMessageByBillTimeProductKey = <String, String>{};
  String? _selectedProductKey;
  String? _selectedProductName;

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
    _knownTotalAmount = null;
    _nextSingleItemPage = _initialBillLimit + 1;
    _showProductInsights = true;
    _isLoadingProductInsights = false;
    _productInsightsError = null;
    _insightBills = [];
    _reviewedProductKeys = <String>{};
    _reviewMessageByProductKey = <String, String>{};
    _reviewMessageByBillProductKey = <String, String>{};
    _reviewMessageByBillTimeProductKey = <String, String>{};
    _selectedProductKey = null;
    _selectedProductName = null;

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
      _HistorySummaryResult quickSummary = const _HistorySummaryResult();
      try {
        quickSummary = await quickSummaryFuture;
      } catch (_) {}

      var mergedInitialBills = _sortBillsByDate(
        _mergeUniqueBills([firstPage.bills, quickSummary.bills]),
      );
      var totalBillsHint = quickSummary.totalBills ?? firstPage.totalDocs;
      var hasMore = _computeHasMore(
        loadedBillCount: mergedInitialBills.length,
        totalBillsHint: totalBillsHint,
        fallbackByPageCount: firstPage.bills.length >= _initialBillLimit,
      );
      var resolvedAmount = _resolveTotalAmount(
        preferredAmount: quickSummary.totalAmount,
        existingAmount: _knownTotalAmount,
        bills: mergedInitialBills,
        hasMore: hasMore,
        totalBillsHint: totalBillsHint,
      );

      final shouldLoadHeavySummary = _shouldFetchHeavySummary(
        bills: mergedInitialBills,
        hasMore: hasMore,
        resolvedAmount: resolvedAmount,
      );
      if (shouldLoadHeavySummary) {
        try {
          final heavySummary = await _fetchHistorySummary(
            normalizedPhone,
            useHeavyFallback: true,
          ).timeout(_historyLoadTimeout);
          mergedInitialBills = _sortBillsByDate(
            _mergeUniqueBills([mergedInitialBills, heavySummary.bills]),
          );
          totalBillsHint ??= heavySummary.totalBills;
          if (heavySummary.totalBills != null && heavySummary.totalBills! > 0) {
            totalBillsHint = heavySummary.totalBills;
          }
          hasMore = _computeHasMore(
            loadedBillCount: mergedInitialBills.length,
            totalBillsHint: totalBillsHint,
            fallbackByPageCount: firstPage.bills.length >= _initialBillLimit,
          );
          resolvedAmount = _resolveTotalAmount(
            preferredAmount:
                heavySummary.totalAmount ?? quickSummary.totalAmount,
            existingAmount: resolvedAmount,
            bills: mergedInitialBills,
            hasMore: hasMore,
            totalBillsHint: totalBillsHint,
          );
        } catch (_) {}
      }

      _knownTotalBills = totalBillsHint;
      _nextSingleItemPage = mergedInitialBills.length + 1;
      if (mounted) {
        setState(() {
          _bills = mergedInitialBills;
          _isLoading = false;
          _isLoadingMore = false;
          _hasMore = hasMore;
          _knownTotalAmount = resolvedAmount;
          _error = null;
        });
      }
      unawaited(
        _loadCustomerReviewedProducts(
          normalizedPhone,
          knownBills: mergedInitialBills,
        ),
      );
      if (_showProductInsights &&
          _insightBills.isEmpty &&
          !_isLoadingProductInsights) {
        unawaited(_loadProductInsights());
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
          _knownTotalAmount = _resolveTotalAmount(
            preferredAmount: null,
            existingAmount: _knownTotalAmount,
            bills: updatedBills,
            hasMore: hasMore,
            totalBillsHint: _knownTotalBills,
          );
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
    final offer = _asMap(map['offer']);
    final dataOffer = _asMap(data?['offer']);
    final resultOffer = _asMap(result?['offer']);
    final summaryOffer = _asMap(summary?['offer']);
    final statsSummary = _asMap(stats?['summary']);
    final statsSummaryOffer = _asMap(statsSummary?['offer']);
    final historyOffer = _asMap(history?['offer']);

    final candidates = <dynamic>[
      map['totalAmount'],
      map['totalSpent'],
      map['totalSpend'],
      map['spentAmount'],
      map['spent'],
      map['lifetimeSpend'],
      map['customerSpend'],
      map['allBillsSpendAmount'],
      map['completedSpendAmount'],
      data?['totalAmount'],
      data?['totalSpent'],
      data?['totalSpend'],
      data?['spentAmount'],
      data?['spent'],
      data?['lifetimeSpend'],
      data?['customerSpend'],
      data?['allBillsSpendAmount'],
      data?['completedSpendAmount'],
      result?['totalAmount'],
      result?['totalSpent'],
      result?['totalSpend'],
      result?['spentAmount'],
      result?['spent'],
      result?['lifetimeSpend'],
      result?['customerSpend'],
      result?['allBillsSpendAmount'],
      result?['completedSpendAmount'],
      summary?['totalAmount'],
      summary?['totalSpent'],
      summary?['totalSpend'],
      summary?['spentAmount'],
      summary?['spent'],
      summary?['lifetimeSpend'],
      summary?['customerSpend'],
      summary?['allBillsSpendAmount'],
      summary?['completedSpendAmount'],
      stats?['totalAmount'],
      stats?['totalSpent'],
      stats?['totalSpend'],
      stats?['spentAmount'],
      stats?['spent'],
      stats?['lifetimeSpend'],
      stats?['customerSpend'],
      stats?['allBillsSpendAmount'],
      stats?['completedSpendAmount'],
      statsSummary?['totalAmount'],
      statsSummary?['totalSpent'],
      statsSummary?['totalSpend'],
      statsSummary?['spentAmount'],
      statsSummary?['spent'],
      statsSummary?['lifetimeSpend'],
      statsSummary?['customerSpend'],
      statsSummary?['allBillsSpendAmount'],
      statsSummary?['completedSpendAmount'],
      history?['totalAmount'],
      history?['totalSpent'],
      history?['totalSpend'],
      history?['spentAmount'],
      history?['spent'],
      history?['lifetimeSpend'],
      history?['customerSpend'],
      history?['allBillsSpendAmount'],
      history?['completedSpendAmount'],
      offer?['totalAmount'],
      offer?['totalSpent'],
      offer?['totalSpend'],
      offer?['allBillsSpendAmount'],
      offer?['completedSpendAmount'],
      dataOffer?['totalAmount'],
      dataOffer?['totalSpent'],
      dataOffer?['totalSpend'],
      dataOffer?['allBillsSpendAmount'],
      dataOffer?['completedSpendAmount'],
      resultOffer?['totalAmount'],
      resultOffer?['totalSpent'],
      resultOffer?['totalSpend'],
      resultOffer?['allBillsSpendAmount'],
      resultOffer?['completedSpendAmount'],
      summaryOffer?['totalAmount'],
      summaryOffer?['totalSpent'],
      summaryOffer?['totalSpend'],
      summaryOffer?['allBillsSpendAmount'],
      summaryOffer?['completedSpendAmount'],
      statsSummaryOffer?['totalAmount'],
      statsSummaryOffer?['totalSpent'],
      statsSummaryOffer?['totalSpend'],
      statsSummaryOffer?['allBillsSpendAmount'],
      statsSummaryOffer?['completedSpendAmount'],
      historyOffer?['totalAmount'],
      historyOffer?['totalSpent'],
      historyOffer?['totalSpend'],
      historyOffer?['allBillsSpendAmount'],
      historyOffer?['completedSpendAmount'],
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
    if (value is String) {
      final direct = double.tryParse(value);
      if (direct != null) return direct;
      final sanitized = value.replaceAll(RegExp(r'[^0-9\.\-+]'), '');
      if (sanitized.isEmpty) return null;
      return double.tryParse(sanitized);
    }
    return null;
  }

  double _extractBillTotalAmount(Map<String, dynamic> bill) {
    final candidates = <dynamic>[
      bill['totalAmount'],
      bill['finalAmount'],
      bill['payableAmount'],
      bill['roundedGrandTotal'],
      bill['roundedTotal'],
      bill['grandTotal'],
      bill['grossAmount'],
      bill['subTotal'],
      bill['subtotal'],
      bill['itemsTotal'],
      bill['amount'],
    ];
    for (final candidate in candidates) {
      final parsed = _asDouble(candidate);
      if (parsed != null && parsed.isFinite && parsed >= 0) return parsed;
    }
    return 0.0;
  }

  double _sumBillAmounts(List<Map<String, dynamic>> bills) {
    var total = 0.0;
    for (final bill in bills) {
      total += _extractBillTotalAmount(bill);
    }
    return total;
  }

  double? _fallbackTotalAmount({
    required List<Map<String, dynamic>> bills,
    required bool hasMore,
    required int? totalBillsHint,
  }) {
    if (bills.isEmpty) return null;
    final hasPartialBills =
        hasMore ||
        (totalBillsHint != null &&
            totalBillsHint > 0 &&
            bills.length < totalBillsHint);
    if (hasPartialBills) return null;
    return _sumBillAmounts(bills);
  }

  double? _normalizeAmountCandidate({
    required double? amount,
    required List<Map<String, dynamic>> bills,
    required bool hasMore,
    required int? totalBillsHint,
    required double? fallbackAmount,
  }) {
    if (amount == null || amount.isNaN || amount.isInfinite || amount < 0) {
      return null;
    }
    if (amount > 0) return amount;
    if (bills.isEmpty) return 0.0;
    if (fallbackAmount != null) return fallbackAmount;

    final loadedAmount = _sumBillAmounts(bills);
    if (loadedAmount > 0.0001) {
      return null;
    }

    final hasPartialBills =
        hasMore ||
        (totalBillsHint != null &&
            totalBillsHint > 0 &&
            bills.length < totalBillsHint);
    return hasPartialBills ? null : 0.0;
  }

  double? _resolveTotalAmount({
    required double? preferredAmount,
    required double? existingAmount,
    required List<Map<String, dynamic>> bills,
    required bool hasMore,
    required int? totalBillsHint,
  }) {
    final fallbackAmount = _fallbackTotalAmount(
      bills: bills,
      hasMore: hasMore,
      totalBillsHint: totalBillsHint,
    );
    final preferred = _normalizeAmountCandidate(
      amount: preferredAmount,
      bills: bills,
      hasMore: hasMore,
      totalBillsHint: totalBillsHint,
      fallbackAmount: fallbackAmount,
    );
    if (preferred != null) return preferred;

    final existing = _normalizeAmountCandidate(
      amount: existingAmount,
      bills: bills,
      hasMore: hasMore,
      totalBillsHint: totalBillsHint,
      fallbackAmount: fallbackAmount,
    );
    if (existing != null) return existing;

    return fallbackAmount;
  }

  bool _computeHasMore({
    required int loadedBillCount,
    required int? totalBillsHint,
    required bool fallbackByPageCount,
  }) {
    if (totalBillsHint != null && totalBillsHint > 0) {
      return loadedBillCount < totalBillsHint;
    }
    return fallbackByPageCount;
  }

  bool _shouldFetchHeavySummary({
    required List<Map<String, dynamic>> bills,
    required bool hasMore,
    required double? resolvedAmount,
  }) {
    if (bills.isEmpty) return true;
    if (!hasMore) return false;
    if (resolvedAmount == null) return true;

    final loadedAmount = _sumBillAmounts(bills);
    final delta = resolvedAmount - loadedAmount;
    return delta <= 0.009;
  }

  void _toggleProductInsights() {
    final nextValue = !_showProductInsights;
    setState(() {
      _showProductInsights = nextValue;
      if (!nextValue) {
        _selectedProductKey = null;
        _selectedProductName = null;
      }
    });
    if (nextValue && _insightBills.isEmpty && !_isLoadingProductInsights) {
      unawaited(_loadProductInsights());
    }
  }

  Future<void> _loadProductInsights() async {
    if (_normalizedPhone.isEmpty) return;
    if (_isLoadingProductInsights) return;
    if (mounted) {
      setState(() {
        _isLoadingProductInsights = true;
        _productInsightsError = null;
      });
    }

    try {
      final fetchedBills = await _fetchAllBillsForInsights(
        normalizedPhone: _normalizedPhone,
        preferredPhoneField: _resolvedPhoneField,
      ).timeout(const Duration(seconds: 25));
      final merged = _sortBillsByDate(
        _mergeUniqueBills([_bills, fetchedBills]),
      );

      if (!mounted) return;
      setState(() {
        _insightBills = merged;
        _isLoadingProductInsights = false;
        _productInsightsError = null;
      });
      unawaited(
        _loadCustomerReviewedProducts(_normalizedPhone, knownBills: merged),
      );
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _insightBills = _sortBillsByDate(
          _mergeUniqueBills([_insightBills, _bills]),
        );
        _isLoadingProductInsights = false;
        _productInsightsError = "Insights loading timed out. Tap retry.";
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _insightBills = _sortBillsByDate(
          _mergeUniqueBills([_insightBills, _bills]),
        );
        _isLoadingProductInsights = false;
        _productInsightsError = "Unable to load product insights. Tap retry.";
      });
    }
  }

  Future<void> _loadCustomerReviewedProducts(
    String normalizedPhone, {
    List<Map<String, dynamic>>? knownBills,
  }) async {
    try {
      final reviewedLookup = await _fetchReviewedProductKeysForPhone(
        normalizedPhone,
        knownBills: knownBills,
      );
      if (!mounted || _normalizedPhone != normalizedPhone) return;
      setState(() {
        final mergedKeys = Set<String>.from(_reviewedProductKeys)
          ..addAll(reviewedLookup.keys);
        final mergedByProduct = Map<String, String>.from(
          _reviewMessageByProductKey,
        );
        reviewedLookup.messagesByProductKey.forEach((key, value) {
          if (!mergedByProduct.containsKey(key)) {
            mergedByProduct[key] = value;
          }
        });
        final mergedByBillProduct = Map<String, String>.from(
          _reviewMessageByBillProductKey,
        );
        reviewedLookup.messagesByBillProductKey.forEach((key, value) {
          if (!mergedByBillProduct.containsKey(key)) {
            mergedByBillProduct[key] = value;
          }
        });
        final mergedByBillTimeProduct = Map<String, String>.from(
          _reviewMessageByBillTimeProductKey,
        );
        reviewedLookup.messagesByBillTimeProductKey.forEach((key, value) {
          if (!mergedByBillTimeProduct.containsKey(key)) {
            mergedByBillTimeProduct[key] = value;
          }
        });

        _reviewedProductKeys = mergedKeys;
        _reviewMessageByProductKey = mergedByProduct;
        _reviewMessageByBillProductKey = mergedByBillProduct;
        _reviewMessageByBillTimeProductKey = mergedByBillTimeProduct;
      });
    } catch (_) {}
  }

  Future<_ReviewedProductsLookupResult> _fetchReviewedProductKeysForPhone(
    String normalizedPhone, {
    List<Map<String, dynamic>>? knownBills,
  }) async {
    final keys = <String>{};
    final messagesByProductKey = <String, String>{};
    final messagesByBillProductKey = <String, String>{};
    final messagesByBillTimeProductKey = <String, String>{};
    final phoneValues = _phoneCandidates(normalizedPhone);
    final normalizedPhoneSet = phoneValues
        .map(_normalizePhoneValue)
        .where((value) => value.isNotEmpty)
        .toSet();
    final allowedBillIds = _collectBillIds(
      knownBills ?? (_insightBills.isNotEmpty ? _insightBills : _bills),
    );

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }

    for (final phone in phoneValues) {
      for (var page = 1; page <= 12; page++) {
        final uri = Uri.parse('https://blackforest.vseyal.com/api/reviews')
            .replace(
              queryParameters: {
                'sort': '-createdAt',
                'page': page.toString(),
                'limit': '100',
                'depth': '2',
                'where[customerPhone][equals]': phone,
              },
            );
        final response = await http
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) break;

        final decoded = jsonDecode(response.body);
        final reviewDocs = _extractReviewDocsFromPayload(decoded);
        if (reviewDocs.isEmpty) break;

        for (final reviewDoc in reviewDocs) {
          if (!_reviewDocBelongsToCustomer(
            reviewDoc,
            normalizedPhoneSet: normalizedPhoneSet,
            allowedBillIds: allowedBillIds,
          )) {
            continue;
          }
          _addReviewedKeysFromReviewDoc(
            reviewDoc,
            keys,
            messagesByProductKey,
            messagesByBillProductKey,
            messagesByBillTimeProductKey,
          );
        }

        if (reviewDocs.length < 100) break;
      }
    }

    return _ReviewedProductsLookupResult(
      keys: keys,
      messagesByProductKey: messagesByProductKey,
      messagesByBillProductKey: messagesByBillProductKey,
      messagesByBillTimeProductKey: messagesByBillTimeProductKey,
    );
  }

  List<Map<String, dynamic>> _extractReviewDocsFromPayload(dynamic payload) {
    if (payload is! Map) return const [];
    final map = Map<String, dynamic>.from(payload);
    final data = _asMap(map['data']);
    final result = _asMap(map['result']);
    final candidates = <dynamic>[
      map['docs'],
      map['reviews'],
      map['items'],
      data?['docs'],
      data?['reviews'],
      result?['docs'],
      result?['reviews'],
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

  void _addReviewedKeysFromReviewDoc(
    Map<String, dynamic> reviewDoc,
    Set<String> output,
    Map<String, String> messagesByProductKey,
    Map<String, String> messagesByBillProductKey,
    Map<String, String> messagesByBillTimeProductKey,
  ) {
    final reviewItems = reviewDoc['items'];
    if (reviewItems is! List) return;
    final billKeys = _reviewBillKeyCandidatesFromReviewDoc(reviewDoc);
    final billUpdatedAt = _extractReviewBillUpdatedAt(reviewDoc);

    for (final raw in reviewItems) {
      if (raw is! Map) continue;
      final reviewItem = Map<String, dynamic>.from(raw);
      if (!_isPositiveReviewItem(reviewItem)) continue;
      final reviewMessage = _extractReviewMessage(reviewItem);

      final product = _asMap(reviewItem['product']);
      final productId =
          (reviewItem['productId'] ??
                  reviewItem['productID'] ??
                  reviewItem['itemId'] ??
                  product?['id'] ??
                  product?['_id'] ??
                  reviewItem['product'])
              ?.toString()
              .trim();
      final productName =
          (reviewItem['name'] ?? reviewItem['productName'] ?? product?['name'])
              ?.toString()
              .trim();
      final nameKey = (productName != null && productName.isNotEmpty)
          ? 'name:${productName.toLowerCase()}'
          : null;

      if (productId != null && productId.isNotEmpty) {
        final idKey = 'id:$productId';
        output.add(idKey);
        if (reviewMessage.isNotEmpty &&
            !messagesByProductKey.containsKey(idKey)) {
          messagesByProductKey[idKey] = reviewMessage;
        }
        if (reviewMessage.isNotEmpty && billKeys.isNotEmpty) {
          for (final billKey in billKeys) {
            final billProductKey = _billProductReviewKey(billKey, idKey);
            if (!messagesByBillProductKey.containsKey(billProductKey)) {
              messagesByBillProductKey[billProductKey] = reviewMessage;
            }
            if (nameKey != null) {
              final nameBillProductKey = _billProductReviewKey(
                billKey,
                nameKey,
              );
              if (!messagesByBillProductKey.containsKey(nameBillProductKey)) {
                messagesByBillProductKey[nameBillProductKey] = reviewMessage;
              }
            }
          }
        }
        if (reviewMessage.isNotEmpty && billUpdatedAt.isNotEmpty) {
          final timeProductKey = _billTimeProductReviewKey(
            billUpdatedAt,
            idKey,
          );
          if (!messagesByBillTimeProductKey.containsKey(timeProductKey)) {
            messagesByBillTimeProductKey[timeProductKey] = reviewMessage;
          }
          if (nameKey != null) {
            final nameTimeProductKey = _billTimeProductReviewKey(
              billUpdatedAt,
              nameKey,
            );
            if (!messagesByBillTimeProductKey.containsKey(nameTimeProductKey)) {
              messagesByBillTimeProductKey[nameTimeProductKey] = reviewMessage;
            }
          }
        }
      }
      if ((productId == null || productId.isEmpty) && nameKey != null) {
        output.add(nameKey);
        if (reviewMessage.isNotEmpty &&
            !messagesByProductKey.containsKey(nameKey)) {
          messagesByProductKey[nameKey] = reviewMessage;
        }
        if (reviewMessage.isNotEmpty && billKeys.isNotEmpty) {
          for (final billKey in billKeys) {
            final billProductKey = _billProductReviewKey(billKey, nameKey);
            if (!messagesByBillProductKey.containsKey(billProductKey)) {
              messagesByBillProductKey[billProductKey] = reviewMessage;
            }
          }
        }
        if (reviewMessage.isNotEmpty && billUpdatedAt.isNotEmpty) {
          final timeProductKey = _billTimeProductReviewKey(
            billUpdatedAt,
            nameKey,
          );
          if (!messagesByBillTimeProductKey.containsKey(timeProductKey)) {
            messagesByBillTimeProductKey[timeProductKey] = reviewMessage;
          }
        }
      }
    }
  }

  String _extractReviewMessage(Map<String, dynamic> reviewItem) {
    final message =
        (reviewItem['feedback'] ??
                reviewItem['review'] ??
                reviewItem['comment'] ??
                reviewItem['message'] ??
                reviewItem['text'])
            ?.toString()
            .trim() ??
        '';
    if (message.isEmpty) return '';
    return message.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _normalizePhoneValue(dynamic value) {
    if (value == null) return '';
    final digits = value.toString().replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return '';
    if (digits.length > 10) {
      return digits.substring(digits.length - 10);
    }
    return digits;
  }

  Set<String> _collectBillIds(List<Map<String, dynamic>> bills) {
    final ids = <String>{};
    for (final bill in bills) {
      final id = _billKey(bill).trim();
      if (id.isNotEmpty) ids.add(id);
    }
    return ids;
  }

  String _extractReviewBillId(Map<String, dynamic> reviewDoc) {
    final billValue = reviewDoc['bill'];
    if (billValue is String) return billValue.trim();
    if (billValue is Map) {
      final billMap = Map<String, dynamic>.from(billValue);
      return (billMap['id'] ?? billMap['_id'] ?? '').toString().trim();
    }
    return '';
  }

  String _extractReviewBillUpdatedAt(Map<String, dynamic> reviewDoc) {
    final billValue = reviewDoc['bill'];
    if (billValue is! Map) return '';
    final billMap = Map<String, dynamic>.from(billValue);
    final updated =
        (billMap['updatedAt'] ?? billMap['createdAt'])?.toString().trim() ?? '';
    return updated;
  }

  String _extractReviewPhoneFromBill(Map<String, dynamic> reviewDoc) {
    final billValue = reviewDoc['bill'];
    if (billValue is! Map) return '';
    final billMap = Map<String, dynamic>.from(billValue);
    final customerDetails = _asMap(billMap['customerDetails']);
    return _normalizePhoneValue(
      customerDetails?['phoneNumber'] ??
          customerDetails?['phone'] ??
          billMap['customerPhone'] ??
          billMap['phoneNumber'],
    );
  }

  bool _reviewDocBelongsToCustomer(
    Map<String, dynamic> reviewDoc, {
    required Set<String> normalizedPhoneSet,
    required Set<String> allowedBillIds,
  }) {
    final reviewPhone = _normalizePhoneValue(reviewDoc['customerPhone']);
    final billPhone = _extractReviewPhoneFromBill(reviewDoc);
    final reviewBillId = _extractReviewBillId(reviewDoc);

    final matchesPhone =
        (reviewPhone.isNotEmpty && normalizedPhoneSet.contains(reviewPhone)) ||
        (billPhone.isNotEmpty && normalizedPhoneSet.contains(billPhone));
    final matchesBill =
        reviewBillId.isNotEmpty && allowedBillIds.contains(reviewBillId);
    return matchesPhone || matchesBill;
  }

  bool _isPositiveReviewItem(Map<String, dynamic> reviewItem) {
    final rating =
        _asDouble(
          reviewItem['rating'] ??
              reviewItem['ratingValue'] ??
              reviewItem['reviewRating'] ??
              reviewItem['stars'] ??
              reviewItem['starRating'],
        ) ??
        0.0;
    if (rating > 0) return true;

    return _extractReviewMessage(reviewItem).isNotEmpty;
  }

  Future<List<Map<String, dynamic>>> _fetchAllBillsForInsights({
    required String normalizedPhone,
    String? preferredPhoneField,
  }) async {
    final collected = <Map<String, dynamic>>[];
    final seen = <String>{};
    var resolvedPhoneField = preferredPhoneField;
    int? totalDocs;

    for (var page = 1; page <= _insightMaxPages; page++) {
      final pageResult = await _fetchBillsPage(
        normalizedPhone: normalizedPhone,
        page: page,
        limit: _insightPageLimit,
        phoneField: resolvedPhoneField,
      ).timeout(_historyLoadTimeout);

      if (resolvedPhoneField == null && pageResult.phoneField != null) {
        resolvedPhoneField = pageResult.phoneField;
      }
      if (pageResult.totalDocs != null && pageResult.totalDocs! > 0) {
        totalDocs = pageResult.totalDocs;
      }

      final bills = pageResult.bills;
      if (bills.isEmpty) break;

      for (final bill in bills) {
        final primaryKey = _billKey(bill).trim();
        final fallbackKey =
            '${bill['createdAt'] ?? ''}:${bill['updatedAt'] ?? ''}:${collected.length}';
        final dedupeKey = primaryKey.isNotEmpty ? primaryKey : fallbackKey;
        if (seen.contains(dedupeKey)) continue;
        seen.add(dedupeKey);
        collected.add(bill);
      }

      if (totalDocs != null && totalDocs > 0 && collected.length >= totalDocs) {
        break;
      }
      if (bills.length < _insightPageLimit) {
        break;
      }
    }

    return _sortBillsByDate(collected);
  }

  List<_ProductInsightCardData> _productInsightCards(
    List<Map<String, dynamic>> bills,
  ) {
    final byProduct = <String, Map<String, dynamic>>{};

    for (final bill in bills) {
      final billDate = DateTime.tryParse(
        (bill['updatedAt'] ?? bill['createdAt'])?.toString() ?? '',
      )?.toLocal();
      final items = bill['items'];
      if (items is! List) continue;

      for (final raw in items) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final status = (item['status']?.toString() ?? '').toLowerCase().trim();
        if (status == 'cancelled' || status == 'canceled') continue;

        final product = _asMap(item['product']);
        final itemName =
            (item['name'] ??
                    product?['name'] ??
                    item['productName'] ??
                    'Product')
                .toString()
                .trim();
        if (itemName.isEmpty) continue;

        final productKey = _productKeyFromInsightItem(
          item,
          product: product,
          fallbackName: itemName,
        );
        if (productKey == null) continue;
        final reviewKeyById = productKey.startsWith('id:') ? productKey : null;
        final reviewKeyByName = productKey.startsWith('name:')
            ? productKey
            : 'name:${itemName.toLowerCase()}';

        final qtyRaw = _asDouble(item['quantity']) ?? 0.0;
        final quantity = qtyRaw.isFinite && qtyRaw > 0 ? qtyRaw : 0.0;

        var amount =
            _asDouble(
              item['lineTotal'] ??
                  item['subtotal'] ??
                  item['total'] ??
                  item['amount'],
            ) ??
            0.0;
        if (!amount.isFinite || amount < 0) amount = 0.0;
        if (amount <= 0 && quantity > 0) {
          final unitPrice =
              _asDouble(
                item['effectiveUnitPrice'] ??
                    item['unitPrice'] ??
                    item['price'] ??
                    product?['price'] ??
                    product?['unitPrice'],
              ) ??
              0.0;
          if (unitPrice.isFinite && unitPrice > 0) {
            amount = unitPrice * quantity;
          }
        }

        final imageUrl = _firstValidImageUrl([
          item['imageUrl'],
          item['image'],
          item['photo'],
          item['thumbnail'],
          item['media'],
          product?['imageUrl'],
          product?['image'],
          product?['photo'],
          product?['thumbnail'],
          product?['media'],
          product?['images'],
          product?['featuredImage'],
          product?['coverImage'],
        ]);

        final existing = byProduct[productKey];
        final hasReview = reviewKeyById != null
            ? _reviewedProductKeys.contains(reviewKeyById)
            : _reviewedProductKeys.contains(reviewKeyByName);
        final reviewMessage = reviewKeyById != null
            ? _reviewMessageByProductKey[reviewKeyById]
            : _reviewMessageByProductKey[reviewKeyByName];
        if (existing == null) {
          byProduct[productKey] = {
            'name': itemName,
            'imageUrl': imageUrl,
            'totalSpend': amount,
            'totalQuantity': quantity,
            'lastEatenAt': billDate,
            'hasReview': hasReview,
            'lastReviewMessage': reviewMessage,
          };
          continue;
        }

        existing['totalSpend'] = (existing['totalSpend'] as double) + amount;
        existing['totalQuantity'] =
            (existing['totalQuantity'] as double) + quantity;
        existing['hasReview'] =
            (existing['hasReview'] as bool? ?? false) || hasReview;
        final existingMessage =
            existing['lastReviewMessage']?.toString().trim() ?? '';
        if (existingMessage.isEmpty &&
            reviewMessage != null &&
            reviewMessage.trim().isNotEmpty) {
          existing['lastReviewMessage'] = reviewMessage.trim();
        }
        final existingImage = existing['imageUrl']?.toString() ?? '';
        if (existingImage.isEmpty && imageUrl != null && imageUrl.isNotEmpty) {
          existing['imageUrl'] = imageUrl;
        }
        final currentLast = existing['lastEatenAt'] as DateTime?;
        if (billDate != null &&
            (currentLast == null || billDate.isAfter(currentLast))) {
          existing['lastEatenAt'] = billDate;
        }
      }
    }

    final cards = <_ProductInsightCardData>[];
    byProduct.forEach((key, value) {
      cards.add(
        _ProductInsightCardData(
          key: key,
          name: value['name']?.toString() ?? 'Product',
          imageUrl: value['imageUrl']?.toString(),
          totalSpend: (value['totalSpend'] as double?) ?? 0.0,
          totalQuantity: (value['totalQuantity'] as double?) ?? 0.0,
          lastEatenAt: value['lastEatenAt'] as DateTime?,
          hasReview: value['hasReview'] as bool? ?? false,
          lastReviewMessage: value['lastReviewMessage']?.toString(),
        ),
      );
    });

    cards.sort((a, b) {
      final quantity = b.totalQuantity.compareTo(a.totalQuantity);
      if (quantity != 0) return quantity;
      final spend = b.totalSpend.compareTo(a.totalSpend);
      if (spend != 0) return spend;
      final aDate = a.lastEatenAt?.millisecondsSinceEpoch ?? 0;
      final bDate = b.lastEatenAt?.millisecondsSinceEpoch ?? 0;
      return bDate.compareTo(aDate);
    });
    return cards;
  }

  String _formatInsightDate(DateTime? value) {
    if (value == null) return 'N/A';
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
    final month = months[(value.month - 1).clamp(0, 11)];
    var hour = value.hour;
    final ampm = hour >= 12 ? 'PM' : 'AM';
    hour = hour % 12;
    if (hour == 0) hour = 12;
    final minute = value.minute.toString().padLeft(2, '0');
    return '$month ${value.day}, ${value.year} $hour:$minute $ampm';
  }

  String? _firstValidImageUrl(List<dynamic> candidates) {
    for (final candidate in candidates) {
      final resolved = _resolveImageUrl(candidate);
      if (resolved != null && resolved.isNotEmpty) {
        return resolved;
      }
    }
    return null;
  }

  String? _resolveImageUrl(dynamic value) {
    if (value == null) return null;
    if (value is String) {
      final text = value.trim();
      if (text.isEmpty) return null;
      if (text.startsWith('http://') || text.startsWith('https://')) {
        return text;
      }
      if (text.startsWith('//')) return 'https:$text';
      if (text.startsWith('/')) return 'https://blackforest.vseyal.com$text';
      if (text.contains(' ')) return null;
      return 'https://blackforest.vseyal.com/$text';
    }
    if (value is List) {
      for (final entry in value) {
        final resolved = _resolveImageUrl(entry);
        if (resolved != null) return resolved;
      }
      return null;
    }
    if (value is Map) {
      final map = Map<String, dynamic>.from(value);
      final sizes = _asMap(map['sizes']);
      final nestedCandidates = <dynamic>[
        map['url'],
        map['imageUrl'],
        map['src'],
        map['path'],
        map['filename'],
        map['thumbnailURL'],
        map['thumbnailUrl'],
        map['largeURL'],
        map['largeUrl'],
        map['mediumURL'],
        map['mediumUrl'],
        map['smallURL'],
        map['smallUrl'],
        map['image'],
        map['photo'],
        map['thumbnail'],
        map['file'],
        sizes?['thumbnail'],
        sizes?['medium'],
        sizes?['large'],
      ];
      for (final candidate in nestedCandidates) {
        final resolved = _resolveImageUrl(candidate);
        if (resolved != null) return resolved;
      }
    }
    return null;
  }

  String? _productKeyFromInsightItem(
    Map<String, dynamic> item, {
    Map<String, dynamic>? product,
    String? fallbackName,
  }) {
    final productMap = product ?? _asMap(item['product']);
    final productId =
        (productMap?['id'] ??
                productMap?['_id'] ??
                item['productId'] ??
                item['product'])
            ?.toString()
            .trim();
    if (productId != null && productId.isNotEmpty) {
      return 'id:$productId';
    }

    final itemName =
        (fallbackName ??
                item['name'] ??
                productMap?['name'] ??
                item['productName'] ??
                '')
            .toString()
            .trim();
    if (itemName.isEmpty) return null;
    return 'name:${itemName.toLowerCase()}';
  }

  String _billProductReviewKey(String billId, String productKey) {
    return '$billId|$productKey';
  }

  String _billTimeProductReviewKey(String billUpdatedAt, String productKey) {
    return '$billUpdatedAt|$productKey';
  }

  void _addBillKeyCandidate(Set<String> output, dynamic value) {
    final key = value?.toString().trim() ?? '';
    if (key.isNotEmpty) output.add(key);
  }

  Set<String> _reviewBillKeyCandidatesFromReviewDoc(
    Map<String, dynamic> reviewDoc,
  ) {
    final keys = <String>{};
    final billValue = reviewDoc['bill'];
    if (billValue is String) {
      _addBillKeyCandidate(keys, billValue);
      return keys;
    }
    if (billValue is Map) {
      final billMap = Map<String, dynamic>.from(billValue);
      _addBillKeyCandidate(keys, billMap['id']);
      _addBillKeyCandidate(keys, billMap['_id']);
      _addBillKeyCandidate(keys, billMap['invoiceNumber']);
      _addBillKeyCandidate(keys, billMap['kotNumber']);
    }
    return keys;
  }

  Set<String> _billKeyCandidatesFromBill(Map<String, dynamic> bill) {
    final keys = <String>{};
    _addBillKeyCandidate(keys, _billKey(bill));
    _addBillKeyCandidate(keys, bill['id']);
    _addBillKeyCandidate(keys, bill['_id']);
    _addBillKeyCandidate(keys, bill['invoiceNumber']);
    _addBillKeyCandidate(keys, bill['kotNumber']);
    return keys;
  }

  void _openProductVisitDetails(_ProductInsightCardData product) {
    setState(() {
      _selectedProductKey = product.key;
      _selectedProductName = product.name;
    });
  }

  void _closeProductVisitDetails() {
    setState(() {
      _selectedProductKey = null;
      _selectedProductName = null;
    });
  }

  List<_ProductVisitEntry> _productVisitEntries({
    required List<Map<String, dynamic>> bills,
    required String productKey,
  }) {
    final entries = <_ProductVisitEntry>[];

    for (final bill in bills) {
      final items = bill['items'];
      if (items is! List) continue;
      final billKeys = _billKeyCandidatesFromBill(bill);
      var visitCount = 0.0;
      String? matchedNameKey;

      for (final raw in items) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final status = (item['status']?.toString() ?? '').toLowerCase().trim();
        if (status == 'cancelled' || status == 'canceled') continue;

        final product = _asMap(item['product']);
        final itemKey = _productKeyFromInsightItem(item, product: product);
        if (itemKey != productKey) continue;

        final qtyRaw = _asDouble(item['quantity']) ?? 0.0;
        final quantity = qtyRaw.isFinite && qtyRaw > 0 ? qtyRaw : 0.0;
        if (quantity <= 0) continue;
        visitCount += quantity;

        if (matchedNameKey == null) {
          final itemName =
              (item['name'] ?? product?['name'] ?? item['productName'] ?? '')
                  .toString()
                  .trim();
          if (itemName.isNotEmpty) {
            matchedNameKey = 'name:${itemName.toLowerCase()}';
          }
        }
      }

      if (visitCount <= 0) continue;
      final billUpdatedAtRaw =
          (bill['updatedAt'] ?? bill['createdAt'])?.toString().trim() ?? '';
      final visitedAt = DateTime.tryParse(
        (bill['updatedAt'] ?? bill['createdAt'])?.toString() ?? '',
      )?.toLocal();
      String? reviewMessage;
      if (billKeys.isNotEmpty) {
        for (final billKey in billKeys) {
          reviewMessage =
              _reviewMessageByBillProductKey[_billProductReviewKey(
                billKey,
                productKey,
              )];
          if (reviewMessage != null && reviewMessage.trim().isNotEmpty) {
            break;
          }
          if (matchedNameKey != null) {
            reviewMessage =
                _reviewMessageByBillProductKey[_billProductReviewKey(
                  billKey,
                  matchedNameKey,
                )];
            if (reviewMessage != null && reviewMessage.trim().isNotEmpty) {
              break;
            }
          }
        }
      }
      if ((reviewMessage == null || reviewMessage.trim().isEmpty) &&
          billUpdatedAtRaw.isNotEmpty) {
        reviewMessage =
            _reviewMessageByBillTimeProductKey[_billTimeProductReviewKey(
              billUpdatedAtRaw,
              productKey,
            )];
        if ((reviewMessage == null || reviewMessage.trim().isEmpty) &&
            matchedNameKey != null) {
          reviewMessage =
              _reviewMessageByBillTimeProductKey[_billTimeProductReviewKey(
                billUpdatedAtRaw,
                matchedNameKey,
              )];
        }
      }
      entries.add(
        _ProductVisitEntry(
          visitedAt: visitedAt,
          count: visitCount,
          reviewMessage: reviewMessage,
        ),
      );
    }

    entries.sort((a, b) {
      final aTime = a.visitedAt?.millisecondsSinceEpoch ?? 0;
      final bTime = b.visitedAt?.millisecondsSinceEpoch ?? 0;
      return bTime.compareTo(aTime);
    });
    return entries;
  }

  Widget _buildProductVisitDetailsBody({
    required List<Map<String, dynamic>> sourceBills,
    required String productKey,
    required String productName,
  }) {
    final visits = _productVisitEntries(
      bills: sourceBills,
      productKey: productKey,
    );
    if (_isLoadingProductInsights && visits.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF262626),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white24),
          ),
          child: Text(
            productName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: visits.isEmpty
              ? const Center(
                  child: Text(
                    "No visits found for this product",
                    style: TextStyle(color: Colors.white70),
                  ),
                )
              : ListView.separated(
                  itemCount: visits.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final visit = visits[index];
                    return Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF232323),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text:
                                      '${_formatInsightDate(visit.visitedAt)} - ',
                                ),
                                TextSpan(
                                  text: _formatSummaryAmount(visit.count),
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ],
                            ),
                            style: const TextStyle(
                              color: _insightGreen,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if ((visit.reviewMessage?.trim().isNotEmpty ??
                              false)) ...[
                            const SizedBox(height: 4),
                            SizedBox(
                              height: 14,
                              child: _AutoMarqueeText(
                                text: 'Review: ${visit.reviewMessage!.trim()}',
                                gap: 24,
                                pixelsPerSecond: 28,
                                style: const TextStyle(
                                  color: Color(0xFFB8E8C6),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildProductInsightBody() {
    final sourceBills = _insightBills.isNotEmpty ? _insightBills : _bills;
    final cards = _productInsightCards(sourceBills);
    final selectedProductKey = _selectedProductKey;
    if (selectedProductKey != null) {
      String selectedName = _selectedProductName?.trim() ?? '';
      for (final card in cards) {
        if (card.key == selectedProductKey) {
          selectedName = card.name;
          break;
        }
      }
      if (selectedName.isEmpty) selectedName = 'Product';
      return _buildProductVisitDetailsBody(
        sourceBills: sourceBills,
        productKey: selectedProductKey,
        productName: selectedName,
      );
    }

    if (_isLoadingProductInsights && cards.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_productInsightsError != null && cards.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _productInsightsError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _loadProductInsights,
              child: const Text("Retry"),
            ),
          ],
        ),
      );
    }
    if (cards.isEmpty) {
      return const Center(
        child: Text(
          "No product history found",
          style: TextStyle(color: Colors.white70),
        ),
      );
    }

    return Column(
      children: [
        if (_isLoadingProductInsights)
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: LinearProgressIndicator(
              minHeight: 2,
              color: _insightGreen,
              backgroundColor: Color(0xFF3A3A3A),
            ),
          ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: cards.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 0.86,
            ),
            itemBuilder: (context, index) {
              final item = cards[index];
              final reviewMessage = item.lastReviewMessage?.trim() ?? '';
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _openProductVisitDetails(item),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: _buildProductInsightImage(item.imageUrl),
                            ),
                            Positioned(
                              left: 8,
                              right: 8,
                              bottom: 8,
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Container(
                                    margin: const EdgeInsets.only(top: 10),
                                    padding: const EdgeInsets.fromLTRB(
                                      8,
                                      13,
                                      8,
                                      7,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: 0.92,
                                      ),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          item.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Color(0xFF1F1F1F),
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w800,
                                            height: 1.15,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        FittedBox(
                                          fit: BoxFit.scaleDown,
                                          alignment: Alignment.centerLeft,
                                          child: Text(
                                            'Last Visit: ${_formatInsightDate(item.lastEatenAt)}',
                                            maxLines: 1,
                                            softWrap: false,
                                            style: const TextStyle(
                                              color: _insightGreen,
                                              fontSize: 10.4,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Positioned(
                                    top: 0,
                                    left: 0,
                                    right: 0,
                                    child: Align(
                                      alignment: Alignment.topCenter,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: _insightGreen,
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          border: Border.all(
                                            color: Colors.white,
                                            width: 1.2,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withValues(
                                                alpha: 0.18,
                                              ),
                                              blurRadius: 7,
                                              offset: const Offset(0, 2),
                                            ),
                                          ],
                                        ),
                                        child: Text(
                                          'Count: ${_formatSummaryAmount(item.totalQuantity)}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 10.8,
                                            fontWeight: FontWeight.w700,
                                            height: 1,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      height: 14,
                      child: reviewMessage.isEmpty
                          ? const SizedBox.shrink()
                          : _AutoMarqueeText(
                              text: 'Review: $reviewMessage',
                              gap: 26,
                              pixelsPerSecond: 28,
                              style: const TextStyle(
                                color: Color(0xFFB8E8C6),
                                fontSize: 9.8,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildProductInsightImage(String? imageUrl) {
    if (imageUrl == null || imageUrl.isEmpty) {
      return Container(
        color: const Color(0xFFEFF5F0),
        alignment: Alignment.center,
        child: const Icon(
          Icons.local_dining_outlined,
          color: _insightGreen,
          size: 34,
        ),
      );
    }
    return Image.network(
      imageUrl,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) {
        return Container(
          color: const Color(0xFFEFF5F0),
          alignment: Alignment.center,
          child: const Icon(
            Icons.broken_image_outlined,
            color: _insightGreen,
            size: 30,
          ),
        );
      },
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return Container(
          color: const Color(0xFFEFF5F0),
          alignment: Alignment.center,
          child: const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: _insightGreen,
            ),
          ),
        );
      },
    );
  }

  String _formatSummaryAmount(double value) {
    final fixed = value.toStringAsFixed(2);
    if (fixed.endsWith('.00')) return fixed.substring(0, fixed.length - 3);
    if (fixed.endsWith('0')) return fixed.substring(0, fixed.length - 1);
    return fixed;
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final knownBills = (_knownTotalBills != null && _knownTotalBills! > 0)
        ? _knownTotalBills!
        : _bills.length;
    final footerBillCount = knownBills < 0 ? 0 : knownBills;
    final footerTotalAmount = _resolveTotalAmount(
      preferredAmount: _knownTotalAmount,
      existingAmount: null,
      bills: _bills,
      hasMore: _hasMore,
      totalBillsHint: _knownTotalBills,
    );
    final footerVisibleAmount =
        footerTotalAmount ??
        (_bills.isNotEmpty ? _sumBillAmounts(_bills) : null);
    final showFooter =
        !_isLoading &&
        _error == null &&
        (footerBillCount > 0 || footerTotalAmount != null);
    final isProductDetailView =
        _showProductInsights && _selectedProductKey != null;
    final dialogTitle = isProductDetailView
        ? "Product Visits"
        : _showProductInsights
        ? "Customer Favorite's"
        : "Customer History";
    final popupWidth = (screenSize.width * (_showProductInsights ? 0.98 : 0.95))
        .clamp(0.0, _showProductInsights ? 980.0 : 760.0)
        .toDouble();
    final popupHeight = screenSize.height * (_showProductInsights ? 0.92 : 0.9);

    return Dialog(
      backgroundColor: const Color(0xFF1E1E1E),
      insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: popupWidth,
        height: popupHeight,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      if (isProductDetailView)
                        IconButton(
                          icon: const Icon(
                            Icons.arrow_back_rounded,
                            color: Colors.white70,
                          ),
                          tooltip: "Back",
                          onPressed: _closeProductVisitDetails,
                        ),
                      Flexible(
                        child: Text(
                          dialogTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!isProductDetailView)
                      IconButton(
                        icon: Icon(
                          _showProductInsights
                              ? Icons.receipt_long
                              : Icons.grid_view_rounded,
                          color: Colors.white70,
                        ),
                        tooltip: _showProductInsights
                            ? "Show Bills"
                            : "Show Product Grid",
                        onPressed: _isLoading ? null : _toggleProductInsights,
                      ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
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
                  : _showProductInsights
                  ? _buildProductInsightBody()
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
                                child: ReceiptContent(
                                  bill: _bills[index],
                                  reviewMessageByBillProductKey:
                                      _reviewMessageByBillProductKey,
                                  reviewMessageByBillTimeProductKey:
                                      _reviewMessageByBillTimeProductKey,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (showFooter) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B8F3D),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.28),
                  ),
                ),
                child: Text(
                  'Total Amount: ${footerVisibleAmount == null ? '0' : _formatSummaryAmount(footerVisibleAmount)} ($footerBillCount ${footerBillCount == 1 ? 'Bill' : 'Bills'})',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AutoMarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final double gap;
  final double pixelsPerSecond;

  const _AutoMarqueeText({
    required this.text,
    required this.style,
    this.gap = 26,
    this.pixelsPerSecond = 28,
  });

  @override
  State<_AutoMarqueeText> createState() => _AutoMarqueeTextState();
}

class _AutoMarqueeTextState extends State<_AutoMarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _lastCycleExtent = -1;
  bool _isRunning = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _stopMarquee() {
    if (!_isRunning) return;
    _controller.stop();
    _controller.reset();
    _isRunning = false;
    _lastCycleExtent = -1;
  }

  void _startOrUpdateMarquee(double cycleExtent) {
    if (cycleExtent <= 0) {
      _stopMarquee();
      return;
    }

    final speed = widget.pixelsPerSecond <= 0 ? 28.0 : widget.pixelsPerSecond;
    final durationMs = (cycleExtent / speed * 1000).round().clamp(1800, 30000);
    final duration = Duration(milliseconds: durationMs);
    final extentChanged = (_lastCycleExtent - cycleExtent).abs() > 0.5;
    final durationChanged = _controller.duration != duration;

    if (durationChanged) {
      _controller.duration = duration;
    }
    if (!_isRunning || extentChanged || durationChanged) {
      _lastCycleExtent = cycleExtent;
      _controller
        ..reset()
        ..repeat();
      _isRunning = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || constraints.maxWidth <= 0) {
          _stopMarquee();
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }

        final textPainter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout(minWidth: 0, maxWidth: double.infinity);

        final textWidth = textPainter.width;
        final availableWidth = constraints.maxWidth;

        if (textWidth <= availableWidth + 0.5) {
          _stopMarquee();
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }

        final cycleExtent = textWidth + widget.gap;
        _startOrUpdateMarquee(cycleExtent);

        final marqueeText = Text(
          widget.text,
          maxLines: 1,
          softWrap: false,
          style: widget.style,
        );

        return ClipRect(
          child: SizedBox(
            width: availableWidth,
            height: textPainter.height,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final dx = -_controller.value * cycleExtent;
                return Stack(
                  children: [
                    Positioned(
                      left: dx,
                      top: 0,
                      child: SizedBox(width: textWidth, child: marqueeText),
                    ),
                    Positioned(
                      left: dx + cycleExtent,
                      top: 0,
                      child: SizedBox(width: textWidth, child: marqueeText),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
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
  final Map<String, String> reviewMessageByBillProductKey;
  final Map<String, String> reviewMessageByBillTimeProductKey;
  const ReceiptContent({
    super.key,
    required this.bill,
    this.reviewMessageByBillProductKey = const <String, String>{},
    this.reviewMessageByBillTimeProductKey = const <String, String>{},
  });

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

  String _formatGstPercent(double value) {
    final safe = (value.isNaN || value.isInfinite || value < 0) ? 0.0 : value;
    final fixed = safe.toStringAsFixed(2);
    var normalized = fixed;
    if (normalized.endsWith('.00')) {
      normalized = normalized.substring(0, normalized.length - 3);
    } else if (normalized.endsWith('0')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return '$normalized%';
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

  String _billProductReviewKey(String billId, String productKey) {
    return '$billId|$productKey';
  }

  String _billTimeProductReviewKey(String billUpdatedAt, String productKey) {
    return '$billUpdatedAt|$productKey';
  }

  void _addBillKeyCandidate(Set<String> output, dynamic value) {
    final key = value?.toString().trim() ?? '';
    if (key.isNotEmpty) output.add(key);
  }

  Set<String> _billKeyCandidates(Map<String, dynamic> bill) {
    final keys = <String>{};
    _addBillKeyCandidate(keys, bill['id']);
    _addBillKeyCandidate(keys, bill['_id']);
    _addBillKeyCandidate(keys, bill['invoiceNumber']);
    _addBillKeyCandidate(keys, bill['kotNumber']);
    return keys;
  }

  String? _productKeyFromItem(
    Map<String, dynamic> item, {
    Map<String, dynamic>? product,
    String? fallbackName,
  }) {
    final productMap = product ?? _asMap(item['product']);
    final productId =
        (productMap?['id'] ??
                productMap?['_id'] ??
                item['productId'] ??
                item['product'])
            ?.toString()
            .trim();
    if (productId != null && productId.isNotEmpty) return 'id:$productId';

    final name =
        (fallbackName ??
                item['name'] ??
                productMap?['name'] ??
                item['productName'] ??
                '')
            .toString()
            .trim();
    if (name.isEmpty) return null;
    return 'name:${name.toLowerCase()}';
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

    final billKeyCandidates = _billKeyCandidates(bill);
    final billUpdatedAtRaw =
        (bill['updatedAt'] ?? bill['createdAt'])?.toString().trim() ?? '';

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
      final productKey = _productKeyFromItem(
        item,
        product: product,
        fallbackName: itemName,
      );
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
      var gstPercent = _positiveMoney(
        item['gstRate'] ??
            item['gstPercent'] ??
            item['gst'] ??
            item['taxPercent'],
      );
      if (tax <= 0 && amount > 0) {
        if (gstPercent > 0) {
          tax = (amount * gstPercent) / 100;
        }
      }
      if (gstPercent <= 0 && amount > 0 && tax > 0) {
        gstPercent = (tax * 100) / amount;
      }

      lineItems.add({
        'name': itemName,
        'productKey': productKey,
        'nameKey': 'name:${itemName.toLowerCase()}',
        'qty': quantity,
        'unitPrice': unitPrice,
        'tax': tax,
        'gstPercent': gstPercent,
        'amount': amount,
      });
      lineAmountTotal += amount;
      lineTaxTotal += tax;
    }

    for (final entry in lineItems) {
      final productKey = entry['productKey']?.toString().trim() ?? '';
      final nameKey = entry['nameKey']?.toString().trim() ?? '';
      final reviewProductKeys = <String>{
        if (productKey.isNotEmpty) productKey,
        if (nameKey.isNotEmpty) nameKey,
      };
      if (reviewProductKeys.isEmpty) continue;
      String? reviewMessage;
      for (final billKey in billKeyCandidates) {
        for (final reviewProductKey in reviewProductKeys) {
          reviewMessage =
              widget.reviewMessageByBillProductKey[_billProductReviewKey(
                billKey,
                reviewProductKey,
              )];
          if (reviewMessage != null && reviewMessage.trim().isNotEmpty) break;
        }
        if (reviewMessage != null && reviewMessage.trim().isNotEmpty) {
          break;
        }
      }
      if ((reviewMessage == null || reviewMessage.trim().isEmpty) &&
          billUpdatedAtRaw.isNotEmpty) {
        for (final reviewProductKey in reviewProductKeys) {
          reviewMessage =
              widget
                  .reviewMessageByBillTimeProductKey[_billTimeProductReviewKey(
                billUpdatedAtRaw,
                reviewProductKey,
              )];
          if (reviewMessage != null && reviewMessage.trim().isNotEmpty) break;
        }
      }
      if (reviewMessage == null || reviewMessage.trim().isEmpty) continue;
      entry['reviewMessage'] = reviewMessage.trim();
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
              tax: 'GST%',
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
              final reviewMessage =
                  entry['reviewMessage']?.toString().trim() ?? '';
              return Padding(
                padding: EdgeInsets.only(bottom: reviewMessage.isEmpty ? 0 : 3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _itemRow(
                      item: entry['name']?.toString() ?? 'ITEM',
                      qty: _formatQty(entry['qty'] as double),
                      price: _formatReceiptMoney(entry['unitPrice'] as double),
                      tax: _formatGstPercent(entry['gstPercent'] as double),
                      amount: _formatReceiptMoney(entry['amount'] as double),
                      style: strongPrintStyle,
                    ),
                    if (reviewMessage.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(2, 0, 2, 2),
                        child: Text(
                          'Review: $reviewMessage',
                          style: fadedPrintStyle.copyWith(
                            fontSize: 10.8,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
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
