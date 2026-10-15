import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/api_config.dart';
import 'package:blackforest_app/return_order_page.dart';
import 'package:blackforest_app/instock_provider.dart';

class ReturnCategoriesPage extends StatefulWidget {
  const ReturnCategoriesPage({super.key});

  @override
  State<ReturnCategoriesPage> createState() => _ReturnCategoriesPageState();
}

class _ReturnCategoriesPageState extends State<ReturnCategoriesPage> {
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<InstockProvider>(context, listen: false).syncBranchId();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<InstockProvider>(
      builder: (context, sp, child) {
        return CommonScaffold(
          title: "Return Order Categories",
          pageType: PageType.returnorder,
          body: sp.isLoading
              ? const Center(child: CircularProgressIndicator(color: Colors.black))
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
    final filteredCategories = isSearching
        ? sp.categories.where((c) {
            final name = (c["name"] ?? "").toString().toLowerCase();
            return name.contains(query.toLowerCase());
          }).toList()
        : sp.categories;

    return Column(
      children: [
        // SEARCH BAR (CATEGORY LIVE SEARCH)
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
                hintText: "Search categories...",
                hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                suffixIcon: isSearching
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: Colors.grey),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() {});
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
              onChanged: (_) => setState(() {}),
            ),
          ),
        ),

        // CATEGORY COUNT HEADER
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Text(
                isSearching
                    ? "MATCHING CATEGORIES (${filteredCategories.length})"
                    : "${sp.categories.length} CATEGORIES",
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey.shade600,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),

        // CATEGORY GRID
        Expanded(
          child: filteredCategories.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isSearching
                            ? Icons.search_off_rounded
                            : Icons.category_outlined,
                        size: 54,
                        color: Colors.grey.shade400,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        isSearching
                            ? 'No categories found for "$query"'
                            : 'No categories found',
                        style: TextStyle(
                          fontSize: 15,
                          color: Colors.grey.shade600,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                )
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
                      itemCount: filteredCategories.length,
                      itemBuilder: (context, index) {
                        final c = filteredCategories[index];
                        String? imageUrl;
                        final img = c['imageUrl'] ?? c['image'] ?? c['thumbnail'];
            if (img is Map) {
              imageUrl = img['url'];
            } else if (img is String) {
              imageUrl = img;
            }
            if (imageUrl != null && imageUrl.startsWith('/')) {
              imageUrl = '${ApiConfig.domain}$imageUrl';
            }
            imageUrl ??= 'https://via.placeholder.com/150?text=No+Image';

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
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                        child: CachedNetworkImage(
                          imageUrl: imageUrl!,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          placeholder: (context, url) => const Center(child: CircularProgressIndicator()),
                          errorWidget: (context, url, error) => const Center(
                            child: Icon(Icons.category, color: Colors.grey, size: 40),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: const BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.vertical(bottom: Radius.circular(8)),
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
}
