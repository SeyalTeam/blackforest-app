import 'dart:convert';
import 'dart:math' as math;

import 'package:blackforest_app/app_http.dart' as http;

class ProductPopularityInfo {
  final double score;
  final int count;

  const ProductPopularityInfo({required this.score, required this.count});
}

class ProductPopularityService {
  static const Duration _cacheTtl = Duration(minutes: 5);
  static final Map<
    String,
    ({DateTime fetchedAt, Map<String, ProductPopularityInfo> values})
  >
  _cache =
      <
        String,
        ({DateTime fetchedAt, Map<String, ProductPopularityInfo> values})
      >{};
  static final Map<String, Future<Map<String, ProductPopularityInfo>>>
  _inFlight = <String, Future<Map<String, ProductPopularityInfo>>>{};

  static Future<Map<String, ProductPopularityInfo>> getPopularityForBranch({
    required String token,
    required String branchId,
  }) async {
    final normalizedBranchId = branchId.trim();
    if (normalizedBranchId.isEmpty) {
      return const <String, ProductPopularityInfo>{};
    }

    final cached = _cache[normalizedBranchId];
    if (cached != null &&
        DateTime.now().difference(cached.fetchedAt) < _cacheTtl) {
      return Map<String, ProductPopularityInfo>.from(cached.values);
    }

    final existing = _inFlight[normalizedBranchId];
    if (existing != null) {
      return existing;
    }

    final future = _fetchPopularityForBranch(
      token: token,
      branchId: normalizedBranchId,
    );
    _inFlight[normalizedBranchId] = future;

    try {
      final values = await future;
      _cache[normalizedBranchId] = (
        fetchedAt: DateTime.now(),
        values: Map<String, ProductPopularityInfo>.from(values),
      );
      return values;
    } finally {
      _inFlight.remove(normalizedBranchId);
    }
  }

  static Future<Map<String, ProductPopularityInfo>> _fetchPopularityForBranch({
    required String token,
    required String branchId,
  }) async {
    int readPositiveInt(dynamic value) {
      if (value is int && value > 0) return value;
      if (value is double && value > 0) return value.round();
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null && parsed > 0) return parsed;
      }
      return 0;
    }

    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value) ?? 0.0;
      return 0.0;
    }

    Map<String, dynamic>? toMap(dynamic value) {
      if (value is Map) {
        return Map<String, dynamic>.from(value);
      }
      return null;
    }

    List<dynamic> toDynamicList(dynamic value) {
      if (value == null) return const <dynamic>[];
      if (value is List) return List<dynamic>.from(value);
      if (value is Map) {
        final map = Map<String, dynamic>.from(value);
        for (final key in ['docs', 'items', 'rules', 'options', 'values']) {
          final nested = map[key];
          if (nested is List) return List<dynamic>.from(nested);
        }
        final data = map['data'];
        if (data is List) return List<dynamic>.from(data);
        if (data is Map) {
          for (final key in ['docs', 'items', 'rules', 'options', 'values']) {
            final nested = data[key];
            if (nested is List) return List<dynamic>.from(nested);
          }
        }
        return <dynamic>[value];
      }
      return <dynamic>[value];
    }

    String extractRefId(dynamic candidate) {
      if (candidate == null) return '';
      if (candidate is Map) {
        final map = Map<String, dynamic>.from(candidate);
        final nested = extractRefId(
          map['id'] ??
              map['_id'] ??
              map[r'$oid'] ??
              map['value'] ??
              map['product'] ??
              map['productId'],
        );
        if (nested.isNotEmpty) return nested;
      }
      final id = candidate.toString().trim();
      return id == 'null' ? '' : id;
    }

    Future<List<dynamic>> fetchBills(Map<String, String> query) async {
      final aggregated = <dynamic>[];
      var currentPage = 1;
      var totalPages = 1;
      const pageLimit = 100;

      while (currentPage <= totalPages) {
        final pagedQuery = <String, String>{
          ...query,
          'limit': pageLimit.toString(),
          'page': currentPage.toString(),
        };
        final uri = Uri.parse(
          'https://blackforest.vseyal.com/api/billings',
        ).replace(queryParameters: pagedQuery);

        final response = await http.get(
          uri,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
        );
        if (response.statusCode != 200) break;

        final decoded = jsonDecode(response.body);
        final pageItems = toDynamicList(decoded);
        if (pageItems.isEmpty) break;
        aggregated.addAll(pageItems);

        final payload = toMap(decoded);
        final payloadData = payload == null ? null : toMap(payload['data']);
        final nextTotalPages = readPositiveInt(
          payload?['totalPages'] ?? payloadData?['totalPages'],
        );
        if (nextTotalPages > 0) {
          totalPages = nextTotalPages;
        } else if (pageItems.length < pageLimit) {
          break;
        } else {
          totalPages = currentPage + 1;
        }
        currentPage += 1;
      }

      return aggregated;
    }

    final bills = await fetchBills({
      'where[branch][equals]': branchId,
      'sort': '-createdAt',
      'depth': '2',
    });

    final countsByProductId = <String, double>{};
    for (final rawBill in bills) {
      final bill = toMap(rawBill);
      if (bill == null) continue;

      final items = toDynamicList(bill['items']);
      for (final rawItem in items) {
        final item = toMap(rawItem);
        if (item == null) continue;
        final status = item['status']?.toString().toLowerCase().trim() ?? '';
        if (status == 'cancelled') continue;

        final productId = extractRefId(
          item['product'] ?? item['productId'] ?? item['id'],
        );
        if (productId.isEmpty) continue;

        final qty = toDouble(item['quantity']);
        countsByProductId[productId] =
            (countsByProductId[productId] ?? 0) + (qty > 0 ? qty : 1.0);
      }
    }

    final popularity = <String, ProductPopularityInfo>{};
    for (final entry in countsByProductId.entries) {
      final count = entry.value.round();
      if (count <= 0) continue;
      final normalized =
          math.log(count + 1) / math.log(251); // 0..~1 for 1..250
      final score = 4.0 + math.min(0.9, normalized * 0.9);
      popularity[entry.key] = ProductPopularityInfo(
        score: double.parse(score.toStringAsFixed(1)),
        count: count,
      );
    }

    return popularity;
  }
}
