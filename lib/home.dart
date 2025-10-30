import 'package:flutter/material.dart';
import 'common_scaffold.dart';
import 'stock_order.dart';
import 'return_order_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  void _openStockPage() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const StockOrderPage(
          categoryId: 'default-stock',
          categoryName: 'Stock Order',
        ),
      ),
    );
  }

  void _openReturnPage() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const ReturnOrderPage(
          categoryId: 'default-return',
          categoryName: 'Return Order',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Home',
      pageType: PageType.home,
      body: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                // 🔹 Stock Page Icon
                GestureDetector(
                  onTap: _openStockPage,
                  child: Column(
                    children: const [
                      Icon(Icons.inventory, size: 40, color: Colors.blue),
                      SizedBox(height: 8),
                      Text(
                        'Stock',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 32),

                // 🔴 Return Page Icon
                GestureDetector(
                  onTap: _openReturnPage,
                  child: Column(
                    children: const [
                      Icon(Icons.assignment_return, size: 40, color: Colors.red),
                      SizedBox(height: 8),
                      Text(
                        'Return',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 32),

                // 📊 Report Icon (placeholder)
                Column(
                  children: const [
                    Icon(Icons.bar_chart, size: 40, color: Colors.green),
                    SizedBox(height: 8),
                    Text(
                      'Report',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 32),

                // 🛒 Orders Icon (placeholder)
                Column(
                  children: const [
                    Icon(Icons.shopping_cart, size: 40, color: Colors.orange),
                    SizedBox(height: 8),
                    Text(
                      'Orders',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
