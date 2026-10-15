import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/stock_provider.dart';
import 'package:blackforest_app/api_config.dart';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StockOrderPage extends StatefulWidget {
  const StockOrderPage({super.key});

  @override
  State<StockOrderPage> createState() => _StockOrderPageState();
}

class _StockOrderPageState extends State<StockOrderPage> {
  bool _showAsGrid = true;
  bool _searchShowAsGrid = false;
  final FocusNode _searchFocusNode = FocusNode();
  List<dynamic> _externalSearchResults = [];
  bool _isSearchingExternal = false;
  Timer? _debounceTimer;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged(String val, StockProvider sp) {
    if (val.trim().isEmpty) {
      _searchShowAsGrid = false;
      _isSearchingExternal = false;
      _externalSearchResults = [];
      _debounceTimer?.cancel();
      setState(() {});
      return;
    }
    setState(() {
      _isSearchingExternal = true;
    });
    _debounceTimer?.cancel();
    final query = val.trim();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () async {
      await _searchExternalProducts(query, sp);
    });
  }

  Future<void> _searchExternalProducts(String query, StockProvider sp) async {
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

      if (res.statusCode == 200 &&
          mounted &&
          sp.searchCtrl.text.trim() == query) {
        final docs = jsonDecode(res.body)["docs"] ?? [];
        final localIds = sp.products.map((p) => p['id']?.toString()).toSet();
        final externals = docs.where((p) {
          final id = p['id']?.toString();
          return id != null && !localIds.contains(id);
        }).toList();

        setState(() {
          _externalSearchResults = externals;
          _isSearchingExternal = false;
        });
      } else {
        if (mounted) setState(() => _isSearchingExternal = false);
      }
    } catch (_) {
      if (mounted) setState(() => _isSearchingExternal = false);
    }
  }
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final sp = Provider.of<StockProvider>(context, listen: false);
      sp.syncBranchId();
      if (sp.categories.isEmpty) {
        sp.loadStockCategories();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<StockProvider>(
      builder: (context, sp, child) {
        return PopScope(
          canPop: sp.step != "products",
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && sp.step == "products") {
              sp.goBackToCategories();
            }
          },
          child: CommonScaffold(
            title: sp.step == "categories"
                ? "Stock Categories"
                : "Products in ${sp.selectedCategoryName}",
            pageType: PageType.stock,
            body: sp.isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.black),
                  )
                : sp.step == "categories"
                ? _buildCategories(context, sp)
                : _buildProducts(context, sp),
          ),
        );
      },
    );
  }

  // ========================== CATEGORY GRID ===========================
  // ========================== CATEGORY GRID & GLOBAL PRODUCT SEARCH ===========================
  Widget _buildCategories(BuildContext context, StockProvider sp) {
    if (sp.categories.isEmpty) {
      return const Center(child: Text("No categories found"));
    }

    final query = sp.searchCtrl.text.trim();
    final isSearching = query.isNotEmpty;
    final matchingCategories = isSearching
        ? sp.categories.where((c) {
            final name = (c["name"] ?? "").toString().toLowerCase();
            return name.contains(query.toLowerCase());
          }).toList()
        : sp.categories;

    return Column(
      children: [
        // SUPERADMIN BRANCH SELECTION
        if (sp.userRole == 'superadmin' && sp.availableBranches.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF0F0),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.pink.shade300),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  hint: const Text("Select Branch"),
                  value: sp.overrideBranchId,
                  items: sp.availableBranches.map<DropdownMenuItem<String>>((b) {
                    return DropdownMenuItem<String>(
                      value: b['id'] ?? b['_id'],
                      child: Text(
                        b['name'] ?? 'Unknown Branch',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    );
                  }).toList(),
                  onChanged: (val) {
                    sp.setOverrideBranch(val);
                  },
                ),
              ),
            ),
          ),

        // SEARCH BAR (SEARCH PRODUCTS & CATEGORIES ACROSS ALL STOCK)
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
              controller: sp.searchCtrl,
              focusNode: _searchFocusNode,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: "Search products (e.g. egg, milk)...",
                hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                suffixIcon: isSearching
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: Colors.grey),
                        onPressed: () {
                          sp.searchCtrl.clear();
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
              onChanged: (val) => _onSearchChanged(val, sp),
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
                    onTap: () async {
                      sp.searchCtrl.clear();
                      await sp.selectCategory(cat);
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
                    ? "MATCHING PRODUCTS (${sp.filteredProducts.length + _externalSearchResults.length})"
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
                // Single view toggle button (shows only one at a time: Grid by default, taps to toggle)
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

        // BODY: IF SEARCHING -> PRODUCTS LISTING! IF NOT SEARCHING -> CATEGORIES GRID!
        Expanded(
          child: isSearching
              ? (!_searchShowAsGrid
                  ? _buildGoogleSearchList(context, sp)
                  : _buildProductGrid(context, sp))
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final crossAxisCount = (width > 600) ? 5 : 3;
                    return GridView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: sp.categories.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        childAspectRatio: 0.75,
                      ),
                      itemBuilder: (_, i) {
                        final c = sp.categories[i];
                        String? img = c["image"]?["url"] ?? c["imageUrl"];
                        if (img != null && img.startsWith("/")) {
                          img = "${ApiConfig.domain}$img";
                        }
                        img ??= "https://via.placeholder.com/200?text=No+Image";

                        return GestureDetector(
                          onTap: () async {
                            await sp.selectCategory(c);
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.grey.withValues(alpha: 0.15),
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(10),
                                    ),
                                    child: CachedNetworkImage(
                                      imageUrl: img,
                                      width: double.infinity,
                                      fit: BoxFit.cover,
                                      placeholder: (_, __) => const Center(
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                      errorWidget: (_, __, ___) => const Center(
                                        child: Icon(
                                          Icons.image_not_supported,
                                          color: Colors.grey,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(8),
                                  alignment: Alignment.center,
                                  decoration: const BoxDecoration(
                                    color: Colors.black,
                                    borderRadius: BorderRadius.vertical(
                                      bottom: Radius.circular(10),
                                    ),
                                  ),
                                  child: Text(
                                    c["name"] ?? "",
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
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

  // ========================== PRODUCT LIST ===========================
  Widget _buildProducts(BuildContext context, StockProvider sp) {
    final query = sp.searchCtrl.text.trim();
    final isSearching = query.isNotEmpty;

    return Column(
      children: [
        // SUPERADMIN BRANCH SELECTION
        if (sp.userRole == 'superadmin' && sp.availableBranches.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF0F0),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.pink.shade300),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  hint: const Text("Select Branch"),
                  value: sp.overrideBranchId,
                  items: sp.availableBranches.map<DropdownMenuItem<String>>((b) {
                    return DropdownMenuItem<String>(
                      value: b['id'] ?? b['_id'],
                      child: Text(
                        b['name'] ?? 'Unknown Branch',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    );
                  }).toList(),
                  onChanged: (val) {
                    sp.setOverrideBranch(val);
                  },
                ),
              ),
            ),
          ),

        // SEARCH BAR (GOOGLE STYLE LIVE SEARCH)
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
              controller: sp.searchCtrl,
              focusNode: _searchFocusNode,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: "Search products (e.g. egg, milk)...",
                hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                suffixIcon: isSearching
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: Colors.grey),
                        onPressed: () {
                          sp.searchCtrl.clear();
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
              onChanged: (val) => _onSearchChanged(val, sp),
            ),
          ),
        ),

        // FIXED POSITION VIEW TOGGLE & PRODUCT COUNT (ALWAYS VISIBLE)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Text(
                isSearching
                    ? "MATCHING PRODUCTS (${sp.filteredProducts.length + _externalSearchResults.length})"
                    : "${sp.filteredProducts.length} PRODUCTS",
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey.shade600,
                  letterSpacing: 0.8,
                ),
              ),
              const Spacer(),
              // Single view toggle button (shows only one at a time: Grid by default, taps to toggle)
              InkWell(
                onTap: () {
                  setState(() {
                    if (isSearching) {
                      _searchShowAsGrid = !_searchShowAsGrid;
                    } else {
                      _showAsGrid = !_showAsGrid;
                    }
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
                        (isSearching ? _searchShowAsGrid : _showAsGrid)
                            ? Icons.grid_view_rounded
                            : Icons.view_list_rounded,
                        size: 16,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        (isSearching ? _searchShowAsGrid : _showAsGrid)
                            ? "Grid"
                            : "List",
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
          ),
        ),

        // BODY: Either Google-style List View or Grid View
        Expanded(
          child: !(isSearching ? _searchShowAsGrid : _showAsGrid)
              ? _buildGoogleSearchList(context, sp)
              : _buildProductGrid(context, sp),
        ),
      ],
    );
  }

  // ========================== GOOGLE SEARCH SUGGESTIONS LIST ===========================
  Widget _buildGoogleSearchList(BuildContext context, StockProvider sp) {
    final localMatches = sp.filteredProducts;
    final totalCount = localMatches.length + _externalSearchResults.length;
    final query = sp.searchCtrl.text.trim();
    final isSearching = query.isNotEmpty;

    if (totalCount == 0 && !_isSearchingExternal) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isSearching
                  ? Icons.search_off_rounded
                  : Icons.inventory_2_outlined,
              size: 54,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 12),
            Text(
              isSearching
                  ? 'No products found for "$query"'
                  : 'No products in this category',
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

    final hasLocal = localMatches.isNotEmpty;
    final hasExternal = _externalSearchResults.isNotEmpty;
    final spinnerCount = _isSearchingExternal ? 1 : 0;
    final itemCount = localMatches.length +
        (hasExternal ? _externalSearchResults.length + (hasLocal ? 1 : 0) : 0) +
        spinnerCount;

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index < localMatches.length) {
          final p = localMatches[index];
          return _buildSuggestionTile(context, sp, p, isExternal: false);
        }

        int offset = localMatches.length;

        if (hasExternal) {
          if (hasLocal && index == offset) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
              child: Row(
                children: [
                  Icon(Icons.category_outlined,
                      size: 14, color: Colors.grey.shade600),
                  const SizedBox(width: 6),
                  Text(
                    "OTHER CATEGORIES",
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade600,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
            );
          }

          final extIndex = hasLocal ? (index - offset - 1) : (index - offset);
          if (extIndex >= 0 && extIndex < _externalSearchResults.length) {
            final p = _externalSearchResults[extIndex];
            return _buildSuggestionTile(context, sp, p, isExternal: true);
          }
          offset += _externalSearchResults.length + (hasLocal ? 1 : 0);
        }

        if (_isSearchingExternal && index >= offset) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.teal),
              ),
            ),
          );
        }

        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildSuggestionTile(
    BuildContext context,
    StockProvider sp,
    dynamic p, {
    bool isExternal = false,
  }) {
    final id = (p['id'] ?? p['_id'])?.toString() ?? '';
    final name = p['name']?.toString() ?? 'Unknown';
    final query = sp.searchCtrl.text.trim();

    final qtyNum = sp.quantities[id] ?? 0.0;
    final isSelected = sp.selected[id] == true && qtyNum > 0;
    final qtyText = (qtyNum == qtyNum.floorToDouble())
        ? qtyNum.toInt().toString()
        : qtyNum.toStringAsFixed(2);

    final dynamic priceDetails = p['defaultPriceDetails'];
    final price = sp.prices[id] ??
        (priceDetails?['price'] as num?)?.toDouble() ??
        0.0;
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
          if (isExternal) {
            sp.registerProduct(p);
          }
          await _promptProductQuantity(context, sp, p);
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
                Text(
                  categoryName,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.teal.shade700,
                  ),
                ),
                Text(
                  " • ",
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
                ),
              ],
              Text(
                "₹ ${price % 1 == 0 ? price.toInt() : price.toStringAsFixed(2)} / $unit",
                style: TextStyle(
                  fontSize: 12,
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
        style: const TextStyle(
          fontSize: 15,
          color: Colors.black87,
        ),
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
  Widget _buildProductGrid(BuildContext context, StockProvider sp) {
    final query = sp.searchCtrl.text.trim();
    final isSearching = query.isNotEmpty;

    final seenIds = <String>{};
    final List<dynamic> combinedProducts = [];
    for (var p in sp.filteredProducts) {
      final id = (p["id"] ?? p["_id"])?.toString() ?? '';
      if (id.isNotEmpty && seenIds.add(id)) {
        combinedProducts.add(p);
      }
    }
    if (isSearching) {
      for (var p in _externalSearchResults) {
        final id = (p["id"] ?? p["_id"])?.toString() ?? '';
        if (id.isNotEmpty && seenIds.add(id)) {
          combinedProducts.add(p);
        }
      }
    }

    if (combinedProducts.isEmpty) {
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
          isSearching ? 'No products found for "$query"' : "No products found",
          style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
        ),
      );
    }

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
          itemCount: combinedProducts.length,
          itemBuilder: (_, i) {
            final p = combinedProducts[i];
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

            final isSelected = sp.selected[id] == true;
            final qtyNum = sp.quantities[id] ?? 0.0;
            String qtyText;
            if (qtyNum == qtyNum.floorToDouble()) {
              qtyText = qtyNum.toInt().toString();
            } else {
              qtyText = qtyNum.toStringAsFixed(2);
            }

            return GestureDetector(
              onTap: () => _promptProductQuantity(context, sp, p),
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
                              p["name"] ?? 'Unknown',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
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
                          "₹ ${sp.prices[id] ?? 0}",
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
              ),
            );
          },
        );
      },
    );
  }

  // ========================== PROMPT PRODUCT QUANTITY ===========================
  Future<void> _promptProductQuantity(
    BuildContext context,
    StockProvider sp,
    dynamic p,
  ) async {
    final String id = (p["id"] ?? p["_id"])?.toString() ?? '';
    if (id.isEmpty) return;
    sp.registerProduct(p);

    bool isWeightBased = false;
    try {
      final unit =
          p['defaultPriceDetails']?['unit']?.toString().toLowerCase();
      final isKgFlag = p['isKg'] == true ||
          p['sellByWeight'] == true ||
          p['weightBased'] == true;
      final pricingType = p['pricingType']?.toString().toLowerCase();

      if (unit != null &&
          (unit.contains('kg') || unit.contains('gram'))) {
        isWeightBased = true;
      }
      if (isKgFlag) isWeightBased = true;
      if (pricingType != null && pricingType.contains('kg')) {
        isWeightBased = true;
      }
    } catch (_) {
      isWeightBased = false;
    }

    final currentQty = sp.quantities[id] ?? 0.0;
    final rawUnit = p['defaultPriceDetails']?['unit']?.toString().trim();
    final unit = (rawUnit != null && rawUnit.isNotEmpty)
        ? rawUnit
        : (isWeightBased ? 'kg' : 'pcs');

    String initialText = '';
    if (currentQty > 0) {
      if (currentQty == currentQty.floorToDouble()) {
        initialText = currentQty.toInt().toString();
      } else {
        initialText = currentQty.toString();
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
                p['name'] ?? 'Product',
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
                    ? 'Enter Weight ($unit)'
                    : 'Enter Quantity ($unit)',
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
              labelText: isWeightBased ? 'Weight in $unit' : 'Quantity in $unit',
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
                final value = double.tryParse(
                      qtyController.text.trim(),
                    ) ??
                    0.0;
                Navigator.pop(context, value);
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );

    if (enteredQty == null || enteredQty < 0) {
      return;
    }
    sp.updateQuantity(id, enteredQty);
  }
}
