import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/return_provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

class ReturnCartPage extends StatefulWidget {
  const ReturnCartPage({super.key});

  @override
  State<ReturnCartPage> createState() => _ReturnCartPageState();
}

class _ReturnCartPageState extends State<ReturnCartPage> {
  static const Color _bg = Color(0xFF121212);
  static const Color _card = Color(0xFF1E1E1E);
  static const Color _accent = Color(0xFFF44336);

  Widget _buildEmptyState() {
    return const Center(
      child: Text(
        "Return Cart is empty",
        style: TextStyle(color: Colors.grey, fontSize: 16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Return Cart',
      pageType: PageType.returnorder,
      body: Container(
        color: _bg,
        child: Consumer<ReturnProvider>(
          builder: (context, provider, child) {
            final items = provider.returnItems;

            return SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: items.isEmpty
                        ? _buildEmptyState()
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
                            itemCount: items.length,
                            itemBuilder: (context, index) {
                              final item = items[index];
                              return ReturnCartItemCard(
                                key: ValueKey(item.id),
                                item: item,
                                cardColor: _card,
                                accent: _accent,
                                onRemove: () => provider.removeItem(item.id),
                                onQuantityChange: (q) =>
                                    provider.updateQuantity(item.id, q),
                                provider: provider,
                              );
                            },
                          ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _bg,
                      border: Border(
                        top: BorderSide(color: Colors.white.withOpacity(0.1)),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Total:',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              '₹${provider.total.toStringAsFixed(2)}',
                              style: const TextStyle(
                                color: Colors.green,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: ElevatedButton(
                            onPressed:
                                (items.isNotEmpty && !provider.isSubmitting)
                                ? () async {
                                      final prefs = await SharedPreferences.getInstance();
                                      final activeBranch = prefs.getString('branchId') ?? prefs.getString('branch') ?? prefs.getString('userBranchId');
                                      await provider.submitReturn(context, activeBranch);
                                      if (provider.returnItems.isEmpty && mounted) {
                                          Navigator.pop(context);
                                      }
                                  }
                                : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: provider.isSubmitting
                                  ? Colors.grey
                                  : Colors.red,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: provider.isSubmitting
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      color: Colors.white,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text(
                                    'Confirm Return',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class ReturnCartItemCard extends StatelessWidget {
  final ReturnItem item;
  final Color cardColor;
  final Color accent;
  final VoidCallback onRemove;
  final Function(double) onQuantityChange;
  final ReturnProvider provider;

  const ReturnCartItemCard({
    required Key key,
    required this.item,
    required this.cardColor,
    required this.accent,
    required this.onRemove,
    required this.onQuantityChange,
    required this.provider,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    ImageProvider? imageProvider;
    final tempFile = provider.getTempPhoto(item.id);
    final url = provider.getPhotoUrl(item.id);

    if (tempFile != null && tempFile.existsSync()) {
      imageProvider = FileImage(tempFile);
    } else if (url != null) {
      imageProvider = CachedNetworkImageProvider(url);
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: onRemove,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 70,
                height: 70,
                color: Colors.white10,
                child: imageProvider != null
                    ? Image(image: imageProvider, fit: BoxFit.cover)
                    : const Icon(Icons.delete, color: Colors.red, size: 30),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '₹${item.price % 1 == 0 ? item.price.toInt() : item.price.toStringAsFixed(2)} x ${item.quantity}',
                  style: const TextStyle(color: Colors.grey, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  '₹${item.subtotal.toStringAsFixed(2)}',
                  style: const TextStyle(
                    color: Colors.green,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
