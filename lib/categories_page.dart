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
import 'package:blackforest_app/api_server_prefs.dart';

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
  static const Duration _categoriesCacheTtl = Duration(hours: 15);
  static const Duration _persistentCategoriesCacheTtl = Duration(days: 7);
  static const String _persistentCategoriesCachePrefix =
      'cached_categories_payload_v1_';
  static final Map<String, _CategoriesCacheEntry> _categoriesCache = {};
  static const Color _homeAccentColor = Color(0xFFEF4F5F);

  List<dynamic> _categories = [];
  bool _isLoading = true;
  String _errorMessage = '';
  String? _companyId;
  String? _branchId;
  String? _userRole;
  String? _currentUserId;
  List<String> _favoriteCategoryIds = <String>[];
  final TextEditingController _homeSearchController = TextEditingController();
  String _homeSearchQuery = '';
  bool _hasOfferBanner = false;
  bool _billingCustomerPromptSkippedForSession = false;
  bool _didOpenInitialCategory = false;
  Map<String, ProductPopularityInfo> _categoryPopularityById =
      <String, ProductPopularityInfo>{};
  TableCustomerDetailsVisibilityConfig _customerDetailsVisibilityConfig =
      TableCustomerDetailsVisibilityConfig.defaultValue;
  Future<void>? _customerDetailsVisibilityLoadFuture;

  bool get _requiresCompanyScopedCategories =>
      widget.sourcePage == PageType.table ||
      widget.sourcePage == PageType.billing;

  bool _usesBillingMenuWidgetApi({String? role}) {
    if (widget.sourcePage == PageType.table) return true;
    if (widget.sourcePage != PageType.billing) return false;
    final effectiveRole = (role ?? _userRole ?? '').trim().toLowerCase();
    return effectiveRole == 'waiter';
  }

  String _categoriesCacheKey(String filterQuery) =>
      filterQuery;

  String _persistentCategoriesCacheKey(String branchId) =>
      '$_persistentCategoriesCachePrefix${_favoritesScope()}_$branchId';

  Future<void> _hydratePersistentCategoriesCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Enable persistent cache for all modes

      final branchId = (prefs.getString('branchId') ?? 'global').trim();
      final cacheKey = _persistentCategoriesCacheKey(
        branchId.isEmpty ? 'global' : branchId,
      );
      final raw = prefs.getString(cacheKey);
      if (raw == null || raw.isEmpty) return;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final payload = Map<String, dynamic>.from(decoded);
      final cachedAtIso = payload['cachedAt']?.toString();
      final categoriesRaw = payload['categories'];
      if (cachedAtIso == null || categoriesRaw is! List) return;
      final cachedAt = DateTime.tryParse(cachedAtIso);
      if (cachedAt == null) return;
      if (DateTime.now().difference(cachedAt) > _persistentCategoriesCacheTtl) {
        return;
      }
      if (!mounted) return;
      if (_categories.isNotEmpty) return;
      _companyId ??= prefs.getString('company_id');
      final normalizedCompanyId = _companyId?.trim();
      if (_requiresCompanyScopedCategories &&
          (normalizedCompanyId == null || normalizedCompanyId.isEmpty)) {
        return;
      }
      final cachedCategories = categoriesRaw
          .whereType<Map>()
          .map((raw) => Map<String, dynamic>.from(raw))
          .toList(growable: false);
      final filteredCategories = _filterCategoriesByCompanyDepartment(
        cachedCategories,
        companyId: normalizedCompanyId,
        strictCompanyScope: _requiresCompanyScopedCategories,
      );
      setState(() {
        _categories = filteredCategories;
        _isLoading = false;
        _errorMessage = '';
      });
    } catch (_) {}
  }

  Future<void> _persistPersistentCategoriesCache(
    List<dynamic> categories,
  ) async {
    if (categories.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      // Persist for all modes

      final branchId = (prefs.getString('branchId') ?? 'global').trim();
      final cacheKey = _persistentCategoriesCacheKey(
        branchId.isEmpty ? 'global' : branchId,
      );
      final payload = <String, dynamic>{
        'cachedAt': DateTime.now().toIso8601String(),
        'categories': categories,
      };
      await prefs.setString(cacheKey, jsonEncode(payload));
    } catch (_) {}
  }

  List<dynamic>? _readCategoriesCache(String filterQuery) {
    final key = _categoriesCacheKey(filterQuery);
    final entry = _categoriesCache[key];
    if (entry == null) return null;
    final bool isExpired =
        DateTime.now().difference(entry.fetchedAt) > const Duration(hours: 15);
    if (isExpired) {
      _categoriesCache.remove(key);
      return null;
    }
    return List<dynamic>.from(entry.categories);
  }

  bool _hasCategoryImageHints(List<dynamic> categories) {
    for (final rawCategory in categories) {
      if (rawCategory is! Map) continue;
      final category = Map<String, dynamic>.from(rawCategory);
      final image = category['image'];
      if (image is Map &&
          ((image['url']?.toString().trim().isNotEmpty ?? false) ||
              (image['thumbnailURL']?.toString().trim().isNotEmpty ?? false) ||
              (image['thumbnailUrl']?.toString().trim().isNotEmpty ?? false))) {
        return true;
      }
      if ((category['imageUrl']?.toString().trim().isNotEmpty ?? false) ||
          (category['thumbnail']?.toString().trim().isNotEmpty ?? false)) {
        return true;
      }
    }
    return false;
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
    unawaited(_hydratePersistentCategoriesCache());
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
    if (widget.sourcePage != PageType.billing &&
        widget.sourcePage != PageType.table) {
      return;
    }
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
                                      customerName: nameCtrl.text,
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

    await _ensureCustomerDetailsVisibilityConfigLoaded().timeout(
      const Duration(milliseconds: 350),
      onTimeout: () {},
    );
    if (!_customerDetailsVisibilityConfig.showCustomerDetailsForBillingOrders) {
      return true;
    }
    final allowSkipCustomerDetailsByCms = _customerDetailsVisibilityConfig
        .allowSkipCustomerDetailsForBillingOrders;

    final existingName = (cartProvider.customerName ?? '').trim();
    final existingPhone = (cartProvider.customerPhone ?? '').trim();
    if (existingName.isNotEmpty || existingPhone.isNotEmpty) {
      return true;
    }
    if (cartProvider.cartItems.isNotEmpty ||
        cartProvider.recalledItems.isNotEmpty) {
      return true;
    }
    if (_billingCustomerPromptSkippedForSession) {
      return true;
    }
    if (allowSkipCustomerDetailsByCms &&
        cartProvider.isCustomerDetailsPromptSkippedForCurrentDraft) {
      return true;
    }

    final customerDetails = await _showBillingCustomerDetailsDialog(
      cartProvider,
      allowSkip: allowSkipCustomerDetailsByCms,
      showHistory:
          _customerDetailsVisibilityConfig.showCustomerHistoryForBillingOrders,
      enableAutoSubmit: _customerDetailsVisibilityConfig
          .autoSubmitCustomerDetailsForBillingOrders,
    );
    if (!mounted || customerDetails == null) return false;

    cartProvider.setCartType(CartType.billing, notify: false);
    if (customerDetails.isEmpty) {
      _billingCustomerPromptSkippedForSession = true;
      cartProvider.setCustomerDetailsPromptSkipped(true);
      cartProvider.setCustomerDetails();
    } else {
      _billingCustomerPromptSkippedForSession = false;
      cartProvider.setCustomerDetailsPromptSkipped(false);
      cartProvider.setCustomerDetails(
        name: customerDetails['name']?.toString(),
        phone: customerDetails['phone']?.toString(),
      );
    }
    return mounted;
  }

  Future<void> _openProductsPage({
    required String categoryId,
    required String categoryName,
    bool instant = false,
  }) async {
    final normalizedId = categoryId.trim();
    if (normalizedId.isEmpty) return;

    // Avoid duplicate network bursts on billing/table taps.
    if (_isHomeMode) {
      unawaited(() async {
        try {
          final prefs = await SharedPreferences.getInstance();
          final token = prefs.getString('token')?.trim();
          if (token == null || token.isEmpty) return;
          await _prefetchSingleCategory(token, normalizedId, _branchId);
        } catch (_) {}
      }());
    }

    final allowedToOpen = await _ensureBillingCustomerDetailsBeforeProducts();
    if (!allowedToOpen || !mounted) return;

    final config = _customerDetailsVisibilityConfig;
    int delayMinutes = 0;
    bool applyDelay = false;
    if (widget.sourcePage == PageType.billing && config.applyToBilling) {
      applyDelay = true;
    } else if (widget.sourcePage == PageType.table && config.applyToTable) {
      applyDelay = true;
    }

    if (applyDelay) {
      final prefs = await SharedPreferences.getInstance();
      final userId = _currentUserId ?? prefs.getString('user_id') ?? '';
      if (config.waiterSelectionType == 'particular') {
        if (!config.waiters.contains(userId)) {
          applyDelay = false;
        }
      }
    }

    if (applyDelay) {
      delayMinutes = config.delayMinutes;
    }

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
                  delayMinutes: delayMinutes,
                ),
          )
        : PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 250),
            pageBuilder: (context, animation, secondaryAnimation) =>
                ProductsPage(
                  categoryId: normalizedId,
                  categoryName: categoryName,
                  sourcePage: widget.sourcePage,
                  initialHomeTopCategories: widget.initialHomeTopCategories,
                  delayMinutes: delayMinutes,
                ),
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
                  return FadeTransition(opacity: animation, child: child);
                },
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
    // Both billing and table use the same menu data
    return 'billing_menu';
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
        return resolveApiAssetUrl(url);
      }
    }

    final directUrl =
        category['imageUrl']?.toString().trim() ??
        category['thumbnail']?.toString().trim();
    if (directUrl != null && directUrl.isNotEmpty) {
      return resolveApiAssetUrl(directUrl);
    }
    return null;
  }

  String _normalizeRelationId(dynamic value) {
    if (value == null) return '';
    if (value is Map) {
      final map = Map<String, dynamic>.from(value);
      final directId = map['id'] ?? map['_id'] ?? map[r'$oid'] ?? map['value'];
      if (directId == null) return '';
      final id = directId.toString().trim();
      return id.isEmpty ? '' : id;
    }
    final id = value.toString().trim();
    return id.isEmpty ? '' : id;
  }

  Set<String> _collectRelationIds(dynamic relation) {
    final ids = <String>{};

    void collect(dynamic node) {
      if (node == null) return;
      if (node is List) {
        for (final item in node) {
          collect(item);
        }
        return;
      }
      if (node is Map) {
        final map = Map<String, dynamic>.from(node);
        final directId = _normalizeRelationId(map);
        if (directId.isNotEmpty) ids.add(directId);
        final relationValue = map['value'];
        if (relationValue != null) {
          collect(relationValue);
        }
        return;
      }
      final directId = _normalizeRelationId(node);
      if (directId.isNotEmpty) ids.add(directId);
    }

    collect(relation);
    return ids;
  }

  List<Map<String, dynamic>> _filterCategoriesByCompanyDepartment(
    List<Map<String, dynamic>> categories, {
    String? companyId,
    bool strictCompanyScope = false,
  }) {
    final normalizedCompanyId = companyId?.trim() ?? '';
    if (categories.isEmpty) {
      return categories;
    }
    if (normalizedCompanyId.isEmpty) {
      return strictCompanyScope ? const <Map<String, dynamic>>[] : categories;
    }

    return categories
        .where((category) {
          final categoryCompanyIds = _collectRelationIds(category['company']);

          // Primary rule: if category has direct company mapping, enforce it.
          // This prevents cross-company leakage when shared departments contain
          // multiple companies.
          if (categoryCompanyIds.isNotEmpty) {
            return categoryCompanyIds.contains(normalizedCompanyId);
          }

          Set<String> departmentCompanyIds = <String>{};
          final department = category['department'];
          if (department is Map) {
            final deptMap = Map<String, dynamic>.from(department);
            departmentCompanyIds = _collectRelationIds(deptMap['company']);
          }

          // Legacy fallback: only when category has no direct company.
          return departmentCompanyIds.contains(normalizedCompanyId);
        })
        .toList(growable: false);
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
    final categoryDisplayName = categoryName.toUpperCase();
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
                    categoryDisplayName,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.left,
                    style: const TextStyle(
                      fontSize: 14,
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
    final showBlockingLoader = _isLoading && visibleCategories.isEmpty;
    return Column(
      children: [
        _buildHomeHeader(),
        if (_isLoading && visibleCategories.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: LinearProgressIndicator(minHeight: 2, color: Colors.black),
          ),
        Expanded(
          child: showBlockingLoader
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
                        onPressed: () => _fetchCategories(forceRefresh: true),
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
                  onRefresh: () => _fetchCategories(forceRefresh: true),
                  child: _buildHomeCategoryGrid(visibleCategories),
                ),
        ),
      ],
    );
  }

  Future<void> _fetchUserData(String token) async {
    try {
      final response = await http.get(
        Uri.parse('https://blackforest4.vseyal.com/api/users/me?depth=2'),
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
        } else if ((user['role'] == 'branch' || user['role'] == 'waiter') &&
            user['branch'] != null &&
            user['branch'] is Map &&
            user['branch']['company'] != null) {
          final comp = user['branch']['company'];
          detectedCompanyId = comp is Map
              ? (comp['id'] ?? comp['_id'] ?? comp[r'$oid'])?.toString()
              : comp.toString();
        }
        if (detectedCompanyId != null && detectedCompanyId.isNotEmpty) {
          await prefs.setString('company_id', detectedCompanyId);
          _branchToCompanyCache[bId ?? ''] = detectedCompanyId;
        }

        if (!mounted) return;

        setState(() {
          _userRole = role;
          _currentUserId = userId;
          _companyId = detectedCompanyId;
          if (bId != null && bId.isNotEmpty) {
            _branchId = bId;
          }
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

  static final Map<String, String> _branchToCompanyCache = {};

  Future<String?> _fetchCompanyIdFromBranch(
    String token,
    String branchId,
  ) async {
    if (_branchToCompanyCache.containsKey(branchId)) {
      return _branchToCompanyCache[branchId];
    }
    try {
      final response = await http.get(
        Uri.parse(
          'https://blackforest4.vseyal.com/api/branches/$branchId?depth=1',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode != 200) return null;
      final branch = jsonDecode(response.body);
      final company = branch['company'];
      String? cId;
      if (company is Map) {
        cId = (company['id'] ?? company['_id'] ?? company['\$oid'])?.toString();
      } else {
        cId = company?.toString();
      }

      if (cId != null && cId.isNotEmpty) {
        _branchToCompanyCache[branchId] = cId;
      }
      return cId;
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

      // 1. Try IP Match and Global Settings first (Fastest)
      try {
        final gRes = await http.get(
          Uri.parse(
            'https://blackforest4.vseyal.com/api/globals/branch-geo-settings',
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

              // Match by stored branchId (Fast Path 2)
              if (branchId != null && locBranchId == branchId) {
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
                if (cId != null) return [cId];
              }

              // Match by IP (Fast Path 3)
              if (deviceIp != null) {
                String? bIpRange = loc['ipAddress']?.toString().trim();
                if (bIpRange != null &&
                    bIpRange.isNotEmpty &&
                    (bIpRange == deviceIp ||
                        _isIpInRange(deviceIp, bIpRange))) {
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
                  if (cId != null) return [cId];
                }
              }
            }
          }
        }
      } catch (e) {
        debugPrint("Error fetching global settings in categories: $e");
      }

      // 2. Fetch GPS Position only if other methods failed
      Position? currentPos;
      if (await _checkLocationPermission()) {
        try {
          // Optimized: Use medium accuracy and a 1.5s timeout.
          currentPos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.medium,
              timeLimit: Duration(milliseconds: 1500),
            ),
          );
        } catch (e) {
          debugPrint("Categories Matching: GPS fetch failed: $e");
        }
      }

      // 3. Fallback to GPS Matching with Global Settings if position obtained
      if (currentPos != null) {
        // We already fetched global settings above, but if we have GPS now, we can scan again
        // Actually, for brevity and performance, if we have GPS, we can just proceed to branch-specific scan
      }

      // 2. Direct fetch by branchId if available (Most reliable for logged-in waiters)
      if (branchId != null) {
        try {
          final bRes = await http.get(
            Uri.parse(
              'https://blackforest4.vseyal.com/api/branches/$branchId?depth=1',
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
            'https://blackforest4.vseyal.com/api/branches?limit=100&depth=1',
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
                final prefs = await SharedPreferences.getInstance();
                final storedBranchId = prefs.getString('branchId');
                if (storedBranchId != bId) {
                  await prefs.setString('branchId', bId);
                  final String? bName = branch['name']?.toString();
                  if (bName != null) {
                    await prefs.setString('branchName', bName);
                  }
                  if (mounted) {
                    setState(() {
                      _branchId = bId;
                    });
                  }
                }

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

  Future<void> _fetchCategories({bool forceRefresh = false}) async {
    setState(() {
      _isLoading = forceRefresh || _categories.isEmpty;
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

      _branchId = (_branchId ?? prefs.getString('branchId') ?? '').trim();
      if (_branchId != null && _branchId!.isEmpty) _branchId = null;

      // 1. Fetch user data only if essential metadata (role, company) is missing
      if (_userRole == null || _userRole!.isEmpty || _companyId == null || _companyId!.isEmpty) {
        final cachedRole = prefs.getString('role');
        final cachedCompanyId = prefs.getString('company_id');
        
        if (cachedRole == null || (cachedCompanyId == null && _branchId == null)) {
          await _fetchUserData(token);
          if (!mounted) return;
        }
      }

      // Refresh from prefs
      _userRole = prefs.getString('role');
      _companyId = prefs.getString('company_id');
      _branchId = (_branchId ?? prefs.getString('branchId') ?? '').trim();
      if (_branchId != null && _branchId!.isEmpty) _branchId = null;

      // 2. Derive company from branch if still missing
      if ((_companyId == null || _companyId!.isEmpty) && _branchId != null) {
        final derivedCompanyId = await _fetchCompanyIdFromBranch(token, _branchId!);
        if (derivedCompanyId != null && derivedCompanyId.isNotEmpty) {
          _companyId = derivedCompanyId;
          await prefs.setString('company_id', derivedCompanyId);
        }
      }


      if (_usesBillingMenuWidgetApi()) {
        final branchId = _branchId;
        if (branchId == null || branchId.isEmpty) {
          const message = 'branch (or branchId) is required';
          if (!mounted) return;
          setState(() {
            if (_categories.isEmpty || forceRefresh) {
              _errorMessage = message;
            }
            _isLoading = false;
          });
          if (_categories.isEmpty || forceRefresh) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text(message)));
          }
          return;
        }
        var scopedCompanyId =
            (_companyId ?? prefs.getString('company_id') ?? '').trim();
        if (scopedCompanyId.isEmpty) {
          final derivedCompanyId = await _fetchCompanyIdFromBranch(
            token,
            branchId,
          );
          if (derivedCompanyId != null && derivedCompanyId.isNotEmpty) {
            scopedCompanyId = derivedCompanyId.trim();
            _companyId = scopedCompanyId;
            await prefs.setString('company_id', scopedCompanyId);
          }
        }
        if (scopedCompanyId.isEmpty) {
          const message = 'Unable to resolve company for the selected branch.';
          if (!mounted) return;
          setState(() {
            if (_categories.isEmpty || forceRefresh) {
              _errorMessage = message;
            }
            _isLoading = false;
          });
          if (_categories.isEmpty || forceRefresh) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text(message)));
          }
          return;
        }

        final cacheKey = 'billing-menu-v2-branch-$branchId';
        if (!forceRefresh) {
          final cachedCategories = _readCategoriesCache(cacheKey);
          final filteredCachedCategories =
              (cachedCategories ?? const <dynamic>[])
                  .whereType<Map>()
                  .map((raw) => Map<String, dynamic>.from(raw))
                  .toList(growable: false);
          final scopedCachedCategories = _filterCategoriesByCompanyDepartment(
            filteredCachedCategories,
            companyId: scopedCompanyId,
            strictCompanyScope: true,
          );
          if (scopedCachedCategories.isNotEmpty) {
            if (!mounted) return;
            setState(() {
              _categories = scopedCachedCategories;
              _isLoading = false;
            });
            // Refresh in background so reopening the screen keeps cache fresh.
            unawaited(
              _fetchBillingMenuCategoriesInternal(
                token: token,
                branchId: branchId,
                cacheKey: cacheKey,
                companyId: scopedCompanyId,
              ),
            );
            return;
          }
        }

        await _fetchBillingMenuCategoriesInternal(
          token: token,
          branchId: branchId,
          cacheKey: cacheKey,
          companyId: scopedCompanyId,
        );
        return;
      }

      String filterQuery = 'where[isBilling][equals]=true';
      // Role-based company filter
      if (_userRole != 'superadmin') {
        String? companyFilter;
        if (_userRole == 'waiter') {
          final branchId = _branchId;
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
          companyFilter = '&where[company][in]=$_companyId';
        } else {
          final storedCompanyId = prefs.getString('company_id');
          if (storedCompanyId != null && storedCompanyId.isNotEmpty) {
            _companyId = storedCompanyId;
            companyFilter = '&where[company][in]=$storedCompanyId';
          }
        }
        if (companyFilter != null) {
          filterQuery += companyFilter;
        }
      }

      if (!forceRefresh) {
        final cachedCategories = _readCategoriesCache(filterQuery);
        final filteredCachedCategories = (cachedCategories ?? const <dynamic>[])
            .whereType<Map>()
            .map((raw) => Map<String, dynamic>.from(raw))
            .toList(growable: false);
        final scopedCachedCategories = _filterCategoriesByCompanyDepartment(
          filteredCachedCategories,
          companyId: _companyId,
          strictCompanyScope: _requiresCompanyScopedCategories,
        );
        if (scopedCachedCategories.isNotEmpty) {
          if (!mounted) return;
          setState(() {
            _categories = scopedCachedCategories;
            _isLoading = false;
          });
          unawaited(_persistPersistentCategoriesCache(scopedCachedCategories));
          // Background refresh to keep data fresh
          unawaited(_fetchCategoriesInternal(token, filterQuery));
          return;
        }
      }

      if (_categories.isEmpty) {
        setState(() {
          _isLoading = true;
          _errorMessage = '';
        });
      } else {
        setState(() {
          _isLoading = false;
          _errorMessage = '';
        });
      }

      await _fetchCategoriesInternal(token, filterQuery);
    } catch (e) {
      if (!mounted) return;
      if (_categories.isEmpty) {
        setState(() {
          _errorMessage = 'Network error: Check your internet';
          _isLoading = false;
        });
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error: Check your internet')),
      );
    }
  }

  String? _extractApiErrorMessage(String responseBody) {
    try {
      final decoded = jsonDecode(responseBody);
      if (decoded is Map && decoded['message'] != null) {
        final message = decoded['message'].toString().trim();
        if (message.isNotEmpty) return message;
      }
    } catch (_) {}
    return null;
  }

  Iterable<List<T>> _chunked<T>(List<T> items, int size) sync* {
    if (size <= 0) {
      yield items;
      return;
    }
    for (var i = 0; i < items.length; i += size) {
      final end = (i + size < items.length) ? i + size : items.length;
      yield items.sublist(i, end);
    }
  }

  Future<List<Map<String, dynamic>>> _hydrateBillingMenuCategoryImages({
    required String token,
    required List<Map<String, dynamic>> categories,
  }) async {
    if (categories.isEmpty) return categories;

    final ids = categories
        .map((row) => row['id']?.toString().trim() ?? '')
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (ids.isEmpty) return categories;

    final docsById = <String, Map<String, dynamic>>{};
    for (final idChunk in _chunked<String>(ids, 60)) {
      final response = await http.get(
        Uri.parse(
          'https://blackforest4.vseyal.com/api/categories?where[id][in]=${idChunk.join(',')}&depth=1&limit=${idChunk.length}',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode != 200) continue;

      final decoded = jsonDecode(response.body);
      final payload = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
      final docs = payload['docs'];
      if (docs is! List) continue;

      for (final rawDoc in docs) {
        if (rawDoc is! Map) continue;
        final doc = Map<String, dynamic>.from(rawDoc);
        final id = doc['id']?.toString().trim() ?? '';
        if (id.isEmpty) continue;
        docsById[id] = doc;
      }
    }

    if (docsById.isEmpty) return categories;

    return categories
        .map((rawCategory) {
          final category = Map<String, dynamic>.from(rawCategory);
          final id = category['id']?.toString().trim() ?? '';
          final doc = docsById[id];
          if (doc == null) return category;

          category['image'] ??= doc['image'];
          category['imageUrl'] ??= doc['imageUrl'];
          category['thumbnail'] ??= doc['thumbnail'];
          if (doc['company'] != null) {
            category['company'] = doc['company'];
          }
          if (doc['department'] != null) {
            category['department'] = doc['department'];
          }
          return category;
        })
        .toList(growable: false);
  }

  Future<void> _fetchBillingMenuCategoriesInternal({
    required String token,
    required String branchId,
    required String cacheKey,
    required String companyId,
  }) async {
    try {
      final response = await http.get(
        Uri.parse(
          'https://blackforest4.vseyal.com/api/widgets/billing-menu',
        ).replace(
          queryParameters: <String, String>{
            'mode': 'categories',
            'branch': branchId,
            'limit': '250',
          },
        ),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final payload = decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : <String, dynamic>{};
        final rawCategories = payload['categories'];
        final categories = rawCategories is List
            ? rawCategories
                  .whereType<Map>()
                  .map((raw) => Map<String, dynamic>.from(raw))
                  .toList(growable: false)
            : <Map<String, dynamic>>[];

        final hydratedCategories = categories;
        final filteredCategories = _filterCategoriesByCompanyDepartment(
          hydratedCategories,
          companyId: companyId,
          strictCompanyScope: true,
        );

        if (!mounted) return;
        setState(() {
          _categories = filteredCategories;
          _isLoading = false;
          _errorMessage = '';
        });
        _writeCategoriesCache(cacheKey, filteredCategories);
        return;
      }

      final message =
          _extractApiErrorMessage(response.body) ??
          'Failed to fetch categories: ${response.statusCode}';
      if (!mounted) return;
      if (_categories.isEmpty) {
        setState(() {
          _errorMessage = message;
          _isLoading = false;
        });
      } else {
        setState(() {
          _isLoading = false;
        });
      }
      if (_categories.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (_) {
      if (!mounted) return;
      if (_categories.isEmpty) {
        setState(() {
          _errorMessage = 'Network error: Check your internet';
          _isLoading = false;
        });
      } else {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _fetchCategoriesInternal(
    String token,
    String filterQuery,
  ) async {
    try {
      final response = await http.get(
        Uri.parse(
          'https://blackforest4.vseyal.com/api/categories?$filterQuery&limit=100&depth=1',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        if (!mounted) return;
        final docs = (data['docs'] is List)
            ? (data['docs'] as List)
                  .whereType<Map>()
                  .map((raw) => Map<String, dynamic>.from(raw))
                  .toList(growable: false)
            : <Map<String, dynamic>>[];
        final filteredDocs = _filterCategoriesByCompanyDepartment(
          docs,
          companyId: _companyId,
          strictCompanyScope: _requiresCompanyScopedCategories,
        );
        setState(() {
          _categories = filteredDocs;
          _isLoading = false;
        });
        _writeCategoriesCache(filterQuery, filteredDocs);
        unawaited(_persistPersistentCategoriesCache(filteredDocs));

        // Keep aggressive prefetch only for home flow; billing/table should
        // prioritize tap responsiveness over bulk background traffic.
        if (_isHomeMode && _companyId != null && _companyId!.isNotEmpty) {
          unawaited(_prefetchProducts(token, _companyId!, _branchId));
        }
      } else {
        if (!mounted) return;
        if (_categories.isEmpty) {
          setState(() {
            _errorMessage =
                'Failed to fetch categories: ${response.statusCode}';
          });
        }
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      if (_categories.isEmpty) {
        setState(() {
          _errorMessage = 'Network error: Check your internet';
        });
      }
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _prefetchProducts(
    String token,
    String companyId,
    String? branchId,
  ) async {
    try {
      // 1. Prioritize visible categories for immediate first taps.
      final topCats = _categories.take(12).toList();
      for (final cat in topCats) {
        final catId = (cat['id'] ?? cat['_id'] ?? cat[r'$oid'])?.toString();
        if (catId != null) {
          unawaited(_prefetchSingleCategory(token, catId, branchId));
        }
      }

      // 2. Perform paginated bulk pre-fetch for the entire company.
      debugPrint(
        "🚀 Starting paginated bulk pre-fetch for company: $companyId",
      );
      final products = await _fetchAllCompanyProductsForCache(token, companyId);
      if (products.isNotEmpty) {
        ProductsPage.bulkCacheProducts(products, branchId);
        debugPrint(
          "✅ Bulk pre-fetched ${products.length} products for company $companyId",
        );
      }
    } catch (e) {
      debugPrint("⚠️ Background bulk pre-fetch skipped or timed out: $e");
    }
  }

  Future<List<dynamic>> _fetchAllCompanyProductsForCache(
    String token,
    String companyId,
  ) async {
    const pageSize = 500;
    const maxPages = 8; // Up to 4000 products cached in background.
    final allProducts = <dynamic>[];

    for (var page = 1; page <= maxPages; page++) {
      final url =
          'https://blackforest4.vseyal.com/api/products?where[company][equals]=$companyId&limit=$pageSize&page=$page&depth=1';
      final response = await http
          .get(Uri.parse(url), headers: {'Authorization': 'Bearer $token'})
          .timeout(const Duration(seconds: 18));
      if (response.statusCode != 200) break;

      final data = jsonDecode(response.body);
      final docs = data['docs'];
      if (docs is! List || docs.isEmpty) break;
      allProducts.addAll(docs);

      final totalPagesRaw = data['totalPages'];
      final totalPages = totalPagesRaw is num
          ? totalPagesRaw.toInt()
          : int.tryParse(totalPagesRaw?.toString() ?? '');
      if (totalPages != null && page >= totalPages) break;
      if (docs.length < pageSize) break;
    }

    return allProducts;
  }

  Future<void> _prefetchSingleCategory(
    String token,
    String categoryId,
    String? branchId,
  ) async {
    try {
      final useBillingMenuApi = _usesBillingMenuWidgetApi();
      if (useBillingMenuApi && (branchId == null || branchId.trim().isEmpty)) {
        return;
      }
      final response = await (useBillingMenuApi
          ? http.get(
              Uri.parse(
                'https://blackforest4.vseyal.com/api/widgets/billing-menu',
              ).replace(
                queryParameters: <String, String>{
                  'mode': 'products',
                  'branch': branchId!.trim(),
                  'categoryId': categoryId.trim(),
                  'limit': '250',
                },
              ),
              headers: {'Authorization': 'Bearer $token'},
            )
          : http.get(
              Uri.parse(
                'https://blackforest4.vseyal.com/api/products?where[category][equals]=$categoryId&limit=250&depth=1',
              ),
              headers: {'Authorization': 'Bearer $token'},
            ));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final products = useBillingMenuApi
            ? data['products'] ?? []
            : data['docs'] ?? [];
        if (products is List) {
          ProductsPage.writeProductsCache(categoryId, branchId, products);
          debugPrint("⚡ Pre-fetched category $categoryId individually");
        }
      }
    } catch (_) {}
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
          'https://blackforest4.vseyal.com/api/products?where[upc][equals]=$scanResult&limit=1&depth=1',
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
          final tableSection = cartProvider.currentType == CartType.table
              ? cartProvider.selectedSection
              : null;
          final price = CartItem.resolveProductPrice(
            product,
            branchId: branchId,
            tableSection: tableSection,
          );
          final item = CartItem.fromProduct(
            product,
            1,
            branchPrice: price,
            branchId: branchId,
            tableSection: tableSection,
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
          'Table: ${cartProvider.selectedTable!.split('-S-').first} (${cartProvider.selectedSection})';
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
              onRefresh: () => _fetchCategories(forceRefresh: true),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final orderedCategories = _orderedCategories();
                  final width = constraints.maxWidth;
                  final crossAxisCount = (width > 600) ? 5 : 3;
                  final showBlockingLoader =
                      _isLoading && orderedCategories.isEmpty;

                  return CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            vertical: _hasOfferBanner ? 10 : 0,
                          ),
                          child: OfferBanner(
                            height: 156,
                            showIndicators: false,
                            showLoadingIndicator: false,
                            onHasOffersChanged: (hasOffers) {
                              if (!mounted || _hasOfferBanner == hasOffers) {
                                return;
                              }
                              setState(() {
                                _hasOfferBanner = hasOffers;
                              });
                            },
                            itemMargin: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 4,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
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
                      if (_isLoading && orderedCategories.isNotEmpty)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 6,
                            ),
                            child: LinearProgressIndicator(
                              minHeight: 2,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      if (showBlockingLoader)
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
                                  onPressed: () =>
                                      _fetchCategories(forceRefresh: true),
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
                              final categoryDisplayName = categoryName
                                  .toUpperCase();
                              final isFavorite = _favoriteCategoryIds.contains(
                                categoryId,
                              );

                              String? imageUrl = _resolveCategoryImageUrl(
                                category,
                              );
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
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 4,
                                                    ),
                                                child: Text(
                                                  categoryDisplayName,
                                                  textAlign: TextAlign.center,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 12.5,
                                                    height: 1.0,
                                                  ),
                                                ),
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
