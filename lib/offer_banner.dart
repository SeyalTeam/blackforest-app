import 'dart:async';
import 'dart:convert';

import 'package:blackforest_app/app_http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OfferBanner extends StatefulWidget {
  final double height;
  final double viewportFraction;
  final bool showIndicators;
  final EdgeInsetsGeometry itemMargin;
  final BorderRadiusGeometry borderRadius;
  final bool showShadow;
  final EdgeInsetsGeometry contentPadding;
  final Color activeIndicatorColor;
  final Color inactiveIndicatorColor;
  final Color loadingIndicatorColor;
  final double indicatorBottomOffset;
  final double mediaSize;
  final bool useCenteredValueLayout;
  final EdgeInsetsGeometry? valueOfferPadding;
  final double? valueOfferVisualSize;
  final double regularTitleFontSize;
  final double regularSubtitleFontSize;
  final double compactTitleFontSize;
  final double compactSubtitleFontSize;
  final int regularSubtitleMaxLines;
  final int compactSubtitleMaxLines;
  final TextOverflow regularSubtitleOverflow;
  final TextOverflow compactSubtitleOverflow;

  const OfferBanner({
    super.key,
    this.height = 200,
    this.viewportFraction = 1,
    this.showIndicators = true,
    this.itemMargin = const EdgeInsets.fromLTRB(0, 4, 0, 6),
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.showShadow = true,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 20,
      vertical: 16,
    ),
    this.activeIndicatorColor = Colors.white,
    this.inactiveIndicatorColor = const Color(0x73FFFFFF),
    this.loadingIndicatorColor = Colors.black,
    this.indicatorBottomOffset = 14,
    this.mediaSize = 110,
    this.useCenteredValueLayout = true,
    this.valueOfferPadding,
    this.valueOfferVisualSize,
    this.regularTitleFontSize = 19,
    this.regularSubtitleFontSize = 13,
    this.compactTitleFontSize = 18,
    this.compactSubtitleFontSize = 12,
    this.regularSubtitleMaxLines = 2,
    this.compactSubtitleMaxLines = 2,
    this.regularSubtitleOverflow = TextOverflow.ellipsis,
    this.compactSubtitleOverflow = TextOverflow.ellipsis,
  });

  @override
  State<OfferBanner> createState() => _OfferBannerState();
}

class _CachedOfferBannerData {
  final List<Map<String, dynamic>> offers;
  final DateTime fetchedAt;

  const _CachedOfferBannerData({required this.offers, required this.fetchedAt});

  bool isFresh(Duration ttl) => DateTime.now().difference(fetchedAt) <= ttl;
}

class _OfferBannerState extends State<OfferBanner> {
  static const Duration _cacheTtl = Duration(hours: 24);
  static const Duration _metadataCheckDebounce = Duration(minutes: 2);
  static const String _settingsBodyCacheKey =
      'offer_banner_settings_body_cache_v1';
  static const String _settingsFetchedAtCacheKey =
      'offer_banner_settings_fetched_at_cache_v1';
  static const String _settingsUpdatedAtCacheKey =
      'offer_banner_settings_updated_at_cache_v1';

  static _CachedOfferBannerData? _memoryCache;
  static DateTime? _lastMetadataCheckAt;
  static bool _isMetadataCheckRunning = false;
  static final Map<String, String> _mediaUrlById = <String, String>{};
  static const List<Color> _bannerPalette = <Color>[
    Color(0xFFFF8C42),
    Color(0xFF4D6CFA),
    Color(0xFF0FA67A),
    Color(0xFFE95480),
    Color(0xFF00A8C6),
    Color(0xFF8F5CF7),
    Color(0xFFD99500),
    Color(0xFFEF5350),
    Color(0xFF26A69A),
    Color(0xFF7E57C2),
  ];

  List<Map<String, dynamic>> _offers = <Map<String, dynamic>>[];
  bool _isLoading = true;
  late final PageController _pageController;
  Timer? _timer;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(
      initialPage: 0,
      viewportFraction: widget.viewportFraction,
    );
    _bootstrapOffers();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _bootstrapOffers() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');

