import 'package:flutter/material.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/customer_search_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Home',
      pageType: PageType.home,
      body: GridView.count(
        padding: const EdgeInsets.all(20),
        crossAxisCount: 2,
        crossAxisSpacing: 20,
        mainAxisSpacing: 20,
        children: [
          _buildGridItem(
            context,
            icon: Icons.people_outline,
            label: 'Customer',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const CustomerSearchPage(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildGridItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(15),
          boxShadow: [
            BoxShadow(
              color: Colors.grey.withOpacity(0.1),
              spreadRadius: 2,
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
          border: Border.all(color: Colors.grey.shade100),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 50, color: Colors.blue),
            const SizedBox(height: 10),
            Text(
              label,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
