import 'dart:async';
import 'dart:convert';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:blackforest_app/category_popularity_service.dart';
import 'package:blackforest_app/categories_page.dart';
import 'package:blackforest_app/cart_page.dart';
import 'package:blackforest_app/cart_provider.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/employee.dart';
import 'package:blackforest_app/offer_banner.dart';
import 'package:blackforest_app/product_popularity_service.dart';
import 'package:blackforest_app/products_page.dart';
import 'package:blackforest_app/widgets/product_rating_badge.dart';
import 'package:blackforest_app/widgets/rolling_qty_text.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
// import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:blackforest_app/kot_auto_print_service.dart';

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
      // Use a lower apex and inset base to make the triangle less sharp.
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

class _HomeRecommendedCacheEntry {
  final List<_FavoriteRuleSection> sections;
  final List<_FavoriteCategoryCard> categories;
  final DateTime fetchedAt;

  const _HomeRecommendedCacheEntry({
    required this.sections,
    required this.categories,
    required this.fetchedAt,
  });
}

class _HomeBillingCategoriesCacheEntry {
  final List<_FavoriteCategoryCard> categories;
  final DateTime fetchedAt;

  const _HomeBillingCategoriesCacheEntry({
    required this.categories,
    required this.fetchedAt,
  });

  bool isFresh(Duration ttl) => DateTime.now().difference(fetchedAt) <= ttl;
}

class _FavoriteRuleSection {
  final String title;
  final List<Map<String, dynamic>> products;

  const _FavoriteRuleSection({required this.title, required this.products});
}

class _FavoriteRuleSeed {
  final String title;
  final List<String> productIds;

  const _FavoriteRuleSeed({required this.title, required this.productIds});
}

class _FavoriteCategoryCard {
  final String id;
  final String name;
  final String? imageUrl;
  final int count;

  const _FavoriteCategoryCard({
    required this.id,
    required this.name,
    required this.imageUrl,
    required this.count,
  });
}

class _FavoriteHomePayload {
  final List<_FavoriteRuleSection> sections;
  final List<_FavoriteCategoryCard> categories;

  const _FavoriteHomePayload({
    required this.sections,
    required this.categories,
  });
}

enum _HomeSearchResultType { category, product }

class _HomeSearchResult {
  final _HomeSearchResultType type;
  final String id;
  final String name;
  final String subtitle;
  final String? imageUrl;
  final String? categoryId;
  final String? categoryName;

  const _HomeSearchResult({
    required this.type,
    required this.id,
    required this.name,
    required this.subtitle,
    required this.imageUrl,
    this.categoryId,
    this.categoryName,
  });
}

class _HomeSearchSelection {
  final _HomeSearchResultType type;
  final String id;
  final String name;
  final String? categoryId;
  final String? categoryName;

  const _HomeSearchSelection({
    required this.type,
    required this.id,
    required this.name,
    this.categoryId,
    this.categoryName,
  });
}

class _HomeSearchOverlay extends StatefulWidget {
  const _HomeSearchOverlay();

  @override
  State<_HomeSearchOverlay> createState() => _HomeSearchOverlayState();
}

