// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:blackforest_app/main.dart';

void main() {
  testWidgets('App starts at LoginPage when no token', (WidgetTester tester) async {
    // Build our app without token (login page)
    await tester.pumpWidget(const MyApp(hasToken: false));

    // Verify that LoginPage elements are present
    expect(find.text('Welcome Team'), findsOneWidget);
    expect(find.text('Login'), findsOneWidget);
    expect(find.text('Enter email'), findsOneWidget);
    expect(find.text('Enter password'), findsNothing); // It's a label, but check for button
    expect(find.byType(TextFormField), findsNWidgets(2)); // Email and password fields
    expect(find.text('Login'), findsOneWidget); // Button text
  });

  testWidgets('App starts at CategoriesPage when has token', (WidgetTester tester) async {
    // Build our app with token (categories page)
    await tester.pumpWidget(const MyApp(hasToken: true));

    // Verify that CategoriesPage elements are present (adjust based on your CategoriesPage content)
    expect(find.text('Categories'), findsOneWidget); // Assuming appBar title
    expect(find.text('Manage categories, products, branches, employees, billing, reports here'), findsOneWidget);
  });
}