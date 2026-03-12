import 'package:flutter/material.dart';
import 'package:blackforest_app/product_popularity_service.dart';

class ProductRatingBadge extends StatelessWidget {
  final ProductPopularityInfo info;
  final double fontSize;
  final EdgeInsetsGeometry padding;

  const ProductRatingBadge({
    super.key,
    required this.info,
    this.fontSize = 12,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: const Color(0xFFD9F7E8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.star_rounded,
            size: fontSize + 3,
            color: const Color(0xFF1E9D55),
          ),
          const SizedBox(width: 2),
          Text(
            '${info.score.toStringAsFixed(1)} (${info.count})',
            style: TextStyle(
              color: const Color(0xFF1E9D55),
              fontSize: fontSize,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}
