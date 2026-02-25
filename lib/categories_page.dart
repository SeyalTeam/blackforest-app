import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/products_page.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:blackforest_app/cart_provider.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:geolocator/geolocator.dart';

class _CategoriesCacheEntry {
  final List<dynamic> categories;
  final DateTime fetchedAt;

  const _CategoriesCacheEntry({
    required this.categories,
    required this.fetchedAt,
  });
}

class CategoriesPage extends StatefulWidget {
  final PageType sourcePage;

  const CategoriesPage({super.key, this.sourcePage = PageType.billing});

  @override
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  static const Duration _categoriesCacheTtl = Duration(seconds: 90);
  static final Map<String, _CategoriesCacheEntry> _categoriesCache = {};

  List<dynamic> _categories = [];
  bool _isLoading = true;
  String _errorMessage = '';
  String? _companyId;
  String? _userRole;
  String? _currentUserId;
  List<String> _favoriteCategoryIds = <String>[];

  String _categoriesCacheKey(String filterQuery) =>
      '${_favoritesScope()}|$filterQuery';

  List<dynamic>? _readCategoriesCache(String filterQuery) {
    final key = _categoriesCacheKey(filterQuery);
    final entry = _categoriesCache[key];
    if (entry == null) return null;
    final expired =
        DateTime.now().difference(entry.fetchedAt) > _categoriesCacheTtl;
    if (expired) {
      _categoriesCache.remove(key);
      return null;
    }
    return List<dynamic>.from(entry.categories);
  }

  void _writeCategoriesCache(String filterQuery, List<dynamic> categories) {
    final key = _categoriesCacheKey(filterQuery);
    _categoriesCache[key] = _CategoriesCacheEntry(
      categories: List<dynamic>.from(categories),
      fetchedAt: DateTime.now(),
    );
  }

  @override
  void initState() {
    super.initState();
    _fetchCategories();
  }

  String _favoritesScope() {
    if (widget.sourcePage == PageType.table) {
      return 'table';
    }
    return 'billing';
  }

  String _favoriteCategoriesKey(String userId) =>
      'favorite_category_ids_${_favoritesScope()}_$userId';

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
    final normalizedFavorites = <String>[];
    for (final id in stored) {
      final cleanedId = id.trim();
      if (cleanedId.isEmpty || normalizedFavorites.contains(cleanedId)) {
        continue;
      }
      normalizedFavorites.add(cleanedId);
    }

    if (normalizedFavorites.length != stored.length) {
      await prefs.setStringList(
        _favoriteCategoriesKey(userId),
        normalizedFavorites,
      );
    }