    if (token == null || token.isEmpty) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      return;
    }

    final cached = _loadCachedOffers(prefs);
    if (cached != null) {
      _applyOffers(cached.offers);
      unawaited(_hydrateCurrentOffersWithMedia(token: token));

      unawaited(
        _checkForRemoteUpdates(token: token, prefs: prefs, cached: cached),
      );
      return;
    }

    await _refreshOffersFromServer(
      token: token,
      prefs: prefs,
      showLoadingIfEmpty: true,
    );
  }

  _CachedOfferBannerData? _loadCachedOffers(SharedPreferences prefs) {
    if (_memoryCache != null) {
      return _memoryCache;
    }

    final cachedBody = prefs.getString(_settingsBodyCacheKey);
    final cachedAtMs = prefs.getInt(_settingsFetchedAtCacheKey);

    if (cachedBody == null || cachedAtMs == null) {
      return null;
    }

    try {
      final settings = jsonDecode(cachedBody) as Map<String, dynamic>;
      final offers = _buildOffersFromSettings(settings);
      final data = _CachedOfferBannerData(
        offers: offers,
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(cachedAtMs),
      );
      _memoryCache = data;
      return data;
    } catch (_) {
      return null;
    }
  }

  String? _extractUpdatedAt(Map<String, dynamic> payload) {
    final updatedAt = payload['updatedAt'];
    if (updatedAt == null) return null;
    final value = updatedAt.toString().trim();
    if (value.isEmpty) return null;
    return value;
  }

  Future<void> _checkForRemoteUpdates({
    required String token,
    required SharedPreferences prefs,
    required _CachedOfferBannerData cached,
  }) async {
    final now = DateTime.now();

    if (_isMetadataCheckRunning) return;

    if (_lastMetadataCheckAt != null &&
        now.difference(_lastMetadataCheckAt!) < _metadataCheckDebounce) {
      if (!cached.isFresh(_cacheTtl)) {
        await _refreshOffersFromServer(
          token: token,
          prefs: prefs,
          showLoadingIfEmpty: false,
        );
      }
      return;
    }

    _isMetadataCheckRunning = true;
    _lastMetadataCheckAt = now;

    try {
      final metadataResponse = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/globals/customer-offer-settings?depth=0',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (metadataResponse.statusCode != 200) {
        if (!cached.isFresh(_cacheTtl)) {
          await _refreshOffersFromServer(
            token: token,
            prefs: prefs,
            showLoadingIfEmpty: false,
          );
        }
        return;
      }

      final metadata =
          jsonDecode(metadataResponse.body) as Map<String, dynamic>;
      final remoteUpdatedAt = _extractUpdatedAt(metadata);
      final cachedUpdatedAt = prefs.getString(_settingsUpdatedAtCacheKey);

      final shouldRefresh = remoteUpdatedAt == null
          ? !cached.isFresh(_cacheTtl)
          : (cachedUpdatedAt == null || cachedUpdatedAt != remoteUpdatedAt);

      if (shouldRefresh) {
        await _refreshOffersFromServer(
          token: token,
          prefs: prefs,
          showLoadingIfEmpty: false,
          expectedUpdatedAt: remoteUpdatedAt,
        );
      }
    } catch (error) {
      debugPrint('OfferBanner: metadata check error: $error');
      if (!cached.isFresh(_cacheTtl)) {
        await _refreshOffersFromServer(
          token: token,
          prefs: prefs,
          showLoadingIfEmpty: false,
        );
      }
    } finally {
      _isMetadataCheckRunning = false;
    }
  }

  Future<void> _refreshOffersFromServer({
    required String token,
    required SharedPreferences prefs,
    required bool showLoadingIfEmpty,
    String? expectedUpdatedAt,
  }) async {
    final start = DateTime.now();

    try {
      final response = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/globals/customer-offer-settings?depth=1',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode != 200) {
        if (!mounted) return;
        if (showLoadingIfEmpty && _offers.isEmpty) {
          setState(() {
            _isLoading = false;
          });
        }
        return;
      }

      final settings = jsonDecode(response.body) as Map<String, dynamic>;
      final offers = _buildOffersFromSettings(settings);
      final hydratedOffers = await _hydrateMissingOfferImages(
        offers: offers,
        token: token,
      );
      final fetchedAt = DateTime.now();
      final updatedAt = _extractUpdatedAt(settings) ?? expectedUpdatedAt;

      _memoryCache = _CachedOfferBannerData(
        offers: hydratedOffers,
        fetchedAt: fetchedAt,
      );

      unawaited(prefs.setString(_settingsBodyCacheKey, response.body));
      unawaited(
        prefs.setInt(
          _settingsFetchedAtCacheKey,
          fetchedAt.millisecondsSinceEpoch,
        ),
      );
      if (updatedAt != null) {
        unawaited(prefs.setString(_settingsUpdatedAtCacheKey, updatedAt));
      }

      _applyOffers(hydratedOffers);
      _precacheFirstImage(hydratedOffers);

      debugPrint(
        'OfferBanner: network refresh done in '
        '${DateTime.now().difference(start).inMilliseconds}ms, offers=${hydratedOffers.length}',
      );
    } catch (error) {
      debugPrint('OfferBanner: refresh error: $error');
      if (!mounted) return;
      if (showLoadingIfEmpty && _offers.isEmpty) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _applyOffers(List<Map<String, dynamic>> offers) {
    if (!mounted) return;

    final cloned = offers
        .map((offer) => Map<String, dynamic>.from(offer))
        .toList(growable: false);

    setState(() {
      _offers = cloned;
      _isLoading = false;

      if (_currentPage >= _offers.length) {
        _currentPage = 0;
      }
    });

    if (_offers.length > 1) {
      _startAutoScroll();
    } else {
      _timer?.cancel();
    }

    _precacheFirstImage(_offers);
  }

  Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map((key, val) => MapEntry(key.toString(), val));
    }
    return null;
  }

  double _asDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value) ?? 0;
    }
    return 0;
  }

  String? _normalizeImageUrl(String? rawUrl) {
    if (rawUrl == null) return null;
    final url = rawUrl.trim();
    if (url.isEmpty) return null;
    if (url.startsWith('/')) {
      return 'https://blackforest.vseyal.com$url';
    }
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
    return null;
  }

  String? _getPrimaryImageMediaId(dynamic product) {
    final productMap = _asMap(product);
    if (productMap == null) return null;

    final images = productMap['images'];
    if (images is! List || images.isEmpty) return null;

    final firstImage = images.first;
    dynamic imageData;
    if (firstImage is Map) {
      imageData = firstImage['image'] ?? firstImage;
    } else {
      imageData = firstImage;
    }

    if (imageData is String) {
      final value = imageData.trim();
      if (value.isEmpty) return null;
      if (_normalizeImageUrl(value) != null) {
        return null;
      }
      return value;
    }

    if (imageData is Map) {
      final id = imageData['id']?.toString().trim();
      if (id != null && id.isNotEmpty) return id;
    }

    return null;
  }

  Future<List<Map<String, dynamic>>> _hydrateMissingOfferImages({
    required List<Map<String, dynamic>> offers,
    required String token,
  }) async {
    final hydrated = offers
        .map((offer) => Map<String, dynamic>.from(offer))
        .toList(growable: false);

    final missingMediaIds = <String>{};
    for (final offer in hydrated) {
      final existingImage = offer['image']?.toString();
      if (existingImage != null && existingImage.trim().isNotEmpty) {
        continue;
      }
      final mediaId = offer['imageMediaId']?.toString().trim();
      if (mediaId == null || mediaId.isEmpty) continue;

      final cachedUrl = _mediaUrlById[mediaId];
      if (cachedUrl != null && cachedUrl.isNotEmpty) {
        offer['image'] = cachedUrl;
      } else {
        missingMediaIds.add(mediaId);
      }
    }

    if (missingMediaIds.isEmpty) {
      return hydrated;
    }

    try {
      final response = await http.get(
        Uri.parse('https://blackforest.vseyal.com/api/media').replace(
          queryParameters: <String, String>{
            'where[id][in]': missingMediaIds.join(','),
            'limit': missingMediaIds.length.toString(),
            'depth': '0',
          },
        ),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final payload = jsonDecode(response.body);
        final docsRaw = (payload is Map<String, dynamic>)
            ? payload['docs']
            : null;
        final docs = docsRaw is List ? docsRaw : const <dynamic>[];
        for (final rawDoc in docs) {
          final doc = _asMap(rawDoc);
          if (doc == null) continue;
          final id = doc['id']?.toString();
          if (id == null || id.isEmpty) continue;
          final url =
              _normalizeImageUrl(doc['thumbnailURL']?.toString()) ??
              _normalizeImageUrl(doc['url']?.toString());
          if (url == null) continue;
          _mediaUrlById[id] = url;
        }
      }
    } catch (error) {
      debugPrint('OfferBanner: media hydration error: $error');
    }

    for (final offer in hydrated) {
      final existingImage = offer['image']?.toString();
      if (existingImage != null && existingImage.trim().isNotEmpty) {
        continue;
      }
      final mediaId = offer['imageMediaId']?.toString().trim();
      if (mediaId == null || mediaId.isEmpty) continue;
      final resolvedUrl = _mediaUrlById[mediaId];
      if (resolvedUrl != null && resolvedUrl.isNotEmpty) {
        offer['image'] = resolvedUrl;
      }
    }

    return hydrated;
  }

  Future<void> _hydrateCurrentOffersWithMedia({required String token}) async {
    if (_offers.isEmpty) return;

    final hydrated = await _hydrateMissingOfferImages(
      offers: _offers,
      token: token,
    );

    bool changed = false;
    for (var i = 0; i < hydrated.length && i < _offers.length; i++) {
      final before = _offers[i]['image']?.toString() ?? '';
      final after = hydrated[i]['image']?.toString() ?? '';
      if (before != after) {
        changed = true;
        break;
      }
    }

    if (!mounted || !changed) return;

    setState(() {
      _offers = hydrated;
    });
    _precacheFirstImage(_offers);
  }

  List<Map<String, dynamic>> _buildOffersFromSettings(
    Map<String, dynamic> settings,
  ) {
    final collectedOffers = <Map<String, dynamic>>[];

    final productToProductOffers = settings['productToProductOffers'];
    if (settings['enableProductToProductOffer'] == true &&
        productToProductOffers is List) {
      for (final raw in productToProductOffers) {
        final offer = _asMap(raw);
        if (offer == null || offer['enabled'] != true) continue;

        final buyProduct = _asMap(offer['buyProduct']);
        final freeProduct = _asMap(offer['freeProduct']);

        final buyName = buyProduct?['name']?.toString() ?? 'Item';
        final freeName = freeProduct?['name']?.toString() ?? 'Item';
        final buyQty = offer['buyQuantity'] ?? 1;
        final freeQty = offer['freeQuantity'] ?? 1;

        String titleText;
        if (buyProduct != null &&
            freeProduct != null &&
            buyProduct['id'] != null &&
            buyProduct['id'] == freeProduct['id']) {
          titleText = 'Buy $buyQty Get $freeQty FREE on $buyName';
        } else {
          titleText = 'Buy $buyQty $buyName & Get $freeQty $freeName FREE';
        }
        final offerImageUrl = _getImageUrl(freeProduct);
        final offerImageMediaId = _getPrimaryImageMediaId(freeProduct);

        collectedOffers.add({
          'type': 'Buy X Get Y',
          'title': titleText,
          'subtitle': 'Special combo offer just for you!',
          'image': offerImageUrl,
          'imageMediaId': offerImageMediaId,
          'color': Colors.orangeAccent,
        });
      }
    }

    final productPriceOffers = settings['productPriceOffers'];
    if (settings['enableProductPriceOffer'] == true &&
        productPriceOffers is List) {
      for (final raw in productPriceOffers) {
        final offer = _asMap(raw);
        if (offer == null || offer['enabled'] != true) continue;

        final product = _asMap(offer['product']);
        if (product == null) continue;

        final productName = product['name']?.toString() ?? 'Unknown Product';
        final originalPrice = _asDouble(
          product['defaultPriceDetails']?['price'],
        );

        double finalPrice = _asDouble(
          offer['offerPrice'] ??
              offer['priceAfterDiscount'] ??
              offer['effectiveUnitPrice'],
        );

        final discountAmount = _asDouble(
          offer['discountPerUnit'] ??
              offer['offerAmount'] ??
              offer['discountAmount'] ??
              offer['discount'],
        );

        if (finalPrice <= 0 && originalPrice > 0 && discountAmount > 0) {
          finalPrice = originalPrice - discountAmount;
        }

        final effectiveDiscount = originalPrice - finalPrice;
        final offerImageUrl = _getImageUrl(product);
        final offerImageMediaId = _getPrimaryImageMediaId(product);

        collectedOffers.add({
          'type': 'Special Price',
          'title': '$productName at ₹${finalPrice.toStringAsFixed(0)}',
          'subtitle': effectiveDiscount > 0
              ? 'Was ₹${originalPrice.toStringAsFixed(0)} | Save ₹${effectiveDiscount.toStringAsFixed(0)}'
              : 'Exclusive Deal!',
          'image': offerImageUrl,
          'imageMediaId': offerImageMediaId,
          'color': Colors.deepPurpleAccent,
        });
      }
    }

    final randomOffers = settings['randomCustomerOfferProducts'];
    if (settings['enableRandomCustomerProductOffer'] == true &&
        randomOffers is List) {
      for (final raw in randomOffers) {
        final offer = _asMap(raw);
        if (offer == null || offer['enabled'] != true) continue;

        final product = _asMap(offer['product']);
        final productName = product?['name']?.toString() ?? 'Product';
        final offerImageUrl = _getImageUrl(product);
        final offerImageMediaId = _getPrimaryImageMediaId(product);

        collectedOffers.add({
          'type': 'Lucky Offer',
          'title': 'FREE $productName?',
          'subtitle': 'You might be our lucky winner today!',
          'image': offerImageUrl,
          'imageMediaId': offerImageMediaId,
          'color': Colors.teal,
        });
      }
    }

    if (settings['enableTotalPercentageOffer'] == true) {
      final percent = settings['totalPercentageOfferPercent'] ?? 0;
      collectedOffers.add({
        'type': 'Flat Discount',
        'title': '$percent% OFF on Total Bill',
        'subtitle': 'Enjoy big savings on your order',
        'image': null,
        'valueText': '$percent%',
        'icon': Icons.percent,
        'color': Colors.pinkAccent,
      });
    }

    if (settings['enableCustomerEntryPercentageOffer'] == true) {
      final percent = settings['customerEntryPercentageOfferPercent'] ?? 0;
      collectedOffers.add({
        'type': 'Sign-up Bonus',
        'title': '$percent% OFF for New Customers',
        'subtitle': 'Provide your details to unlock this offer',
        'image': null,
        'valueText': '$percent%',
        'icon': Icons.person_add,
        'color': Colors.indigoAccent,
      });
    }

    if (settings['enabled'] == true &&
        settings['offerAmount'] != null &&
        _asDouble(settings['offerAmount']) > 0) {
      final spend = settings['spendAmountPerStep'] ?? 0;
      final pts = settings['pointsPerStep'] ?? 0;
      final needed = settings['pointsNeededForOffer'] ?? 0;
      final reward = settings['offerAmount'] ?? 0;

      collectedOffers.add({
        'type': 'Loyalty Rewards',
        'title': 'Earn ₹$reward Cashback!',
        'subtitle': 'Spend ₹$spend = $pts Points | Reach $needed pts',
        'image': null,
        'valueText': '₹$reward',
        'icon': Icons.account_balance_wallet,
        'color': Colors.amber.shade700,
      });
    }

    for (int i = 0; i < collectedOffers.length; i++) {
      collectedOffers[i]['color'] = _bannerPalette[i % _bannerPalette.length];
    }

    return collectedOffers;
  }

  String? _getImageUrl(dynamic product) {
    final productMap = _asMap(product);
    if (productMap == null) return null;

    final images = productMap['images'];
    if (images is! List || images.isEmpty) return null;

    final firstImage = images.first;
    dynamic imageData;
    if (firstImage is Map) {
      imageData = firstImage['image'] ?? firstImage;
    } else {
      imageData = firstImage;
    }

    String? url;
    if (imageData is String) {
      final raw = imageData.trim();
      url = _normalizeImageUrl(raw);
      if (url == null && raw.isNotEmpty) {
        url = _mediaUrlById[raw];
      }
    } else if (imageData is Map) {
      url =
          _normalizeImageUrl(imageData['thumbnailURL']?.toString()) ??
          _normalizeImageUrl(imageData['url']?.toString());
      if (url == null) {
        final id = imageData['id']?.toString().trim();
        if (id != null && id.isNotEmpty) {
          url = _mediaUrlById[id];
        }
      }
    }

    if (url == null || url.isEmpty) return null;
    return _normalizeImageUrl(url);
  }

  void _precacheFirstImage(List<Map<String, dynamic>> offers) {
    if (!mounted || offers.isEmpty) return;
    final imageUrl = offers.first['image'];
    if (imageUrl is! String || imageUrl.isEmpty) return;

    unawaited(
      precacheImage(CachedNetworkImageProvider(imageUrl), context).catchError((
        _,
      ) {
        // Ignore cache warm-up failures
      }),
    );
  }

  void _startAutoScroll() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 4), (timer) {
      if (!_pageController.hasClients || _offers.isEmpty) {
        return;
      }
      _currentPage = (_currentPage + 1) % _offers.length;
      _pageController.animateToPage(
        _currentPage,
        duration: const Duration(milliseconds: 800),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return SizedBox(
        height: widget.height,
        child: Center(
          child: CircularProgressIndicator(color: widget.loadingIndicatorColor),
        ),
      );
    }

    if (_offers.isEmpty) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      height: widget.height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            controller: _pageController,
            onPageChanged: (index) {
              setState(() {
                _currentPage = index;
              });
            },
            itemCount: _offers.length,
            itemBuilder: (context, index) {
              final offer = _offers[index];
              return _buildBannerItem(offer);
            },
          ),
          if (widget.showIndicators && _offers.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: widget.indicatorBottomOffset,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  _offers.length,
                  (index) => AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: _currentPage == index ? 18 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _currentPage == index
                          ? widget.activeIndicatorColor
                          : widget.inactiveIndicatorColor,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBannerItem(Map<String, dynamic> offer) {
    final isValueOffer = offer['image'] == null && offer['valueText'] != null;
    final useCenteredValueLayout =
        widget.useCenteredValueLayout && isValueOffer;
    final valueOfferPadding =
        (widget.valueOfferPadding ?? const EdgeInsets.fromLTRB(22, 174, 22, 18))
            .resolve(Directionality.of(context));
    final valueOfferVisualSize =
        widget.valueOfferVisualSize ?? (widget.mediaSize - 24);
    return Container(
      margin: widget.itemMargin,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            offer['color'] as Color,
            Color.lerp(offer['color'] as Color, Colors.black, 0.4)!,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: widget.borderRadius,
        boxShadow: widget.showShadow
            ? [
                BoxShadow(
                  color: (offer['color'] as Color).withValues(alpha: 0.4),
                  blurRadius: 15,
                  offset: const Offset(0, 8),
                ),
              ]
            : const [],
      ),
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: Stack(
          children: [
            Positioned(
              top: -50,
              right: -20,
              child: Container(
                width: 150,
                height: 150,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.1),
                ),
              ),
            ),
            Positioned(
              bottom: -40,
              left: -30,
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.05),
                ),
              ),
            ),
            Positioned(
              right: 10,
              bottom: -20,
              child: Icon(
                offer['icon'] as IconData? ?? Icons.local_offer,
                size: 140,
                color: Colors.white.withValues(alpha: 0.08),
              ),
            ),
            Padding(
              padding: useCenteredValueLayout
                  ? valueOfferPadding
                  : widget.contentPadding,
              child: useCenteredValueLayout
                  ? Column(
                      mainAxisSize: MainAxisSize.max,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        _buildOfferTextContent(
                          offer,
                          centered: true,
                          compact: true,
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: Center(
                            child: _buildOfferVisual(
                              offer,
                              size: valueOfferVisualSize,
                            ),
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(child: _buildOfferTextContent(offer)),
                        const SizedBox(width: 8),
                        _buildOfferVisual(offer),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOfferTextContent(
    Map<String, dynamic> offer, {
    bool centered = false,
    bool compact = false,
  }) {
    final badgeVerticalPadding = compact ? 2.0 : 3.0;
    final badgeFontSize = compact ? 9.0 : 10.0;
    final badgeGap = compact ? 8.0 : 10.0;
    final subtitleGap = compact ? 4.0 : 6.0;
    final titleFontSize = compact
        ? widget.compactTitleFontSize
        : widget.regularTitleFontSize;
    final subtitleFontSize = compact
        ? widget.compactSubtitleFontSize
        : widget.regularSubtitleFontSize;
    final subtitleMaxLines = compact
        ? widget.compactSubtitleMaxLines
        : widget.regularSubtitleMaxLines;
    final subtitleOverflow = compact
        ? widget.compactSubtitleOverflow
        : widget.regularSubtitleOverflow;
    return Column(
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        Align(
          alignment: centered ? Alignment.center : Alignment.centerLeft,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: 10,
              vertical: badgeVerticalPadding,
            ),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  offer['icon'] as IconData? ?? Icons.bolt,
                  color: Colors.white,
                  size: 12,
                ),
                const SizedBox(width: 4),
                Text(
                  (offer['type']?.toString() ?? '').toUpperCase(),
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: badgeFontSize,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(height: badgeGap),
        Text(
          offer['title']?.toString() ?? '',
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: TextStyle(
            color: Colors.white,
            fontSize: titleFontSize,
            fontWeight: FontWeight.w900,
            height: 1.05,
            letterSpacing: -0.2,
            shadows: [
              Shadow(
                color: Colors.black38,
                offset: Offset(0, 2),
                blurRadius: 4,
              ),
            ],
          ),
          maxLines: centered ? 2 : 3,
        ),
        SizedBox(height: subtitleGap),
        Text(
          offer['subtitle']?.toString() ?? '',
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.85),
            fontSize: subtitleFontSize,
            fontWeight: FontWeight.w500,
            fontStyle: FontStyle.italic,
            height: 1.15,
          ),
          maxLines: subtitleMaxLines,
          overflow: subtitleOverflow,
          softWrap: subtitleMaxLines > 1,
        ),
      ],
    );
  }

  Widget _buildOfferVisual(Map<String, dynamic> offer, {double? size}) {
    final visualSize = size ?? widget.mediaSize;
    return Hero(
      tag: 'offer_${offer['title']}',
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: const Duration(milliseconds: 1000),
        builder: (context, value, child) {
          return Transform.translate(
            offset: Offset(0, -5 * value),
            child: child,
          );
        },
        child: offer['image'] != null
            ? Container(
                width: visualSize,
                height: visualSize,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.2),
                    width: 4,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: CachedNetworkImage(
                    imageUrl: offer['image'] as String,
                    fit: BoxFit.cover,
                    placeholder: (context, url) =>
                        Container(color: Colors.white12),
                    errorWidget: (context, url, error) => const Icon(
                      Icons.image_not_supported,
                      color: Colors.grey,
                      size: 40,
                    ),
                  ),
                ),
              )
            : _buildStylizedFallback(offer, size: visualSize),
      ),
    );
  }

  Widget _buildStylizedFallback(Map<String, dynamic> offer, {double? size}) {
    final visualSize = size ?? widget.mediaSize;
    return SizedBox(
      width: visualSize,
      height: visualSize,
      child: Transform.rotate(
        angle: -0.15,
        child: Center(
          child: offer['valueText'] != null
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      offer['valueText'].toString(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 60,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -3,
                        height: 0.9,
                        shadows: [
                          Shadow(
                            color: Colors.black54,
                            offset: Offset(4, 4),
                            blurRadius: 15,
                          ),
                          Shadow(
                            color: Colors.white24,
                            offset: Offset(-1, -1),
                            blurRadius: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : Icon(
                  offer['icon'] as IconData? ?? Icons.local_offer,
                  color: Colors.white,
                  size: 70,
                  shadows: const [
                    Shadow(
                      color: Colors.black54,
                      offset: Offset(4, 4),
                      blurRadius: 15,
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
