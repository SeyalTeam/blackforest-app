import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:blackforest_app/category_popularity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/product_popularity_service.dart';
import 'package:blackforest_app/products_page.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:blackforest_app/cart_provider.dart';
import 'package:blackforest_app/offer_banner.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:blackforest_app/customer_history_dialog.dart';
import 'package:blackforest_app/table_customer_details_visibility_service.dart';
import 'package:blackforest_app/widgets/product_rating_badge.dart';

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
  final String? initialCategoryId;
  final String? initialCategoryName;
  final List<Map<String, dynamic>> initialHomeTopCategories;

  const CategoriesPage({
    super.key,
    this.sourcePage = PageType.billing,
    this.initialCategoryId,
    this.initialCategoryName,
    this.initialHomeTopCategories = const <Map<String, dynamic>>[],
  });

  @override
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  static const Duration _categoriesCacheTtl = Duration(seconds: 90);
  static final Map<String, _CategoriesCacheEntry> _categoriesCache = {};
  static const Color _homeAccentColor = Color(0xFFEF4F5F);

  List<dynamic> _categories = [];
  bool _isLoading = true;
  String _errorMessage = '';
  String? _companyId;
  String? _userRole;
  String? _currentUserId;
  List<String> _favoriteCategoryIds = <String>[];
  final TextEditingController _homeSearchController = TextEditingController();
  String _homeSearchQuery = '';
  bool _didOpenInitialCategory = false;
  Map<String, ProductPopularityInfo> _categoryPopularityById =
      <String, ProductPopularityInfo>{};
  TableCustomerDetailsVisibilityConfig _customerDetailsVisibilityConfig =
      TableCustomerDetailsVisibilityConfig.defaultValue;
  Future<void>? _customerDetailsVisibilityLoadFuture;

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
    _loadCategoryPopularity();
    unawaited(_ensureCustomerDetailsVisibilityConfigLoaded());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openInitialCategoryIfNeeded();
    });
  }

  @override
  void dispose() {
    _homeSearchController.dispose();
    super.dispose();
  }

  Future<void> _ensureCustomerDetailsVisibilityConfigLoaded() async {
    if (widget.sourcePage != PageType.billing) return;
    final existing = _customerDetailsVisibilityLoadFuture;
    if (existing != null) {
      await existing;
      return;
    }

    final future = () async {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token')?.trim();
      final branchId = prefs.getString('branchId')?.trim();
      if (token == null ||
          token.isEmpty ||
          branchId == null ||
          branchId.isEmpty) {
        return;
      }
      final config =
          await TableCustomerDetailsVisibilityService.getConfigForBranch(
            branchId: branchId,
            token: token,
            forceRefresh: true,
          );
      if (!mounted) return;
      setState(() {
        _customerDetailsVisibilityConfig = config;
      });
    }();

    _customerDetailsVisibilityLoadFuture = future.whenComplete(() {
      _customerDetailsVisibilityLoadFuture = null;
    });
    await _customerDetailsVisibilityLoadFuture;
  }

  Future<Map<String, dynamic>?> _showBillingCustomerDetailsDialog(
    CartProvider cartProvider, {
    bool allowSkip = true,
    bool showHistory = true,
    bool enableAutoSubmit = true,
  }) async {
    final nameCtrl = TextEditingController(
      text: cartProvider.customerName ?? '',
    );
    final phoneCtrl = TextEditingController(
      text: cartProvider.customerPhone ?? '',
    );
    Timer? debounceTimer;
    bool isDialogActive = true;
    bool isDialogSubmitting = false;
    bool didCloseDialog = false;
    int lookupSequence = 0;
    bool isLookupInProgress = false;
    String? lookupError;
    Map<String, dynamic>? customerLookupData;

    String normalizePhone(String value) => value.replaceAll(RegExp(r'\D'), '');

    Future<void> lookupCustomerPreview(
      String normalizedPhone,
      int requestId,
      void Function(VoidCallback fn) setDialogState,
    ) async {
      try {
        final quickData = await cartProvider.fetchCustomerLookupPreview(
          normalizedPhone,
          limit: 1,
          useHeavyFallback: true,
          includeGlobalLookup: true,
        );
        final latestPhone = normalizePhone(phoneCtrl.text);
        if (!isDialogActive ||
            !mounted ||
            latestPhone != normalizedPhone ||
            requestId != lookupSequence) {
          return;
        }

        final quickName = quickData?['name']?.toString().trim() ?? '';
        final quickIsNewCustomer = quickData?['isNewCustomer'] == true;
        if (!quickIsNewCustomer &&
            quickName.isNotEmpty &&
            nameCtrl.text.trim().isEmpty) {
          nameCtrl.text = quickName;
        }

        setDialogState(() {
          customerLookupData = quickData;
          isLookupInProgress = false;
          lookupError = null;
        });
      } catch (error) {
        final latestPhone = normalizePhone(phoneCtrl.text);
        if (!isDialogActive ||
            !mounted ||
            latestPhone != normalizedPhone ||
            requestId != lookupSequence) {
          return;
        }
        setDialogState(() {
          customerLookupData = null;
          isLookupInProgress = false;
          lookupError = 'Unable to fetch customer details';
        });
      }
    }

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            void closeDialogSafely(Map<String, dynamic>? value) {
              if (didCloseDialog) return;
              didCloseDialog = true;
              setDialogState(() {
                isDialogSubmitting = true;
              });
              isDialogActive = false;
              lookupSequence += 1;
              debounceTimer?.cancel();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                final nav = Navigator.of(dialogContext);
                if (nav.canPop()) {
                  nav.pop(value);
                }
              });
            }

            bool autoSubmitIfReady() {
              if (!enableAutoSubmit) return false;
              if (!isDialogActive || isDialogSubmitting || didCloseDialog) {
                return false;
              }
              final normalizedPhone = normalizePhone(phoneCtrl.text);
              final customerName = nameCtrl.text.trim();
              if (normalizedPhone.length < 10 || customerName.isEmpty) {
                return false;
              }
              closeDialogSafely(<String, dynamic>{
                'name': customerName,
                'phone': phoneCtrl.text.trim(),
              });
              return true;
            }

            final normalizedPhoneForHistory = normalizePhone(phoneCtrl.text);
            final isExistingCustomerForHistory =
                customerLookupData != null &&
                customerLookupData?['isNewCustomer'] != true;
            final canOpenCustomerHistory =
                showHistory &&
                isExistingCustomerForHistory &&
                !isDialogSubmitting &&
                normalizedPhoneForHistory.length >= 10;

            return Dialog(
              backgroundColor: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              insetPadding: const EdgeInsets.symmetric(horizontal: 28),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(dialogContext).size.height * 0.78,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Center(
                              child: Text(
                                'Customer Details',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Phone Number',
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF121212),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: const Color(
                              0xFF0A84FF,
                            ).withValues(alpha: 0.5),
                          ),
                        ),
                        child: TextField(
                          controller: phoneCtrl,
                          keyboardType: TextInputType.phone,
                          textInputAction: enableAutoSubmit
                              ? TextInputAction.done
                              : TextInputAction.next,
                          style: const TextStyle(color: Colors.white),
                          onSubmitted: (_) {
                            if (autoSubmitIfReady()) return;
                            FocusScope.of(dialogContext).nextFocus();
                          },
                          onChanged: (value) {
                            if (!isDialogActive || isDialogSubmitting) return;
                            setDialogState(() {});
                            final normalizedPhone = normalizePhone(value);
                            lookupSequence += 1;
                            if (normalizedPhone.length < 10) {
                              debounceTimer?.cancel();
                              setDialogState(() {
                                customerLookupData = null;
                                lookupError = null;
                                isLookupInProgress = false;
                              });
                              return;
                            }
                            setDialogState(() {
                              lookupError = null;
                              isLookupInProgress = true;
                            });
                            debounceTimer?.cancel();
                            final requestId = lookupSequence;
                            debounceTimer = Timer(
                              const Duration(milliseconds: 350),
                              () async {
                                await lookupCustomerPreview(
                                  normalizedPhone,
                                  requestId,
                                  setDialogState,
                                );
                                if (!mounted) return;
                                autoSubmitIfReady();
                              },
                            );
                          },
                          decoration: const InputDecoration(
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                            border: InputBorder.none,
                            hintText: 'Enter phone number',
                            hintStyle: TextStyle(color: Colors.white38),
                          ),
                        ),
                      ),
                      if (isLookupInProgress) ...[
                        const SizedBox(height: 10),
                        const Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFF0A84FF),
                            ),
                          ),
                        ),
                      ],
                      if (lookupError != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          lookupError!,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 12,
                          ),
                        ),
                      ],
                      const SizedBox(height: 18),
                      const Text(
                        'Customer Name',
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF121212),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: const Color(
                              0xFF0A84FF,
                            ).withValues(alpha: 0.5),
                          ),
                        ),
                        child: TextField(
                          controller: nameCtrl,
                          textInputAction: TextInputAction.done,
                          style: const TextStyle(color: Colors.white),
                          onSubmitted: (_) {
                            if (autoSubmitIfReady()) return;
                            FocusScope.of(dialogContext).unfocus();
                          },
                          decoration: const InputDecoration(
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                            border: InputBorder.none,
                            hintText: 'Enter customer name',
                            hintStyle: TextStyle(color: Colors.white38),
                          ),
                        ),
                      ),
                      if (showHistory &&
                          isExistingCustomerForHistory &&
                          normalizedPhoneForHistory.length >= 10) ...[
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: canOpenCustomerHistory
                                ? () async {
                                    await showCustomerHistoryDialog(
                                      dialogContext,
                                      phoneNumber: phoneCtrl.text,
                                    );
                                  }
                                : null,
                            icon: const Icon(
                              Icons.history_rounded,
                              color: Colors.white,
                            ),
                            label: const Text(
                              'CUSTOMER HISTORY',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.3,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF16A34A),
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: const Color(0xFF2C3A2F),
                              disabledForegroundColor: Colors.white54,
                              padding: const EdgeInsets.symmetric(vertical: 13),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (phoneCtrl.text.trim().isEmpty) ...[
                        const SizedBox(height: 12),
                        const Text(
                          'Enter customer phone number to apply offers',
                          style: TextStyle(
                            color: Colors.orangeAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      const SizedBox(height: 28),
                      if (allowSkip)
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: isDialogSubmitting
                                    ? null
                                    : () => closeDialogSafely(
                                        <String, dynamic>{},
                                      ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white70,
                                  side: const BorderSide(color: Colors.white24),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                child: const Text('Skip'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: isDialogSubmitting
                                    ? null
                                    : () {
                                        final customerName = nameCtrl.text
                                            .trim();
                                        final customerPhone = phoneCtrl.text
                                            .trim();
                                        if (customerName.isEmpty &&
                                            customerPhone.isEmpty) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'Please enter customer name or phone number, or use Skip',
                                              ),
                                            ),
                                          );
                                          return;
                                        }
                                        closeDialogSafely(<String, dynamic>{
                                          'name': customerName,
                                          'phone': customerPhone,
                                        });
                                      },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF0A84FF),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                child: const Text(
                                  'Submit',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        )
                      else
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: isDialogSubmitting
                                ? null
                                : () {
                                    final customerName = nameCtrl.text.trim();
                                    final customerPhone = phoneCtrl.text.trim();
                                    if (customerName.isEmpty &&
                                        customerPhone.isEmpty) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Please enter customer name or phone number',
                                          ),
                                        ),
                                      );
                                      return;
                                    }
                                    closeDialogSafely(<String, dynamic>{
                                      'name': customerName,
                                      'phone': customerPhone,
                                    });
                                  },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF0A84FF),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            child: const Text(
                              'Submit',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    debounceTimer?.cancel();
    return result;
  }

  Future<bool> _ensureBillingCustomerDetailsBeforeProducts() async {
    if (widget.sourcePage != PageType.billing) return true;
    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    cartProvider.setCartType(CartType.billing, notify: false);

    await _ensureCustomerDetailsVisibilityConfigLoaded();
    if (!_customerDetailsVisibilityConfig.showCustomerDetailsForBillingOrders) {
      return true;
    }

    final existingName = (cartProvider.customerName ?? '').trim();
    final existingPhone = (cartProvider.customerPhone ?? '').trim();
    if (existingName.isNotEmpty || existingPhone.isNotEmpty) {
      return true;
    }

    final customerDetails = await _showBillingCustomerDetailsDialog(
      cartProvider,
      allowSkip: _customerDetailsVisibilityConfig
          .allowSkipCustomerDetailsForBillingOrders,
      showHistory:
          _customerDetailsVisibilityConfig.showCustomerHistoryForBillingOrders,
      enableAutoSubmit: _customerDetailsVisibilityConfig
          .autoSubmitCustomerDetailsForBillingOrders,
    );
    if (!mounted || customerDetails == null) return false;

    cartProvider.setCartType(CartType.billing, notify: false);
    if (customerDetails.isEmpty) {
      cartProvider.setCustomerDetails();
    } else {
      cartProvider.setCustomerDetails(
        name: customerDetails['name']?.toString(),
        phone: customerDetails['phone']?.toString(),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 220));
    return mounted;
  }

  Future<void> _openProductsPage({
    required String categoryId,
    required String categoryName,
    bool instant = false,
  }) async {
    final normalizedId = categoryId.trim();
    if (normalizedId.isEmpty) return;
    final allowedToOpen = await _ensureBillingCustomerDetailsBeforeProducts();
    if (!allowedToOpen || !mounted) return;

    final route = instant
        ? PageRouteBuilder(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (context, animation, secondaryAnimation) =>
                ProductsPage(
                  categoryId: normalizedId,
                  categoryName: categoryName,
                  sourcePage: widget.sourcePage,
                  initialHomeTopCategories: widget.initialHomeTopCategories,
                ),
          )
        : MaterialPageRoute(
            builder: (context) => ProductsPage(
              categoryId: normalizedId,
              categoryName: categoryName,
              sourcePage: widget.sourcePage,
              initialHomeTopCategories: widget.initialHomeTopCategories,
            ),
          );

    await Navigator.push(context, route);
  }

  Future<void> _openInitialCategoryIfNeeded() async {
    if (!mounted || _didOpenInitialCategory) return;
    final categoryId = widget.initialCategoryId?.trim() ?? '';
    if (categoryId.isEmpty) return;

    _didOpenInitialCategory = true;
    final categoryName =
        (widget.initialCategoryName?.trim().isNotEmpty ?? false)
        ? widget.initialCategoryName!.trim()
        : 'Category';
    await _openProductsPage(
      categoryId: categoryId,
      categoryName: categoryName,
      instant: true,
    );
  }

  String _favoritesScope() {
    if (widget.sourcePage == PageType.table ||
        widget.sourcePage == PageType.home) {
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

  bool get _isHomeMode => widget.sourcePage == PageType.home;

  ProductPopularityInfo? _categoryBadgeInfo(String categoryId) {
    final normalizedId = categoryId.trim();
    if (normalizedId.isEmpty) return null;
    return _categoryPopularityById[normalizedId];
  }

  Future<void> _loadCategoryPopularity() async {
    if (!_isHomeMode) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token')?.trim();
      final branchId = (prefs.getString('branchId') ?? '').trim();
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

  List<dynamic> _filteredHomeCategories() {
    final query = _homeSearchQuery.trim().toLowerCase();
    final orderedCategories = _orderedCategories();
    if (query.isEmpty) {
      return orderedCategories;
    }

    return orderedCategories
        .where((rawCategory) {
          if (rawCategory is! Map) return false;
          final category = Map<String, dynamic>.from(rawCategory);
          final name = (category['name'] ?? '').toString().trim().toLowerCase();
          return name.contains(query);
        })
        .toList(growable: false);
  }

  String? _resolveCategoryImageUrl(dynamic rawCategory) {
    if (rawCategory is! Map) return null;
    final category = Map<String, dynamic>.from(rawCategory);

    final image = category['image'];
    if (image is Map) {
      final url =
          image['url']?.toString().trim() ??
          image['thumbnailURL']?.toString().trim() ??
          image['thumbnailUrl']?.toString().trim();
      if (url != null && url.isNotEmpty) {
        return url.startsWith('/') ? 'https://blackforest.vseyal.com$url' : url;
      }
    }

    final directUrl =
        category['imageUrl']?.toString().trim() ??
        category['thumbnail']?.toString().trim();
    if (directUrl != null && directUrl.isNotEmpty) {
      return directUrl.startsWith('/')
          ? 'https://blackforest.vseyal.com$directUrl'
          : directUrl;
    }
    return null;
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
                        decoration: const InputDecoration(
                          isCollapsed: true,
                          border: InputBorder.none,
                          hintText: 'Search in categories',
                          hintStyle: TextStyle(
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

  Widget _buildHomeCategoryGrid(List<dynamic> visibleCategories) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width > 960
            ? 4
            : width > 680
            ? 3
            : 2;
        final spacing = width > 680 ? 16.0 : 14.0;
        final aspectRatio = width > 680 ? 0.92 : 0.95;

        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 18),
          physics: const AlwaysScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: spacing,
            mainAxisSpacing: 12,
            childAspectRatio: aspectRatio,
          ),
          itemCount: visibleCategories.length,
          itemBuilder: (context, index) {
            return _buildHomeCategoryCard(visibleCategories[index]);
          },
        );
      },
    );
  }

  Widget _buildHomeCategoryCard(dynamic rawCategory) {
    final category = rawCategory is Map
        ? Map<String, dynamic>.from(rawCategory)
        : <String, dynamic>{};
    final categoryId = category['id']?.toString().trim() ?? '';
    final categoryName = (category['name'] ?? 'Unknown').toString().trim();
    final imageUrl = _resolveCategoryImageUrl(category);
    final isFavorite = _favoriteCategoryIds.contains(categoryId);
    final badgeInfo = _categoryBadgeInfo(categoryId);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _openProductsPage(
          categoryId: categoryId,
          categoryName: categoryName,
        ),
        onLongPress: () => _toggleFavoriteCategory(categoryId, categoryName),
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
                  child: imageUrl != null && imageUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: imageUrl,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Container(
                            color: const Color(0xFFF3F5F7),
                            alignment: Alignment.center,
                            child: const CircularProgressIndicator(
                              color: _homeAccentColor,
                            ),
                          ),
                          errorWidget: (context, url, error) {
                            return _buildHomeCategoryPlaceholder();
                          },
                        )
                      : _buildHomeCategoryPlaceholder(),
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
                    categoryName,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.left,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      height: 1.1,
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () =>
                        _toggleFavoriteCategory(categoryId, categoryName),
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
      ),
    );
  }

  Widget _buildHomeCategoryPlaceholder() {
    return Container(
      color: const Color(0xFFF3F5F7),
      alignment: Alignment.center,
      child: const Icon(
        Icons.restaurant_menu_rounded,
        color: Color(0xFF98A2B3),
        size: 40,
      ),
    );
  }

  Widget _buildHomeModeBody({required List<dynamic> visibleCategories}) {
    return Column(
      children: [
        _buildHomeHeader(),
        Expanded(
          child: _isLoading
              ? const Center(
                  child: CircularProgressIndicator(color: Colors.black),
                )
              : _errorMessage.isNotEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(24, 80, 24, 24),
                  children: [
                    Text(
                      _errorMessage,
                      style: const TextStyle(
                        color: Color(0xFF4A4A4A),
                        fontSize: 18,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: ElevatedButton(
                        onPressed: _fetchCategories,
                        child: const Text('Retry'),
                      ),
                    ),
                  ],
                )
              : visibleCategories.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(24, 80, 24, 24),
                  children: const [
                    Text(
                      'No categories found',
                      style: TextStyle(color: Color(0xFF4A4A4A), fontSize: 18),
                      textAlign: TextAlign.center,
                    ),
                  ],
                )
              : RefreshIndicator(
                  onRefresh: _fetchCategories,
                  child: _buildHomeCategoryGrid(visibleCategories),
                ),
        ),
      ],
    );
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
      if (_isHomeMode && widget.initialHomeTopCategories.isNotEmpty) {
        final storedUserId = prefs.getString('user_id');
        if (storedUserId != _currentUserId) {
          await _loadFavoriteCategories(preferredUserId: storedUserId);
        }
        if (!mounted) return;
        setState(() {
          _categories = widget.initialHomeTopCategories
              .map((category) => Map<String, dynamic>.from(category))
              .toList(growable: false);
          _isLoading = false;
          _errorMessage = '';
        });
        return;
      }

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
          final prefs = await SharedPreferences.getInstance();
          final branchId = prefs.getString('branchId')?.trim();
          // Get branch-specific price if available (similar to ProductsPage)
          double price =
              product['defaultPriceDetails']?['price']?.toDouble() ?? 0.0;
          if (_userRole == 'branch') {
            // Reuse _fetchUserData logic or store globally
            if (product['branchOverrides'] != null) {
              // Removed unused branchId/branchOid loop logic
            }
          }
          final item = CartItem.fromProduct(
            product,
            1,
            branchPrice: price,
            branchId: branchId,
          );
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
    final visibleHomeCategories = _filteredHomeCategories();
    String title = _isHomeMode ? 'Categories' : 'Billing';
    if (!_isHomeMode && cartProvider.selectedTable != null) {
      title =
          'Table: ${cartProvider.selectedTable} (${cartProvider.selectedSection})';
    } else if (!_isHomeMode && cartProvider.isSharedTableOrder) {
      title = CartProvider.sharedTablesSectionName;
    }

    return CommonScaffold(
      title: title,
      pageType: widget.sourcePage,
      showAppBar: !_isHomeMode,
      onScanCallback: _handleScan, // Add this for global scan from categories
      body: _isHomeMode
          ? Container(
              color: const Color(0xFFF4F8F4),
              child: _buildHomeModeBody(
                visibleCategories: visibleHomeCategories,
              ),
            )
          : RefreshIndicator(
              onRefresh: _fetchCategories,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final orderedCategories = _orderedCategories();
                  final width = constraints.maxWidth;
                  final crossAxisCount = (width > 600) ? 5 : 3;

                  return CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      const SliverPadding(
                        padding: EdgeInsets.symmetric(vertical: 10),
                        sliver: SliverToBoxAdapter(
                          child: OfferBanner(
                            height: 156,
                            showIndicators: false,
                            itemMargin: EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 4,
                            ),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 14,
                            ),
                            mediaSize: 96,
                            useCenteredValueLayout: false,
                            regularTitleFontSize: 17,
                            regularSubtitleFontSize: 13,
                            regularSubtitleMaxLines: 3,
                            regularSubtitleOverflow: TextOverflow.visible,
                          ),
                        ),
                      ),
                      if (_isLoading)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: CircularProgressIndicator(
                              color: Colors.black,
                            ),
                          ),
                        )
                      else if (_errorMessage.isNotEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  _errorMessage,
                                  style: const TextStyle(
                                    color: Color(0xFF4A4A4A),
                                    fontSize: 18,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 10),
                                ElevatedButton(
                                  onPressed: _fetchCategories,
                                  child: const Text('Retry'),
                                ),
                              ],
                            ),
                          ),
                        )
                      else if (orderedCategories.isEmpty)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Text(
                              'No categories found',
                              style: TextStyle(
                                color: Color(0xFF4A4A4A),
                                fontSize: 18,
                              ),
                            ),
                          ),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.all(10),
                          sliver: SliverGrid(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: crossAxisCount,
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10,
                                  childAspectRatio: 0.75,
                                ),
                            delegate: SliverChildBuilderDelegate((
                              context,
                              index,
                            ) {
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
                                  imageUrl =
                                      'https://blackforest.vseyal.com$imageUrl';
                                }
                              }
                              imageUrl ??=
                                  'https://via.placeholder.com/150?text=No+Image';
                              return GestureDetector(
                                onTap: () => _openProductsPage(
                                  categoryId: categoryId,
                                  categoryName: categoryName,
                                ),
                                onLongPress: () => _toggleFavoriteCategory(
                                  categoryId,
                                  categoryName,
                                ),
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.grey.withValues(
                                          alpha: 0.1,
                                        ),
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
                                              borderRadius:
                                                  const BorderRadius.vertical(
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
                                                errorWidget:
                                                    (context, url, error) =>
                                                        const Center(
                                                          child: Text(
                                                            'No Image',
                                                            style: TextStyle(
                                                              color:
                                                                  Colors.grey,
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
                                                borderRadius:
                                                    BorderRadius.vertical(
                                                      bottom: Radius.circular(
                                                        8,
                                                      ),
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
                            }, childCount: orderedCategories.length),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
    );
  }
}