    if (!mounted) return;
    setState(() {
      _currentUserId = userId;
      _favoriteCategoryIds = normalizedFavorites;
    });
  }

  List<dynamic> _orderedCategories() {
    if (_categories.isEmpty || _favoriteCategoryIds.isEmpty) {
      return _categories;
    }

    final Map<String, dynamic> categoriesById = {};
    final List<dynamic> nonFavoriteCategories = [];

    for (final category in _categories) {
      final categoryId = category['id']?.toString() ?? '';
      if (categoryId.isNotEmpty) {
        categoriesById[categoryId] = category;
      }
      if (!_favoriteCategoryIds.contains(categoryId)) {
        nonFavoriteCategories.add(category);
      }
    }

    final List<dynamic> favoriteCategories = [];
    for (final favoriteId in _favoriteCategoryIds) {
      final category = categoriesById[favoriteId];
      if (category != null) {
        favoriteCategories.add(category);
      }
    }

    return <dynamic>[...favoriteCategories, ...nonFavoriteCategories];
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
    if (categoryId.isEmpty) return;

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

    if (_favoriteCategoryIds.contains(categoryId)) {
      setState(() {
        _favoriteCategoryIds.remove(categoryId);
      });
      await _saveFavoriteCategories();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$categoryName removed from favorites')),
      );
      return;
    }

    setState(() {
      _favoriteCategoryIds.add(categoryId);
    });
    await _saveFavoriteCategories();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$categoryName added to favorites')));
  }

  Future<void> _fetchUserData(String token) async {
    try {
      final response = await http.get(
        Uri.parse('https://blackforest.vseyal.com/api/users/me?depth=2'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final user = data['user'] ?? data; // Depending on response structure
        final prefs = await SharedPreferences.getInstance();
        final userId =
            user['id']?.toString() ??
            user['_id']?.toString() ??
            user['\$oid']?.toString();

        if (userId != null && userId.isNotEmpty) {
          await prefs.setString('user_id', userId);
        }

        final role = user['role']?.toString();
        if (role != null && role.isNotEmpty) {
          await prefs.setString('role', role);
        }

        // Extract Branch ID if present in user profile
        dynamic branchRef = user['branch'];
        String? bId;
        if (branchRef is Map) {
          bId = (branchRef['id'] ?? branchRef['_id'] ?? branchRef['\$oid'])
              ?.toString();
        } else {
          bId = branchRef?.toString();
        }
        if (bId != null && bId.isNotEmpty) {
          await prefs.setString('branchId', bId);
        }

        String? detectedCompanyId;
        if (user['role'] == 'company' && user['company'] != null) {
          final comp = user['company'];
          detectedCompanyId = comp is Map
              ? (comp['id'] ?? comp['_id'] ?? comp[r'$oid'])?.toString()
              : comp.toString();
        } else if (user['role'] == 'branch' &&
            user['branch'] != null &&
            user['branch']['company'] != null) {
          final comp = user['branch']['company'];
          detectedCompanyId = comp is Map
              ? (comp['id'] ?? comp['_id'] ?? comp[r'$oid'])?.toString()
              : comp.toString();
        }
        if (detectedCompanyId != null && detectedCompanyId.isNotEmpty) {
          await prefs.setString('company_id', detectedCompanyId);
        }

        if (!mounted) return;

        setState(() {
          _userRole = role;
          _currentUserId = userId;
          _companyId = detectedCompanyId;
        });
        debugPrint(
          "User Role: $_userRole, Company ID: $_companyId, Branch ID: ${prefs.getString('branchId')}",
        );
        await _loadFavoriteCategories(preferredUserId: userId);
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

  Future<bool> _checkLocationPermission() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return false;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return false;
    }

    return true;
  }

  Future<String?> _fetchCompanyIdFromBranch(
    String token,
    String branchId,
  ) async {
    try {
      final response = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/branches/$branchId?depth=1',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode != 200) return null;
      final branch = jsonDecode(response.body);
      final company = branch['company'];
      if (company is Map) {
        return (company['id'] ?? company['_id'] ?? company['\$oid'])
            ?.toString();
      }
      return company?.toString();
    } catch (e) {
      return null;
    }
  }

  Future<List<String>> _fetchMatchingCompanyIds(
    String token,
    String? deviceIp, {
    String? branchId,
  }) async {
    debugPrint(
      "Fetching matching company IDs. Device IP: $deviceIp, Branch ID: $branchId",
    );
    List<String> companyIds = [];
    try {
      Set<String> uniqueCompanyIds = {};

      // Fast path: when branch is known we can derive company directly.
      if (branchId != null && branchId.isNotEmpty) {
        final directCompanyId = await _fetchCompanyIdFromBranch(
          token,
          branchId,
        );
        if (directCompanyId != null && directCompanyId.isNotEmpty) {
          return [directCompanyId];
        }
      }

      // 1. Fetch Current GPS Position once for matching
      Position? currentPos;
      if (await _checkLocationPermission()) {
        try {
          currentPos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
            ),
          );
          debugPrint(
            "Categories Matching: Current Location: ${currentPos.latitude}, ${currentPos.longitude}",
          );
        } catch (e) {
          debugPrint("Categories Matching: GPS fetch failed: $e");
        }
      } else {
        debugPrint("Categories Matching: GPS permission denied.");
      }

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
              final locBranch = loc['branch'];
              String? locBranchId;
              if (locBranch is Map) {
                locBranchId =
                    locBranch['id']?.toString() ??
                    locBranch['_id']?.toString() ??
                    locBranch['\$oid']?.toString();
              } else {
                locBranchId = locBranch?.toString();
              }

              bool isMatch = false;
              // Match by stored branchId
              if (branchId != null && locBranchId == branchId) {
                isMatch = true;
                debugPrint(
                  "Categories Matching: [S1] ID Match for $locBranchId",
                );
              }
              // Match by IP
              else if (deviceIp != null) {
                String? bIpRange = loc['ipAddress']?.toString().trim();
                if (bIpRange != null &&
                    bIpRange.isNotEmpty &&
                    (bIpRange == deviceIp ||
                        _isIpInRange(deviceIp, bIpRange))) {
                  isMatch = true;
                  debugPrint(
                    "Categories Matching: [S1] IP Match for $locBranchId",
                  );
                }
              }
              // Match by GPS
              if (!isMatch && currentPos != null) {
                final double? lat = loc['latitude'] != null
                    ? (loc['latitude'] as num).toDouble()
                    : null;
                final double? lng = loc['longitude'] != null
                    ? (loc['longitude'] as num).toDouble()
                    : null;
                final int radius = loc['radius'] != null
                    ? (loc['radius'] as num).toInt()
                    : 100;

                if (lat != null && lng != null) {
                  final dist = Geolocator.distanceBetween(
                    currentPos.latitude,
                    currentPos.longitude,
                    lat,
                    lng,
                  );
                  if (dist <= radius) {
                    isMatch = true;
                    debugPrint(
                      "Categories Matching: [S1] GPS Match for $locBranchId (Dist: ${dist.toStringAsFixed(1)}m)",
                    );
                  } else {
                    // Log even if no match to debug distance issues
                    if (locBranchId == branchId) {
                      debugPrint(
                        "Categories Matching: [S1] GPS Out-of-Range for $locBranchId. Dist: ${dist.toStringAsFixed(1)}m, Required: ${radius}m",
                      );
                    }
                  }
                }
              }

              if (isMatch) {
                final company = (locBranch is Map)
                    ? locBranch['company']
                    : loc['company'];
                String? cId;
                if (company is Map) {
                  cId = (company['id'] ?? company['_id'] ?? company['\$oid'])
                      ?.toString();
                } else {
                  cId = company?.toString();
                }
                if (cId != null) {
                  debugPrint("Categories Matching: [S1] Added Company: $cId");
                  uniqueCompanyIds.add(cId);
                }
              }
            }
          }
        }
      } catch (e) {
        debugPrint("Error fetching global settings in categories: $e");
      }

      // 2. Direct fetch by branchId if available (Most reliable for logged-in waiters)
      if (branchId != null) {
        try {
          final bRes = await http.get(
            Uri.parse(
              'https://blackforest.vseyal.com/api/branches/$branchId?depth=1',
            ),
            headers: {'Authorization': 'Bearer $token'},
          );
          if (bRes.statusCode == 200) {
            final branch = jsonDecode(bRes.body);
            var company = branch['company'];
            String? cId;
            if (company is Map) {
              cId =
                  company['id']?.toString() ??
                  company['_id']?.toString() ??
                  company['\$oid']?.toString();
            } else {
              cId = company?.toString();
            }
            if (cId != null) {
              debugPrint(
                "Categories Matching: [Direct] Successfully recovered Company ID: $cId",
              );
              uniqueCompanyIds.add(cId);
            } else {
              debugPrint(
                "Categories Matching: [Direct] Branch found but Company ID is NULL",
              );
            }
          } else {
            debugPrint(
              "Categories Matching: [Direct] Failed to fetch branch details: ${bRes.statusCode}",
            );
          }
        } catch (e) {
          debugPrint("Error fetching direct branch in categories: $e");
        }
      }

      // 3. Fallback/Include Branches Collection (Scan for IP matches if needed)
      if (uniqueCompanyIds.isEmpty) {
        final allBranchesResponse = await http.get(
          Uri.parse(
            'https://blackforest.vseyal.com/api/branches?limit=100&depth=1',
          ),
          headers: {'Authorization': 'Bearer $token'},
        );
        if (allBranchesResponse.statusCode == 200) {
          final branchesData = jsonDecode(allBranchesResponse.body);
          if (branchesData['docs'] != null && branchesData['docs'] is List) {
            for (var branch in branchesData['docs']) {
              final String bId =
                  branch['id']?.toString() ?? branch['_id']?.toString() ?? '';

              bool isMatch = false;
              // Match by stored branchId
              if (branchId != null && bId == branchId) {
                isMatch = true;
                debugPrint("Categories Matching: [S3] ID Match for $bId");
              }
              // Match by IP
              else if (deviceIp != null) {
                String? bIpRange = branch['ipAddress']?.toString().trim();
                if (bIpRange != null &&
                    bIpRange.isNotEmpty &&
                    (bIpRange == deviceIp ||
                        _isIpInRange(deviceIp, bIpRange))) {
                  isMatch = true;
                  debugPrint("Categories Matching: [S3] IP Match for $bId");
                }
              }
              // Match by GPS Fallback
              if (!isMatch && currentPos != null) {
                final double? lat = branch['latitude'] != null
                    ? (branch['latitude'] as num).toDouble()
                    : null;
                final double? lng = branch['longitude'] != null
                    ? (branch['longitude'] as num).toDouble()
                    : null;
                final int radius = branch['radius'] != null
                    ? (branch['radius'] as num).toInt()
                    : 100;

                if (lat != null && lng != null) {
                  final dist = Geolocator.distanceBetween(
                    currentPos.latitude,
                    currentPos.longitude,
                    lat,
                    lng,
                  );
                  if (dist <= radius) {
                    isMatch = true;
                    debugPrint(
                      "Categories Matching: [S3] GPS Match for $bId (Dist: ${dist.toStringAsFixed(1)}m)",
                    );
                  }
                }
              }

              if (isMatch) {
                var company = branch['company'];
                String? companyId;
                if (company is Map) {
                  companyId =
                      company['id']?.toString() ??
                      company['_id']?.toString() ??
                      company['\$oid']?.toString();
                } else {
                  companyId = company?.toString();
                }
                if (companyId != null) {
                  debugPrint(
                    "Categories Matching: [S3] Added Company: $companyId",
                  );
                  uniqueCompanyIds.add(companyId);
                }
              }
            }
          }
        }
      }
      companyIds = uniqueCompanyIds.toList();
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
      _userRole ??= prefs.getString('role');
      _companyId ??= prefs.getString('company_id');
      final storedUserId = prefs.getString('user_id');
      if (storedUserId != _currentUserId) {
        await _loadFavoriteCategories(preferredUserId: storedUserId);
      }

      if (token == null) {
        if (!mounted) return;
        setState(() {
          _errorMessage = 'No token found. Please login again.';
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No token found. Please login again.')),
        );
        return;
      }

      final branchId = prefs.getString('branchId');

      // Fetch user data if not already fetched
      if (_userRole == null) {
        await _fetchUserData(token);
      }
      if (!mounted) return;
      _userRole ??= prefs.getString('role');
      _companyId ??= prefs.getString('company_id');

      String filterQuery = 'where[isBilling][equals]=true';
      // Role-based company filter
      if (_userRole != 'superadmin') {
        String? companyFilter;
        if (_userRole == 'waiter') {
          String? waiterCompanyId = _companyId ?? prefs.getString('company_id');
          if ((waiterCompanyId == null || waiterCompanyId.isEmpty) &&
              branchId != null) {
            waiterCompanyId = await _fetchCompanyIdFromBranch(token, branchId);
            if (waiterCompanyId != null && waiterCompanyId.isNotEmpty) {
              await prefs.setString('company_id', waiterCompanyId);
              _companyId = waiterCompanyId;
            }
          }

          if (waiterCompanyId != null && waiterCompanyId.isNotEmpty) {
            companyFilter = '&where[company][in]=$waiterCompanyId';
          } else {
            final deviceIp = await _fetchDeviceIp();
            final matchingCompanyIds = await _fetchMatchingCompanyIds(
              token,
              deviceIp,
              branchId: branchId,
            );
            if (matchingCompanyIds.isNotEmpty) {
              companyFilter =
                  '&where[company][in]=${matchingCompanyIds.join(',')}';
              final firstMatch = matchingCompanyIds.first;
              _companyId = firstMatch;
              await prefs.setString('company_id', firstMatch);
            } else {
              setState(() {
                _errorMessage =
                    'No matching branches for your connection or location.';
                _isLoading = false;
              });
              return;
            }
          }
        } else if (_companyId != null && _companyId!.isNotEmpty) {
          companyFilter = '&where[company][contains]=$_companyId';
        } else {
          final storedCompanyId = prefs.getString('company_id');
          if (storedCompanyId != null && storedCompanyId.isNotEmpty) {
            _companyId = storedCompanyId;
            companyFilter = '&where[company][contains]=$storedCompanyId';
          }
        }
        if (companyFilter != null) {
          filterQuery += companyFilter;
        }
      }

      final cachedCategories = _readCategoriesCache(filterQuery);
      if (cachedCategories != null) {
        setState(() {
          _categories = cachedCategories;
          _isLoading = false;
        });
        return;
      }

      final response = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/categories?$filterQuery&limit=100&depth=1',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        if (!mounted) return;
        final docs = List<dynamic>.from(data['docs'] ?? []);
        setState(() {
          _categories = docs;
          _isLoading = false;
        });
        _writeCategoriesCache(filterQuery, docs);
      } else {
        if (!mounted) return;
        setState(() {
          _errorMessage = 'Failed to fetch categories: ${response.statusCode}';
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to fetch categories: ${response.statusCode}'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
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
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No token found. Please login again.')),
        );
        return;
      }
      // Fetch product by UPC globally
      final response = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/products?where[upc][equals]=$scanResult&limit=1&depth=1',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final List<dynamic> products = data['docs'] ?? [];
        if (products.isNotEmpty) {
          final product = products[0];
          if (!mounted) return;
          final cartProvider = Provider.of<CartProvider>(
            context,
            listen: false,
          );
          // Get branch-specific price if available (similar to ProductsPage)
          double price =
              product['defaultPriceDetails']?['price']?.toDouble() ?? 0.0;
          if (_userRole == 'branch') {
            // Reuse _fetchUserData logic or store globally
            if (product['branchOverrides'] != null) {
              // Removed unused branchId/branchOid loop logic
            }
          }
          final item = CartItem.fromProduct(product, 1, branchPrice: price);
          cartProvider.addOrUpdateItem(item);
          final newQty = cartProvider.cartItems
              .firstWhere((i) => i.id == item.id)
              .quantity;
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${product['name']} added/updated (Qty: $newQty)'),
            ),
          );
        } else {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Product not found')));
        }
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to fetch product: ${response.statusCode}'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error: Check your internet')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cartProvider = Provider.of<CartProvider>(context);
    String title = 'Billing';
    if (cartProvider.selectedTable != null) {
      title =
          'Table: ${cartProvider.selectedTable} (${cartProvider.selectedSection})';
    } else if (cartProvider.isSharedTableOrder) {
      title = CartProvider.sharedTablesSectionName;
    }
    PageType pageType = widget.sourcePage;

    return CommonScaffold(
      title: title,
      pageType: pageType,
      onScanCallback: _handleScan, // Add this for global scan from categories
      body: RefreshIndicator(
        onRefresh: _fetchCategories,
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(color: Colors.black),
              )
            : _errorMessage.isNotEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _errorMessage,
                      style: const TextStyle(
                        color: Color(0xFF4A4A4A),
                        fontSize: 18,
                      ),
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
                  final orderedCategories = _orderedCategories();
                  final width = constraints.maxWidth;
                  final crossAxisCount = (width > 600)
                      ? 5
                      : 3; // 3 on phones, 5 on desktop/web/tablets
                  return GridView.builder(
                    padding: const EdgeInsets.all(10),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      childAspectRatio: 0.75, // Rectangular
                    ),
                    itemCount: orderedCategories.length,
                    itemBuilder: (context, index) {
                      final category = orderedCategories[index];
                      final String categoryId =
                          category['id']?.toString() ?? '';
                      final String categoryName =
                          category['name']?.toString() ?? 'Unknown';
                      final isFavorite = _favoriteCategoryIds.contains(
                        categoryId,
                      );

                      String? imageUrl;
                      if (category['image'] != null &&
                          category['image']['url'] != null) {
                        imageUrl = category['image']['url'];
                        if (imageUrl?.startsWith('/') ?? false) {
                          imageUrl = 'https://blackforest.vseyal.com$imageUrl';
                        }
                      }
                      imageUrl ??=
                          'https://via.placeholder.com/150?text=No+Image'; // Fallback
                      return GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => ProductsPage(
                                categoryId: categoryId,
                                categoryName: categoryName,
                                sourcePage: widget.sourcePage,
                              ),
                            ),
                          );
                        },
                        onLongPress: () =>
                            _toggleFavoriteCategory(categoryId, categoryName),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
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
                                    flex: 8, // 80% image
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
                                    flex: 2, // 20% name
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
                                        categoryName,
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
                              if (isFavorite)
                                Positioned(
                                  top: 8,
                                  right: 8,
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: 0.35,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.star,
                                      size: 20,
                                      color: Colors.yellow.shade700,
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
