import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:blackforest_app/cart_provider.dart';

class KitchenNotificationsPage extends StatelessWidget {
  const KitchenNotificationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Kitchen Notifications',
          style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold),
        ),
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
      body: Consumer<CartProvider>(
        builder: (context, cartProvider, child) {
          final notifications = cartProvider.kitchenNotifications;

          if (notifications.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.notifications_none,
                    size: 64,
                    color: Colors.grey[800],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'No items ready yet.',
                    style: TextStyle(color: Colors.white70, fontSize: 18),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Checked just now',
                    style: TextStyle(color: Colors.grey[600], fontSize: 14),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: notifications.length,
            itemBuilder: (context, index) {
              final item = notifications[index];
              final String billId = item['billId'];
              final String tableName = item['tableName'];
              final String productName = item['productName'];
              final double quantity = (item['quantity'] as num).toDouble();
              final String? preparedAt = item['preparedAt'];

              String timeAgo = '';
              if (preparedAt != null) {
                try {
                  final dt = DateTime.parse(preparedAt);
                  final diff = DateTime.now().difference(dt);
                  if (diff.inMinutes < 1) {
                    timeAgo = 'Just now';
                  } else if (diff.inMinutes < 60) {
                    timeAgo = '${diff.inMinutes}m ago';
                  } else {
                    timeAgo = '${diff.inHours}h ago';
                  }
                } catch (_) {}
              }

              // Formatting KOT Number to suffix (e.g., KOT-01)
              String kotNoDisplay = item['kotNumber'] ?? 'N/A';
              if (kotNoDisplay.contains('-')) {
                final parts = kotNoDisplay.split('-');
                final suffix = parts.last.replaceAll('KOT', '');
                kotNoDisplay = 'KOT-$suffix';
              }

              // Formatting Table Number (e.g., TABLE-01)
              String locationDisplay = tableName;
              if (tableName != 'Kitchen' && tableName != 'Counter') {
                final tableDigits = tableName.replaceAll(RegExp(r'[^0-9]'), '');
                if (tableDigits.isNotEmpty) {
                  locationDisplay = 'TABLE-${tableDigits.padLeft(2, '0')}';
                }
              }

              final String? statusLabel = item['status']
                  ?.toString()
                  .toUpperCase();
              final Color statusColor = statusLabel == 'PREPARED'
                  ? Colors.green
                  : const Color(0xFF0A84FF);

              return Card(
                color: const Color(0xFF1E1E1E),
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          productName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          statusLabel ?? 'READY',
                          style: TextStyle(
                            color: statusColor,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 8),
                      // Row: Location, KOT, Qty
                      Text(
                        '$locationDisplay  $kotNoDisplay  QTY-${quantity.toInt()}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          timeAgo,
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                  onTap: () async {
                    // Navigate to CartPage for this table
                    cartProvider.openBillAndNavigate(context, billId);
                  },
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.white,
        child: const Icon(Icons.refresh, color: Colors.black),
        onPressed: () {
          Provider.of<CartProvider>(
            context,
            listen: false,
          ).syncKitchenNotifications();
        },
      ),
    );
  }
}
