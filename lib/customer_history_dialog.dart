import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
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

  const _HistorySummaryResult({this.totalBills, this.totalAmount});
}

class _CustomerHistoryDialogState extends State<CustomerHistoryDialog> {
  static const Duration _historyLoadTimeout = Duration(seconds: 12);
  static const int _initialBillLimit = 2;
  static const int _loadMoreBillLimit = 1;
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
  double _overallTotal = 0;
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
        _overallTotal = 0;
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
        _overallTotal = 0;
      });
    }

    try {
      final initialData = await Future.wait<dynamic>([
        _fetchBillsPage(
          normalizedPhone: normalizedPhone,
          page: 1,
          limit: _initialBillLimit,
        ).timeout(_historyLoadTimeout),
        _fetchHistorySummary(normalizedPhone).timeout(_historyLoadTimeout),
      ]);
      final firstPage = initialData[0] as _BillPageResult;
      final summary = initialData[1] as _HistorySummaryResult;
      final initialBills = _sortBillsByDate(firstPage.bills);
      _resolvedPhoneField = firstPage.phoneField;
      _knownTotalBills = summary.totalBills ?? firstPage.totalDocs;

      final hasMore = (_knownTotalBills != null && _knownTotalBills! > 0)
          ? initialBills.length < _knownTotalBills!
          : initialBills.length >= _initialBillLimit;
      final loadedTotal = summary.totalAmount != null
          ? summary.totalAmount!
          : _totalOfBills(initialBills);

      if (mounted) {
        setState(() {
          _bills = initialBills;
          _overallTotal = loadedTotal;
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

  double _readMoney(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  double _totalOfBills(List<Map<String, dynamic>> bills) {
    var total = 0.0;
    for (final bill in bills) {
      total += _readMoney(
        bill['totalAmount'] ??
            bill['grossAmount'] ??
            bill['finalAmount'] ??
            bill['subtotal'] ??
            bill['amount'],
      );
    }
    return total;
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

      for (final field in fieldsToTry) {
        final uri = Uri.parse('https://blackforest.vseyal.com/api/billings')
            .replace(
              queryParameters: {
                'sort': '-createdAt',
                'page': page.toString(),
                'limit': limit.toString(),
                'depth': '4',
                'where[$field][equals]': normalizedPhone,
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
    } catch (_) {}
    return const _BillPageResult();
  }

  Future<_HistorySummaryResult> _fetchHistorySummary(
    String normalizedPhone,
  ) async {
    try {
      final cartProvider = Provider.of<CartProvider>(context, listen: false);
      final accurateData = await cartProvider
          .fetchCustomerLookupPreview(
            normalizedPhone,
            limit: 1,
            includeCancelled: false,
            useHeavyFallback: true,
          )
          .timeout(const Duration(seconds: 12));
      if (accurateData != null) {
        final accurateBills = _extractSummaryTotalBills(accurateData);
        final accurateAmount = _extractSummaryTotalAmount(accurateData);
        if (accurateBills != null || accurateAmount != null) {
          return _HistorySummaryResult(
            totalBills: accurateBills,
            totalAmount: accurateAmount,
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
      return _HistorySummaryResult(
        totalBills: _extractSummaryTotalBills(decoded),
        totalAmount: _extractSummaryTotalAmount(decoded),
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
            if (!_isLoading && _bills.isNotEmpty) ...[
              const Divider(color: Colors.white24, height: 32),
              Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 8,
                  horizontal: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.green.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "Total Amount",
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

class _ReceiptRule extends StatelessWidget {
  final Color color;
  final double dashWidth;
  final double gapWidth;

  const _ReceiptRule({
    this.color = const Color(0xFF6C675E),
    this.dashWidth = 8,
    this.gapWidth = 4,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final dashCount = (constraints.maxWidth / (dashWidth + gapWidth))
            .floor()
            .clamp(1, 200);

        return Row(
          children: List.generate(dashCount, (index) {
            return Padding(
              padding: EdgeInsets.only(
                right: index == dashCount - 1 ? 0 : gapWidth,
              ),
              child: SizedBox(
                width: dashWidth,
                height: 1.2,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.75),
                  ),
                ),
              ),
            );
          }),
        );
      },
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
  static final Map<String, Map<String, dynamic>?> _reviewCacheByBillId = {};
  static final Map<String, Future<Map<String, dynamic>?>>
  _reviewFutureByBillId = {};

  Map<String, dynamic>? _reviewData;
  bool _isLoadingReview = true;

  @override
  void initState() {
    super.initState();
    final billId = _extractBillId(widget.bill);
    if (billId != null && _reviewCacheByBillId.containsKey(billId)) {
      _reviewData = _reviewCacheByBillId[billId];
      _isLoadingReview = false;
      return;
    }
    if (billId == null || billId.isEmpty) {
      _isLoadingReview = false;
      return;
    }
    _fetchReview();
  }

  Future<void> _fetchReview() async {
    final billId = _extractBillId(widget.bill);
    if (billId == null || billId.isEmpty) {
      if (mounted) {
        setState(() => _isLoadingReview = false);
      }
      return;
    }

    if (_reviewCacheByBillId.containsKey(billId)) {
      if (mounted) {
        setState(() {
          _reviewData = _reviewCacheByBillId[billId];
          _isLoadingReview = false;
        });
      }
      return;
    }

    final future = _reviewFutureByBillId[billId] ??= _fetchReviewForBill(
      billId,
    );
    final data = await future;
    _reviewFutureByBillId.remove(billId);
    _reviewCacheByBillId[billId] = data;

    if (mounted) {
      setState(() {
        _reviewData = data;
        _isLoadingReview = false;
      });
    }
  }

  String? _extractBillId(dynamic bill) {
    if (bill is! Map) return null;
    return (bill['id'] ?? bill['_id'] ?? bill[r'$oid'])?.toString();
  }

  Future<Map<String, dynamic>?> _fetchReviewForBill(String billId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null || token.isEmpty) {
        return null;
      }

      final res = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/reviews?where[bill][equals]=$billId&limit=1',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['docs'] is List && (data['docs'] as List).isNotEmpty) {
          return data['docs'][0] as Map<String, dynamic>;
        }
      }
    } catch (_) {}
    return null;
  }

  String _textOf(dynamic value, {String fallback = 'N/A'}) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return fallback;
    return text;
  }

  double _moneyOf(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  double? _moneyOrNull(dynamic value) {
    final amount = _moneyOf(value);
    if (amount <= 0) return null;
    return amount;
  }

  String _formatQuantity(dynamic value) {
    num? quantity;
    if (value is num) {
      quantity = value;
    } else if (value is String) {
      quantity = num.tryParse(value);
    }

    if (quantity == null) return '0';
    if (quantity % 1 == 0) return quantity.toInt().toString();
    return quantity.toStringAsFixed(2);
  }

  int _totalQuantityOf(List items) {
    return items.fold<int>(0, (sum, item) {
      num? quantity;
      final value = item is Map ? item['quantity'] : null;
      if (value is num) {
        quantity = value;
      } else if (value is String) {
        quantity = num.tryParse(value);
      }
      return sum + (quantity?.round() ?? 0);
    });
  }

  Widget _buildSummaryLine(
    String label,
    String value,
    TextStyle labelStyle,
    TextStyle valueStyle,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: labelStyle)),
          Text(value, style: valueStyle),
        ],
      ),
    );
  }

  Widget _buildMetaCell(
    MapEntry<String, String> entry,
    TextStyle labelStyle,
    TextStyle valueStyle,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(entry.key, style: labelStyle),
        const SizedBox(height: 4),
        Text(
          entry.value,
          style: valueStyle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildMetaSection(
    List<List<MapEntry<String, String>>> rows,
    TextStyle labelStyle,
    TextStyle valueStyle,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
      ),
      child: Column(
        children: List.generate(rows.length, (index) {
          final rowEntries = rows[index];
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              border: index == rows.length - 1
                  ? null
                  : Border(
                      bottom: BorderSide(
                        color: Colors.black.withValues(alpha: 0.08),
                      ),
                    ),
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _buildMetaCell(
                      rowEntries.first,
                      labelStyle,
                      valueStyle,
                    ),
                  ),
                  if (rowEntries.length > 1) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: Colors.black.withValues(alpha: 0.08),
                      ),
                    ),
                    Expanded(
                      child: _buildMetaCell(
                        rowEntries[1],
                        labelStyle,
                        valueStyle,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bill = widget.bill;
    final items = bill['items'] as List? ?? [];
    final createdAt = DateTime.tryParse(
      _textOf(bill['createdAt'], fallback: ''),
    );
    final date = createdAt?.toLocal();
    final formattedDate = date == null
        ? 'N/A'
        : "${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year.toString().substring(2)}";
    final formattedTime = date == null
        ? '--:--'
        : "${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}";
    final billNumber = _textOf(
      bill['kotNumber']?.toString().split('-KOT').first ??
          bill['invoiceNumber']?.toString().split('-').last ??
          bill['invoiceNumber'],
    );
    final createdBy = _textOf(
      bill['createdBy'] is Map
          ? (bill['createdBy'] as Map)['name']
          : bill['createdBy'],
    );
    final paymentMethod = _textOf(bill['paymentMethod']).toUpperCase();
    final rawCustomerDetails = bill['customerDetails'];
    final Map? customerDetails = rawCustomerDetails is Map
        ? rawCustomerDetails
        : null;
    final customerName = _textOf(customerDetails?['name']).toUpperCase();
    final customerPhone = _textOf(
      customerDetails?['phoneNumber'] ?? customerDetails?['phone'],
    );
    final totalQuantity = _totalQuantityOf(items);
    final subtotal = _moneyOf(
      bill['subTotal'] ??
          bill['subtotal'] ??
          bill['itemsTotal'] ??
          bill['totalAmount'],
    );
    final discountAmount = _moneyOrNull(
      bill['discountAmount'] ?? bill['discount'],
    );
    final taxAmount = _moneyOrNull(
      bill['gstAmount'] ?? bill['taxAmount'] ?? bill['tax'],
    );
    final grandTotal = _moneyOf(bill['totalAmount']);

    const printColor = Color(0xFF1F1B17);
    const fadedPrintColor = Color(0xFF6C675E);
    final basePrintStyle = TextStyle(
      color: printColor,
      fontSize: 12.6,
      height: 1.28,
      letterSpacing: 0.35,
      fontFeatures: const [ui.FontFeature.tabularFigures()],
    );
    final titlePrintStyle = basePrintStyle.copyWith(
      fontSize: 19.5,
      fontWeight: FontWeight.w900,
      letterSpacing: 1.4,
    );
    final captionPrintStyle = basePrintStyle.copyWith(
      fontSize: 10.5,
      color: fadedPrintColor,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.6,
    );
    final labelPrintStyle = basePrintStyle.copyWith(
      color: fadedPrintColor,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.8,
    );
    final strongPrintStyle = basePrintStyle.copyWith(
      fontWeight: FontWeight.w800,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 26, 18, 28),
      child: DefaultTextStyle(
        style: basePrintStyle,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "BLACKFOREST CAKES",
              textAlign: TextAlign.center,
              style: titlePrintStyle,
            ),
            const SizedBox(height: 4),
            Text(
              "CUSTOMER HISTORY COPY",
              textAlign: TextAlign.center,
              style: captionPrintStyle,
            ),
            const SizedBox(height: 14),
            const _ReceiptRule(),
            const SizedBox(height: 12),
            _buildMetaSection(
              [
                [
                  MapEntry("BILL NO", billNumber),
                  MapEntry("DATE", "$formattedDate  $formattedTime"),
                ],
                [
                  MapEntry("STAFF", createdBy.toUpperCase()),
                  MapEntry("PAY MODE", paymentMethod),
                ],
                [
                  MapEntry("CUSTOMER NAME", customerName),
                  MapEntry("PHONE NUMBER", customerPhone),
                ],
              ],
              labelPrintStyle,
              strongPrintStyle,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
              ),
              child: Row(
                children: [
                  Expanded(child: Text("ITEM", style: labelPrintStyle)),
                  SizedBox(
                    width: 44,
                    child: Text(
                      "QTY",
                      textAlign: TextAlign.right,
                      style: labelPrintStyle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 68,
                    child: Text(
                      "AMOUNT",
                      textAlign: TextAlign.right,
                      style: labelPrintStyle,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  "NO LINE ITEMS AVAILABLE",
                  textAlign: TextAlign.center,
                  style: captionPrintStyle,
                ),
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

              final quantity = _formatQuantity(item['quantity']);
              final unitPrice = _moneyOf(item['unitPrice']);
              final itemTotal = _moneyOf(
                item['subtotal'] ?? item['total'] ?? item['price'],
              );
              final itemName = _textOf(
                item['name'],
                fallback: 'ITEM',
              ).toUpperCase();
              final rating = reviewItem?['rating'];
              final feedback = reviewItem?['feedback']?.toString().trim() ?? '';

              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            itemName,
                            style: strongPrintStyle.copyWith(fontSize: 13.2),
                          ),
                        ),
                        SizedBox(
                          width: 44,
                          child: Text(
                            quantity,
                            textAlign: TextAlign.right,
                            style: strongPrintStyle,
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 68,
                          child: Text(
                            itemTotal.toStringAsFixed(2),
                            textAlign: TextAlign.right,
                            style: strongPrintStyle,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "$quantity x ${unitPrice.toStringAsFixed(2)}",
                      style: captionPrintStyle.copyWith(
                        fontSize: 11.2,
                        letterSpacing: 0.8,
                      ),
                    ),
                    if (rating is int) ...[
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.38),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: Colors.black.withValues(alpha: 0.08),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "RATING  ${"★" * rating}${"☆" * (5 - rating)}",
                              style: strongPrintStyle.copyWith(fontSize: 11.8),
                            ),
                            if (feedback.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                feedback.toUpperCase(),
                                style: captionPrintStyle.copyWith(
                                  fontSize: 11.2,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: _ReceiptRule(
                        color: Colors.black.withValues(alpha: 0.28),
                        dashWidth: 6,
                        gapWidth: 4,
                      ),
                    ),
                  ],
                ),
              );
            }),
            if (_isLoadingReview)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.4,
                        color: Colors.black.withValues(alpha: 0.65),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text("LOADING CUSTOMER RATING", style: captionPrintStyle),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            const _ReceiptRule(),
            const SizedBox(height: 12),
            _buildSummaryLine(
              "LINE ITEMS",
              items.length.toString(),
              labelPrintStyle,
              strongPrintStyle,
            ),
            _buildSummaryLine(
              "TOTAL QTY",
              totalQuantity.toString(),
              labelPrintStyle,
              strongPrintStyle,
            ),
            _buildSummaryLine(
              "SUBTOTAL",
              subtotal.toStringAsFixed(2),
              labelPrintStyle,
              strongPrintStyle,
            ),
            if (discountAmount != null)
              _buildSummaryLine(
                "DISCOUNT",
                "-${discountAmount.toStringAsFixed(2)}",
                labelPrintStyle,
                strongPrintStyle,
              ),
            if (taxAmount != null)
              _buildSummaryLine(
                "TAX",
                taxAmount.toStringAsFixed(2),
                labelPrintStyle,
                strongPrintStyle,
              ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      "GRAND TOTAL",
                      style: strongPrintStyle.copyWith(
                        fontSize: 15.2,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                  Text(
                    "RS ${grandTotal.toStringAsFixed(2)}",
                    style: strongPrintStyle.copyWith(
                      fontSize: 16.8,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            const _ReceiptRule(),
            const SizedBox(height: 12),
            Text(
              "THANK YOU. VISIT AGAIN.",
              textAlign: TextAlign.center,
              style: strongPrintStyle.copyWith(
                fontSize: 12.4,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              "PRINTED FROM CUSTOMER HISTORY",
              textAlign: TextAlign.center,
              style: captionPrintStyle.copyWith(fontSize: 10.2),
            ),
          ],
        ),
      ),
    );
  }
}
