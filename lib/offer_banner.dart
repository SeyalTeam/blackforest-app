import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';

class OfferBanner extends StatefulWidget {
  const OfferBanner({super.key});

  @override
  State<OfferBanner> createState() => _OfferBannerState();
}

class _OfferBannerState extends State<OfferBanner> {
  List<Map<String, dynamic>> _offers = [];
  bool _isLoading = true;
  late PageController _pageController;
  Timer? _timer;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 0, viewportFraction: 0.92);
    _fetchOffers();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _fetchOffers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) return;

      final response = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/globals/customer-offer-settings?depth=2',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final settings = jsonDecode(response.body);
        final List<Map<String, dynamic>> collectedOffers = [];

        // 1. Product to Product Offers
        if (settings['enableProductToProductOffer'] == true &&
            settings['productToProductOffers'] != null) {
          for (var offer in settings['productToProductOffers']) {
            if (offer['enabled'] == true) {
              final buyProduct = offer['buyProduct'];
              final freeProduct = offer['freeProduct'];
              final buyName = buyProduct?['name'] ?? 'Item';
              final freeName = freeProduct?['name'] ?? 'Item';
              final buyQty = offer['buyQuantity'] ?? 1;
              final freeQty = offer['freeQuantity'] ?? 1;

              String titleText;
              if (buyProduct != null &&
                  freeProduct != null &&
                  buyProduct['id'] == freeProduct['id']) {
                // Same product: "Buy 1 Get 1 Free on Pista Kunafa"
                titleText = 'Buy $buyQty Get $freeQty FREE on $buyName';
              } else {
                // Different products: "Buy Cake Get 1 Coke FREE"
                titleText =
                    'Buy $buyQty $buyName & Get $freeQty $freeName FREE';
              }

              collectedOffers.add({
                'type': 'Buy X Get Y',
                'title': titleText,
                'subtitle': 'Special combo offer just for you!',
                'image': _getImageUrl(freeProduct),
                'color': Colors.orangeAccent,
              });
            }
          }
        }

        // 2. Product Price Offers
        if (settings['enableProductPriceOffer'] == true &&
            settings['productPriceOffers'] != null) {
          final priceOffers = (settings['productPriceOffers'] as List);
          for (var offer in priceOffers) {
            final product = offer['product'];
            if (offer['enabled'] == true && product != null) {
              final productName = product['name'] ?? 'Unknown Product';
              final originalPrice =
                  (product['defaultPriceDetails']?['price'] ?? 0).toDouble();

              // Handle both direct offer price or a discount amount
              double finalPrice =
                  (offer['offerPrice'] ??
                          offer['priceAfterDiscount'] ??
                          offer['effectiveUnitPrice'] ??
                          0)
                      .toDouble();

              final discountAmount =
                  (offer['discountPerUnit'] ??
                          offer['offerAmount'] ??
                          offer['discountAmount'] ??
                          offer['discount'] ??
                          0)
                      .toDouble();

              // If offerPrice is not set but discount is, calculate finalPrice
              if (finalPrice <= 0 && originalPrice > 0 && discountAmount > 0) {
                finalPrice = originalPrice - discountAmount;
              }

              // If only finalPrice is set, calculate the relative discount for the subtitle
              final effectiveDiscount = originalPrice - finalPrice;

              collectedOffers.add({
                'type': 'Special Price',
                'title': '$productName at ₹${finalPrice.toStringAsFixed(0)}',
                'subtitle': effectiveDiscount > 0
                    ? 'Was ₹${originalPrice.toStringAsFixed(0)} | Save ₹${effectiveDiscount.toStringAsFixed(0)}'
                    : 'Exclusive Deal!',
                'image': _getImageUrl(product),
                'color': Colors.deepPurpleAccent,
              });
            }
          }
        }

        // 3. Random Customer Offer
        if (settings['enableRandomCustomerProductOffer'] == true &&
            settings['randomCustomerOfferProducts'] != null) {
          for (var offer in settings['randomCustomerOfferProducts']) {
            if (offer['enabled'] == true) {
              collectedOffers.add({
                'type': 'Lucky Offer',
                'title': 'FREE ${offer['product']['name']}?',
                'subtitle': 'You might be our lucky winner today!',
                'image': _getImageUrl(offer['product']),
                'color': Colors.teal,
              });
            }
          }
        }

        // 4. Total Percentage Offer
        if (settings['enableTotalPercentageOffer'] == true) {
          collectedOffers.add({
            'type': 'Flat Discount',
            'title':
                '${settings['totalPercentageOfferPercent']}% OFF on Total Bill',
            'subtitle': 'Enjoy big savings on your order',
            'image': null,
            'valueText': '${settings['totalPercentageOfferPercent']}%',
            'icon': Icons.percent,
            'color': Colors.pinkAccent,
          });
        }

        // 5. Customer Entry Percentage Offer
        if (settings['enableCustomerEntryPercentageOffer'] == true) {
          collectedOffers.add({
            'type': 'Sign-up Bonus',
            'title':
                '${settings['customerEntryPercentageOfferPercent']}% OFF for New Customers',
            'subtitle': 'Provide your details to unlock this offer',
            'image': null,
            'valueText': '${settings['customerEntryPercentageOfferPercent']}%',
            'icon': Icons.person_add,
            'color': Colors.indigoAccent,
          });
        }

        // 6. Customer Credit Offer
        if (settings['enabled'] == true &&
            settings['offerAmount'] != null &&
            (settings['offerAmount'] as num) > 0) {
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

        // Assign distinct colors if not already specified or to ensure variety
        final colors = [
          Colors.orangeAccent,
          Colors.deepPurpleAccent,
          Colors.teal,
          Colors.pinkAccent,
          Colors.indigoAccent,
          Colors.amber.shade700,
          Colors.cyan.shade600,
          Colors.redAccent,
        ];
        for (int i = 0; i < collectedOffers.length; i++) {
          if (collectedOffers[i]['color'] == null) {
            collectedOffers[i]['color'] = colors[i % colors.length];
          }
        }

        if (mounted) {
          setState(() {
            _offers = collectedOffers;
            _isLoading = false;
          });
          if (_offers.length > 1) {
            _startAutoScroll();
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  String? _getImageUrl(dynamic product) {
    if (product == null ||
        product['images'] == null ||
        (product['images'] as List).isEmpty) {
      return null;
    }
    final img = product['images'][0]['image'];
    if (img == null || img['url'] == null) return null;
    String url = img['url'];
    if (url.startsWith('/')) {
      url = 'https://blackforest.vseyal.com$url';
    }
    return url;
  }

  void _startAutoScroll() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 4), (timer) {
      if (_pageController.hasClients) {
        _currentPage = (_currentPage + 1) % _offers.length;
        _pageController.animateToPage(
          _currentPage,
          duration: const Duration(milliseconds: 800),
          curve: Curves.easeInOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator(color: Colors.black)),
      );
    }

    if (_offers.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      height: 140,
      margin: const EdgeInsets.symmetric(vertical: 10),
      child: PageView.builder(
        controller: _pageController,
        onPageChanged: (index) {
          _currentPage = index;
        },
        itemCount: _offers.length,
        itemBuilder: (context, index) {
          final offer = _offers[index];
          return _buildBannerItem(offer);
        },
      ),
    );
  }

  Widget _buildBannerItem(Map<String, dynamic> offer) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            offer['color'],
            Color.lerp(offer['color'], Colors.black, 0.4)!,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: offer['color'].withValues(alpha: 0.4),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          children: [
            // Decorative Background Blob 1
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
            // Decorative Background Blob 2
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
            // Background pattern icon
            Positioned(
              right: 10,
              bottom: -20,
              child: Icon(
                offer['icon'] ?? Icons.local_offer,
                size: 140,
                color: Colors.white.withValues(alpha: 0.08),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  // Text content
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Glassmorphic Tag
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(30),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                offer['icon'] ?? Icons.bolt,
                                color: Colors.white,
                                size: 12,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                offer['type'].toUpperCase(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          offer['title'],
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
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
                          maxLines: 3,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          offer['subtitle'],
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            fontStyle: FontStyle.italic,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Image or Stylized Fallback
                  Hero(
                    tag: 'offer_${offer['title']}',
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 1000),
                      builder: (context, value, child) {
                        return Transform.translate(
                          offset: Offset(0, -5 * value), // Subtle bounce/float
                          child: child,
                        );
                      },
                      child: offer['image'] != null
                          ? Container(
                              width: 110,
                              height: 110,
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
                                  imageUrl: offer['image'],
                                  fit: BoxFit.cover,
                                  placeholder: (context, url) => const Center(
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  errorWidget: (context, url, error) =>
                                      const Icon(
                                        Icons.image_not_supported,
                                        color: Colors.grey,
                                        size: 40,
                                      ),
                                ),
                              ),
                            )
                          : _buildStylizedFallback(offer),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStylizedFallback(Map<String, dynamic> offer) {
    return SizedBox(
      width: 120,
      height: 120,
      child: Center(
        child: Transform.rotate(
          angle: -0.15,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (offer['valueText'] != null)
                Text(
                  offer['valueText'],
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
              if (offer['valueText'] == null)
                Icon(
                  offer['icon'] ?? Icons.local_offer,
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
            ],
          ),
        ),
      ),
    );
  }
}