class _HomeSearchOverlayState extends State<_HomeSearchOverlay> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _debounce;
  bool _isLoading = false;
  String? _error;
  List<_HomeSearchResult> _results = const <_HomeSearchResult>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _handleQueryChanged(String value) async {
    setState(() {});
    _debounce?.cancel();

    final query = value.trim();
    if (query.isEmpty) {
      setState(() {
        _results = const <_HomeSearchResult>[];
        _isLoading = false;
        _error = null;
      });
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 260), () async {
      await _search(query);
    });
  }

  Future<void> _search(String query) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token')?.trim();
      if (token == null || token.isEmpty) {
        if (!mounted) return;
        setState(() {
          _results = const <_HomeSearchResult>[];
          _isLoading = false;
          _error = 'No token found. Please login again.';
        });
        return;
      }

      final branchId = prefs.getString('branchId')?.trim();
      final role = prefs.getString('role')?.trim();
      final companyId = prefs.getString('company_id')?.trim();
      final encodedQuery = Uri.encodeQueryComponent(query);

      final values = await Future.wait<List<_HomeSearchResult>>([
        _fetchCategoryResults(
          token: token,
          query: encodedQuery,
          role: role,
          companyId: companyId,
        ),
        _fetchProductResults(
          token: token,
          query: encodedQuery,
          branchId: branchId,
          role: role,
          companyId: companyId,
        ),
      ]);

      if (!mounted || _controller.text.trim() != query) return;
      setState(() {
        _results = <_HomeSearchResult>[...values[0], ...values[1]];
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _results = const <_HomeSearchResult>[];
        _isLoading = false;
        _error = 'Unable to load search results';
      });
    }
  }

  Future<List<_HomeSearchResult>> _fetchCategoryResults({
    required String token,
    required String query,
    required String? role,
    required String? companyId,
  }) async {
    var filterQuery =
        'where[isBilling][equals]=true&where[name][like]=$query&limit=6&depth=1&sort=name';
    if (role != 'superadmin' &&
        companyId != null &&
        companyId.trim().isNotEmpty) {
      filterQuery += '&where[company][contains]=$companyId';
    }

    final response = await http.get(
      Uri.parse('https://blackforest.vseyal.com/api/categories?$filterQuery'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
    );
    if (response.statusCode != 200) {
      return const <_HomeSearchResult>[];
    }

    final decoded = jsonDecode(response.body);
    final results = <_HomeSearchResult>[];
    final seen = <String>{};
    for (final raw in _toDynamicList(decoded)) {
      final category = _toMap(raw);
      if (category == null) continue;
      final id = _extractRefId(category['id'] ?? category['_id']);
      final name = (category['name'] ?? '').toString().trim();
      if (id.isEmpty || name.isEmpty || !seen.add(id)) continue;
      results.add(
        _HomeSearchResult(
          type: _HomeSearchResultType.category,
          id: id,
          name: name,
          subtitle: 'Category',
          imageUrl: _extractImageFromAny(
            category['imageUrl'] ??
                category['image'] ??
                category['thumbnail'] ??
                category,
          ),
          categoryId: id,
          categoryName: name,
        ),
      );
    }
    return results;
  }

  Future<List<_HomeSearchResult>> _fetchProductResults({
    required String token,
    required String query,
    required String? branchId,
    required String? role,
    required String? companyId,
  }) async {
    final response = await http.get(
      Uri.parse(
        'https://blackforest.vseyal.com/api/products?where[name][like]=$query&limit=12&depth=2&sort=name',
      ),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
    );
    if (response.statusCode != 200) {
      return const <_HomeSearchResult>[];
    }

    final decoded = jsonDecode(response.body);
    final results = <_HomeSearchResult>[];
    final seen = <String>{};

    for (final raw in _toDynamicList(decoded)) {
      final product = _toMap(raw);
      if (product == null) continue;
      final id = _extractRefId(product['id'] ?? product['_id']);
      final name = (product['name'] ?? '').toString().trim();
      if (id.isEmpty || name.isEmpty || !seen.add(id)) continue;
      if (!_isProductSearchMatchAllowed(
        product,
        branchId: branchId,
        role: role,
        companyId: companyId,
      )) {
        continue;
      }

      final category = _readProductCategory(product);
      results.add(
        _HomeSearchResult(
          type: _HomeSearchResultType.product,
          id: id,
          name: name,
          subtitle: 'Dish',
          imageUrl: _resolveProductImage(product),
          categoryId: category?['id'] as String?,
          categoryName: category?['name'] as String?,
        ),
      );
    }

    return results;
  }

  bool _isProductSearchMatchAllowed(
    Map<String, dynamic> product, {
    required String? branchId,
    required String? role,
    required String? companyId,
  }) {
    if (product['status'] == 'inactive') return false;
    if (product['isAvailable'] == false) return false;

    if (branchId != null && branchId.isNotEmpty) {
      final inactiveBranches = _toDynamicList(product['inactiveBranches']);
      for (final branch in inactiveBranches) {
        if (_extractRefId(branch) == branchId) return false;
      }
    }

    if (role != 'superadmin' &&
        companyId != null &&
        companyId.isNotEmpty &&
        !_productMatchesCompany(product, companyId)) {
      return false;
    }

    return true;
  }

  bool _productMatchesCompany(Map<String, dynamic> product, String companyId) {
    final category = _toMap(product['category']);
    if (category == null) return true;
    final companies = _toDynamicList(category['company']);
    if (companies.isEmpty) return true;
    for (final company in companies) {
      if (_extractRefId(company) == companyId) return true;
    }
    return false;
  }

  Map<String, dynamic>? _readProductCategory(Map<String, dynamic> product) {
    final category = _toMap(product['category']);
    if (category == null) return null;
    final id = _extractRefId(category['id'] ?? category['_id']);
    final name = (category['name'] ?? '').toString().trim();
    if (id.isEmpty || name.isEmpty) return null;
    return <String, dynamic>{'id': id, 'name': name};
  }

  String? _resolveProductImage(Map<String, dynamic> product) {
    final directImage = _normalizeImageUrl(
      product['imageUrl'] ??
          product['thumbnail'] ??
          product['image']?['url'] ??
          product['image'],
    );
    if (directImage != null) return directImage;

    final images = product['images'];
    if (images is List && images.isNotEmpty) {
      final first = images.first;
      if (first is Map) {
        final nested = _normalizeImageUrl(
          first['image'] is Map ? first['image']['url'] : first['url'],
        );
        if (nested != null) return nested;
      }
    }

    return _extractImageFromAny(product);
  }

  void _clearQuery() {
    _debounce?.cancel();
    _controller.clear();
    setState(() {
      _results = const <_HomeSearchResult>[];
      _isLoading = false;
      _error = null;
    });
    _focusNode.requestFocus();
  }

  Map<String, dynamic>? _toMap(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return null;
  }

  List<dynamic> _toDynamicList(dynamic value) {
    if (value == null) return const [];
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
    final lower = value.toLowerCase();
    final maybeFilePath =
        lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.svg') ||
        lower.endsWith('.avif');
    if (value.startsWith('uploads/') ||
        value.startsWith('media/') ||
        value.startsWith('files/') ||
        value.startsWith('api/') ||
        maybeFilePath) {
      return 'https://blackforest.vseyal.com/$value';
    }
    return null;
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

  Widget _buildResultImage(_HomeSearchResult result) {
    if (result.imageUrl == null || result.imageUrl!.isEmpty) {
      return Container(
        color: const Color(0xFFF1F1F1),
        child: Icon(
          result.type == _HomeSearchResultType.product
              ? Icons.fastfood_outlined
              : Icons.grid_view_rounded,
          color: const Color(0xFF9A9A9A),
          size: 22,
        ),
      );
    }

    return Image.network(
      result.imageUrl!,
      fit: BoxFit.cover,
      errorBuilder: (context, _, __) {
        return Container(
          color: const Color(0xFFF1F1F1),
          child: Icon(
            result.type == _HomeSearchResultType.product
                ? Icons.fastfood_outlined
                : Icons.grid_view_rounded,
            color: const Color(0xFF9A9A9A),
            size: 22,
          ),
        );
      },
    );
  }

  Widget _buildHighlightedText(String text, String query) {
    final normalizedText = text.toLowerCase();
    final normalizedQuery = query.toLowerCase();
    final start = normalizedText.indexOf(normalizedQuery);
    if (query.isEmpty || start < 0) {
      return Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: Color(0xFF505050),
        ),
      );
    }

    final end = start + query.length;
    return Text.rich(
      TextSpan(
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: Color(0xFF505050),
        ),
        children: [
          TextSpan(text: text.substring(0, start)),
          TextSpan(
            text: text.substring(start, end),
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              color: Color(0xFF2A2A2A),
            ),
          ),
          TextSpan(text: text.substring(end)),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  @override
  Widget build(BuildContext context) {
    final trimmedQuery = _controller.text.trim();
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    final hasSearchResultsPanel =
        trimmedQuery.isNotEmpty || _isLoading || _error != null;
    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(color: Colors.black.withValues(alpha: 0.5)),
            ),
          ),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                GestureDetector(
                  onTap: () {},
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    decoration: BoxDecoration(
                      color: Color(0xFFF8F8F8),
                      borderRadius: hasSearchResultsPanel
                          ? BorderRadius.zero
                          : const BorderRadius.only(
                              bottomLeft: Radius.circular(30),
                              bottomRight: Radius.circular(30),
                            ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x33000000),
                          blurRadius: 24,
                          offset: Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            IconButton(
                              onPressed: () => Navigator.of(context).pop(),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 40,
                                minHeight: 40,
                              ),
                              icon: const Icon(
                                Icons.arrow_back_rounded,
                                size: 30,
                                color: Color(0xFF666666),
                              ),
                            ),
                            const Expanded(
                              child: Text(
                                'Search for dishes & restaurants',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF333333),
                                ),
                              ),
                            ),
                            const SizedBox(width: 40),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Container(
                          height: 58,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: const Color(0xFFD7D7D7)),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Stack(
                                  children: [
                                    if (_controller.text.isEmpty)
                                      const IgnorePointer(
                                        child: Padding(
                                          padding: EdgeInsets.fromLTRB(
                                            20,
                                            7,
                                            12,
                                            7,
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                "Try 'Sweets'",
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: Color(0xFFCDCDCD),
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                              SizedBox(height: 2),
                                              Text(
                                                "Try 'EatRight'",
                                                style: TextStyle(
                                                  fontSize: 16,
                                                  color: Color(0xFF8A8A8A),
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    TextField(
                                      controller: _controller,
                                      focusNode: _focusNode,
                                      textInputAction: TextInputAction.search,
                                      cursorColor: const Color(0xFF333333),
                                      style: const TextStyle(
                                        fontSize: 16,
                                        color: Color(0xFF333333),
                                        fontWeight: FontWeight.w500,
                                      ),
                                      onChanged: _handleQueryChanged,
                                      decoration: const InputDecoration(
                                        border: InputBorder.none,
                                        contentPadding: EdgeInsets.fromLTRB(
                                          20,
                                          12,
                                          12,
                                          10,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (trimmedQuery.isNotEmpty)
                                IconButton(
                                  onPressed: _clearQuery,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 40,
                                    minHeight: 40,
                                  ),
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    color: Color(0xFF8A8A8A),
                                    size: 26,
                                  ),
                                ),
                              Container(
                                width: 1,
                                height: 24,
                                color: const Color(0xFFE1E1E1),
                              ),
                              IconButton(
                                onPressed: () => _focusNode.requestFocus(),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 52,
                                  minHeight: 52,
                                ),
                                icon: const Icon(
                                  Icons.mic,
                                  color: Color(0xFFFF7A1A),
                                  size: 28,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (hasSearchResultsPanel)
                  Expanded(
                    child: Container(
                      color: Colors.white,
                      child: _isLoading
                          ? const Center(
                              child: CircularProgressIndicator(
                                color: Colors.black,
                              ),
                            )
                          : _error != null
                          ? Center(
                              child: Text(
                                _error!,
                                style: const TextStyle(
                                  color: Color(0xFF7A7A7A),
                                  fontSize: 14,
                                ),
                              ),
                            )
                          : _results.isEmpty
                          ? Center(
                              child: Text(
                                'No results for "$trimmedQuery"',
                                style: const TextStyle(
                                  color: Color(0xFF7A7A7A),
                                  fontSize: 14,
                                ),
                              ),
                            )
                          : ListView.separated(
                              padding: EdgeInsets.fromLTRB(
                                20,
                                8,
                                20,
                                keyboardInset + 18,
                              ),
                              itemCount: _results.length + 1,
                              separatorBuilder: (context, index) =>
                                  const SizedBox(height: 14),
                              itemBuilder: (context, index) {
                                if (index == 0) {
                                  return const Padding(
                                    padding: EdgeInsets.only(bottom: 4),
                                    child: Text(
                                      'MORE RESULTS MATCHING YOUR QUERY',
                                      style: TextStyle(
                                        color: Color(0xFF737373),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 2.2,
                                      ),
                                    ),
                                  );
                                }

                                final result = _results[index - 1];
                                return InkWell(
                                  onTap: () {
                                    Navigator.of(context).pop(
                                      _HomeSearchSelection(
                                        type: result.type,
                                        id: result.id,
                                        name: result.name,
                                        categoryId:
                                            result.categoryId ?? result.id,
                                        categoryName:
                                            result.categoryName ?? result.name,
                                      ),
                                    );
                                  },
                                  borderRadius: BorderRadius.circular(16),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 4,
                                    ),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 64,
                                          height: 64,
                                          padding: const EdgeInsets.all(2),
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white,
                                              width: 2,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withValues(
                                                  alpha: 0.09,
                                                ),
                                                blurRadius: 14,
                                                offset: const Offset(0, 5),
                                              ),
                                              BoxShadow(
                                                color: Colors.white.withValues(
                                                  alpha: 0.35,
                                                ),
                                                blurRadius: 2,
                                                spreadRadius: 1,
                                              ),
                                            ],
                                          ),
                                          child: ClipOval(
                                            child: _buildResultImage(result),
                                          ),
                                        ),
                                        const SizedBox(width: 14),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              _buildHighlightedText(
                                                result.name,
                                                trimmedQuery,
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                result.subtitle,
                                                style: const TextStyle(
                                                  fontSize: 14,
                                                  color: Color(0xFF8A8A8A),
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const int _maxProductsPerRule = 30;
  static const Duration _recommendedCacheTtl = Duration(minutes: 5);
  static const Duration _billingCategoriesCacheTtl = Duration(seconds: 90);
  static const String _topCircleCategoriesRuleName = 'Top Categories';
  static const double _topSectionHeight = 314;
  static const double _stickyHomeHeaderTriggerOffset = 300;
  static final Map<String, _HomeRecommendedCacheEntry>
  _recommendedCacheByBranch = <String, _HomeRecommendedCacheEntry>{};
  static final Map<String, _HomeBillingCategoriesCacheEntry>
  _billingCategoriesCache = <String, _HomeBillingCategoriesCacheEntry>{};
  static final Map<String, Future<_FavoriteHomePayload>>
  _recommendedFetchInFlightByBranch = <String, Future<_FavoriteHomePayload>>{};

  final ScrollController _homeScrollController = ScrollController();
  Future<void>? _homeBillingCategoriesLoadFuture;
  String? _photoUrl;
  String? _branchId;
  String? _branchName;
  String? _currentUserId;
  bool _isLoadingRecommended = true;
  bool _showStickyHomeHeader = false;
  List<_FavoriteRuleSection> _ruleSections = <_FavoriteRuleSection>[];
  List<_FavoriteCategoryCard> _billingCategories = <_FavoriteCategoryCard>[];
  List<_FavoriteCategoryCard> _favoriteCategories = <_FavoriteCategoryCard>[];
  List<String> _favoriteCategoryIds = <String>[];
  List<String> _favoriteProductIds = <String>[];
  Map<String, ProductPopularityInfo> _categoryPopularityById =
      <String, ProductPopularityInfo>{};
  Map<String, ProductPopularityInfo> _productPopularityById =
      <String, ProductPopularityInfo>{};

  @override
  void initState() {
    super.initState();
    _homeScrollController.addListener(_handleHomeScroll);
    _loadUserPhoto();
    _loadFavoriteCategories();
    _loadFavoriteProducts();
    _loadRecommendedProducts();
    _loadHomeBillingCategories();
    _loadCategoryPopularity();
    _loadProductPopularity();
    _ensureTableCartMode();
    _initForegroundTask();
  }

  Future<void> _initForegroundTask() async {
    if (!Platform.isAndroid) return;

    // Start the service
    await KotAutoPrintService.startService();
  }

  @override
  void dispose() {
    _homeScrollController.removeListener(_handleHomeScroll);
    _homeScrollController.dispose();
    super.dispose();
  }

  void _handleHomeScroll() {
    if (!_homeScrollController.hasClients) return;
    final shouldShow =
        _homeScrollController.offset >= _stickyHomeHeaderTriggerOffset;
    if (shouldShow &&
        _billingCategories.isEmpty &&
        _homeBillingCategoriesLoadFuture == null) {
      unawaited(_loadHomeBillingCategories());
    }
    if (shouldShow == _showStickyHomeHeader || !mounted) return;
    setState(() {
      _showStickyHomeHeader = shouldShow;
    });
  }

  void _preloadHomeTopCategories() {
    if (_billingCategories.isNotEmpty) return;
    unawaited(_loadHomeBillingCategories());
  }

  void _ensureTableCartMode() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Provider.of<CartProvider>(
        context,
        listen: false,
      ).setCartType(CartType.table, notify: false);
    });
  }

  Future<void> _loadUserPhoto() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _photoUrl = prefs.getString('employee_photo_url');
      _branchName = prefs.getString('branchName')?.trim();
    });
  }

  String _favoriteCategoriesKey(String userId) =>
      'favorite_category_ids_table_$userId';

  Future<void> _loadFavoriteCategories({String? preferredUserId}) async {
    final prefs = await SharedPreferences.getInstance();
    final userId =
        preferredUserId ?? _currentUserId ?? prefs.getString('user_id');

    if (userId == null || userId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _currentUserId = null;
        _favoriteCategoryIds = <String>[];
      });
      return;
    }

    final stored =
        prefs.getStringList(_favoriteCategoriesKey(userId)) ?? <String>[];
    final normalized = <String>[];
    for (final id in stored) {
      final cleanId = id.trim();
      if (cleanId.isEmpty || normalized.contains(cleanId)) continue;
      normalized.add(cleanId);
    }

    if (normalized.length != stored.length) {
      await prefs.setStringList(_favoriteCategoriesKey(userId), normalized);
    }

    if (!mounted) return;
    setState(() {
      _currentUserId = userId;
      _favoriteCategoryIds = normalized;
    });
  }

  Future<void> _saveFavoriteCategories() async {
    if (_currentUserId == null || _currentUserId!.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _favoriteCategoriesKey(_currentUserId!),
      _favoriteCategoryIds.toList(),
    );
  }

  Future<void> _toggleFavoriteCategory(
    String categoryId,
    String categoryName,
  ) async {
    if (categoryId.trim().isEmpty) return;

    if (_currentUserId == null || _currentUserId!.isEmpty) {
      await _loadFavoriteCategories();
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

    final normalizedId = categoryId.trim();
    if (_favoriteCategoryIds.contains(normalizedId)) {
      setState(() {
        _favoriteCategoryIds.remove(normalizedId);
      });
      await _saveFavoriteCategories();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$categoryName removed from favorites')),
      );
      return;
    }

    setState(() {
      _favoriteCategoryIds.remove(normalizedId);
      _favoriteCategoryIds.insert(0, normalizedId);
    });
    await _saveFavoriteCategories();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$categoryName added to favorites')));
  }

  String _favoriteProductsKey(String userId) =>
      'favorite_product_ids_table_$userId';

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

  Future<void> _loadCategoryPopularity() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token')?.trim();
      final branchId = (_branchId ?? prefs.getString('branchId') ?? '')
          .toString()
          .trim();
      if (token == null || token.isEmpty || branchId.isEmpty) {
        return;
      }

      final popularity = await CategoryPopularityService.getPopularityForBranch(
        token: token,
        branchId: branchId,
      );
      if (!mounted) return;
      setState(() {
        _categoryPopularityById = popularity;
      });
    } catch (_) {}
  }

  ProductPopularityInfo? _categoryBadgeInfo(String categoryId) {
    final normalizedId = categoryId.trim();
    if (normalizedId.isEmpty) return null;
    return _categoryPopularityById[normalizedId];
  }

  Future<void> _saveFavoriteProducts() async {
    if (_currentUserId == null || _currentUserId!.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _favoriteProductsKey(_currentUserId!),
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

    if (_favoriteProductIds.contains(normalizedId)) {
      setState(() {
        _favoriteProductIds.remove(normalizedId);
      });
      await _saveFavoriteProducts();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$productName removed from favorites')),
      );
      return;
    }

    setState(() {
      _favoriteProductIds.remove(normalizedId);
      _favoriteProductIds.insert(0, normalizedId);
    });
    await _saveFavoriteProducts();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$productName added to favorites')));
  }

  List<_FavoriteCategoryCard> _orderedCategories(
    List<_FavoriteCategoryCard> categories,
  ) {
    if (categories.isEmpty || _favoriteCategoryIds.isEmpty) {
      return categories;
    }

    final byId = <String, _FavoriteCategoryCard>{
      for (final category in categories) category.id: category,
    };

    final favorite = <_FavoriteCategoryCard>[];
    for (final id in _favoriteCategoryIds) {
      final item = byId[id];
      if (item != null) favorite.add(item);
    }

    final nonFavorite = categories
        .where((category) => !_favoriteCategoryIds.contains(category.id))
        .toList();

    return <_FavoriteCategoryCard>[...favorite, ...nonFavorite];
  }

  List<_FavoriteCategoryCard> _orderedFavoriteCategories() =>
      _orderedCategories(_favoriteCategories);

  List<_FavoriteCategoryCard> _orderedBillingCategories() => _billingCategories;

  List<Map<String, dynamic>> _homeTopCategoriesPayload() =>
      _orderedBillingCategories()
          .map(
            (category) => <String, dynamic>{
              'id': category.id,
              'name': category.name,
              'imageUrl': category.imageUrl,
              'count': category.count,
            },
          )
          .toList(growable: false);

  List<_FavoriteCategoryCard> _orderedFastMovementCategories() =>
      _orderedCategories(_extractFastMovementCategories());

  List<Map<String, dynamic>> _orderedProductsForRule(
    _FavoriteRuleSection section,
  ) {
    if (section.products.isEmpty || _favoriteProductIds.isEmpty) {
      return section.products;
    }

    final productsById = <String, Map<String, dynamic>>{};
    for (final product in section.products) {
      final id = _productId(product);
      if (id.isEmpty || productsById.containsKey(id)) continue;
      productsById[id] = product;
    }

    final favoriteProducts = <Map<String, dynamic>>[];
    for (final id in _favoriteProductIds) {
      final product = productsById[id];
      if (product != null) {
        favoriteProducts.add(product);
      }
    }

    final nonFavoriteProducts = section.products
        .where((product) => !_favoriteProductIds.contains(_productId(product)))
        .toList();

    return <Map<String, dynamic>>[...favoriteProducts, ...nonFavoriteProducts];
  }

  List<_FavoriteCategoryCard> _extractFastMovementCategories() {
    final order = <String>[];
    final namesByKey = <String, String>{};
    final imagesByKey = <String, String?>{};
    final countsByKey = <String, int>{};

    for (final section in _ruleSections) {
      for (final product in _orderedProductsForRule(section)) {
        final category = _readProductCategoryEntry(product);
        if (category == null) continue;
        final key = (category['key'] as String? ?? '').trim();
        final name = (category['name'] as String? ?? '').trim();
        if (key.isEmpty || name.isEmpty) continue;

        if (!countsByKey.containsKey(key)) {
          order.add(key);
          namesByKey[key] = name;
          imagesByKey[key] = category['imageUrl'] as String?;
          countsByKey[key] = 0;
        }

        countsByKey[key] = (countsByKey[key] ?? 0) + 1;
        imagesByKey[key] ??= category['imageUrl'] as String?;
      }
    }

    return order
        .map(
          (key) => _FavoriteCategoryCard(
            id: key,
            name: namesByKey[key] ?? 'Category',
            imageUrl: imagesByKey[key],
            count: countsByKey[key] ?? 0,
          ),
        )
        .toList();
  }

  Map<String, dynamic>? _readProductCategoryEntry(
    Map<String, dynamic> product,
  ) {
    final categoryCandidates = <dynamic>[
      product['category'],
      product['categories'],
      product['defaultCategory'],
    ];

    for (final candidate in categoryCandidates) {
      final entry = _toCategoryEntry(candidate);
      if (entry != null) return entry;
    }

    final categoryNameCandidates = <dynamic>[
      product['categoryName'],
      product['department'],
    ];
    for (final candidate in categoryNameCandidates) {
      final name = candidate?.toString().trim() ?? '';
      if (name.isEmpty) continue;
      return <String, dynamic>{
        'key': name.toLowerCase(),
        'name': name,
        'imageUrl': _resolveImageUrl(product),
      };
    }

    return null;
  }

  String _billingCategoriesCacheKey(String branchId) =>
      'branch-rule-top-categories-v1|${branchId.trim()}';

  Future<void> _loadHomeBillingCategories() async {
    final inFlight = _homeBillingCategoriesLoadFuture;
    if (inFlight != null) {
      return inFlight;
    }

    final future = _loadHomeBillingCategoriesInternal();
    _homeBillingCategoriesLoadFuture = future;
    future.whenComplete(() {
      if (identical(_homeBillingCategoriesLoadFuture, future)) {
        _homeBillingCategoriesLoadFuture = null;
      }
    });
    return future;
  }

  Future<void> _loadHomeBillingCategoriesInternal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token')?.trim();
      final branchId = prefs.getString('branchId')?.trim() ?? '';

      if (token == null || token.isEmpty) {
        if (!mounted) return;
        setState(() {
          _billingCategories = <_FavoriteCategoryCard>[];
        });
        return;
      }

      final cacheKey = _billingCategoriesCacheKey(branchId);
      final cached = _billingCategoriesCache[cacheKey];
      if (cached != null && cached.isFresh(_billingCategoriesCacheTtl)) {
        if (!mounted) return;
        setState(() {
          _billingCategories = _cloneFavoriteCategories(cached.categories);
        });
        return;
      }

      var categories = await _fetchTopSellingKotCategoriesForBranch(
        token: token,
        branchId: branchId,
      );
      if (categories.isNotEmpty) {
        categories = await _hydrateFavoriteCategories(categories, token);
      }

      _billingCategoriesCache[cacheKey] = _HomeBillingCategoriesCacheEntry(
        categories: _cloneFavoriteCategories(categories),
        fetchedAt: DateTime.now(),
      );

      if (!mounted) return;
      setState(() {
        _billingCategories = categories;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _billingCategories = <_FavoriteCategoryCard>[];
      });
    }
  }

  Future<List<_FavoriteCategoryCard>> _fetchTopSellingKotCategoriesForBranch({
    required String token,
    required String branchId,
  }) async {
    final normalizedBranchId = branchId.trim();
    if (normalizedBranchId.isEmpty) return const <_FavoriteCategoryCard>[];

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
        return const <_FavoriteCategoryCard>[];
      }
      final decoded = jsonDecode(response.body);
      return _readFavoriteCategoriesForBranch(
        decoded,
        normalizedBranchId,
        ruleNameFilter: _topCircleCategoriesRuleName,
      );
    } catch (_) {
      return const <_FavoriteCategoryCard>[];
    }
  }

  Future<void> _loadRecommendedProducts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token')?.trim();
      _branchId = prefs.getString('branchId')?.trim();

      if (token == null ||
          token.isEmpty ||
          _branchId == null ||
          _branchId!.isEmpty) {
        if (!mounted) return;
        setState(() {
          _ruleSections = <_FavoriteRuleSection>[];
          _favoriteCategories = <_FavoriteCategoryCard>[];
          _isLoadingRecommended = false;
        });
        return;
      }

      unawaited(_loadCategoryPopularity());
      unawaited(_loadProductPopularity());

      final branchKey = _branchId!;
      final cacheEntry = _recommendedCacheByBranch[branchKey];
      if (cacheEntry != null) {
        if (mounted) {
          setState(() {
            _ruleSections = _cloneRuleSections(cacheEntry.sections);
            _favoriteCategories = _cloneFavoriteCategories(
              cacheEntry.categories,
            );
            _isLoadingRecommended = false;
          });
        }
        final isFresh =
            DateTime.now().difference(cacheEntry.fetchedAt) <
            _recommendedCacheTtl;
        if (isFresh) {
          return;
        }
      }

      if (mounted && _ruleSections.isEmpty) {
        setState(() {
          _isLoadingRecommended = true;
        });
      }

      final inFlight = _recommendedFetchInFlightByBranch[branchKey];
      final createdInFlight = inFlight == null;
      final fetchFuture =
          inFlight ??
          _fetchRecommendedProductsForBranch(token: token, branchId: branchKey);
      if (createdInFlight) {
        _recommendedFetchInFlightByBranch[branchKey] = fetchFuture;
      }
      _FavoriteHomePayload payload = const _FavoriteHomePayload(
        sections: <_FavoriteRuleSection>[],
        categories: <_FavoriteCategoryCard>[],
      );
      try {
        payload = await fetchFuture;
      } finally {
        if (createdInFlight) {
          _recommendedFetchInFlightByBranch.remove(branchKey);
        }
      }

      if (!mounted) return;
      setState(() {
        _ruleSections = _cloneRuleSections(payload.sections);
        _favoriteCategories = _cloneFavoriteCategories(payload.categories);
        _isLoadingRecommended = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingRecommended = false;
      });
    }
  }

  Future<_FavoriteHomePayload> _fetchRecommendedProductsForBranch({
    required String token,
    required String branchId,
  }) async {
    final rulesResponse = await http.get(
      Uri.parse(
        'https://blackforest.vseyal.com/api/globals/widget-settings?depth=1',
      ),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
    );

    if (rulesResponse.statusCode != 200) {
      return const _FavoriteHomePayload(
        sections: <_FavoriteRuleSection>[],
        categories: <_FavoriteCategoryCard>[],
      );
    }

    final rulesDecoded = jsonDecode(rulesResponse.body);
    final favoriteCategories = await _hydrateFavoriteCategories(
      _readFavoriteCategoriesForBranch(rulesDecoded, branchId),
      token,
    );
    final favoriteRuleSeeds = _readFavoriteRuleSeedsForBranch(
      rulesDecoded,
      branchId,
    );
    if (favoriteRuleSeeds.isEmpty) {
      return _cacheFavoriteHomePayload(
        branchId: branchId,
        categories: favoriteCategories,
      );
    }

    final favoriteProductIds = <String>[];
    final uniqueIds = <String>{};
    for (final rule in favoriteRuleSeeds) {
      for (final productId in rule.productIds) {
        if (!uniqueIds.add(productId)) continue;
        favoriteProductIds.add(productId);
      }
    }
    if (favoriteProductIds.isEmpty) {
      return _cacheFavoriteHomePayload(
        branchId: branchId,
        categories: favoriteCategories,
      );
    }

    final idsParam = favoriteProductIds.join(',');
    final optionsResponse = await http.get(
      Uri.parse(
        'https://blackforest.vseyal.com/api/widgets/product-options?ids=$idsParam',
      ),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
    );

    if (optionsResponse.statusCode != 200) {
      return _cacheFavoriteHomePayload(
        branchId: branchId,
        categories: favoriteCategories,
      );
    }

    final optionsDecoded = jsonDecode(optionsResponse.body);
    final normalizedOptions = _extractNormalizedProductOptions(optionsDecoded);
    final optionById = <String, Map<String, dynamic>>{
      for (final option in normalizedOptions) _productId(option): option,
    };
    final productsById = await _fetchProductsByIds(favoriteProductIds, token);
    final sections = <_FavoriteRuleSection>[];
    for (final seed in favoriteRuleSeeds) {
      final products = <Map<String, dynamic>>[];
      final seenInRule = <String>{};
      for (final productId in seed.productIds) {
        if (!seenInRule.add(productId)) continue;
        final item = optionById[productId];
        if (item == null) continue;
        final productDoc = productsById[productId];
        final merged = <String, dynamic>{...item};
        if (productDoc != null) {
          final vegValue =
              productDoc['isVeg'] ?? productDoc['is_veg'] ?? productDoc['veg'];
          if (vegValue != null) {
            merged['isVeg'] = vegValue;
          }
          if (productDoc['category'] != null) {
            merged['category'] = productDoc['category'];
          }
          final imageFromDoc = _resolveImageUrl(productDoc);
          if (imageFromDoc != null && imageFromDoc.isNotEmpty) {
            merged['imageUrl'] = imageFromDoc;
            merged['images'] = <Map<String, dynamic>>[
              <String, dynamic>{
                'image': <String, dynamic>{'url': imageFromDoc},
              },
            ];
          }
        }
        products.add(merged);
        if (products.length >= _maxProductsPerRule) break;
      }
      if (products.isEmpty) continue;
      sections.add(_FavoriteRuleSection(title: seed.title, products: products));
    }
    if (sections.isEmpty) {
      return _cacheFavoriteHomePayload(
        branchId: branchId,
        categories: favoriteCategories,
      );
    }

    for (final section in sections) {
      for (var i = 0; i < section.products.length; i++) {
        final current = section.products[i];
        if (_resolveImageUrl(current) != null) continue;
        final id = _productId(current);
        final productDoc = productsById[id];
        if (productDoc == null) continue;
        final imageUrl = _resolveImageUrl(productDoc);
        if (imageUrl == null || imageUrl.isEmpty) continue;
        section.products[i] = <String, dynamic>{
          ...current,
          'imageUrl': imageUrl,
          'images': <Map<String, dynamic>>[
            <String, dynamic>{
              'image': <String, dynamic>{'url': imageUrl},
            },
          ],
        };
      }
    }

    return _cacheFavoriteHomePayload(
      branchId: branchId,
      sections: sections,
      categories: favoriteCategories,
    );
  }

  List<_FavoriteRuleSection> _cloneRuleSections(
    List<_FavoriteRuleSection> source,
  ) {
    return source
        .map(
          (section) => _FavoriteRuleSection(
            title: section.title,
            products: section.products
                .map((product) => Map<String, dynamic>.from(product))
                .toList(),
          ),
        )
        .toList();
  }

  List<_FavoriteCategoryCard> _cloneFavoriteCategories(
    List<_FavoriteCategoryCard> source,
  ) {
    return source
        .map(
          (category) => _FavoriteCategoryCard(
            id: category.id,
            name: category.name,
            imageUrl: category.imageUrl,
            count: category.count,
          ),
        )
        .toList();
  }

  _FavoriteHomePayload _cacheFavoriteHomePayload({
    required String branchId,
    List<_FavoriteRuleSection> sections = const <_FavoriteRuleSection>[],
    List<_FavoriteCategoryCard> categories = const <_FavoriteCategoryCard>[],
  }) {
    final payload = _FavoriteHomePayload(
      sections: _cloneRuleSections(sections),
      categories: _cloneFavoriteCategories(categories),
    );
    _recommendedCacheByBranch[branchId] = _HomeRecommendedCacheEntry(
      sections: _cloneRuleSections(payload.sections),
      categories: _cloneFavoriteCategories(payload.categories),
      fetchedAt: DateTime.now(),
    );
    return payload;
  }

  List<_FavoriteCategoryCard> _readFavoriteCategoriesForBranch(
    dynamic decoded,
    String branchId, {
    String? ruleNameFilter,
  }) {
    final rulesNode = _findByKey(decoded, 'favoriteCategoriesByBranchRules');
    final rules = _toDynamicList(rulesNode);
    final categories = <_FavoriteCategoryCard>[];
    final seenCategoryIds = <String>{};

    for (final rawRule in rules) {
      final rule = _toMap(rawRule);
      if (rule == null) continue;
      if (!_toBool(rule['enabled'])) continue;

      final branchesNode =
          rule['branches'] ??
          rule['branchesIds'] ??
          rule['branchIds'] ??
          rule['branch'];
      if (!_ruleMatchesBranch(branchesNode, branchId)) continue;
      if (!_ruleNameMatches(rule, ruleNameFilter)) continue;

      final categoriesNode = rule['categories'] ?? rule['category'];
      for (final rawCategory in _toDynamicList(categoriesNode)) {
        final category = _toFavoriteCategoryCard(rawCategory);
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

  Future<List<_FavoriteCategoryCard>> _hydrateFavoriteCategories(
    List<_FavoriteCategoryCard> categories,
    String token,
  ) async {
    if (categories.isEmpty) return const <_FavoriteCategoryCard>[];

    final ids = categories
        .map((category) => category.id.trim())
        .where((id) => id.isNotEmpty)
        .toList();
    if (ids.isEmpty) return categories;

    try {
      final idsParam = Uri.encodeQueryComponent(ids.join(','));
      final response = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/categories?where[id][in]=$idsParam&depth=1&limit=${ids.length}',
        ),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );
      if (response.statusCode != 200) return categories;

      final decoded = jsonDecode(response.body);
      final fetchedById = <String, _FavoriteCategoryCard>{};
      for (final rawCategory in _toDynamicList(decoded)) {
        final category = _toFavoriteCategoryCard(rawCategory);
        if (category == null) continue;
        fetchedById[category.id] = category;
      }

      return categories.map((category) {
        final hydrated = fetchedById[category.id];
        if (hydrated == null) return category;
        return _FavoriteCategoryCard(
          id: category.id,
          name: hydrated.name.isNotEmpty ? hydrated.name : category.name,
          imageUrl: hydrated.imageUrl ?? category.imageUrl,
          count: category.count,
        );
      }).toList();
    } catch (_) {
      return categories;
    }
  }

  _FavoriteCategoryCard? _toFavoriteCategoryCard(dynamic rawCategory) {
    final entry = _toCategoryEntry(rawCategory);
    if (entry == null) return null;

    final id = (entry['id'] as String? ?? entry['key'] as String? ?? '').trim();
    final name = (entry['name'] as String? ?? '').trim();
    if (id.isEmpty || name.isEmpty) return null;

    return _FavoriteCategoryCard(
      id: id,
      name: name,
      imageUrl: entry['imageUrl'] as String?,
      count: 0,
    );
  }

  Map<String, dynamic>? _toCategoryEntry(dynamic categoryNode) {
    if (categoryNode == null) return null;
    if (categoryNode is List) {
      for (final item in categoryNode) {
        final parsed = _toCategoryEntry(item);
        if (parsed != null) return parsed;
      }
      return null;
    }

    if (categoryNode is String || categoryNode is num) {
      final raw = categoryNode.toString().trim();
      if (raw.isEmpty) return null;
      return <String, dynamic>{
        'id': raw,
        'key': raw.toLowerCase(),
        'name': raw,
        'imageUrl': null,
      };
    }

    final category = _toMap(categoryNode);
    if (category == null) return null;
    final id = _extractRefId(
      category['id'] ??
          category['_id'] ??
          category['value'] ??
          category['categoryId'],
    );
    final nameCandidates = <dynamic>[
      category['name'],
      category['label'],
      category['title'],
      category['categoryName'],
    ];
    String name = '';
    for (final candidate in nameCandidates) {
      final text = candidate?.toString().trim() ?? '';
      if (text.isEmpty) continue;
      name = text;
      break;
    }
    if (name.isEmpty && id.isNotEmpty) {
      name = id;
    }
    if (name.isEmpty) return null;

    final key = id.isNotEmpty ? id : name.toLowerCase();
    final imageUrl = _extractImageFromAny(
      category['imageUrl'] ??
          category['image'] ??
          category['thumbnail'] ??
          category,
    );
    return <String, dynamic>{
      'id': id.isNotEmpty ? id : null,
      'key': key,
      'name': name,
      'imageUrl': imageUrl,
    };
  }

  Future<Map<String, Map<String, dynamic>>> _fetchProductsByIds(
    List<String> productIds,
    String token,
  ) async {
    if (productIds.isEmpty) return const <String, Map<String, dynamic>>{};
    try {
      final idsParam = Uri.encodeQueryComponent(productIds.join(','));
      final response = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/products?where[id][in]=$idsParam&depth=2&limit=100',
        ),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );
      if (response.statusCode != 200) {
        return const <String, Map<String, dynamic>>{};
      }

      final decoded = jsonDecode(response.body);
      final productsById = <String, Map<String, dynamic>>{};
      for (final raw in _toDynamicList(decoded)) {
        final product = _toMap(raw);
        if (product == null) continue;
        final id = _productId(product);
        if (id.isEmpty) continue;
        productsById[id] = product;
      }
      return productsById;
    } catch (_) {
      return const <String, Map<String, dynamic>>{};
    }
  }

  List<_FavoriteRuleSeed> _readFavoriteRuleSeedsForBranch(
    dynamic decoded,
    String branchId,
  ) {
    final rulesNode = _findByKey(decoded, 'favoriteProductsByBranchRules');
    final rules = _toDynamicList(rulesNode);
    final sections = <_FavoriteRuleSeed>[];

    for (final rawRule in rules) {
      final rule = _toMap(rawRule);
      if (rule == null) continue;
      if (!_toBool(rule['enabled'])) continue;
      final branchesNode =
          rule['branches'] ??
          rule['branchesIds'] ??
          rule['branchIds'] ??
          rule['branch'];
      if (!_ruleMatchesBranch(branchesNode, branchId)) continue;

      final productsNode =
          rule['products'] ??
          rule['productIds'] ??
          rule['favoriteProducts'] ??
          rule['product'];
      final productIds = <String>[];
      final seen = <String>{};
      for (final productRef in _toDynamicList(productsNode)) {
        final id = _extractRefId(productRef);
        if (id.isEmpty || !seen.add(id)) continue;
        productIds.add(id);
      }
      if (productIds.isEmpty) continue;

      sections.add(
        _FavoriteRuleSeed(
          title: _readFavoriteRuleTitle(rule),
          productIds: productIds,
        ),
      );
    }

    return sections;
  }

  String _readFavoriteRuleTitle(Map<String, dynamic> rule) {
    const candidates = <String>[
      'ruleName',
      'ruleTitle',
      'name',
      'title',
      'label',
      'heading',
    ];
    for (final key in candidates) {
      final text = rule[key]?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return 'Recommended';
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

  Map<String, dynamic>? _toMap(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return null;
  }

  List<dynamic> _toDynamicList(dynamic value) {
    if (value == null) return const [];
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
      ];
      for (final candidate in candidates) {
        final id = _extractRefId(candidate);
        if (id.isNotEmpty) return id;
      }
    }
    return '';
  }

  bool _ruleMatchesBranch(dynamic branchesNode, String branchId) {
    for (final branchRef in _toDynamicList(branchesNode)) {
      if (_extractRefId(branchRef) == branchId) return true;
    }
    return false;
  }

  List<Map<String, dynamic>> _extractNormalizedProductOptions(dynamic decoded) {
    final rawOptions = _extractOptionList(decoded);
    final normalized = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (final rawOption in rawOptions) {
      final option = _toMap(rawOption);
      if (option == null) continue;
      final normalizedOption = _normalizeProductOption(option);
      if (normalizedOption == null) continue;

      final id = _productId(normalizedOption);
      if (id.isEmpty || seen.contains(id)) {
        continue;
      }

      seen.add(id);
      normalized.add(normalizedOption);
    }

    return normalized;
  }

  List<dynamic> _extractOptionList(dynamic decoded) {
    if (decoded is List) return List<dynamic>.from(decoded);

    final root = _toMap(decoded);
    if (root == null) return const [];

    final data = root['data'];
    final dataMap = data is Map ? Map<String, dynamic>.from(data) : null;

    final candidates = <dynamic>[
      root['options'],
      root['docs'],
      root['items'],
      root['results'],
      root['values'],
      root['data'],
      dataMap?['options'],
      dataMap?['docs'],
      dataMap?['items'],
      dataMap?['results'],
      dataMap?['values'],
    ];

    for (final candidate in candidates) {
      if (candidate is List) return List<dynamic>.from(candidate);
    }
    return const [];
  }

  Map<String, dynamic>? _normalizeProductOption(Map<String, dynamic> option) {
    final id = _extractRefId(
      option['value'] ??
          option['id'] ??
          option['product'] ??
          option['productId'],
    );
    if (id.isEmpty) return null;

    final label = (option['label'] ?? '').toString().trim();
    final explicitName = (option['name'] ?? option['title'] ?? '')
        .toString()
        .trim();
    final name = explicitName.isNotEmpty
        ? explicitName
        : _deriveNameFromLabel(label);
    final price = _readOptionPrice(option, label);

    final imageUrl = _extractImageFromAny(option);

    return <String, dynamic>{
      'id': id,
      'value': id,
      'name': name.isNotEmpty ? name : 'Product',
      'label': label,
      'price': price,
      'defaultPriceDetails': <String, dynamic>{'price': price},
      if (imageUrl != null) 'imageUrl': imageUrl,
      if (imageUrl != null)
        'images': <Map<String, dynamic>>[
          <String, dynamic>{
            'image': <String, dynamic>{'url': imageUrl},
          },
        ],
    };
  }

  String _deriveNameFromLabel(String label) {
    if (label.isEmpty) return '';
    final priceIndex = label.indexOf('₹');
    var name = priceIndex > 0 ? label.substring(0, priceIndex) : label;
    name = name.replaceAll(RegExp(r'[\-\|\:\u2022\s]+$'), '').trim();
    return name;
  }

  double _readOptionPrice(Map<String, dynamic> option, String label) {
    final directCandidates = <dynamic>[
      option['price'],
      option['unitPrice'],
      option['sellingPrice'],
      option['amount'],
      option['mrp'],
      option['valuePrice'],
    ];
    for (final candidate in directCandidates) {
      final value = _toDouble(candidate);
      if (value > 0) return value;
    }

    final labelPrice = _extractPriceFromText(label);
    if (labelPrice > 0) return labelPrice;

    final valueLabelPrice = _extractPriceFromText(
      (option['valueLabel'] ?? '').toString(),
    );
    if (valueLabelPrice > 0) return valueLabelPrice;

    return 0;
  }

  double _extractPriceFromText(String text) {
    if (text.trim().isEmpty) return 0;
    final match = RegExp(
      r'(?:₹|rs\.?|inr)\s*([0-9]+(?:\.[0-9]+)?)',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return 0;
    return _toDouble(match.group(1));
  }

  String? _normalizeImageUrl(dynamic rawUrl) {
    final value = rawUrl?.toString().trim();
    if (value == null || value.isEmpty) return null;
    if (value.startsWith('data:image/')) return value;
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    if (value.startsWith('//')) {
      return 'https:$value';
    }
    if (value.startsWith('blackforest.vseyal.com')) {
      return 'https://$value';
    }
    if (value.startsWith('/')) {
      return 'https://blackforest.vseyal.com$value';
    }
    final lower = value.toLowerCase();
    final maybeFilePath =
        lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.svg') ||
        lower.endsWith('.avif');
    if (value.startsWith('uploads/') ||
        value.startsWith('media/') ||
        value.startsWith('files/') ||
        value.startsWith('api/') ||
        maybeFilePath) {
      return 'https://blackforest.vseyal.com/$value';
    }
    return null;
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

  String? _resolveImageUrl(Map<String, dynamic> product) {
    final directImage = _normalizeImageUrl(
      product['imageUrl'] ??
          product['thumbnail'] ??
          product['image']?['url'] ??
          product['image'],
    );
    if (directImage != null) return directImage;

    final images = product['images'];
    if (images is! List || images.isEmpty) return null;

    dynamic rawUrl;
    final first = images.first;
    if (first is Map) {
      if (first['image'] is Map) {
        rawUrl = first['image']['url'];
      }
      rawUrl ??= first['url'];
    }

    final fromImages = _normalizeImageUrl(rawUrl);
    if (fromImages != null) return fromImages;

    return _extractImageFromAny(product);
  }

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  double _readProductPrice(Map<String, dynamic> product) {
    final directPrice = _toDouble(product['price']);
    if (directPrice > 0) return directPrice;

    final labelPrice = _extractPriceFromText(
      (product['label'] ?? '').toString(),
    );
    if (labelPrice > 0) return labelPrice;

    return _toDouble(product['defaultPriceDetails']?['price']);
  }

  bool? _readIsVegStatus(Map<String, dynamic> product) {
    final direct = <dynamic>[
      product['isVeg'],
      product['is_veg'],
      product['veg'],
    ];
    for (final value in direct) {
      if (value == null) continue;
      return _toBool(value);
    }

    final category = _toMap(product['category']);
    if (category != null) {
      final value = category['isVeg'] ?? category['is_veg'] ?? category['veg'];
      if (value != null) {
        return _toBool(value);
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

  String _formatPrice(double price) {
    if (price == price.floorToDouble()) {
      return '₹${price.toInt()}';
    }
    return '₹${price.toStringAsFixed(2)}';
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

  String _productId(Map<String, dynamic> product) {
    final candidates = <dynamic>[
      product['id'],
      product['value'],
      product['productId'],
      product['product'],
    ];
    for (final candidate in candidates) {
      final id = _extractRefId(candidate);
      if (id.isNotEmpty) return id;
    }
    return '';
  }

  double _qtyInCart(CartProvider cartProvider, String productId) {
    if (productId.isEmpty) return 0;
    if (cartProvider.currentType != CartType.table ||
        !cartProvider.isSharedTableOrder) {
      return 0;
    }
    final existing = cartProvider.cartItems.where((i) => i.id == productId);
    if (existing.isEmpty) return 0;
    return existing.first.quantity;
  }

  void _addToCart(Map<String, dynamic> product) {
    final productId = _productId(product);
    if (productId.isEmpty) return;

    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    _prepareHomeTableCartContext(cartProvider);
    final item = CartItem.fromProduct(
      product,
      1,
      branchPrice: _readProductPrice(product),
      branchId: _branchId,
    );
    cartProvider.addOrUpdateItem(item);
  }

  void _decreaseQty(Map<String, dynamic> product, double currentQty) {
    final productId = _productId(product);
    if (productId.isEmpty) return;

    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    _prepareHomeTableCartContext(cartProvider);
    if (currentQty <= 1) {
      cartProvider.removeItem(productId);
      return;
    }
    cartProvider.updateQuantity(productId, currentQty - 1);
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
    cartProvider.setCurrentDraftHomeCategoriesUi(
      enabled: true,
      homeTopCategories: _homeTopCategoriesPayload(),
    );
  }

  Future<void> _openTableCartFromHome() async {
    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    cartProvider.setCartType(CartType.table, notify: false);

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const CartPage()),
    );
  }

  Future<void> _openCategoryProducts(_FavoriteCategoryCard category) async {
    final categoryId = category.id.trim();
    if (categoryId.isEmpty) return;
    await _openCategoryByIdName(categoryId, category.name);
  }

  Future<void> _openCategoryByIdName(
    String categoryId,
    String categoryName,
  ) async {
    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    _prepareHomeTableCartContext(cartProvider);
    _preloadHomeTopCategories();
    if (!mounted) return;

    await Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (context, animation, secondaryAnimation) => ProductsPage(
          categoryId: categoryId,
          categoryName: categoryName,
          sourcePage: PageType.home,
          initialHomeTopCategories: _homeTopCategoriesPayload(),
        ),
      ),
    );
  }

  Future<void> _openAllCategoriesPage() async {
    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    _prepareHomeTableCartContext(cartProvider);
    _preloadHomeTopCategories();
    if (!mounted) return;

    await Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (context, animation, secondaryAnimation) => CategoriesPage(
          sourcePage: PageType.home,
          initialHomeTopCategories: _homeTopCategoriesPayload(),
        ),
      ),
    );
  }

  Future<void> _openHomeSearchOverlay() async {
    if (!mounted) return;
    final selection = await showGeneralDialog<_HomeSearchSelection>(
      context: context,
      barrierLabel: 'Search',
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, animation, secondaryAnimation) {
        return const _HomeSearchOverlay();
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -0.05),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );

    if (!mounted || selection == null) return;
    if (selection.type == _HomeSearchResultType.category) {
      await _openCategoryByIdName(
        selection.categoryId ?? selection.id,
        selection.categoryName ?? selection.name,
      );
      return;
    }

    final categoryId = selection.categoryId?.trim() ?? '';
    final categoryName = selection.categoryName?.trim() ?? 'Products';
    if (categoryId.isEmpty) return;

    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    _prepareHomeTableCartContext(cartProvider);
    _preloadHomeTopCategories();
    if (!mounted) return;

    await Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (context, animation, secondaryAnimation) => ProductsPage(
          categoryId: categoryId,
          categoryName: categoryName,
          sourcePage: PageType.home,
          initialHomeTopCategories: _homeTopCategoriesPayload(),
          initialFocusedProductId: selection.id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<CartProvider>(
      builder: (context, cartProvider, child) {
        final activeCartItems =
            cartProvider.currentType == CartType.table &&
                cartProvider.isSharedTableOrder
            ? cartProvider.cartItems
                  .where((item) => item.quantity > 0)
                  .toList(growable: false)
            : const <CartItem>[];
        final totalQty = activeCartItems.fold<double>(
          0.0,
          (sum, item) => sum + item.quantity,
        );
        final hasCartItems = totalQty > 0.0001;
        final cartBottomInset =
            MediaQuery.of(context).padding.bottom + (hasCartItems ? 118 : 24);

        return CommonScaffold(
          title: '',
          pageType: PageType.home,
          showAppBar: false,
          hideBottomNavigationBar: hasCartItems,
          body: Stack(
            children: [
              SingleChildScrollView(
                controller: _homeScrollController,
                child: Padding(
                  padding: EdgeInsets.only(bottom: cartBottomInset),
                  child: Column(
                    children: [
                      _buildTopSection(context),
                      const SizedBox(height: 14),
                      _buildBillingCategoriesStrip(),
                      if (_billingCategories.isNotEmpty)
                        const SizedBox(height: 6),
                      _buildFastMovementSection(),
                      const SizedBox(height: 10),
                      _buildRecommendedSection(),
                      if (_favoriteCategories.isNotEmpty)
                        const SizedBox(height: 8),
                      _buildFavoriteCategoriesSection(),
                      const SizedBox(height: 30),
                    ],
                  ),
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  ignoring: !_showStickyHomeHeader,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    offset: _showStickyHomeHeader
                        ? Offset.zero
                        : const Offset(0, -1),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 180),
                      opacity: _showStickyHomeHeader ? 1 : 0,
                      child: _buildStickyHomeHeader(),
                    ),
                  ),
                ),
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
          ),
        );
      },
    );
  }

  String _formatCartCount(double qty) {
    if (qty == qty.floorToDouble()) {
      return qty.toInt().toString();
    }
    return qty.toStringAsFixed(1);
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
          onTap: () {
            _openTableCartFromHome();
          },
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
                color: Color(0xFFEF4F5F),
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            )
          : const Icon(
              Icons.shopping_bag_rounded,
              color: Color(0xFFEF4F5F),
              size: 18,
            ),
    );
  }

  Widget _buildFavoriteCategoriesSection() {
    final orderedCategories = _orderedFavoriteCategories();
    if (orderedCategories.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF4FBF7),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: orderedCategories.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 14,
              mainAxisSpacing: 12,
              childAspectRatio: 0.95,
            ),
            itemBuilder: (context, index) {
              return _buildFavoriteCategoryCard(orderedCategories[index]);
            },
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _buildFastMovementSection() {
    final orderedCategories = _orderedFastMovementCategories();
    if (orderedCategories.isEmpty) {
      return const SizedBox.shrink();
    }

    const cardsPerPage = 3;
    final pageCount =
        (orderedCategories.length + cardsPerPage - 1) ~/ cardsPerPage;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Fast Movement',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1F2430),
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final cardWidth = (constraints.maxWidth - 20) / 3;
              return SizedBox(
                height: cardWidth,
                child: PageView.builder(
                  itemCount: pageCount,
                  itemBuilder: (context, pageIndex) {
                    final start = pageIndex * cardsPerPage;
                    final end =
                        (start + cardsPerPage) > orderedCategories.length
                        ? orderedCategories.length
                        : (start + cardsPerPage);
                    final pageItems = orderedCategories.sublist(start, end);

                    return Row(
                      children: [
                        for (var slot = 0; slot < cardsPerPage; slot++) ...[
                          Expanded(
                            child: slot < pageItems.length
                                ? _buildFastMovementCategoryCard(
                                    pageItems[slot],
                                  )
                                : const SizedBox.shrink(),
                          ),
                          if (slot != cardsPerPage - 1)
                            const SizedBox(width: 10),
                        ],
                      ],
                    );
                  },
                ),
              );
            },
          ),
          const SizedBox(height: 6),
          _buildHomeSectionDivider(),
        ],
      ),
    );
  }

  Widget _buildHomeSectionDivider() {
    return const Padding(
      padding: EdgeInsets.only(top: 6),
      child: Divider(height: 1, thickness: 1, color: Color(0xFFE3E5E8)),
    );
  }

  Widget _buildBillingCategoriesStrip({
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 16),
    double height = 104,
  }) {
    final orderedCategories = _orderedBillingCategories();
    if (orderedCategories.isEmpty) {
      return const SizedBox.shrink();
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
      padding: padding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const visibleItems = 4;
          const itemGap = 8.0;
          final itemWidth =
              (constraints.maxWidth - (itemGap * (visibleItems - 1))) /
              visibleItems;

          return SizedBox(
            height: height,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              itemCount: orderedCategories.length + 1,
              separatorBuilder: (context, index) =>
                  const SizedBox(width: itemGap),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _buildBillingCategoryStripItem(
                    width: itemWidth,
                    label: 'All',
                    imageUrl: allImageUrl,
                    isAll: true,
                    onTap: _openAllCategoriesPage,
                  );
                }

                final category = orderedCategories[index - 1];
                return _buildBillingCategoryStripItem(
                  width: itemWidth,
                  label: category.name,
                  imageUrl: category.imageUrl,
                  onTap: () => _openCategoryProducts(category),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildBillingCategoryStripItem({
    required double width,
    required String label,
    required VoidCallback onTap,
    String? imageUrl,
    bool isAll = false,
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
                border: Border.all(color: Colors.white, width: 2),
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
                            return _buildBillingCategoryStripPlaceholder();
                          },
                        ),
                      ),
                    )
                  : _buildBillingCategoryStripPlaceholder(),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isAll ? FontWeight.w800 : FontWeight.w600,
                color: isAll
                    ? const Color(0xFF1F2430)
                    : const Color(0xFF667085),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBillingCategoryStripPlaceholder() {
    return const Icon(
      Icons.restaurant_menu_rounded,
      size: 32,
      color: Color(0xFF98A2B3),
    );
  }

  Widget _buildFastMovementCategoryCard(_FavoriteCategoryCard category) {
    final isFavorite = _favoriteCategoryIds.contains(category.id);
    return GestureDetector(
      onTap: () => _openCategoryProducts(category),
      onLongPress: () => _toggleFavoriteCategory(category.id, category.name),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          children: [
            Positioned.fill(
              child: category.imageUrl == null
                  ? _buildFavoriteCategoryPlaceholder()
                  : Image.network(
                      category.imageUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (context, _, __) {
                        return _buildFavoriteCategoryPlaceholder();
                      },
                    ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: GestureDetector(
                onTap: () =>
                    _toggleFavoriteCategory(category.id, category.name),
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
                        ? const Color(0xFFFF4D5A)
                        : Colors.white.withValues(alpha: 0.95),
                    size: 18,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(8, 14, 8, 7),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Color(0x8A000000),
                      Color(0xCC000000),
                    ],
                  ),
                ),
                child: Text(
                  category.name.toUpperCase(),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    height: 1.05,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFavoriteCategoryCard(_FavoriteCategoryCard category) {
    final isFavorite = _favoriteCategoryIds.contains(category.id);
    final badgeInfo = _categoryBadgeInfo(category.id);
    return GestureDetector(
      onTap: () => _openCategoryProducts(category),
      onLongPress: () => _toggleFavoriteCategory(category.id, category.name),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFE5E7EB)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            children: [
              Positioned.fill(
                child: category.imageUrl == null
                    ? _buildFavoriteCategoryPlaceholder()
                    : Image.network(
                        category.imageUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (context, _, __) {
                          return _buildFavoriteCategoryPlaceholder();
                        },
                      ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  height: 72,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Color(0x8A000000),
                        Color(0xCC000000),
                      ],
                    ),
                  ),
                ),
              ),
              if (badgeInfo != null)
                Positioned(
                  top: 8,
                  left: 8,
                  child: ProductRatingBadge(
                    info: badgeInfo,
                    fontSize: 10,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                  ),
                ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 13,
                child: Text(
                  category.name,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.left,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: GestureDetector(
                  onTap: () =>
                      _toggleFavoriteCategory(category.id, category.name),
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
                          ? const Color(0xFFFF4D5A)
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
    );
  }

  Widget _buildFavoriteCategoryPlaceholder() {
    return Container(
      color: const Color(0xFFF3F4F6),
      child: const Center(
        child: Icon(
          Icons.fastfood_outlined,
          size: 34,
          color: Color(0xFF9CA3AF),
        ),
      ),
    );
  }

  Widget _buildRecommendedSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isLoadingRecommended)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: CircularProgressIndicator(color: Colors.black),
              ),
            )
          else if (_ruleSections.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: const Text(
                'No recommended products available',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.black54,
                ),
              ),
            )
          else
            Consumer<CartProvider>(
              builder: (context, cartProvider, child) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (
                      var sectionIndex = 0;
                      sectionIndex < _ruleSections.length;
                      sectionIndex++
                    ) ...[
                      ...() {
                        final section = _ruleSections[sectionIndex];
                        final orderedProducts = _orderedProductsForRule(
                          section,
                        );
                        return [
                          if (sectionIndex != 0) const SizedBox(height: 10),
                          GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            padding: EdgeInsets.zero,
                            itemCount: orderedProducts.length,
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  crossAxisSpacing: 14,
                                  mainAxisSpacing: 10,
                                  childAspectRatio: 0.59,
                                ),
                            itemBuilder: (context, index) {
                              final product = orderedProducts[index];
                              final productId = _productId(product);
                              final productName = (product['name'] ?? 'Product')
                                  .toString();
                              final qty = _qtyInCart(cartProvider, productId);
                              final isFavorite = _favoriteProductIds.contains(
                                productId,
                              );
                              return GestureDetector(
                                onLongPress: () => _toggleFavoriteProduct(
                                  productId,
                                  productName,
                                ),
                                child: _buildRecommendedProductCard(
                                  product: product,
                                  qty: qty,
                                  isFavorite: isFavorite,
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 12),
                          _buildHomeSectionDivider(),
                        ];
                      }(),
                    ],
                  ],
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildRecommendedProductCard({
    required Map<String, dynamic> product,
    required double qty,
    required bool isFavorite,
  }) {
    final productId = _productId(product);
    final imageUrl = _resolveImageUrl(product);
    final productName = (product['name'] ?? 'Product').toString();
    final isVeg = _readIsVegStatus(product);
    final badgeInfo = _readProductBadgeInfo(product);
    final priceText = _formatPrice(_readProductPrice(product));
    final hasMetaRow = isVeg != null || badgeInfo != null;
    final topGap = hasMetaRow ? 8.0 : 10.0;
    final nameHeight = hasMetaRow ? 34.0 : 40.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: Stack(
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: imageUrl == null
                    ? Container(
                        color: const Color(0xFFF0F0F0),
                        child: const Center(
                          child: Icon(
                            Icons.fastfood_outlined,
                            size: 36,
                            color: Colors.black45,
                          ),
                        ),
                      )
                    : Image.network(
                        imageUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            color: const Color(0xFFF0F0F0),
                            child: const Center(
                              child: Icon(
                                Icons.fastfood_outlined,
                                size: 36,
                                color: Colors.black45,
                              ),
                            ),
                          );
                        },
                      ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: GestureDetector(
                  onTap: () => _toggleFavoriteProduct(productId, productName),
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
                          ? const Color(0xFFFF4D5A)
                          : Colors.white.withValues(alpha: 0.95),
                      size: 18,
                    ),
                  ),
                ),
              ),
            ],
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
            productName,
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
          children: [
            Text(
              priceText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Colors.black,
                height: 1,
              ),
            ),
            const Spacer(),
            const SizedBox(width: 10),
            SizedBox(
              width: 81,
              child: _buildQtyControl(product: product, qty: qty),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildQtyControl({
    required Map<String, dynamic> product,
    required double qty,
  }) {
    const addAccentColor = Color(0xFFEF4F5F);
    const activeControlColor = Color(0xFFEF4F5F);
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth <= 96;
        final buttonBorder = BorderRadius.circular(12);
        final addControlHeight = isCompact ? 34.0 : 36.0;
        final controlHeight = addControlHeight;
        final actionWidth = isCompact ? 22.0 : 24.0;
        final addFontSize = isCompact ? 16.0 : 17.0;
        final actionIconSize = isCompact ? 22.0 : 23.0;
        final qtyFontSize = isCompact ? 18.0 : 19.0;

        if (qty <= 0) {
          return SizedBox(
            height: addControlHeight,
            child: OutlinedButton(
              onPressed: () => _addToCart(product),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: addAccentColor, width: 1.2),
                shape: RoundedRectangleBorder(borderRadius: buttonBorder),
                backgroundColor: const Color(0xFFFFF7F8),
                padding: EdgeInsets.zero,
              ),
              child: Center(
                child: Text(
                  'ADD',
                  style: TextStyle(
                    color: addAccentColor,
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
            color: activeControlColor,
            borderRadius: buttonBorder,
          ),
          child: Row(
            children: [
              _buildQtyActionButton(
                icon: Icons.remove,
                onTap: () => _decreaseQty(product, qty),
                width: actionWidth,
                height: controlHeight,
                iconSize: actionIconSize,
                color: Colors.white,
              ),
              Expanded(
                child: Center(
                  child: RollingQtyText(
                    value: qty,
                    height: controlHeight,
                    style: TextStyle(
                      fontSize: qtyFontSize,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              _buildQtyActionButton(
                icon: Icons.add,
                onTap: () => _addToCart(product),
                width: actionWidth,
                height: controlHeight,
                iconSize: actionIconSize,
                color: Colors.white,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildQtyActionButton({
    required IconData icon,
    required VoidCallback onTap,
    required double width,
    required double height,
    required double iconSize,
    Color color = const Color(0xFF16A16E),
  }) {
    final symbol = icon == Icons.remove ? '−' : '+';
    final xOffset = symbol == '−' ? 2.5 : -2.5;
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
              symbol,
              style: TextStyle(
                fontSize: iconSize,
                fontWeight: FontWeight.w900,
                height: 1,
                color: color,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHomeSearchBar({double elevation = 3}) {
    final shadowOpacity = elevation <= 0 ? 0.0 : 0.06 + (elevation * 0.01);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFFE0E3E8), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: shadowOpacity.clamp(0, 0.14)),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(15),
          onTap: _openHomeSearchOverlay,
          child: Container(
            height: 50,
            padding: const EdgeInsets.symmetric(horizontal: 15),
            child: const Row(
              children: [
                Icon(Icons.search, color: Color(0xFFEF4F5F)),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    "Search for 'Pizza'",
                    style: TextStyle(
                      color: Color(0xFF8A8A8A),
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Icon(Icons.mic, color: Color(0xFFEF4F5F)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStickyHomeHeader() {
    return Material(
      color: Colors.white,
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: 0.08),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHomeSearchBar(elevation: 5),
              if (_orderedBillingCategories().isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildBillingCategoriesStrip(
                  padding: EdgeInsets.zero,
                  height: 88,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopSection(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.only(
        bottomLeft: Radius.circular(30),
        bottomRight: Radius.circular(30),
      ),
      child: SizedBox(
        width: double.infinity,
        height: _topSectionHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF4B7CC0), Color(0xFF3D68B6)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
            const OfferBanner(
              height: 314,
              viewportFraction: 1,
              showIndicators: true,
              itemMargin: EdgeInsets.zero,
              borderRadius: BorderRadius.zero,
              showShadow: false,
              loadingIndicatorColor: Colors.white,
              indicatorBottomOffset: 14,
              mediaSize: 84,
              contentPadding: EdgeInsets.fromLTRB(22, 160, 22, 32),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black12,
                        Colors.transparent,
                        Colors.black26.withValues(alpha: 0.08),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(top: 10, left: 20, right: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if ((_branchName?.isNotEmpty ?? false)) ...[
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.location_on_rounded,
                                    size: 15,
                                    color: Colors.white,
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      _branchName!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                        ] else
                          const Spacer(),
                        GestureDetector(
                          onTap: () {
                            Navigator.pushAndRemoveUntil(
                              context,
                              MaterialPageRoute(
                                builder: (context) => const EmployeePage(),
                              ),
                              (route) => false,
                            );
                          },
                          child: _photoUrl != null && _photoUrl!.isNotEmpty
                              ? CircleAvatar(
                                  radius: 20,
                                  backgroundImage: NetworkImage(_photoUrl!),
                                  backgroundColor: Colors.grey[100],
                                )
                              : const CircleAvatar(
                                  radius: 20,
                                  backgroundColor: Colors.white,
                                  child: Icon(
                                    Icons.person,
                                    color: Colors.black54,
                                  ),
                                ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 15),
                    _buildHomeSearchBar(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
