import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/api_config.dart';
import 'package:blackforest_app/api_server_prefs.dart';
import 'package:blackforest_app/qr_products_page.dart';

class QrUpdatePage extends StatefulWidget {
  const QrUpdatePage({super.key});

  @override
  State<QrUpdatePage> createState() => _QrUpdatePageState();
}

class _QrUpdatePageState extends State<QrUpdatePage> {
  List<dynamic> _categories = [];
  List<dynamic> _filteredCategories = [];
  bool _isLoading = true;
  String _errorMessage = '';
  String? _companyId;
  String? _companyName;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchBillingCategories();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<String?> _resolveCompanyId(SharedPreferences prefs, String? token) async {
    // 1. Check cached in prefs
    String? cached = prefs.getString('company_id')?.trim();
    if (cached == null || cached.isEmpty) {
      cached = prefs.getString('companyId')?.trim();
    }
    if (cached != null && cached.isNotEmpty) {
      _companyName = prefs.getString('company_name') ?? prefs.getString('companyName');
      return cached;
    }

    // 2. Resolve via active branch
    final branchId = prefs.getString('branchId') ?? prefs.getString('branch') ?? prefs.getString('userBranchId');
    if (branchId != null && branchId.isNotEmpty && token != null) {
      try {
        final bRes = await http.get(
          Uri.parse("${ApiConfig.baseUrl}/branches/$branchId?depth=1"),
          headers: ApiConfig.getHeaders(token),
        );
        if (bRes.statusCode == 200) {
          final bData = jsonDecode(bRes.body);
          final comp = bData["company"];
          final compId = comp is Map ? (comp["id"] ?? comp["_id"])?.toString() : comp?.toString();
          if (comp is Map && comp["name"] != null) {
            _companyName = comp["name"]?.toString();
            await prefs.setString('company_name', _companyName!);
          }
          if (compId != null && compId.isNotEmpty) {
            await prefs.setString('company_id', compId);
            return compId;
          }
        }
      } catch (_) {}
    }

    // 3. Fallback to /users/me
    if (token != null) {
      try {
        final uRes = await http.get(
          Uri.parse("${ApiConfig.baseUrl}/users/me?depth=2"),
          headers: ApiConfig.getHeaders(token),
        );
        if (uRes.statusCode == 200) {
          final uData = jsonDecode(uRes.body);
          final user = uData["user"] ?? uData;
          dynamic comp = user["company"];
          if (comp == null && user["branch"] != null && user["branch"] is Map) {
            comp = user["branch"]["company"];
          }
          if (comp == null && user["lastLoginBranch"] != null && user["lastLoginBranch"] is Map) {
            comp = user["lastLoginBranch"]["company"];
          }
          final compId = comp is Map ? (comp["id"] ?? comp["_id"])?.toString() : comp?.toString();
          if (comp is Map && comp["name"] != null) {
            _companyName = comp["name"]?.toString();
            await prefs.setString('company_name', _companyName!);
          }
          if (compId != null && compId.isNotEmpty) {
            await prefs.setString('company_id', compId);
            return compId;
          }
        }
      } catch (_) {}
    }
    return null;
  }

  bool _matchesCompany(dynamic item, String compId) {
    if (item is! Map) return false;
    final comp = item['company'];
    if (comp == null) return false;
    if (comp is List) {
      return comp.any((c) {
        final cId = c is Map ? (c['id'] ?? c['_id'])?.toString() : c?.toString();
        return cId == compId;
      });
    } else if (comp is Map) {
      final cId = (comp['id'] ?? comp['_id'])?.toString();
      return cId == compId;
    } else if (comp is String) {
      return comp == compId;
    }
    return false;
  }

  Future<void> _fetchBillingCategories() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');

      // Resolve active company
      _companyId = await _resolveCompanyId(prefs, token);

      String companyQuery = '';
      if (_companyId != null && _companyId!.isNotEmpty) {
        companyQuery = '&where[company][in]=$_companyId';
      }

      // 1. Try fetching billing categories with company filter
      http.Response response = await http.get(
        Uri.parse(
          "${ApiConfig.baseUrl}/categories?where[isBilling][equals]=true$companyQuery&limit=200&depth=1",
        ),
        headers: ApiConfig.getHeaders(token),
      );

