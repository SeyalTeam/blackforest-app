// cake.dart (new page)
import 'package:flutter/material.dart';
import 'package:blackforest_app/common_scaffold.dart';

class CakePage extends StatefulWidget {
  const CakePage({super.key});

  @override
  _CakePageState createState() => _CakePageState();
}

class _CakePageState extends State<CakePage> {
  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Cake',
      pageType: PageType.cake,
      body: const Center(
        child: Text(
          'Cake Order Coming soon',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}