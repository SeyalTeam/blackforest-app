import 'package:flutter/material.dart';
import 'package:blackforest_app/common_scaffold.dart';

class TablePage extends StatelessWidget {
  const TablePage({super.key});

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Table Order',
      body: const Center(
        child: Text('Table Order screen coming soon'),
      ),
      pageType: PageType.table,
    );
  }
}