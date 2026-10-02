import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/instock_provider.dart';
import 'package:blackforest_app/instock_products_page.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:blackforest_app/api_config.dart';

class InstockCategoriesPage extends StatefulWidget {
  const InstockCategoriesPage({super.key});

  @override
  State<InstockCategoriesPage> createState() => _InstockCategoriesPageState();
}

class _InstockCategoriesPageState extends State<InstockCategoriesPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<InstockProvider>(context, listen: false).syncBranchId();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<InstockProvider>(
      builder: (context, sp, child) {
        return CommonScaffold(
          title: "Instock Categories",
          pageType: PageType.instock,
          body: sp.isLoading
              ? const Center(child: CircularProgressIndicator(color: Colors.black))
              : _buildGrid(sp),
        );
      },
    );
  }

  Widget _buildGrid(InstockProvider sp) {
    final cats = sp.categories;
    if (cats.isEmpty) {
      return const Center(child: Text("No categories found."));
    }
    return LayoutBuilder(
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
          itemCount: cats.length,
          itemBuilder: (context, index) {
            final c = cats[index];
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
                sp.selectCategory(c);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const InstockProductsPage()),
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
    );
  }
}
