import 'package:flutter/material.dart';
import 'package:blackforest_app/common_scaffold.dart';

class EmployeePage extends StatelessWidget {
  const EmployeePage({super.key});

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Employees',
      pageType: PageType.employee,
      body: const Center(
        child: Text('Employees Page - Coming Soon'),
      ),
    );
  }
}