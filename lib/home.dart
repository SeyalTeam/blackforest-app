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
      body: const Center(
        child: Text(
          'Home Page Coming soon',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
      ),
      pageType: PageType.home,
    );
  }
}