      List<dynamic> docs = [];
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        docs = data["docs"] ?? [];
      }

      // 2. If empty and company filter was used, try without isBilling filter but keep company filter
      if (docs.isEmpty && _companyId != null && _companyId!.isNotEmpty) {
        response = await http.get(
          Uri.parse(
            "${ApiConfig.baseUrl}/categories?where[company][in]=$_companyId&limit=200&depth=1",
          ),
          headers: ApiConfig.getHeaders(token),
        );
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          docs = data["docs"] ?? [];
        }
      }

      // 3. Fallback: if server query with company filter returned empty, fetch all categories and filter client-side
      if (docs.isEmpty) {
        response = await http.get(
          Uri.parse(
            "${ApiConfig.baseUrl}/categories?limit=200&depth=1",
          ),
          headers: ApiConfig.getHeaders(token),
        );
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final allDocs = data["docs"] ?? [];
          if (_companyId != null && _companyId!.isNotEmpty) {
            docs = allDocs.where((cat) => _matchesCompany(cat, _companyId!)).toList();
          } else {
            docs = allDocs;
          }
        }
      } else if (_companyId != null && _companyId!.isNotEmpty) {
        // Enforce client-side company filtering
        docs = docs.where((cat) => _matchesCompany(cat, _companyId!)).toList();
      }

      if (mounted) {
        setState(() {
          _categories = docs;
          _filterCategories(_searchController.text);
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = "Network error. Please check your connection.";
          _isLoading = false;
        });
      }
    }
  }

  void _filterCategories(String query) {
    final q = query.trim().toLowerCase();
    setState(() {
      if (q.isEmpty) {
        _filteredCategories = List.from(_categories);
      } else {
        _filteredCategories = _categories.where((cat) {
          final name = (cat["name"] ?? "").toString().toLowerCase();
          return name.contains(q);
        }).toList();
      }
    });
  }

  String _getCategoryImage(dynamic category) {
    try {
      if (category is Map) {
        final img = category["image"];
        if (img is Map && img["url"] != null) {
          final url = img["url"].toString().trim();
          if (url.isNotEmpty) {
            return resolveApiAssetUrl(url);
          }
        }
        final directUrl = category["imageUrl"]?.toString().trim();
        if (directUrl != null && directUrl.isNotEmpty) {
          return resolveApiAssetUrl(directUrl);
        }
      }
    } catch (_) {}
    return "https://via.placeholder.com/200?text=No+Image";
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: "Product QR Update",
      pageType: PageType.billing,
      body: RefreshIndicator(
        onRefresh: _fetchBillingCategories,
        child: Column(
          children: [
            // Search Bar + Optional Company Indicator
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _searchController,
                    onChanged: _filterCategories,
                    decoration: InputDecoration(
                      hintText: "Search categories...",
                      prefixIcon: const Icon(Icons.search, color: Colors.grey),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, color: Colors.grey),
                              onPressed: () {
                                _searchController.clear();
                                _filterCategories('');
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: Colors.grey.shade100,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  if (_companyName != null && _companyName!.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(
                          Icons.apartment_rounded,
                          size: 14,
                          color: Color(0xFF7C3AED),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _companyName!,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            // Content
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: Color(0xFF7C3AED)),
                    )
                  : _errorMessage.isNotEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _errorMessage,
                                style: const TextStyle(color: Colors.red),
                              ),
                              const SizedBox(height: 12),
                              ElevatedButton(
                                onPressed: _fetchBillingCategories,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF7C3AED),
                                  foregroundColor: Colors.white,
                                ),
                                child: const Text("Retry"),
                              ),
                            ],
                          ),
                        )
                      : _filteredCategories.isEmpty
                          ? Center(
                              child: Text(
                                _searchController.text.isNotEmpty
                                    ? "No categories match your search"
                                    : "No categories found for this company",
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 16,
                                ),
                              ),
                            )
                          : LayoutBuilder(
                              builder: (context, constraints) {
                                final width = constraints.maxWidth;
                                final crossCount = width > 700
                                    ? 4
                                    : width > 480
                                        ? 3
                                        : 2;

                                return GridView.builder(
                                  padding: const EdgeInsets.all(12),
                                  gridDelegate:
                                      SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: crossCount,
                                    crossAxisSpacing: 12,
                                    mainAxisSpacing: 12,
                                    childAspectRatio: 0.82,
                                  ),
                                  itemCount: _filteredCategories.length,
                                  itemBuilder: (context, index) {
                                    final category =
                                        _filteredCategories[index];
                                    final imageUrl =
                                        _getCategoryImage(category);
                                    final name = category["name"] ?? "";

                                    return GestureDetector(
                                      onTap: () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => QrProductsPage(
                                              categoryId: category["id"],
                                              categoryName: name,
                                              companyId: _companyId,
                                            ),
                                          ),
                                        );
                                      },
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius:
                                              BorderRadius.circular(14),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black
                                                  .withValues(alpha: 0.08),
                                              spreadRadius: 1,
                                              blurRadius: 6,
                                              offset: const Offset(0, 3),
                                            ),
                                          ],
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            Expanded(
                                              child: ClipRRect(
                                                borderRadius:
                                                    const BorderRadius.vertical(
                                                  top: Radius.circular(14),
                                                ),
                                                child: CachedNetworkImage(
                                                  imageUrl: imageUrl,
                                                  fit: BoxFit.cover,
                                                  placeholder: (context, url) =>
                                                      const Center(
                                                    child: SizedBox(
                                                      width: 24,
                                                      height: 24,
                                                      child:
                                                          CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: Color(0xFF7C3AED),
                                                      ),
                                                    ),
                                                  ),
                                                  errorWidget: (context, url,
                                                          error) =>
                                                      Container(
                                                    color: Colors.grey.shade200,
                                                    child: const Icon(
                                                      Icons.image_not_supported_outlined,
                                                      color: Colors.grey,
                                                      size: 32,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 8,
                                                vertical: 10,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Colors.grey.shade900,
                                                borderRadius:
                                                    const BorderRadius.vertical(
                                                  bottom: Radius.circular(14),
                                                ),
                                              ),
                                              alignment: Alignment.center,
                                              child: Text(
                                                name,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 13,
                                                ),
                                                textAlign: TextAlign.center,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
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
        ),
      ),
    );
  }
}
