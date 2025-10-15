import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/common_header.dart'; // Import CommonScaffold
import 'package:blackforest_app/products_page.dart'; // Import ProductsPage

class CategoriesPage extends StatefulWidget {
  const CategoriesPage({super.key});

  @override
  _CategoriesPageState createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  List<dynamic> _bilingCategories = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchBilingCategories();
  }

  Future<void> _fetchBilingCategories() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No token found. Please login again.')),
        );
        return;
      }

      final response = await http.get(
        Uri.parse('https://apib.theblackforestcakes.com/api/categories/list-categories?type=biling'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        setState(() {
          _bilingCategories = jsonDecode(response.body);
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to fetch categories: ${response.statusCode}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error: Check your internet')),
      );
    }

    setState(() {
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Welcome Team',
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.black))
          : _bilingCategories.isEmpty
          ? const Center(child: Text('No biling categories found', style: TextStyle(color: Color(0xFF4A4A4A), fontSize: 18)))
          : LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final crossAxisCount = (width > 600) ? 5 : 3; // 3 on phones, 5 on desktop/web/tablets
          return GridView.builder(
            padding: const EdgeInsets.all(10),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 0.75, // Rectangular
            ),
            itemCount: _bilingCategories.length,
            itemBuilder: (context, index) {
              final category = _bilingCategories[index];
              final imageUrl = category['image'] != null
                  ? 'https://apib.theblackforestcakes.com/uploads/categories/${category['image'].split('/').last}'
                  : 'https://via.placeholder.com/150?text=No+Image'; // Fallback

              return GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ProductsPage(
                        categoryId: category['_id'],
                        categoryName: category['name'],
                      ),
                    ),
                  );
                },
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.grey.withOpacity(0.1),
                        spreadRadius: 2,
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Expanded(
                        flex: 8, // 80% image
                        child: ClipRRect(
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                          child: Image.network(
                            imageUrl,
                            fit: BoxFit.cover,
                            width: double.infinity,
                            errorBuilder: (context, error, stackTrace) {
                              return const Center(child: Text('No Image', style: TextStyle(color: Colors.grey)));
                            },
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 2, // 20% name
                        child: Container(
                          width: double.infinity,
                          decoration: const BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.vertical(bottom: Radius.circular(8)),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            category['name'] ?? 'Unknown',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}