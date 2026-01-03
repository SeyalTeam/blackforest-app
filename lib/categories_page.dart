import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/products_page.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:blackforest_app/cart_provider.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:blackforest_app/api_config.dart';

class CategoriesPage extends StatefulWidget {
  const CategoriesPage({
    super.key,
  });

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
        Uri.parse('${ApiConfig.baseUrl}/users/me?depth=2'),
        headers: ApiConfig.getHeaders(token),
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

  Future<String?> _fetchDeviceIp() async {
    try {
      final info = NetworkInfo();
      final ip = await info.getWifiIP();
      return ip?.trim();
    } catch (e) {
      return null;
    }
  }

  int _ipToInt(String ip) {
    final parts = ip.split('.').map(int.parse).toList();
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
  }

  bool _isIpInRange(String deviceIp, String range) {
    final parts = range.split('-');
    if (parts.length != 2) return false;
    final startIp = _ipToInt(parts[0].trim());
    final endIp = _ipToInt(parts[1].trim());
    final device = _ipToInt(deviceIp);
    return device >= startIp && device <= endIp;
  }

  Future<List<String>> _fetchMatchingCompanyIds(String token, String? deviceIp) async {
    List<String> companyIds = [];
    if (deviceIp == null) return companyIds;
    try {
      final allBranchesResponse = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/branches?depth=1'),
        headers: ApiConfig.getHeaders(token),
      );
      if (allBranchesResponse.statusCode == 200) {
        final branchesData = jsonDecode(allBranchesResponse.body);
        if (branchesData['docs'] != null && branchesData['docs'] is List) {
          Set<String> uniqueCompanyIds = {};
          for (var branch in branchesData['docs']) {
            String? bIpRange = branch['ipAddress']?.toString().trim();
            if (bIpRange != null && _isIpInRange(deviceIp, bIpRange)) {
              var company = branch['company'];
              String? companyId = company is Map ? company['id'] : company?.toString();
              if (companyId != null) {
                uniqueCompanyIds.add(companyId);
              }
            }
          }
          companyIds = uniqueCompanyIds.toList();
        }
      }
    } catch (e) {
      // Handle silently
    }
    return companyIds;
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
      if (_userRole == null) {
        await _fetchUserData(token);
      }
      String filterQuery = 'where[isBilling][equals]=true';
      // Role-based company filter
      if (_userRole != 'superadmin') {
        String? companyFilter;
        if (_userRole == 'waiter') {
          String? deviceIp = await _fetchDeviceIp();
          if (deviceIp != null) {
            List<String> matchingCompanyIds = await _fetchMatchingCompanyIds(token, deviceIp);
            if (matchingCompanyIds.isNotEmpty) {
              companyFilter = '&where[company][in]=${matchingCompanyIds.join(',')}';
            } else {
              setState(() {
                _errorMessage = 'No matching branches for your device IP.';
                _isLoading = false;
              });
              return;
            }
          } else {
            setState(() {
              _errorMessage = 'Unable to fetch device IP.';
              _isLoading = false;
            });
            return;
          }
        } else if (_companyId != null) {
          companyFilter = '&where[company][contains]=$_companyId';
        }
        if (companyFilter != null) {
          filterQuery += companyFilter;
        }
      }
      final response = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/categories?$filterQuery&limit=100&depth=1'),
        headers: ApiConfig.getHeaders(token),
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

  Future<void> _handleScan(String scanResult) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No token found. Please login again.')),
        );
        return;
      }
      // Fetch product by UPC globally
      final response = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/products?where[upc][equals]=$scanResult&limit=1&depth=1'),
        headers: ApiConfig.getHeaders(token),
      );
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final List<dynamic> products = data['docs'] ?? [];
        if (products.isNotEmpty) {
          final product = products[0];
          final cartProvider = Provider.of<CartProvider>(context, listen: false);
          // Get branch-specific price if available (similar to ProductsPage)
          double price = product['defaultPriceDetails']?['price']?.toDouble() ?? 0.0;
          String? _branchId; // Fetch branchId if needed, assume from user data
          if (_userRole == 'branch') {
            // Reuse _fetchUserData logic or store globally
            if (_branchId != null && product['branchOverrides'] != null) {
              for (var override in product['branchOverrides']) {
                var branch = override['branch'];
                String branchOid = branch is Map ? branch[r'$oid'] ?? branch['id'] ?? '' : branch ?? '';
                if (branchOid == _branchId) {
                  price = override['price']?.toDouble() ?? price;
                  break;
                }
              }
            }
          }
          final item = CartItem.fromProduct(product, 1, branchPrice: price);
          cartProvider.addOrUpdateItem(item);
          final newQty = cartProvider.cartItems.firstWhere((i) => i.id == item.id).quantity;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${product['name']} added/updated (Qty: $newQty)')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Product not found')),
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to fetch product: ${response.statusCode}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error: Check your internet')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    String title = 'Billing Categories';
    PageType pageType = PageType.billing;

    return CommonScaffold(
      title: title,
      pageType: pageType,
      onScanCallback: _handleScan, // Add this for global scan from categories
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
                    imageUrl = '${ApiConfig.baseUrl.replaceAll('/api', '')}$imageUrl';
                  }
                }
                imageUrl ??= 'https://via.placeholder.com/150?text=No+Image'; // Fallback
                return GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => ProductsPage(
                        categoryId: category['id'],
                        categoryName: category['name'],
                      )),
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
                              imageUrl: imageUrl!,
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