import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/products_page.dart';
import 'package:blackforest_app/pastry_products_page.dart';
import 'package:cached_network_image/cached_network_image.dart';

class CategoriesPage extends StatefulWidget {
  final bool isPastryFilter; // Toggle between biling and pastry categories

  const CategoriesPage({super.key, this.isPastryFilter = false});

  @override
  _CategoriesPageState createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  List<dynamic> _categories = [];
  bool _isLoading = true;
  String _errorMessage = '';
  String? _companyId;
  String? _userRole;

  @override
  void initState() {
    super.initState();
    _fetchCategories();
  }

  Future<void> _fetchUserData(String token) async {
    try {
      final response = await http.get(
        Uri.parse('https://admin.theblackforestcakes.com/api/users/me?depth=2'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final user = data['user'] ?? data; // Depending on response structure
        setState(() {
          _userRole = user['role'];
          if (user['role'] == 'company' && user['company'] != null) {
            _companyId = (user['company'] is Map) ? user['company']['id'] : user['company'];
          } else if (user['role'] == 'branch' && user['branch'] != null && user['branch']['company'] != null) {
            _companyId = (user['branch']['company'] is Map) ? user['branch']['company']['id'] : user['branch']['company'];
          }
          // For superadmin, _companyId remains null
        });
      } else {
        // Handle error silently or log
      }
    } catch (e) {
      // Handle error silently
    }
  }

  Future<void> _fetchCategories() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) {
        setState(() {
          _errorMessage = 'No token found. Please login again.';
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No token found. Please login again.')),
        );
        return;
      }

      // Fetch user data if not already fetched
      if (_companyId == null && _userRole == null) {
        await _fetchUserData(token);
      }

      String filterQuery = widget.isPastryFilter
          ? 'where[isStock][equals]=true'
          : 'where[isBilling][equals]=true';

      // Add company filter if not superadmin and _companyId is available
      if (_userRole != 'superadmin' && _companyId != null) {
        filterQuery += '&where[company][contains]=$_companyId';
      }

      final response = await http.get(
        Uri.parse('https://admin.theblackforestcakes.com/api/categories?$filterQuery&limit=100&depth=1'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        setState(() {
          _categories = data['docs'] ?? [];
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = 'Failed to fetch categories: ${response.statusCode}';
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to fetch categories: ${response.statusCode}')),
        );
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Network error: Check your internet';
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error: Check your internet')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final String title = widget.isPastryFilter ? 'Pastry Categories' : 'Billing Categories';

    return CommonScaffold(
      title: title,
      pageType: widget.isPastryFilter ? PageType.pastry : PageType.home,
      body: RefreshIndicator(
        onRefresh: _fetchCategories,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator(color: Colors.black))
            : _errorMessage.isNotEmpty
            ? Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _errorMessage,
                style: const TextStyle(color: Color(0xFF4A4A4A), fontSize: 18),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: _fetchCategories,
                child: const Text('Retry'),
              ),
            ],
          ),
        )
            : _categories.isEmpty
            ? const Center(
          child: Text(
            'No categories found',
            style: TextStyle(color: Color(0xFF4A4A4A), fontSize: 18),
          ),
        )
            : LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final crossAxisCount = (width > 600) ? 5 : 3; // 3 on phones, 5 on desktop/web/tablets
            return GridView.builder(
              padding: const EdgeInsets.all(10),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 0.75, // Rectangular
              ),
              itemCount: _categories.length,
              itemBuilder: (context, index) {
                final category = _categories[index];
                String? imageUrl;
                if (category['image'] != null && category['image']['url'] != null) {
                  imageUrl = category['image']['url'];
                  if (imageUrl?.startsWith('/') ?? false) {
                    imageUrl = 'https://admin.theblackforestcakes.com$imageUrl';
                  }
                }
                imageUrl ??= 'https://via.placeholder.com/150?text=No+Image'; // Fallback

                return GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => widget.isPastryFilter
                            ? PastryProductsPage(
                          categoryId: category['id'],
                          categoryName: category['name'],
                        )
                            : ProductsPage(
                          categoryId: category['id'],
                          categoryName: category['name'],
                        ),
                      ),
                    );
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.grey.withOpacity(0.1),
                          spreadRadius: 2,
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Expanded(
                          flex: 8, // 80% image
                          child: ClipRRect(
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                            child: CachedNetworkImage(
                              imageUrl: imageUrl,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              placeholder: (context, url) => const Center(child: CircularProgressIndicator()),
                              errorWidget: (context, url, error) => const Center(child: Text('No Image', style: TextStyle(color: Colors.grey))),
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2, // 20% name
                          child: Container(
                            width: double.infinity,
                            decoration: const BoxDecoration(
                              color: Colors.black,
                              borderRadius: BorderRadius.vertical(bottom: Radius.circular(8)),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              category['name'] ?? 'Unknown',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              textAlign: TextAlign.center,
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
    );
  }
}