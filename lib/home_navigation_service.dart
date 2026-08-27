import 'dart:async';
import 'dart:convert';

import 'package:blackforest_app/app_http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class HomeNavigationService {
  static const Duration _cacheTtl = Duration(minutes: 10);
  static final Map<String, Future<bool>> _inFlightByBranch =
      <String, Future<bool>>{};
  static final Map<String, Future<bool>> _tableInFlightByBranch =
      <String, Future<bool>>{};

  static String _visibilityKey(String branchId) => 'home_nav_visible_$branchId';
  static String _fetchedAtKey(String branchId) =>
      'home_nav_visible_fetched_at_$branchId';
  static String _tableVisibilityKey(String branchId) =>
      'table_nav_visible_$branchId';
  static String _tableFetchedAtKey(String branchId) =>
      'table_nav_visible_fetched_at_$branchId';

  static bool readCachedVisibility(
    SharedPreferences prefs, {
    required String branchId,
    bool fallback = true,
  }) {
    final normalizedBranchId = branchId.trim();
    if (normalizedBranchId.isEmpty) {
      return fallback;
    }
    return prefs.getBool(_visibilityKey(normalizedBranchId)) ?? fallback;
  }

  static Future<bool> loadVisibilityForCurrentBranch({
    SharedPreferences? prefs,
    bool forceRefresh = false,
    bool fallback = true,
  }) async {
    final resolvedPrefs = prefs ?? await SharedPreferences.getInstance();
    final token = resolvedPrefs.getString('token')?.trim() ?? '';
    final branchId = resolvedPrefs.getString('branchId')?.trim() ?? '';
    if (branchId.isEmpty) {
      return fallback;
    }

    final cached = resolvedPrefs.getBool(_visibilityKey(branchId));
    final fetchedAtMillis = resolvedPrefs.getInt(_fetchedAtKey(branchId));
    final isFresh =
        fetchedAtMillis != null &&
        DateTime.now().difference(
              DateTime.fromMillisecondsSinceEpoch(fetchedAtMillis),
            ) <=
            _cacheTtl;

    if (!forceRefresh && cached != null && isFresh) {
      return cached;
    }

    if (token.isEmpty) {
      return cached ?? fallback;
    }

    final inFlight = _inFlightByBranch[branchId];
    final future =
        inFlight ??
        _fetchAndPersist(
          prefs: resolvedPrefs,
          token: token,
          branchId: branchId,
          fallback: cached ?? fallback,
        );

    if (inFlight == null) {
      _inFlightByBranch[branchId] = future;
    }

    try {
      return await future;
    } finally {
      if (identical(_inFlightByBranch[branchId], future)) {
        _inFlightByBranch.remove(branchId);
      }
    }
  }

  static bool readCachedTableVisibility(
    SharedPreferences prefs, {
    required String branchId,
    bool fallback = true,
  }) {
    final normalizedBranchId = branchId.trim();
    if (normalizedBranchId.isEmpty) {
      return fallback;
    }
    return prefs.getBool(_tableVisibilityKey(normalizedBranchId)) ?? fallback;
  }

  static Future<bool> loadTableVisibilityForCurrentBranch({
    SharedPreferences? prefs,
    bool forceRefresh = false,
    bool fallback = true,
  }) async {
    final resolvedPrefs = prefs ?? await SharedPreferences.getInstance();
    final token = resolvedPrefs.getString('token')?.trim() ?? '';
    final branchId = resolvedPrefs.getString('branchId')?.trim() ?? '';
    if (branchId.isEmpty) {
      return fallback;
    }

    final cached = resolvedPrefs.getBool(_tableVisibilityKey(branchId));
    final fetchedAtMillis = resolvedPrefs.getInt(_tableFetchedAtKey(branchId));
    final isFresh =
        fetchedAtMillis != null &&
        DateTime.now().difference(
              DateTime.fromMillisecondsSinceEpoch(fetchedAtMillis),
            ) <=
            _cacheTtl;

    if (!forceRefresh && cached != null && isFresh) {
      return cached;
    }

    if (token.isEmpty) {
      return cached ?? fallback;
    }

    final inFlight = _tableInFlightByBranch[branchId];
    final future =
        inFlight ??
        _fetchAndPersistTableVisibility(
          prefs: resolvedPrefs,
          token: token,
          branchId: branchId,
          fallback: cached ?? fallback,
        );

    if (inFlight == null) {
      _tableInFlightByBranch[branchId] = future;
    }

    try {
      return await future;
    } finally {
      if (identical(_tableInFlightByBranch[branchId], future)) {
        _tableInFlightByBranch.remove(branchId);
      }
    }
  }

  static Future<bool> _fetchAndPersist({
    required SharedPreferences prefs,
    required String token,
    required String branchId,
    required bool fallback,
  }) async {
    try {
      final response = await http
          .get(
            Uri.parse(
              'https://blackforest.vseyal.com/api/globals/widget-settings?depth=1',
            ),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        return fallback;
      }

      final decoded = jsonDecode(response.body);
      final isVisible =
          _hasFavoriteCategoriesForBranch(decoded, branchId) ||
          _hasFavoriteProductsForBranch(decoded, branchId);

      await prefs.setBool(_visibilityKey(branchId), isVisible);
      await prefs.setInt(
        _fetchedAtKey(branchId),
        DateTime.now().millisecondsSinceEpoch,
      );
      return isVisible;
    } catch (_) {
      return fallback;
    }
  }

  static Future<bool> _fetchAndPersistTableVisibility({
    required SharedPreferences prefs,
    required String token,
    required String branchId,
    required bool fallback,
  }) async {
    try {
      final response = await http
          .get(
            Uri.parse(
              'https://blackforest.vseyal.com/api/tables?where[branch][equals]=$branchId&limit=1&depth=1',
            ),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        return fallback;
      }

      final decoded = jsonDecode(response.body);
      final isVisible = _hasTableSections(decoded);

      await prefs.setBool(_tableVisibilityKey(branchId), isVisible);
      await prefs.setInt(
        _tableFetchedAtKey(branchId),
        DateTime.now().millisecondsSinceEpoch,
      );
      return isVisible;
    } catch (_) {
      return fallback;
    }
  }

  static bool _hasFavoriteCategoriesForBranch(
    dynamic decoded,
    String branchId,
  ) {
    final rulesNode = _findByKey(decoded, 'favoriteCategoriesByBranchRules');
    for (final rawRule in _toDynamicList(rulesNode)) {
      final rule = _toMap(rawRule);
      if (rule == null || !_toBool(rule['enabled'])) {
        continue;
      }

      final branchesNode =
          rule['branches'] ??
          rule['branchesIds'] ??
          rule['branchIds'] ??
          rule['branch'];
      if (!_ruleMatchesBranch(branchesNode, branchId)) {
        continue;
      }

      final categoriesNode = rule['categories'] ?? rule['category'];
      if (_toDynamicList(categoriesNode).any(_hasMeaningfulCategoryEntry)) {
        return true;
      }
    }
    return false;
  }

  static bool _hasFavoriteProductsForBranch(dynamic decoded, String branchId) {
    final rulesNode = _findByKey(decoded, 'favoriteProductsByBranchRules');
    for (final rawRule in _toDynamicList(rulesNode)) {
      final rule = _toMap(rawRule);
      if (rule == null || !_toBool(rule['enabled'])) {
        continue;
      }

      final branchesNode =
          rule['branches'] ??
          rule['branchesIds'] ??
          rule['branchIds'] ??
          rule['branch'];
      if (!_ruleMatchesBranch(branchesNode, branchId)) {
        continue;
      }

      final productsNode =
          rule['products'] ??
          rule['productIds'] ??
          rule['favoriteProducts'] ??
          rule['product'];
      if (_toDynamicList(productsNode).any(_hasMeaningfulProductEntry)) {
        return true;
      }
    }
    return false;
  }

  static bool _hasMeaningfulCategoryEntry(dynamic rawCategory) {
    if (rawCategory == null) {
      return false;
    }
    if (rawCategory is List) {
      return rawCategory.any(_hasMeaningfulCategoryEntry);
    }
    if (rawCategory is String || rawCategory is num) {
      return rawCategory.toString().trim().isNotEmpty;
    }

    final category = _toMap(rawCategory);
    if (category == null) {
      return false;
    }

    if (_extractRefId(
      category['id'] ??
          category['_id'] ??
          category['value'] ??
          category['categoryId'],
    ).isNotEmpty) {
      return true;
    }

    for (final key in const <String>[
      'name',
      'label',
      'title',
      'categoryName',
    ]) {
      final text = category[key]?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        return true;
      }
    }

    return false;
  }

  static bool _hasMeaningfulProductEntry(dynamic rawProduct) {
    if (rawProduct == null) {
      return false;
    }
    if (rawProduct is List) {
      return rawProduct.any(_hasMeaningfulProductEntry);
    }
    if (rawProduct is String || rawProduct is num) {
      return rawProduct.toString().trim().isNotEmpty;
    }

    final product = _toMap(rawProduct);
    if (product == null) {
      return false;
    }

    if (_extractRefId(
      product['id'] ??
          product['_id'] ??
          product['value'] ??
          product['productId'] ??
          product['product'],
    ).isNotEmpty) {
      return true;
    }

    for (final key in const <String>['name', 'label', 'title']) {
      final text = product[key]?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        return true;
      }
    }

    return false;
  }

  static bool _hasTableSections(dynamic decoded) {
    for (final rawDoc in _toDynamicList(decoded)) {
      final doc = _toMap(rawDoc);
      if (doc == null) {
        continue;
      }
      final sections = _toDynamicList(doc['sections']);
      for (final rawSection in sections) {
        if (_hasMeaningfulTableSection(rawSection)) {
          return true;
        }
      }
    }
    return false;
  }

  static bool _hasMeaningfulTableSection(dynamic rawSection) {
    if (rawSection == null) {
      return false;
    }
    if (rawSection is String) {
      return rawSection.trim().isNotEmpty;
    }
    final section = _toMap(rawSection);
    if (section == null) {
      return false;
    }

    final tableCount = _toInt(section['tableCount'] ?? section['count']);
    if (tableCount > 0) {
      return true;
    }

    final directTables = _toDynamicList(
      section['tables'] ?? section['tableNumbers'] ?? section['tableList'],
    );
    return directTables.isNotEmpty;
  }

  static dynamic _findByKey(dynamic node, String key) {
    final target = key.toLowerCase();

    dynamic scan(dynamic value) {
      if (value is Map) {
        for (final entry in value.entries) {
          if (entry.key.toString().toLowerCase() == target) {
            return entry.value;
          }
        }
        for (final entry in value.entries) {
          final nested = scan(entry.value);
          if (nested != null) {
            return nested;
          }
        }
      } else if (value is List) {
        for (final item in value) {
          final nested = scan(item);
          if (nested != null) {
            return nested;
          }
        }
      }
      return null;
    }

    return scan(node);
  }

  static Map<String, dynamic>? _toMap(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return null;
  }

  static List<dynamic> _toDynamicList(dynamic value) {
    if (value == null) {
      return const <dynamic>[];
    }
    if (value is List) {
      return List<dynamic>.from(value);
    }
    if (value is Map) {
      final map = Map<String, dynamic>.from(value);
      for (final key in const <String>[
        'docs',
        'items',
        'rules',
        'options',
        'values',
      ]) {
        final nested = map[key];
        if (nested is List) {
          return List<dynamic>.from(nested);
        }
      }
      final data = map['data'];
      if (data is List) {
        return List<dynamic>.from(data);
      }
      if (data is Map) {
        for (final key in const <String>[
          'docs',
          'items',
          'rules',
          'options',
          'values',
        ]) {
          final nested = data[key];
          if (nested is List) {
            return List<dynamic>.from(nested);
          }
        }
      }
      return <dynamic>[value];
    }
    return <dynamic>[value];
  }

  static bool _toBool(dynamic value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value == 1;
    }
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized == 'true' ||
          normalized == '1' ||
          normalized == 'yes' ||
          normalized == 'enabled' ||
          normalized == 'on';
    }
    return false;
  }

  static int _toInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim()) ?? 0;
    }
    return 0;
  }

  static String _extractRefId(dynamic ref) {
    if (ref == null) {
      return '';
    }
    if (ref is String || ref is num) {
      return ref.toString().trim();
    }
    if (ref is Map) {
      final map = Map<String, dynamic>.from(ref);
      for (final candidate in <dynamic>[
        map['id'],
        map['_id'],
        map[r'$oid'],
        map['value'],
        map['productId'],
        map['product'],
        map['categoryId'],
        map['category'],
        map['branchId'],
        map['branch'],
        map['item'],
      ]) {
        final id = _extractRefId(candidate);
        if (id.isNotEmpty) {
          return id;
        }
      }
    }
    return '';
  }

  static bool _ruleMatchesBranch(dynamic branchesNode, String branchId) {
    for (final branchRef in _toDynamicList(branchesNode)) {
      if (_extractRefId(branchRef) == branchId) {
        return true;
      }
    }
    return false;
  }
}
