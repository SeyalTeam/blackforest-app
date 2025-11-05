import 'package:flutter/material.dart';
import 'package:blackforest_app/common_scaffold.dart';

class TablePage extends StatelessWidget {
  const TablePage({super.key});

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Tables',
      pageType: PageType.table,
      body: const Center(
        child: Text('Tables Page - Coming Soon'),
      ),
    );
  }
}