import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/api_config.dart';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:blackforest_app/return_order_page.dart';
import 'package:blackforest_app/return_provider.dart';
import 'package:blackforest_app/instock_provider.dart';

class ReturnCategoriesPage extends StatefulWidget {
  const ReturnCategoriesPage({super.key});

  @override
  State<ReturnCategoriesPage> createState() => _ReturnCategoriesPageState();
}

class _ReturnCategoriesPageState extends State<ReturnCategoriesPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  List<dynamic> _externalSearchResults = [];
  bool _isSearchingExternal = false;
  Timer? _debounceTimer;
  bool _searchShowAsGrid = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<InstockProvider>(context, listen: false).syncBranchId();
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged(String val) {
    if (val.trim().isEmpty) {
      _debounceTimer?.cancel();
      setState(() {
        _searchShowAsGrid = false;
        _isSearchingExternal = false;
        _externalSearchResults = [];
      });
      return;
    }
    setState(() {
      _isSearchingExternal = true;
    });
    _debounceTimer?.cancel();
    final query = val.trim();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () async {
      await _searchExternalProducts(query);
    });
  }

  Future<void> _searchExternalProducts(String query) async {
    if (!mounted) return;
    setState(() => _isSearchingExternal = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString("token");
      if (token == null) {
        if (mounted) setState(() => _isSearchingExternal = false);
        return;
      }

      final encoded = Uri.encodeQueryComponent(query);
      final url =
          "${ApiConfig.baseUrl}/products?where[name][like]=$encoded&limit=50&depth=1";
      final res = await http.get(
        Uri.parse(url),
        headers: ApiConfig.getHeaders(token),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final docs = data["docs"] ?? [];
        if (mounted) {
          setState(() {
            _externalSearchResults = docs;
            _isSearchingExternal = false;
          });
        }
      } else {
        if (mounted) setState(() => _isSearchingExternal = false);
      }
    } catch (_) {
      if (mounted) setState(() => _isSearchingExternal = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<InstockProvider>(
      builder: (context, sp, child) {
        return CommonScaffold(
          title: "Return Order Categories",
          pageType: PageType.returnorder,
          body: sp.isLoading
              ? const Center(
                  child: CircularProgressIndicator(color: Colors.black),
                )
              : _buildGrid(sp),
        );
      },
    );
  }

  Widget _buildGrid(InstockProvider sp) {
    if (sp.categories.isEmpty) {
      return const Center(child: Text("No categories found."));
    }

    final query = _searchCtrl.text.trim();
    final isSearching = query.isNotEmpty;
    final matchingCategories = isSearching
        ? sp.categories.where((c) {
            final name = (c["name"] ?? "").toString().toLowerCase();
            return name.contains(query.toLowerCase());
          }).toList()
        : sp.categories;

    return Column(
      children: [
        // SEARCH BAR (GLOBAL PRODUCT & CATEGORY SEARCH)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.grey.withValues(alpha: 0.18),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: TextField(
              controller: _searchCtrl,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: "Search return products (e.g. egg, milk)...",
                hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                suffixIcon: isSearching
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: Colors.grey),
                        onPressed: () {
                          _searchCtrl.clear();
                          _debounceTimer?.cancel();
                          setState(() {
                            _externalSearchResults = [];
                            _isSearchingExternal = false;
                            _searchShowAsGrid = false;
                          });
                        },
                      )
                    : null,
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
              onChanged: _onSearchChanged,
            ),
          ),
        ),

        // WHEN SEARCHING: SHOW MATCHING CATEGORY CHIPS (IF ANY)
        if (isSearching && matchingCategories.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: matchingCategories.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final cat = matchingCategories[i];
                  return InkWell(
                    onTap: () {
                      _searchCtrl.clear();
                      setState(() {
                        _externalSearchResults = [];
                        _isSearchingExternal = false;
                      });
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ReturnOrderPage(
                            categoryId: cat['id'],
                            categoryName: cat['name'] ?? 'Unknown',
                          ),
                        ),
                      );
                    },
                    borderRadius: BorderRadius.circular(18),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0FDF4),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: const Color(0xFF0F766E).withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.category_outlined,
                            size: 14,
                            color: Color(0xFF0F766E),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            cat['name'] ?? '',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF0F766E),
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

        // HEADER ROW: PRODUCTS COUNT + VIEW TOGGLE (WHEN SEARCHING) OR CATEGORIES COUNT (WHEN NOT SEARCHING)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Text(
                isSearching
                    ? "MATCHING PRODUCTS (${_externalSearchResults.length})"
                    : "${sp.categories.length} CATEGORIES",
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey.shade600,
                  letterSpacing: 0.8,
                ),
              ),
              if (isSearching) ...[
                const Spacer(),
                InkWell(
                  onTap: () {
                    setState(() {
                      _searchShowAsGrid = !_searchShowAsGrid;
                    });
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F766E),
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0F766E).withValues(alpha: 0.2),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _searchShowAsGrid
                              ? Icons.grid_view_rounded
                              : Icons.view_list_rounded,
                          size: 16,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _searchShowAsGrid ? "Grid" : "List",
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),

        // BODY: PRODUCTS LISTING (WHEN SEARCHING) OR CATEGORIES GRID (WHEN NOT SEARCHING)
        Expanded(
          child: isSearching
              ? (!_searchShowAsGrid
                  ? _buildGoogleSearchList(context)
                  : _buildProductGrid(context))
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final crossAxisCount = constraints.maxWidth > 600 ? 5 : 3;
                    return GridView.builder(
                      padding: const EdgeInsets.all(10),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                        childAspectRatio: 0.85,
                      ),
                      itemCount: sp.categories.length,
                      itemBuilder: (context, index) {
                        final c = sp.categories[index];
                        String? imageUrl;
                        final img =
                            c['imageUrl'] ?? c['image'] ?? c['thumbnail'];
                        if (img is Map) {
                          imageUrl = img['url'];
                        } else if (img is String) {
                          imageUrl = img;
                        }
                        if (imageUrl != null && imageUrl.startsWith('/')) {
                          imageUrl = '${ApiConfig.domain}$imageUrl';
                        }
                        imageUrl ??=
                            'https://via.placeholder.com/150?text=No+Image';

                        return GestureDetector(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => ReturnOrderPage(
                                  categoryId: c['id'],
                                  categoryName: c['name'] ?? 'Unknown',
                                ),
                              ),
                            );
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: Colors.white,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.grey.withValues(alpha: 0.1),
                                  spreadRadius: 2,
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                Expanded(
                                  flex: 7,
                                  child: ClipRRect(
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(8),
                                    ),
                                    child: CachedNetworkImage(
                                      imageUrl: imageUrl,
                                      fit: BoxFit.cover,
                                      width: double.infinity,
                                      placeholder: (context, url) =>
                                          const Center(
                                        child: CircularProgressIndicator(),
                                      ),
                                      errorWidget: (context, url, error) =>
                                          const Center(
                                        child: Icon(
                                          Icons.category,
                                          color: Colors.grey,
                                          size: 40,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  flex: 3,
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    decoration: const BoxDecoration(
                                      color: Colors.black,
                                      borderRadius: BorderRadius.vertical(
                                        bottom: Radius.circular(8),
                                      ),
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      c['name'] ?? 'Unknown',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ========================== GOOGLE SEARCH SUGGESTIONS LIST ===========================
  Widget _buildGoogleSearchList(BuildContext context) {
    final query = _searchCtrl.text.trim();

    if (_externalSearchResults.isEmpty && !_isSearchingExternal) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 54,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 12),
            Text(
              'No return products found for "$query"',
              style: TextStyle(
                fontSize: 15,
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }

    final spinnerCount = _isSearchingExternal ? 1 : 0;
    final itemCount = _externalSearchResults.length + spinnerCount;

    return Consumer<ReturnProvider>(
      builder: (context, returnProvider, _) {
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          itemCount: itemCount,
          itemBuilder: (context, index) {
            if (index < _externalSearchResults.length) {
              final p = _externalSearchResults[index];
              return _buildSuggestionTile(context, returnProvider, p);
            }

            if (_isSearchingExternal && index >= _externalSearchResults.length) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.teal,
                    ),
                  ),
                ),
              );
            }

            return const SizedBox.shrink();
          },
        );
      },
    );
  }

  Widget _buildSuggestionTile(
    BuildContext context,
    ReturnProvider returnProvider,
    dynamic p,
  ) {
    final id = (p['id'] ?? p['_id'])?.toString() ?? '';
    final name = p['name']?.toString() ?? 'Unknown';
    final query = _searchCtrl.text.trim();

    final matching =
        returnProvider.returnItems.where((i) => i.id == id).toList();
    final isSelected = matching.isNotEmpty && matching.first.quantity > 0;
    final qtyNum = isSelected ? matching.first.quantity : 0.0;
    final qtyText = (qtyNum == qtyNum.floorToDouble())
        ? qtyNum.toInt().toString()
        : qtyNum.toStringAsFixed(2);

    final dynamic priceDetails = p['defaultPriceDetails'];
    final price = (priceDetails?['price'] as num?)?.toDouble() ?? 0.0;
    final rawUnit = priceDetails?['unit']?.toString() ?? '';
    final isKgFlag = p['isKg'] == true ||
        p['sellByWeight'] == true ||
        p['weightBased'] == true;
    final unit = rawUnit.isNotEmpty ? rawUnit : (isKgFlag ? 'kg' : 'pcs');

    String? categoryName;
    if (p['category'] is Map) {
      categoryName = p['category']['name']?.toString();
    }

    String? imageUrl;
    if (p['images'] != null &&
        p['images'].isNotEmpty &&
        p['images'][0]['image'] != null &&
        p['images'][0]['image']['url'] != null) {
      imageUrl = p['images'][0]['image']['url'];
      if (imageUrl != null && imageUrl.startsWith('/')) {
        imageUrl = '${ApiConfig.domain}$imageUrl';
      }
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFFF1F8E9) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isSelected ? Colors.green.shade400 : Colors.grey.shade200,
          width: isSelected ? 1.5 : 1,
        ),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        onTap: () async {
          await _promptReturnQuantity(context, returnProvider, p);
        },
        leading: Stack(
          alignment: Alignment.center,
          children: [
            if (imageUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CachedNetworkImage(
                  imageUrl: imageUrl,
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                    width: 40,
                    height: 40,
                    color: Colors.grey.shade100,
                    child:
                        const Icon(Icons.search, size: 20, color: Colors.grey),
                  ),
                  errorWidget: (_, __, ___) => Container(
                    width: 40,
                    height: 40,
                    color: Colors.grey.shade100,
                    child:
                        const Icon(Icons.search, size: 20, color: Colors.grey),
                  ),
                ),
              )
            else
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isSelected
                      ? Colors.green.shade100
                      : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  isSelected
                      ? Icons.check_circle_rounded
                      : Icons.search_rounded,
                  color:
                      isSelected ? Colors.green.shade700 : Colors.grey.shade600,
                  size: 20,
                ),
              ),
          ],
        ),
        title: _buildHighlightedText(name, query),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            children: [
              if (categoryName != null) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    categoryName,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                "₹${price.toStringAsFixed(0)}",
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade700,
                ),
              ),
            ],
          ),
        ),
        trailing: isSelected
            ? Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.green.shade700,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "$qtyText $unit",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.edit, color: Colors.white, size: 12),
                  ],
                ),
              )
            : Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(14),
                  color: Colors.grey.shade50,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 14, color: Colors.grey.shade700),
                    const SizedBox(width: 2),
                    Text(
                      "Add",
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade800,
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildHighlightedText(String text, String query) {
    if (query.isEmpty) {
      return Text(
        text,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final index = lowerText.indexOf(lowerQuery);

    if (index == -1) {
      return Text(
        text,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    final before = text.substring(0, index);
    final match = text.substring(index, index + query.length);
    final after = text.substring(index + query.length);

    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: const TextStyle(fontSize: 15, color: Colors.black87),
        children: [
          if (before.isNotEmpty)
            TextSpan(
              text: before,
              style: const TextStyle(fontWeight: FontWeight.normal),
            ),
          TextSpan(
            text: match,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.black,
              backgroundColor: Color(0x33FFD54F),
            ),
          ),
          if (after.isNotEmpty)
            TextSpan(
              text: after,
              style: const TextStyle(fontWeight: FontWeight.normal),
            ),
        ],
      ),
    );
  }

  // ========================== PRODUCT GRID ===========================
  Widget _buildProductGrid(BuildContext context) {
    final query = _searchCtrl.text.trim();

    if (_externalSearchResults.isEmpty) {
      if (_isSearchingExternal) {
        return const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child:
                CircularProgressIndicator(strokeWidth: 2, color: Colors.teal),
          ),
        );
      }
      return Center(
        child: Text(
          'No return products found for "$query"',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
        ),
      );
    }

    return Consumer<ReturnProvider>(
      builder: (context, returnProvider, _) {
        return LayoutBuilder(
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
              itemCount: _externalSearchResults.length,
              itemBuilder: (_, i) {
                final p = _externalSearchResults[i];
                final String id = (p["id"] ?? p["_id"])?.toString() ?? '';

                String? imageUrl;
                if (p['images'] != null &&
                    p['images'].isNotEmpty &&
                    p['images'][0]['image'] != null &&
                    p['images'][0]['image']['url'] != null) {
                  imageUrl = p['images'][0]['image']['url'];
                  if (imageUrl != null && imageUrl.startsWith('/')) {
                    imageUrl = '${ApiConfig.domain}$imageUrl';
                  }
                }
                imageUrl ??= 'https://via.placeholder.com/150?text=No+Image';

                final matching = returnProvider.returnItems
                    .where((item) => item.id == id)
                    .toList();
                final isSelected =
                    matching.isNotEmpty && matching.first.quantity > 0;
                final qtyNum = isSelected ? matching.first.quantity : 0.0;
                String qtyText;
                if (qtyNum == qtyNum.floorToDouble()) {
                  qtyText = qtyNum.toInt().toString();
                } else {
                  qtyText = qtyNum.toStringAsFixed(2);
                }

                final dynamic priceDetails = p['defaultPriceDetails'];
                final price =
                    (priceDetails?['price'] as num?)?.toDouble() ?? 0.0;

                return GestureDetector(
                  onTap: () =>
                      _promptReturnQuantity(context, returnProvider, p),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: isSelected
                          ? Border.all(color: Colors.green, width: 4)
                          : null,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.grey.withValues(alpha: 0.1),
                          spreadRadius: 2,
                          blurRadius: 4,
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
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(8),
                                ),
                                child: CachedNetworkImage(
                                  imageUrl: imageUrl,
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                  placeholder: (_, __) => const Center(
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  errorWidget: (_, __, ___) => const Center(
                                    child: Text(
                                      'No Image',
                                      style: TextStyle(color: Colors.grey),
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
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                child: Text(
                                  p['name'] ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 11,
                                  ),
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
                              "₹ $price",
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
                                  color: Colors.black.withValues(alpha: 0.7),
                                  border: Border.all(
                                    color: Colors.grey,
                                    width: 1,
                                  ),
                                  borderRadius: BorderRadius.circular(4),
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
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  // ========================== PROMPT RETURN QUANTITY ===========================
  Future<void> _promptReturnQuantity(
    BuildContext context,
    ReturnProvider returnProvider,
    dynamic product,
  ) async {
    final String id = (product["id"] ?? product["_id"])?.toString() ?? '';
    if (id.isEmpty) return;

    bool isWeightBased = false;
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
        isWeightBased = true;
      }
      if (isKgFlag) isWeightBased = true;
      if (pricingType != null && pricingType.contains('kg')) {
        isWeightBased = true;
      }
    } catch (_) {
      isWeightBased = false;
    }

    final matching =
        returnProvider.returnItems.where((i) => i.id == id).toList();
    final double existingQty =
        matching.isNotEmpty ? matching.first.quantity : 0.0;
    final rawUnit = product['defaultPriceDetails']?['unit']?.toString().trim();
    final unit = (rawUnit != null && rawUnit.isNotEmpty)
        ? rawUnit
        : (isWeightBased ? 'kg' : 'pcs');

    String initialText = '';
    if (existingQty > 0) {
      if (existingQty == existingQty.floorToDouble()) {
        initialText = existingQty.toInt().toString();
      } else {
        initialText = existingQty.toString();
      }
    }

    final TextEditingController qtyController =
        TextEditingController(text: initialText);
    qtyController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: initialText.length,
    );

    final enteredQty = await showDialog<double>(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return AlertDialog(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                product['name'] ?? 'Product',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                isWeightBased
                    ? 'Enter Return Weight ($unit)'
                    : 'Enter Return Quantity ($unit)',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.normal,
                  color: Colors.grey.shade700,
                ),
              ),
            ],
          ),
          content: TextField(
            controller: qtyController,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
            ),
            decoration: InputDecoration(
              hintText: isWeightBased ? 'e.g. 0.5' : 'e.g. 100',
              labelText:
                  isWeightBased ? 'Weight in $unit' : 'Quantity in $unit',
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (val) {
              final value = double.tryParse(val.trim()) ?? 0.0;
              Navigator.pop(context, value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final value =
                    double.tryParse(qtyController.text.trim()) ?? 0.0;
                Navigator.pop(context, value);
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );

    if (enteredQty == null || enteredQty < 0) return;

    final price =
        (product['defaultPriceDetails']?['price'] as num?)?.toDouble() ?? 0.0;
    if (enteredQty == 0) {
      returnProvider.removeItem(id);
    } else {
      if (matching.isNotEmpty) {
        returnProvider.updateQuantity(id, enteredQty);
      } else {
        returnProvider.addOrUpdateItem(
          id,
          product['name'] ?? 'Product',
          enteredQty,
          price,
        );
      }
    }

    if (_searchCtrl.text.isNotEmpty) {
      _searchCtrl.clear();
      _onSearchChanged('');
    }
    setState(() {});
  }
}
