import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:blackforest_app/cart_page.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/cart_provider.dart';
import 'package:blackforest_app/product_popularity_service.dart';
import 'package:blackforest_app/widgets/rolling_qty_text.dart';
import 'package:blackforest_app/widgets/product_rating_badge.dart';

class _FilledTrianglePainter extends CustomPainter {
  final Color color;

  const _FilledTrianglePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final path = Path()
      ..moveTo(size.width / 2, size.height * 0.1)
      ..lineTo(size.width * 0.08, size.height * 0.9)
      ..lineTo(size.width * 0.92, size.height * 0.9)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _FilledTrianglePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _ProductsCacheEntry {
  final List<dynamic> products;
  final DateTime fetchedAt;

  const _ProductsCacheEntry({required this.products, required this.fetchedAt});
}

class _HomeTopCategoryChip {
  final String id;
  final String name;
  final String? imageUrl;
  final int count;

  const _HomeTopCategoryChip({
    required this.id,
    required this.name,
    this.imageUrl,
    this.count = 0,
  });
}

class ProductsPage extends StatefulWidget {
  final String categoryId;
  final String categoryName;
  final PageType sourcePage;
  final List<Map<String, dynamic>> initialHomeTopCategories;
  final String? initialFocusedProductId;

  const ProductsPage({
    super.key,
    required this.categoryId,
    required this.categoryName,
    this.sourcePage = PageType.billing,
    this.initialHomeTopCategories = const <Map<String, dynamic>>[],
    this.initialFocusedProductId,
  });

  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  static const Duration _productsCacheTtl = Duration(seconds: 90);
  static final Map<String, _ProductsCacheEntry> _productsCache = {};
  static const Duration _homeTopCategoriesCacheTtl = Duration(seconds: 90);
  static const String _homeTopCategoriesCacheVersion =
      'branch-rule-top-categories-v1';
  static const String _topCircleCategoriesRuleName = 'Top Categories';
  static final Map<
    String,
    ({DateTime fetchedAt, List<_HomeTopCategoryChip> items})
  >
  _homeTopCategoriesCache = {};
  static const Color _homeAccentColor = Color(0xFFEF4F5F);

  List<dynamic> _products = [];
  List<_HomeTopCategoryChip> _homeTopCategories = <_HomeTopCategoryChip>[];
  Future<void>? _homeTopCategoriesLoadFuture;
  Map<String, ProductPopularityInfo> _productPopularityById =
      <String, ProductPopularityInfo>{};
  bool _isLoading = true;
  String? _branchId;
  String? _userRole;
  String? _currentUserId;
  List<String> _favoriteProductIds = <String>[];
  final TextEditingController _homeSearchController = TextEditingController();
  String _homeSearchQuery = '';
  String? _focusedProductId;
  bool _showFocusedProductHighlight = false;

  bool get _isHomeMode => widget.sourcePage == PageType.home;
  bool get _usesTableCart =>
      widget.sourcePage == PageType.table || widget.sourcePage == PageType.home;

  String _productsScope() {
    if (widget.sourcePage == PageType.home) return 'home';
    if (widget.sourcePage == PageType.table) return 'table';
    return 'billing';
  }

  String _cacheKey() {
    return '${_productsScope()}|${widget.categoryId}|${_branchId ?? ''}|${_userRole ?? ''}';
  }

  List<dynamic>? _readProductsCache() {
    final entry = _productsCache[_cacheKey()];
    if (entry == null) return null;
    final isExpired =
        DateTime.now().difference(entry.fetchedAt) > _productsCacheTtl;
    if (isExpired) {
      _productsCache.remove(_cacheKey());
      return null;
    }
    return List<dynamic>.from(entry.products);
  }

  void _writeProductsCache(List<dynamic> products) {
    _productsCache[_cacheKey()] = _ProductsCacheEntry(
      products: List<dynamic>.from(products),
      fetchedAt: DateTime.now(),
    );
  }

  @override
  void initState() {
    super.initState();
    _ensureCartMode();
    unawaited(_loadFavoriteProducts());
    if (_isHomeMode) {
      _homeTopCategories = _decodeInitialHomeTopCategories(
        widget.initialHomeTopCategories,
      );
      _focusedProductId =
          widget.initialFocusedProductId?.trim().isNotEmpty == true
          ? widget.initialFocusedProductId!.trim()
          : null;
      _showFocusedProductHighlight = _focusedProductId != null;
      if (_homeTopCategories.isEmpty) {
        unawaited(_loadHomeTopCategories());
      }
    }
    unawaited(_loadProductPopularity());
    _fetchProducts();
  }

  @override
  void dispose() {
    _homeSearchController.dispose();
    super.dispose();
  }

