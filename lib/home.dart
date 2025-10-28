import 'package:flutter/material.dart';
import 'common_scaffold.dart'; // Adjust import if needed

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Home',
      body: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                Column(
                  children: [
                    Icon(
                      Icons.inventory,
                      size: 40,
                      color: Colors.blue,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Stock',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(width: 32), // Space between icons
                Column(
                  children: [
                    Icon(
                      Icons.assignment_return,
                      size: 40,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Return',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(width: 32), // Space between icons
                Column(
                  children: [
                    Icon(
                      Icons.bar_chart,
                      size: 40,
                      color: Colors.green,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Report',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(width: 32), // Space between icons
                Column(
                  children: [
                    Icon(
                      Icons.shopping_cart,
                      size: 40,
                      color: Colors.orange,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Orders',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // You can add more content here if needed
        ],
      ),
      pageType: PageType.home,
    );
  }
}