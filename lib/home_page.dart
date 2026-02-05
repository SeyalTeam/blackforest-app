import 'package:flutter/material.dart';
import 'package:blackforest_app/common_scaffold.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Home',
      pageType: PageType.home,
      body: const Center(
        child: Text(
          'Welcome to Black Forest',
          style: TextStyle(fontSize: 18, color: Colors.grey),
        ),
      ),
    );
  }
}