  void _ensureCartMode() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final cartProvider = Provider.of<CartProvider>(context, listen: false);
      cartProvider.setCartType(
        _usesTableCart ? CartType.table : CartType.billing,
        notify: false,
      );
    });
  }

  void _prepareHomeTableCartContext(CartProvider cartProvider) {
    cartProvider.setCartType(CartType.table, notify: false);
    final shouldResumeSharedDraft =
        cartProvider.isSharedTableOrder && cartProvider.recalledBillId == null;
    final existingSharedTableNumber = shouldResumeSharedDraft
        ? cartProvider.selectedTable?.trim()
        : null;
    cartProvider.startSharedTableOrder(
      preserveActiveItems: shouldResumeSharedDraft,
      tableNumber: existingSharedTableNumber?.isNotEmpty == true
          ? existingSharedTableNumber
          : null,
    );
    final initialHomeTopCategories = widget.initialHomeTopCategories.isNotEmpty
        ? widget.initialHomeTopCategories
        : _encodeHomeTopCategories(_homeTopCategories);
    cartProvider.setCurrentDraftHomeCategoriesUi(
      enabled: true,
      homeTopCategories: initialHomeTopCategories,
    );
  }

  List<Map<String, dynamic>> _filteredHomeProducts() {
    final query = _homeSearchQuery.trim().toLowerCase();
    final normalized = _products
        .whereType<Map>()
        .map((product) => Map<String, dynamic>.from(product))
        .toList(growable: true);
    final filtered = query.isEmpty
        ? normalized
        : normalized
              .where((product) {
                final name = (product['name'] ?? '').toString().toLowerCase();
                return name.contains(query);
              })
              .toList(growable: true);

    final favoritesOrdered = <Map<String, dynamic>>[];
    final nonFavorites = <Map<String, dynamic>>[];
    final byId = <String, Map<String, dynamic>>{};

    for (final product in filtered) {
      final productId = _productId(product);
      if (productId.isNotEmpty) {
        byId[productId] = product;
      }
      if (_favoriteProductIds.contains(productId)) {
        continue;
      }
      nonFavorites.add(product);
    }

    for (final favoriteId in _favoriteProductIds) {
      final product = byId[favoriteId];
      if (product != null) {
        favoritesOrdered.add(product);
      }
    }

    final ordered = <Map<String, dynamic>>[
      ...favoritesOrdered,
      ...nonFavorites,
    ];

    final focusedProductId = _focusedProductId?.trim() ?? '';
    if (focusedProductId.isEmpty) return ordered;

    final focusedIndex = ordered.indexWhere(
      (product) => _productId(product) == focusedProductId,
    );
    if (focusedIndex <= 0) return ordered;

    final focusedProduct = ordered.removeAt(focusedIndex);
    ordered.insert(0, focusedProduct);
    return ordered;
  }

  Future<void> _loadProductPopularity() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token')?.trim();
      final branchId = (_branchId ?? prefs.getString('branchId') ?? '')
          .toString()
          .trim();
      if (token == null || token.isEmpty || branchId.isEmpty) {
        return;
      }

      final popularity = await ProductPopularityService.getPopularityForBranch(
        token: token,
        branchId: branchId,
      );
      if (!mounted) return;
      setState(() {
        _productPopularityById = popularity;
      });
    } catch (_) {}
  }

  Map<String, dynamic>? _toMap(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return null;
  }

  List<dynamic> _toDynamicList(dynamic value) {
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

  String _extractRefId(dynamic ref) {
    if (ref == null) return '';
    if (ref is String || ref is num) return ref.toString().trim();
    if (ref is Map) {
      final map = Map<String, dynamic>.from(ref);
      final candidates = <dynamic>[
        map['id'],
        map['_id'],
        map[r'$oid'],
        map['value'],
        map['productId'],
        map['product'],
        map['branchId'],
        map['branch'],
        map['item'],
        map['categoryId'],
        map['category'],
      ];
      for (final candidate in candidates) {
        final id = _extractRefId(candidate);
        if (id.isNotEmpty) return id;
      }
    }
    return '';
  }

  List<_HomeTopCategoryChip> _decodeInitialHomeTopCategories(
    List<Map<String, dynamic>> rawCategories,
  ) {
    if (rawCategories.isEmpty) return const <_HomeTopCategoryChip>[];
    final seen = <String>{};
    final items = <_HomeTopCategoryChip>[];

    for (final raw in rawCategories) {
      final id = (raw['id'] ?? '').toString().trim();
      final name = (raw['name'] ?? '').toString().trim();
      if (id.isEmpty || name.isEmpty || !seen.add(id)) continue;
      final imageUrl = raw['imageUrl']?.toString().trim();
      final countValue = raw['count'];
      final count = countValue is num
          ? countValue.toInt()
          : int.tryParse(countValue?.toString() ?? '') ?? 0;

      items.add(
        _HomeTopCategoryChip(
          id: id,
          name: name,
          imageUrl: imageUrl != null && imageUrl.isNotEmpty ? imageUrl : null,
          count: count,
        ),
      );
    }

    return items;
  }

  List<Map<String, dynamic>> _encodeHomeTopCategories(
    List<_HomeTopCategoryChip> categories,
  ) => categories
      .map(
        (category) => <String, dynamic>{
          'id': category.id,
          'name': category.name,
          'imageUrl': category.imageUrl,
          'count': category.count,
        },
      )
      .toList(growable: false);

  Future<void> _loadHomeTopCategories() async {
    final inFlight = _homeTopCategoriesLoadFuture;
    if (inFlight != null) {
      return inFlight;
    }

    final future = _loadHomeTopCategoriesInternal();
    _homeTopCategoriesLoadFuture = future;
    future.whenComplete(() {
      if (identical(_homeTopCategoriesLoadFuture, future)) {
        _homeTopCategoriesLoadFuture = null;
      }
    });
    return future;
  }

  Future<void> _loadHomeTopCategoriesInternal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token')?.trim();
      final branchId = (_branchId ?? prefs.getString('branchId') ?? '')
          .toString()
          .trim();
      if (token == null ||
          token.isEmpty ||
          branchId.isEmpty ||
          !_isHomeMode ||
          !mounted) {
        if (!mounted) return;
        setState(() {
          _homeTopCategories = <_HomeTopCategoryChip>[];
        });
        return;
      }

      final cacheKey = '$_homeTopCategoriesCacheVersion|$branchId';
      final cached = _homeTopCategoriesCache[cacheKey];
      if (cached != null &&
          DateTime.now().difference(cached.fetchedAt) <
              _homeTopCategoriesCacheTtl) {
        setState(() {
          _homeTopCategories = List<_HomeTopCategoryChip>.from(cached.items);
        });
        return;
      }

      var categories = await _fetchTopSellingKotCategoriesForBranch(
        token: token,
        branchId: branchId,
      );
      if (categories.isNotEmpty) {
        categories = await _hydrateTopCategories(categories, token);
      }

      _homeTopCategoriesCache[cacheKey] = (
        fetchedAt: DateTime.now(),
        items: List<_HomeTopCategoryChip>.from(categories),
      );
      if (!mounted) return;
      setState(() {
        _homeTopCategories = categories;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _homeTopCategories = <_HomeTopCategoryChip>[];
      });
    }
  }

  Future<List<_HomeTopCategoryChip>> _fetchTopSellingKotCategoriesForBranch({
    required String token,
    required String branchId,
  }) async {
    final normalizedBranchId = branchId.trim();
    if (normalizedBranchId.isEmpty) {
      return const <_HomeTopCategoryChip>[];
    }

    try {
      final response = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/globals/widget-settings?depth=1',
        ),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );
      if (response.statusCode != 200) {
        return const <_HomeTopCategoryChip>[];
      }

      final decoded = jsonDecode(response.body);
      return _readHomeTopCategoriesForBranch(
        decoded,
        normalizedBranchId,
        ruleNameFilter: _topCircleCategoriesRuleName,
      );
    } catch (_) {
      return const <_HomeTopCategoryChip>[];
    }
  }

  List<_HomeTopCategoryChip> _readHomeTopCategoriesForBranch(
    dynamic decoded,
    String branchId, {
    String? ruleNameFilter,
  }) {
    final rulesNode = _findByKey(decoded, 'favoriteCategoriesByBranchRules');
    final rules = _toDynamicList(rulesNode);
    final categories = <_HomeTopCategoryChip>[];
    final seenCategoryIds = <String>{};

    for (final rawRule in rules) {
      final rule = _toMap(rawRule);
      if (rule == null || !_toBool(rule['enabled'])) continue;

      final branchesNode =
          rule['branches'] ??
          rule['branchesIds'] ??
          rule['branchIds'] ??
          rule['branch'];
      if (!_ruleMatchesBranch(branchesNode, branchId)) continue;
      if (!_ruleNameMatches(rule, ruleNameFilter)) continue;

      final categoriesNode = rule['categories'] ?? rule['category'];
      for (final rawCategory in _toDynamicList(categoriesNode)) {
        final category = _toHomeTopCategoryChip(rawCategory);
        if (category == null || !seenCategoryIds.add(category.id)) continue;
        categories.add(category);
      }
    }

    return categories;
  }

  bool _ruleNameMatches(Map<String, dynamic> rule, String? expectedRuleName) {
    final normalizedExpected = expectedRuleName?.trim().toLowerCase() ?? '';
    if (normalizedExpected.isEmpty) return true;
    final normalizedActual = (rule['ruleName'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    return normalizedActual == normalizedExpected;
  }

  _HomeTopCategoryChip? _toHomeTopCategoryChip(dynamic rawCategory) {
    if (rawCategory == null) return null;

    final category = _toMap(rawCategory);
    if (category != null) {
      final id = _extractRefId(
        category['id'] ??
            category['_id'] ??
            category['value'] ??
            category['categoryId'] ??
            category,
      );
      final name =
          <dynamic>[
                category['name'],
                category['label'],
                category['title'],
                category['categoryName'],
              ]
              .map((value) => value?.toString().trim() ?? '')
              .firstWhere((value) => value.isNotEmpty, orElse: () => id);
      if (id.isEmpty || name.isEmpty) return null;
      return _HomeTopCategoryChip(
        id: id,
        name: name,
        imageUrl: _extractImageFromAny(
          category['imageUrl'] ??
              category['image'] ??
              category['thumbnail'] ??
              category,
        ),
        count: 0,
      );
    }

    final id = rawCategory.toString().trim();
    if (id.isEmpty) return null;
    return _HomeTopCategoryChip(id: id, name: id, imageUrl: null, count: 0);
  }

  dynamic _findByKey(dynamic node, String key) {
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
          if (nested != null) return nested;
        }
      } else if (value is List) {
        for (final item in value) {
          final nested = scan(item);
          if (nested != null) return nested;
        }
      }
      return null;
    }

    return scan(node);
  }

  bool _toBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value == 1;
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

  bool _ruleMatchesBranch(dynamic branchesNode, String branchId) {
    for (final branchRef in _toDynamicList(branchesNode)) {
      if (_extractRefId(branchRef) == branchId) return true;
    }
    return false;
  }

  Future<List<_HomeTopCategoryChip>> _hydrateTopCategories(
    List<_HomeTopCategoryChip> categories,
    String token,
  ) async {
    if (categories.isEmpty) return categories;
    final ids = categories
        .map((category) => category.id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (ids.isEmpty) return categories;

    try {
      final response = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/categories?where[id][in]=${ids.join(',')}&depth=1&limit=100',
        ),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );
      if (response.statusCode != 200) return categories;

      final decoded = jsonDecode(response.body);
      final docs = _toDynamicList(decoded);
      final byId = <String, Map<String, dynamic>>{};
      for (final rawDoc in docs) {
        final doc = _toMap(rawDoc);
        if (doc == null) continue;
        final id = (doc['id'] ?? doc['_id'] ?? doc[r'$oid'] ?? '')
            .toString()
            .trim();
        if (id.isEmpty) continue;
        byId[id] = doc;
      }

      return categories
          .map((category) {
            final doc = byId[category.id];
            if (doc == null) return category;
            final imageUrl = _normalizeImageUrl(
              doc['image']?['url'] ??
                  doc['image']?['thumbnailURL'] ??
                  doc['imageUrl'] ??
                  doc['thumbnail'],
            );
            final name = (doc['name'] ?? '').toString().trim();
            return _HomeTopCategoryChip(
              id: category.id,
              name: name.isNotEmpty ? name : category.name,
              imageUrl: imageUrl ?? category.imageUrl,
              count: category.count,
            );
          })
          .toList(growable: false);
    } catch (_) {
      return categories;
    }
  }

  void _openHomeTopCategory(_HomeTopCategoryChip category) {
    if (category.id.trim().isEmpty || category.id == widget.categoryId) return;
    final initialHomeTopCategories = widget.initialHomeTopCategories.isNotEmpty
        ? widget.initialHomeTopCategories
        : _encodeHomeTopCategories(_homeTopCategories);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => ProductsPage(
          categoryId: category.id,
          categoryName: category.name,
          sourcePage: PageType.home,
          initialHomeTopCategories: initialHomeTopCategories,
          initialFocusedProductId: null,
        ),
      ),
    );
  }

  /// Fetch user data and determine branch or waiter roles
  Future<void> _fetchUserData(String token) async {
    try {
      final response = await http.get(
        Uri.parse('https://blackforest.vseyal.com/api/users/me?depth=2'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final user = data['user'] ?? data;
        final prefs = await SharedPreferences.getInstance();
        final role = user['role']?.toString();
        if (role != null && role.isNotEmpty) {
          await prefs.setString('role', role);
        }

        String? branchId;
        if (user['role'] == 'branch' && user['branch'] != null) {
          branchId = (user['branch'] is Map)
              ? user['branch']['id']?.toString()
              : user['branch']?.toString();
        } else if (user['role'] == 'waiter') {
          await _fetchWaiterBranch(token);
        }

        if (branchId != null && branchId.isNotEmpty) {
          await prefs.setString('branchId', branchId);
        }

        if (!mounted) return;
        setState(() {
          _userRole = role;
          if (branchId != null && branchId.isNotEmpty) {
            _branchId = branchId;
          }
        });
      }
    } catch (e) {
      // Handle silently
    }
  }

  /// Get private device IP (LAN)
  Future<String?> _fetchDeviceIp() async {
    try {
      final info = NetworkInfo();
      final ip = await info.getWifiIP();
      return ip?.trim();
    } catch (e) {
      return null;
    }
  }

  /// Convert IP string to int for range comparison
  int _ipToInt(String ip) {
    final parts = ip.split('.').map(int.parse).toList();
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
  }

  /// Check if an IP falls inside a range "startIP - endIP"
  bool _isIpInRange(String deviceIp, String range) {
    final parts = range.split('-');
    if (parts.length != 2) return false;
    final startIp = _ipToInt(parts[0].trim());
    final endIp = _ipToInt(parts[1].trim());
    final device = _ipToInt(deviceIp);
    return device >= startIp && device <= endIp;
  }

  /// Find the waiter's branch by matching device IP to branch IP or range
  Future<void> _fetchWaiterBranch(String token) async {
    try {
      // 0. Prioritize stored branchId from login
      final prefs = await SharedPreferences.getInstance();
      final storedBranchId = prefs.getString('branchId');
      if (storedBranchId != null) {
        setState(() {
          _branchId = storedBranchId;
        });
        return;
      }

      String? deviceIp = await _fetchDeviceIp();
      if (deviceIp == null) return;

      // 1. Try Global Settings
      try {
        final gRes = await http.get(
          Uri.parse(
            'https://blackforest.vseyal.com/api/globals/branch-geo-settings',
          ),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
        );
        if (gRes.statusCode == 200) {
          final settings = jsonDecode(gRes.body);
          final locations = settings['locations'] as List?;
          if (locations != null) {
            for (var loc in locations) {
              String? bIpRange = loc['ipAddress']?.toString().trim();
              if (bIpRange != null &&
                  (bIpRange == deviceIp || _isIpInRange(deviceIp, bIpRange))) {
                final branchRef = loc['branch'];
                String? branchId;
                if (branchRef is Map) {
                  branchId =
                      branchRef['id']?.toString() ??
                      branchRef['_id']?.toString() ??
                      branchRef['\$oid']?.toString();
                } else {
                  branchId = branchRef?.toString();
                }
                if (branchId != null) {
                  setState(() {
                    _branchId = branchId;
                  });
                  return;
                }
              }
            }
          }
        }
      } catch (e) {
        debugPrint("Error fetching global settings in products: $e");
      }

      // 2. Fallback to Branches Collection
      final allBranchesResponse = await http.get(
        Uri.parse('https://blackforest.vseyal.com/api/branches?depth=1'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (allBranchesResponse.statusCode == 200) {
        final branchesData = jsonDecode(allBranchesResponse.body);
        if (branchesData['docs'] != null && branchesData['docs'] is List) {
          for (var branch in branchesData['docs']) {
            String? bIpRange = branch['ipAddress']?.toString().trim();
            if (bIpRange != null &&
                (bIpRange == deviceIp || _isIpInRange(deviceIp, bIpRange))) {
              setState(() {
                _branchId =
                    branch['id']?.toString() ?? branch['_id']?.toString();
              });
              break;
            }
          }
        }
      }
    } catch (e) {
      // Handle silently
    }
  }

  /// Fetch all products under a category, filtered by role/branch
  Future<void> _fetchProducts() async {
    setState(() {
      _isLoading = true;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No token found. Please login again.')),
        );
        setState(() {
          _isLoading = false;
        });
        return;
      }

      _userRole ??= prefs.getString('role');
      _branchId ??= prefs.getString('branchId');

      final cachedProducts = _readProductsCache();
      if (cachedProducts != null) {
        if (!mounted) return;
        setState(() {
          _products = cachedProducts;
          _isLoading = false;
        });
        return;
      }

      if (_userRole == null || (_userRole == 'waiter' && _branchId == null)) {
        await _fetchUserData(token);
      }

      if (_isHomeMode && _homeTopCategories.isEmpty) {
        unawaited(_loadHomeTopCategories());
      }
      unawaited(_loadProductPopularity());

      // Updated: Fetch all products in the category without restricting to branch overrides
      final url =
          'https://blackforest.vseyal.com/api/products?where[category][equals]=${widget.categoryId}&limit=100&depth=2';
      final response = await http.get(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);

        var fetchedProducts = data['docs'] ?? [];

        // Filter out products:
        // 1. Globally inactive (status == 'inactive')
        // 2. Inactive for current branch (branch in inactiveBranches)
        if (fetchedProducts is List) {
          fetchedProducts = fetchedProducts.where((product) {
            // Check global status
            final status = product['status'];
            if (status == 'inactive') return false;

            // Check availability
            if (product['isAvailable'] == false) return false;

            // Check branch-specific inactivity
            if (_branchId != null) {
              final inactiveBranches = product['inactiveBranches'];
              if (inactiveBranches != null && inactiveBranches is List) {
                for (var branch in inactiveBranches) {
                  String? id;
                  if (branch is Map) {
                    id =
                        branch['id']?.toString() ??
                        branch['_id']?.toString() ??
                        branch['\$oid']?.toString();
                  } else {
                    id = branch?.toString();
                  }
                  if (id == _branchId) return false;
                }
              }
            }
            return true;
          }).toList();
        }

        if (!mounted) return;
        setState(() {
          _products = fetchedProducts;
          _isLoading = false;
        });
        _writeProductsCache(List<dynamic>.from(fetchedProducts));
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to fetch products: ${response.statusCode}'),
          ),
        );
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error: Check your internet')),
      );
      setState(() {
        _isLoading = false;
      });
    }
  }

  String _favoriteProductsScope() => _usesTableCart ? 'table' : 'billing';

  String _favoriteProductsKey(String userId) =>
      'favorite_product_ids_${_favoriteProductsScope()}_$userId';

  Future<void> _loadFavoriteProducts({String? preferredUserId}) async {
    final prefs = await SharedPreferences.getInstance();
    final userId =
        preferredUserId ?? _currentUserId ?? prefs.getString('user_id');

    if (userId == null || userId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _currentUserId = null;
        _favoriteProductIds = <String>[];
      });
      return;
    }

    final stored =
        prefs.getStringList(_favoriteProductsKey(userId)) ?? <String>[];
    final normalized = <String>[];
    for (final id in stored) {
      final cleanId = id.trim();
      if (cleanId.isEmpty || normalized.contains(cleanId)) continue;
      normalized.add(cleanId);
    }

    if (normalized.length != stored.length) {
      await prefs.setStringList(_favoriteProductsKey(userId), normalized);
    }

    if (!mounted) return;
    setState(() {
      _currentUserId = userId;
      _favoriteProductIds = normalized;
    });
  }

  Future<void> _saveFavoriteProducts() async {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _favoriteProductsKey(userId),
      _favoriteProductIds.toList(),
    );
  }

  Future<void> _toggleFavoriteProduct(
    String productId,
    String productName,
  ) async {
    final normalizedId = productId.trim();
    if (normalizedId.isEmpty) return;

    if (_currentUserId == null || _currentUserId!.isEmpty) {
      await _loadFavoriteProducts();
    }
    if (_currentUserId == null || _currentUserId!.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to save favorites. Please login again.'),
        ),
      );
      return;
    }

    final alreadyFavorite = _favoriteProductIds.contains(normalizedId);
    setState(() {
      _favoriteProductIds.remove(normalizedId);
      if (!alreadyFavorite) {
        _favoriteProductIds.insert(0, normalizedId);
      }
    });
    await _saveFavoriteProducts();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          alreadyFavorite
              ? '$productName removed from favorites'
              : '$productName added to favorites',
        ),
      ),
    );
  }

  String _productId(Map<String, dynamic> product) {
    final candidates = <dynamic>[
      product['id'],
      product['value'],
      product['productId'],
      product['product'],
    ];
    for (final candidate in candidates) {
      if (candidate == null) continue;
      if (candidate is Map) {
        final id =
            candidate['id']?.toString().trim() ??
            candidate['_id']?.toString().trim() ??
            candidate[r'$oid']?.toString().trim() ??
            '';
        if (id.isNotEmpty) return id;
      } else {
        final id = candidate.toString().trim();
        if (id.isNotEmpty) return id;
      }
    }
    return '';
  }

  String? _normalizeImageUrl(dynamic rawUrl) {
    final value = rawUrl?.toString().trim();
    if (value == null || value.isEmpty) return null;
    if (value.startsWith('data:image/')) return value;
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    if (value.startsWith('//')) return 'https:$value';
    if (value.startsWith('blackforest.vseyal.com')) return 'https://$value';
    if (value.startsWith('/')) return 'https://blackforest.vseyal.com$value';
    return value;
  }

  String? _extractImageFromAny(dynamic node) {
    final direct = _normalizeImageUrl(node);
    if (direct != null) return direct;

    if (node is List) {
      for (final item in node) {
        final nested = _extractImageFromAny(item);
        if (nested != null) return nested;
      }
      return null;
    }

    if (node is! Map) return null;
    final map = Map<String, dynamic>.from(node);
    final preferredKeys = <String>[
      'imageUrl',
      'thumbnail',
      'image',
      'images',
      'photo',
      'picture',
      'icon',
      'media',
      'file',
      'url',
      'src',
      'asset',
      'product',
    ];
    for (final key in preferredKeys) {
      if (!map.containsKey(key)) continue;
      final nested = _extractImageFromAny(map[key]);
      if (nested != null) return nested;
    }
    for (final value in map.values) {
      final nested = _extractImageFromAny(value);
      if (nested != null) return nested;
    }
    return null;
  }

  String? _resolveProductImage(Map<String, dynamic> product) {
    final images = product['images'];
    if (images is List && images.isNotEmpty) {
      final first = images.first;
      if (first is Map) {
        final nested = first['image'];
        if (nested is Map) {
          final url = _normalizeImageUrl(
            nested['url'] ?? nested['thumbnailURL'],
          );
          if (url != null) return url;
        }
        final direct = _normalizeImageUrl(first['url']);
        if (direct != null) return direct;
      }
    }

    final image = product['image'];
    if (image is Map) {
      final url = _normalizeImageUrl(image['url'] ?? image['thumbnailURL']);
      if (url != null) return url;
    }

    return _normalizeImageUrl(product['imageUrl'] ?? product['thumbnail']);
  }

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  double _readProductPrice(Map<String, dynamic> product) {
    var price = _toDouble(product['defaultPriceDetails']?['price']);
    if (_branchId != null && product['branchOverrides'] is List) {
      for (final rawOverride in product['branchOverrides']) {
        if (rawOverride is! Map) continue;
        final branch = rawOverride['branch'];
        final branchId = branch is Map
            ? (branch[r'$oid'] ?? branch['id'] ?? '').toString()
            : (branch ?? '').toString();
        if (branchId == _branchId) {
          price = _toDouble(rawOverride['price']);
          break;
        }
      }
    }
    return price;
  }

  bool? _readIsVegStatus(Map<String, dynamic> product) {
    final directValue = product['isVeg'] ?? product['is_veg'] ?? product['veg'];
    if (directValue is bool) return directValue;
    if (directValue is num) return directValue != 0;
    if (directValue is String) {
      final lower = directValue.trim().toLowerCase();
      if (lower == 'veg' || lower == 'true' || lower == '1') return true;
      if (lower == 'nonveg' || lower == 'false' || lower == '0') return false;
    }

    final category = product['category'];
    if (category is Map) {
      final categoryValue =
          category['isVeg'] ?? category['is_veg'] ?? category['veg'];
      if (categoryValue is bool) return categoryValue;
      if (categoryValue is num) return categoryValue != 0;
      if (categoryValue is String) {
        final lower = categoryValue.trim().toLowerCase();
        if (lower == 'veg' || lower == 'true' || lower == '1') return true;
        if (lower == 'nonveg' || lower == 'false' || lower == '0') {
          return false;
        }
      }
    }
    return null;
  }

  double? _readExplicitRatingValue(Map<String, dynamic> product) {
    final candidates = <dynamic>[
      product['rating'],
      product['avgRating'],
      product['averageRating'],
      product['ratingValue'],
      product['reviewRating'],
      product['ratings'] is Map ? product['ratings']['average'] : null,
      product['reviews'] is Map ? product['reviews']['average'] : null,
    ];
    for (final candidate in candidates) {
      final parsed = _toDouble(candidate);
      if (parsed > 0) return parsed;
    }
    return null;
  }

  int _readExplicitRatingCount(Map<String, dynamic> product) {
    final candidates = <dynamic>[
      product['ratingCount'],
      product['ratingsCount'],
      product['reviewCount'],
      product['reviewsCount'],
      product['totalRatings'],
      product['totalReviews'],
      product['ratings'] is Map ? product['ratings']['count'] : null,
      product['reviews'] is Map ? product['reviews']['count'] : null,
    ];
    for (final candidate in candidates) {
      final parsed = _toDouble(candidate).round();
      if (parsed > 0) return parsed;
    }
    return 0;
  }

  ProductPopularityInfo? _readProductBadgeInfo(Map<String, dynamic> product) {
    final explicitRating = _readExplicitRatingValue(product);
    final fallback = _productPopularityById[_productId(product)];
    if (explicitRating != null) {
      final explicitCount = _readExplicitRatingCount(product);
      return ProductPopularityInfo(
        score: double.parse(explicitRating.toStringAsFixed(1)),
        count: explicitCount > 0 ? explicitCount : (fallback?.count ?? 0),
      );
    }
    return fallback;
  }

  bool _isWeightBasedProduct(Map<String, dynamic> product) {
    try {
      final unit = product['defaultPriceDetails']?['unit']
          ?.toString()
          .toLowerCase();
      final isKgFlag =
          product['isKg'] == true ||
          product['sellByWeight'] == true ||
          product['weightBased'] == true;
      final pricingType = product['pricingType']?.toString().toLowerCase();

      if (unit != null && (unit.contains('kg') || unit.contains('gram'))) {
        return true;
      }
      if (isKgFlag) {
        return true;
      }
      if (pricingType != null && pricingType.contains('kg')) {
        return true;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  String _formatCompactPrice(double price) {
    if (price == price.floorToDouble()) {
      return '₹${price.toInt()}';
    }
    return '₹${price.toStringAsFixed(2)}';
  }

  String _formatDetailedPrice(double price) => 'Rs ${price.toStringAsFixed(2)}';

  double _qtyInCart(CartProvider cartProvider, String productId) {
    if (productId.isEmpty) return 0;
    if (_isHomeMode &&
        (cartProvider.currentType != CartType.table ||
            !cartProvider.isSharedTableOrder)) {
      return 0;
    }
    final existing = cartProvider.cartItems.where(
      (item) => item.id == productId,
    );
    if (existing.isEmpty) return 0;
    return existing.first.quantity;
  }

  Widget _buildVegNonVegIcon(bool isVeg) {
    final markerColor = isVeg
        ? const Color(0xFF1E9D55)
        : const Color(0xFFE53935);
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: markerColor, width: 0.9),
      ),
      child: Center(
        child: isVeg
            ? Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: markerColor,
                  shape: BoxShape.circle,
                ),
              )
            : CustomPaint(
                size: const Size(8, 8),
                painter: _FilledTrianglePainter(markerColor),
              ),
      ),
    );
  }

  Widget _buildHomeQtyControl({
    required Map<String, dynamic> product,
    required double qty,
  }) {
    final buttonBorder = BorderRadius.circular(12);
    const addControlHeight = 34.0;
    const addFontSize = 16.0;
    const controlHeight = addControlHeight;
    const actionWidth = 22.0;
    const actionFontSize = 21.0;
    const qtyFontSize = 18.0;

    if (qty <= 0) {
      return SizedBox(
        height: addControlHeight,
        child: OutlinedButton(
          onPressed: () => _addOrUpdateProduct(product),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: _homeAccentColor, width: 1.4),
            shape: RoundedRectangleBorder(borderRadius: buttonBorder),
            backgroundColor: const Color(0xFFFFF7F8),
            padding: EdgeInsets.zero,
          ),
          child: const Center(
            child: Text(
              'ADD',
              style: TextStyle(
                color: _homeAccentColor,
                fontSize: addFontSize,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.2,
                height: 1,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      height: controlHeight,
      decoration: BoxDecoration(
        color: _homeAccentColor,
        borderRadius: buttonBorder,
      ),
      child: Row(
        children: [
          _buildHomeQtyActionButton(
            symbol: '-',
            onTap: () => _decreaseQty(product, qty),
            width: actionWidth,
            height: controlHeight,
            fontSize: actionFontSize,
          ),
          Expanded(
            child: Center(
              child: RollingQtyText(
                value: qty,
                height: controlHeight,
                style: const TextStyle(
                  fontSize: qtyFontSize,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  height: 1,
                ),
              ),
            ),
          ),
          _buildHomeQtyActionButton(
            symbol: '+',
            onTap: () => _addOrUpdateProduct(product),
            width: actionWidth,
            height: controlHeight,
            fontSize: actionFontSize,
          ),
        ],
      ),
    );
  }

  Widget _buildHomeQtyActionButton({
    required String symbol,
    required VoidCallback onTap,
    required double width,
    required double height,
    required double fontSize,
  }) {
    final displaySymbol = symbol == '-' ? '−' : symbol;
    final xOffset = displaySymbol == '−' ? 2.5 : -2.5;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: width,
        height: height,
        child: Center(
          child: Transform.translate(
            offset: Offset(xOffset, 0),
            child: Text(
              displaySymbol,
              style: TextStyle(
                color: Colors.white,
                fontSize: fontSize,
                fontWeight: FontWeight.w900,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _dismissFocusedProductHighlightIfMatches(String productId) {
    if ((_focusedProductId?.trim() ?? '') != productId) return;
    if (!_showFocusedProductHighlight) return;
    if (!mounted) return;
    setState(() {
      _showFocusedProductHighlight = false;
    });
  }

  void _decreaseQty(Map<String, dynamic> product, double currentQty) {
    final productId = _productId(product);
    if (productId.isEmpty) return;
    _dismissFocusedProductHighlightIfMatches(productId);
    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    if (_isHomeMode) {
      _prepareHomeTableCartContext(cartProvider);
    } else {
      cartProvider.setCartType(
        _usesTableCart ? CartType.table : CartType.billing,
        notify: false,
      );
    }
    if (_isWeightBasedProduct(product) || currentQty <= 1) {
      cartProvider.removeItem(productId);
      return;
    }
    cartProvider.updateQuantity(productId, currentQty - 1);
  }

  /// Add or update product in cart
  Future<void> _addOrUpdateProduct(Map<String, dynamic> product) async {
    final productId = _productId(product);
    if (productId.isEmpty) return;
    _dismissFocusedProductHighlightIfMatches(productId);
    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    if (_isHomeMode) {
      _prepareHomeTableCartContext(cartProvider);
    } else {
      cartProvider.setCartType(
        _usesTableCart ? CartType.table : CartType.billing,
        notify: false,
      );
    }

    // Step 1: Get product price
    final price = _readProductPrice(product);

    // Step 2: Detect if the product is weight-based
    final isWeightBased = _isWeightBasedProduct(product);

    // Step 3: Get current quantity if exists
    double existingQty = 0.0;
    final existingItem = cartProvider.cartItems.firstWhere(
      (i) => i.id == productId,
      orElse: () => CartItem(id: '', name: '', price: 0, quantity: 0),
    );
    if (existingItem.id.isNotEmpty) {
      existingQty = existingItem.quantity.toDouble();
    }

    double quantity = 1.0;
    if (isWeightBased) {
      // Step 4: Show popup if weight-based
      final unit = product['defaultPriceDetails']?['unit'] ?? 'kg';
      final TextEditingController weightController = TextEditingController(
        text: existingQty > 0 ? existingQty.toStringAsFixed(2) : '',
      );
      final enteredWeight = await showDialog<double>(
        context: context,
        barrierDismissible: true,
        builder: (context) {
          return AlertDialog(
            title: Text('Enter Weight ($unit)'),
            content: TextField(
              controller: weightController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                hintText: 'e.g. 0.5',
                labelText: 'Weight in $unit',
                border: const OutlineInputBorder(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  final value =
                      double.tryParse(weightController.text.trim()) ?? 0.0;
                  Navigator.pop(context, value);
                },
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
      if (enteredWeight == null || enteredWeight <= 0) return;
      quantity = enteredWeight;
    }

    // Step 5: Update or add
    final item = CartItem.fromProduct(
      product,
      quantity,
      branchPrice: price,
      branchId: _branchId,
    );
    if (isWeightBased) {
      if (existingItem.id.isNotEmpty) {
        cartProvider.updateQuantity(productId, quantity);
      } else {
        cartProvider.addOrUpdateItem(item);
      }
    } else {
      cartProvider.addOrUpdateItem(item);
    }
  }

  void _toggleProductSelection(int index) async {
    final product = Map<String, dynamic>.from(_products[index] as Map);
    await _addOrUpdateProduct(product);
  }

  /// Barcode scan support
  void _handleScan(String scanResult) {
    for (int index = 0; index < _products.length; index++) {
      final product = _products[index];
      if (product['upc'] == scanResult) {
        _toggleProductSelection(index);
        return;
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Product not found in this category')),
    );
  }

  String _formatCartCount(double qty) {
    if (qty == qty.floorToDouble()) {
      return qty.toInt().toString();
    }
    return qty.toStringAsFixed(1);
  }

  Future<void> _openHomeCartFromProducts() async {
    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    cartProvider.setCartType(CartType.table, notify: false);

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const CartPage()),
    );
  }

  Widget _buildFloatingCartBar({
    required double totalQty,
    required List<CartItem> cartItems,
  }) {
    const cartBarColor = Color(0xFFEF4F5F);
    final displayCount = _formatCartCount(totalQty);
    final itemLabel = totalQty > 1.0001 ? 'items added' : 'item added';

    return Container(
      color: Colors.white,
      padding: EdgeInsets.fromLTRB(
        16,
        10,
        16,
        MediaQuery.of(context).padding.bottom + 10,
      ),
      child: Material(
        color: cartBarColor,
        borderRadius: BorderRadius.circular(18),
        elevation: 2,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: _openHomeCartFromProducts,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      _buildCartPreviewStack(cartItems),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SizedBox(
                          height: 22,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '$displayCount $itemLabel',
                              maxLines: 1,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'View cart',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 1),
                    Transform.translate(
                      offset: const Offset(2, 0),
                      child: const Icon(
                        Icons.chevron_right_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCartPreviewStack(List<CartItem> cartItems) {
    final previewItems = cartItems.length <= 3
        ? cartItems
        : cartItems.sublist(cartItems.length - 3);
    const avatarSize = 34.0;
    const overlapOffset = 17.0;
    final stackWidth = previewItems.isEmpty
        ? avatarSize
        : avatarSize + (previewItems.length - 1) * overlapOffset;

    return SizedBox(
      width: stackWidth,
      height: avatarSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (int i = 0; i < previewItems.length; i++)
            Positioned(
              left: i * overlapOffset,
              child: _buildCartPreviewAvatar(previewItems[i], avatarSize),
            ),
          if (previewItems.isEmpty) _buildCartPreviewAvatar(null, avatarSize),
        ],
      ),
    );
  }

  Widget _buildCartPreviewAvatar(CartItem? item, double size) {
    final imageUrl = _normalizeImageUrl(item?.imageUrl);
    final fallbackLetter = (item?.name.trim().isNotEmpty ?? false)
        ? item!.name.trim()[0].toUpperCase()
        : null;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        color: Colors.white.withValues(alpha: 0.22),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 6,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: ClipOval(
        child: imageUrl != null
            ? Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    _buildCartPreviewFallback(fallbackLetter),
              )
            : _buildCartPreviewFallback(fallbackLetter),
      ),
    );
  }

  Widget _buildCartPreviewFallback(String? letter) {
    return Container(
      color: const Color(0xFFFFE7EA),
      alignment: Alignment.center,
      child: letter != null
          ? Text(
              letter,
              style: const TextStyle(
                color: _homeAccentColor,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            )
          : const Icon(
              Icons.shopping_bag_rounded,
              color: _homeAccentColor,
              size: 18,
            ),
    );
  }

  Widget _buildHomeHeader() {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        child: Row(
          children: [
            InkWell(
              onTap: () => Navigator.of(context).maybePop(),
              borderRadius: BorderRadius.circular(18),
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFE2E5EA)),
                ),
                child: const Icon(
                  Icons.arrow_back_ios_new_rounded,
                  size: 18,
                  color: Colors.black87,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F6FA),
                  borderRadius: BorderRadius.circular(21),
                  border: Border.all(color: const Color(0xFFE1E4EA)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    const Icon(
                      Icons.search_rounded,
                      size: 27,
                      color: _homeAccentColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _homeSearchController,
                        onChanged: (value) {
                          setState(() {
                            _homeSearchQuery = value;
                          });
                        },
                        style: const TextStyle(
                          color: Color(0xFF70768B),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                        decoration: InputDecoration(
                          isCollapsed: true,
                          border: InputBorder.none,
                          hintText: 'Search in ${widget.categoryName}',
                          hintStyle: const TextStyle(
                            color: Color(0xFF70768B),
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeTopCategoriesStrip() {
    if (_homeTopCategories.isEmpty) {
      return const SizedBox.shrink();
    }

    final orderedCategories = <_HomeTopCategoryChip>[];
    final selectedCategoryId = widget.categoryId.trim();
    if (selectedCategoryId.isNotEmpty) {
      for (final category in _homeTopCategories) {
        if (category.id == selectedCategoryId) {
          orderedCategories.add(category);
          break;
        }
      }
    }
    for (final category in _homeTopCategories) {
      if (category.id == selectedCategoryId) continue;
      orderedCategories.add(category);
    }

    String? allImageUrl;
    for (final category in orderedCategories) {
      final url = category.imageUrl?.trim();
      if (url != null && url.isNotEmpty) {
        allImageUrl = url;
        break;
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const visibleItems = 4;
          const itemGap = 8.0;
          final itemWidth =
              (constraints.maxWidth - (itemGap * (visibleItems - 1))) /
              visibleItems;

          return SizedBox(
            height: 88,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              itemCount: orderedCategories.length + 1,
              separatorBuilder: (context, index) =>
                  const SizedBox(width: itemGap),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _buildHomeTopCategoryItem(
                    width: itemWidth,
                    label: 'All',
                    imageUrl: allImageUrl,
                    isAll: true,
                    isSelected: false,
                    onTap: () => Navigator.of(context).maybePop(),
                  );
                }

                final category = orderedCategories[index - 1];
                return _buildHomeTopCategoryItem(
                  width: itemWidth,
                  label: category.name,
                  imageUrl: category.imageUrl,
                  isSelected: category.id == widget.categoryId,
                  onTap: () => _openHomeTopCategory(category),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildHomeTopCategoryItem({
    required double width,
    required String label,
    required VoidCallback onTap,
    String? imageUrl,
    bool isAll = false,
    bool isSelected = false,
  }) {
    final normalizedImageUrl = imageUrl?.trim();
    final hasImage =
        normalizedImageUrl != null && normalizedImageUrl.isNotEmpty;
    final circleSize = (width * 0.82).clamp(46.0, 58.0).toDouble();

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: circleSize,
              height: circleSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? _homeAccentColor : Colors.white,
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.09),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.35),
                    blurRadius: 2,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: hasImage
                  ? ClipOval(
                      child: SizedBox(
                        width: circleSize,
                        height: circleSize,
                        child: Image.network(
                          normalizedImageUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (context, _, __) {
                            return _buildHomeTopCategoryPlaceholder();
                          },
                        ),
                      ),
                    )
                  : _buildHomeTopCategoryPlaceholder(),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isAll || isSelected
                    ? FontWeight.w800
                    : FontWeight.w600,
                color: isSelected
                    ? _homeAccentColor
                    : isAll
                    ? const Color(0xFF1F2430)
                    : const Color(0xFF667085),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeTopCategoryPlaceholder() {
    return const Icon(
      Icons.restaurant_menu_rounded,
      size: 32,
      color: Color(0xFF98A2B3),
    );
  }

  Widget _buildHomeModeBody({
    required List<Map<String, dynamic>> visibleProducts,
    required double totalQty,
    required List<CartItem> activeCartItems,
  }) {
    final hasCartItems = totalQty > 0.0001;
    final gridBottomInset =
        MediaQuery.of(context).padding.bottom + (hasCartItems ? 118 : 24);

    return Stack(
      children: [
        Column(
          children: [
            _buildHomeHeader(),
            if (_homeTopCategories.isNotEmpty) _buildHomeTopCategoriesStrip(),
            Expanded(
              child: visibleProducts.isEmpty
                  ? const Center(
                      child: Text(
                        'No products found',
                        style: TextStyle(
                          color: Color(0xFF4A4A4A),
                          fontSize: 18,
                        ),
                      ),
                    )
                  : _buildHomeProductScrollView(
                      visibleProducts,
                      bottomInset: gridBottomInset,
                    ),
            ),
          ],
        ),
        if (hasCartItems)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildFloatingCartBar(
              totalQty: totalQty,
              cartItems: activeCartItems,
            ),
          ),
      ],
    );
  }

  Widget _buildHomeProductScrollView(
    List<Map<String, dynamic>> visibleProducts, {
    required double bottomInset,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width > 960
            ? 4
            : width > 680
            ? 3
            : 2;
        final spacing = width > 680 ? 16.0 : 14.0;
        final aspectRatio = width > 680 ? 0.62 : 0.59;

        return CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(16, 6, 16, bottomInset),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: spacing,
                  mainAxisSpacing: 10,
                  childAspectRatio: aspectRatio,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  return _buildHomeProductCard(visibleProducts[index]);
                }, childCount: visibleProducts.length),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHomeProductCard(Map<String, dynamic> product) {
    final productId = _productId(product);
    final productName = (product['name'] ?? 'Unknown').toString().trim();
    final imageUrl = _resolveProductImage(product);
    final price = _readProductPrice(product);
    final isVeg = _readIsVegStatus(product);
    final badgeInfo = _readProductBadgeInfo(product);
    final hasMetaRow = isVeg != null || badgeInfo != null;
    final topGap = hasMetaRow ? 8.0 : 10.0;
    final nameHeight = hasMetaRow ? 46.0 : 52.0;
    final isFocused = (_focusedProductId?.trim() ?? '') == productId;

    return Consumer<CartProvider>(
      builder: (context, cartProvider, child) {
        final qty = _qtyInCart(cartProvider, productId);
        final isFavorite = _favoriteProductIds.contains(productId);
        final showFocusHighlight =
            isFocused && _showFocusedProductHighlight && qty <= 0;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: showFocusHighlight
                ? const Color(0xFFFFF7F8)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
              color: showFocusHighlight
                  ? _homeAccentColor.withValues(alpha: 0.38)
                  : Colors.transparent,
              width: 1.4,
            ),
            boxShadow: showFocusHighlight
                ? [
                    BoxShadow(
                      color: _homeAccentColor.withValues(alpha: 0.12),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : const [],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(26),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: imageUrl == null
                            ? Container(
                                color: const Color(0xFFF3F3F3),
                                alignment: Alignment.center,
                                child: const Icon(
                                  Icons.fastfood_outlined,
                                  size: 34,
                                  color: Colors.black45,
                                ),
                              )
                            : CachedNetworkImage(
                                imageUrl: imageUrl,
                                fit: BoxFit.cover,
                                placeholder: (context, url) =>
                                    Container(color: const Color(0xFFF3F3F3)),
                                errorWidget: (context, url, error) => Container(
                                  color: const Color(0xFFF3F3F3),
                                  alignment: Alignment.center,
                                  child: const Icon(
                                    Icons.fastfood_outlined,
                                    size: 34,
                                    color: Colors.black45,
                                  ),
                                ),
                              ),
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: GestureDetector(
                          onTap: () =>
                              _toggleFavoriteProduct(productId, productName),
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.26),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              isFavorite
                                  ? Icons.favorite_rounded
                                  : Icons.favorite_border_rounded,
                              color: isFavorite
                                  ? _homeAccentColor
                                  : Colors.white.withValues(alpha: 0.95),
                              size: 18,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: topGap),
              if (hasMetaRow) ...[
                Row(
                  children: [
                    if (isVeg != null) _buildVegNonVegIcon(isVeg),
                    const Spacer(),
                    if (badgeInfo != null)
                      ProductRatingBadge(
                        info: badgeInfo,
                        fontSize: 10,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
              ],
              SizedBox(
                height: nameHeight,
                child: Text(
                  '$productName (${_formatDetailedPrice(price)})',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2D333D),
                    height: 1.15,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 22,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _formatCompactPrice(price),
                          maxLines: 1,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Colors.black,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 81,
                    child: _buildHomeQtyControl(product: product, qty: qty),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cartProvider = Provider.of<CartProvider>(context);
    final activeCartItems =
        _isHomeMode &&
            (cartProvider.currentType != CartType.table ||
                !cartProvider.isSharedTableOrder)
        ? const <CartItem>[]
        : cartProvider.cartItems
              .where((item) => item.quantity > 0)
              .toList(growable: false);
    final totalQty = activeCartItems.fold<double>(
      0.0,
      (sum, item) => sum + item.quantity,
    );
    final visibleProducts = _filteredHomeProducts();
    String title = widget.categoryName;
    if (!_isHomeMode && cartProvider.selectedTable != null) {
      title = '${widget.categoryName} (Table: ${cartProvider.selectedTable})';
    }

    return CommonScaffold(
      title: title,
      pageType: _isHomeMode ? PageType.home : widget.sourcePage,
      showAppBar: !_isHomeMode,
      hideBottomNavigationBar: _isHomeMode && totalQty > 0.0001,
      onScanCallback: _handleScan,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.black))
          : _isHomeMode
          ? RefreshIndicator(
              onRefresh: _fetchProducts,
              child: _buildHomeModeBody(
                visibleProducts: visibleProducts,
                totalQty: totalQty,
                activeCartItems: activeCartItems,
              ),
            )
          : _products.isEmpty
          ? const Center(
              child: Text(
                'No products found',
                style: TextStyle(color: Color(0xFF4A4A4A), fontSize: 18),
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final crossAxisCount = (width > 600) ? 5 : 3;
                return GridView.builder(
                  padding: const EdgeInsets.all(10),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 0.75,
                  ),
                  itemCount: _products.length,
                  itemBuilder: (context, index) {
                    final product = _products[index];
                    String? imageUrl;
                    if (product['images'] != null &&
                        product['images'].isNotEmpty &&
                        product['images'][0]['image'] != null &&
                        product['images'][0]['image']['url'] != null) {
                      imageUrl = product['images'][0]['image']['url'];
                      if (imageUrl != null && imageUrl.startsWith('/')) {
                        imageUrl = 'https://blackforest.vseyal.com$imageUrl';
                      }
                    }
                    imageUrl ??=
                        'https://via.placeholder.com/150?text=No+Image';

                    dynamic priceDetails = product['defaultPriceDetails'];
                    if (_branchId != null &&
                        product['branchOverrides'] != null) {
                      for (var override in product['branchOverrides']) {
                        var branch = override['branch'];
                        String branchOid = branch is Map
                            ? branch[r'$oid'] ?? branch['id'] ?? ''
                            : branch ?? '';
                        if (branchOid == _branchId) {
                          priceDetails = override;
                          break;
                        }
                      }
                    }
                    final price = priceDetails != null
                        ? '₹${priceDetails['price'] ?? 0}'
                        : '₹0';
                    return GestureDetector(
                      onTap: () => _toggleProductSelection(index),
                      child: Consumer<CartProvider>(
                        builder: (context, cartProvider, child) {
                          final isSelected = cartProvider.cartItems.any(
                            (i) => i.id == product['id'],
                          );
                          final qty = cartProvider.cartItems
                              .firstWhere(
                                (i) => i.id == product['id'],
                                orElse: () => CartItem(
                                  id: '',
                                  name: '',
                                  price: 0,
                                  quantity: 0,
                                ),
                              )
                              .quantity;
                          String qtyText;
                          if (qty == qty.floorToDouble()) {
                            qtyText = qty.toInt().toString();
                          } else {
                            qtyText = qty.toStringAsFixed(2);
                          }

                          return Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: isSelected
                                  ? Border.all(color: Colors.green, width: 4)
                                  : null,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.1),
                                  spreadRadius: 1,
                                  blurRadius: 5,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Stack(
                              children: [
                                Column(
                                  children: [
                                    Expanded(
                                      flex: 8,
                                      child: ClipRRect(
                                        borderRadius:
                                            const BorderRadius.vertical(
                                              top: Radius.circular(8),
                                            ),
                                        child: CachedNetworkImage(
                                          imageUrl: imageUrl!,
                                          fit: BoxFit.cover,
                                          width: double.infinity,
                                          placeholder: (context, url) =>
                                              const Center(
                                                child:
                                                    CircularProgressIndicator(),
                                              ),
                                          errorWidget: (context, url, error) =>
                                              const Center(
                                                child: Text(
                                                  'No Image',
                                                  style: TextStyle(
                                                    color: Colors.grey,
                                                  ),
                                                ),
                                              ),
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      flex: 2,
                                      child: Container(
                                        width: double.infinity,
                                        decoration: const BoxDecoration(
                                          color: Colors.black,
                                          borderRadius: BorderRadius.vertical(
                                            bottom: Radius.circular(8),
                                          ),
                                        ),
                                        alignment: Alignment.center,
                                        child: Text(
                                          product['name'] ?? 'Unknown',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          textAlign: TextAlign.center,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                Positioned(
                                  top: 2,
                                  left: 2,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      price,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ),
                                ),
                                if (isSelected)
                                  Positioned.fill(
                                    child: Align(
                                      alignment: Alignment.center,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                            alpha: 0.7,
                                          ),
                                          border: Border.all(
                                            color: Colors.grey,
                                            width: 1,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        child: Text(
                                          qtyText,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}
