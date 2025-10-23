import 'dart:async';
import 'dart:io' as io; // For Platform check
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_scanner/mobile_scanner.dart'; // Import for scanner
import 'package:blackforest_app/categories_page.dart'; // Import CategoriesPage
import 'package:blackforest_app/home.dart'; // Import HomePage
import 'package:blackforest_app/cake.dart'; // Import CakePage

enum PageType { home, billing, pastry, cart, stock, cake } // Added cake to enum

class CommonScaffold extends StatefulWidget {
  final String title; // Custom title for the page
  final Widget body; // The main content
  final Function(String)? onScanCallback; // Optional callback for scan result
  final PageType pageType; // To highlight active footer icon

  const CommonScaffold({
    super.key,
    required this.title,
    required this.body,
    this.onScanCallback,
    required this.pageType,
  });

  @override
  _CommonScaffoldState createState() => _CommonScaffoldState();
}

class _CommonScaffoldState extends State<CommonScaffold> {
  Timer? _inactivityTimer;
  String _username = 'Menu'; // Fallback

  @override
  void initState() {
    super.initState();
    _loadUsername();
    _resetTimer(); // Start timer
  }

  @override
  void dispose() {
    _inactivityTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadUsername() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _username = prefs.getString('username') ?? 'Menu';
    });
  }

  void _resetTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(const Duration(hours: 7), _logout); // 7 hours timeout
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    Navigator.pushReplacementNamed(context, '/login'); // Go to login
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.grey[800],
      ),
    );
  }

  Future<void> _scanBarcode() async {
    _resetTimer(); // Reset timer on tap
    if (!io.Platform.isAndroid && !io.Platform.isIOS) {
      _showMessage('Scanner not supported on this platform');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const ScannerPage(),
      ),
    ).then((result) {
      if (result != null) {
        if (widget.onScanCallback != null) {
          widget.onScanCallback!(result); // Call page-specific handler
        } else {
          _showMessage('Scanned barcode: $result');
        }
      } else {
        _showMessage('Scan cancelled');
      }
    });
  }

  Route _createRoute(Widget page) {
    return PageRouteBuilder(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return child; // No transition animation
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Detect taps to reset timer
      onTap: _resetTimer,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title, style: const TextStyle(color: Colors.white)),
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white), // White menu icon
          actions: [
            IconButton(
              icon: const Icon(Icons.qr_code_scanner_outlined, color: Colors.white), // Scan icon, white, line style
              onPressed: _scanBarcode,
            ),
            IconButton(
              icon: const Icon(Icons.shopping_cart_outlined, color: Colors.white), // Cart icon, white, line style
              onPressed: () {
                _resetTimer(); // Reset timer on tap
                _showMessage('Cart screen coming soon');
              },
            ),
          ],
        ),
        drawer: Drawer( // Left sidebar menu
          child: ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              DrawerHeader(
                decoration: const BoxDecoration(
                  color: Colors.black,
                ),
                child: Text(
                  _username,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.shopping_cart, color: Colors.black),
                title: const Text('Products'),
                onTap: () {
                  _resetTimer(); // Reset timer on tap
                  Navigator.pop(context); // Close drawer
                  _showMessage('Products screen coming soon');
                },
              ),
              ListTile(
                leading: const Icon(Icons.category, color: Colors.black),
                title: const Text('Categories'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
                  _showMessage('Categories screen coming soon');
                },
              ),
              ListTile(
                leading: const Icon(Icons.location_on, color: Colors.black),
                title: const Text('Branches'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
                  _showMessage('Branches screen coming soon');
                },
              ),
              ListTile(
                leading: const Icon(Icons.people, color: Colors.black),
                title: const Text('Employees'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
                  _showMessage('Employees screen coming soon');
                },
              ),
              ListTile(
                leading: const Icon(Icons.receipt, color: Colors.black),
                title: const Text('Billing'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
                  _showMessage('Billing screen coming soon');
                },
              ),
              ListTile(
                leading: const Icon(Icons.bar_chart, color: Colors.black),
                title: const Text('Reports'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
                  _showMessage('Reports screen coming soon');
                },
              ),
              ListTile( // Logout at bottom
                leading: const Icon(Icons.logout, color: Colors.black),
                title: const Text('Logout'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
                  _logout();
                },
              ),
            ],
          ),
        ),
        body: widget.body, // Page-specific content
        backgroundColor: Colors.white,
        bottomNavigationBar: Container(
          decoration: const BoxDecoration(
            border: Border(
              top: BorderSide(color: Colors.grey, width: 1.0),
            ),
          ),
          child: BottomAppBar(
            color: Colors.white, // White background
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround, // Adjusted for five icons
              children: [
                GestureDetector(
                  onTap: () {
                    _resetTimer(); // Reset timer on tap
                    Navigator.pushAndRemoveUntil(
                      context,
                      _createRoute(const HomePage()),
                          (route) => false, // Clear stack
                    );
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.home_outlined,
                        color: widget.pageType == PageType.home ? Colors.blue : Colors.black,
                        size: 32,
                      ),
                      Text(
                        'Home',
                        style: TextStyle(
                          color: widget.pageType == PageType.home ? Colors.blue : Colors.black,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    _resetTimer(); // Reset timer on tap
                    Navigator.pushAndRemoveUntil(
                      context,
                      _createRoute(const CategoriesPage()),
                          (route) => false, // Clear stack to go back to Categories
                    );
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.receipt_outlined,
                        color: widget.pageType == PageType.billing ? Colors.blue : Colors.black,
                        size: 32,
                      ),
                      Text(
                        'Billing',
                        style: TextStyle(
                          color: widget.pageType == PageType.billing ? Colors.blue : Colors.black,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    _resetTimer(); // Reset timer on tap
                    Navigator.pushAndRemoveUntil(
                      context,
                      _createRoute(const CakePage()),
                          (route) => false, // Clear stack
                    );
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.cake_outlined,
                        color: widget.pageType == PageType.cake ? Colors.blue : Colors.black,
                        size: 32,
                      ),
                      Text(
                        'Cake',
                        style: TextStyle(
                          color: widget.pageType == PageType.cake ? Colors.blue : Colors.black,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    _resetTimer(); // Reset timer on tap
                    Navigator.pushAndRemoveUntil(
                      context,
                      _createRoute(const CategoriesPage(isStockFilter: true)),
                          (route) => false, // Clear stack
                    );
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.inventory_outlined,
                        color: widget.pageType == PageType.stock ? Colors.blue : Colors.black,
                        size: 32,
                      ),
                      Text(
                        'Return',
                        style: TextStyle(
                          color: widget.pageType == PageType.stock ? Colors.blue : Colors.black,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    _resetTimer(); // Reset timer on tap
                    Navigator.pushAndRemoveUntil(
                      context,
                      _createRoute(const CategoriesPage(isPastryFilter: true)),
                          (route) => false, // Clear stack
                    );
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.description_outlined,
                        color: widget.pageType == PageType.pastry ? Colors.blue : Colors.black,
                        size: 32,
                      ),
                      Text(
                        'Stock',
                        style: TextStyle(
                          color: widget.pageType == PageType.pastry ? Colors.blue : Colors.black,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ScannerPage for barcode scanning
class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  _ScannerPageState createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final MobileScannerController _controller = MobileScannerController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Barcode')),
      body: MobileScanner(
        controller: _controller,
        onDetect: (capture) {
          final List<Barcode> barcodes = capture.barcodes;
          for (final barcode in barcodes) {
            if (barcode.rawValue != null) {
              Navigator.pop(context, barcode.rawValue); // Return scanned value
              return;
            }
          }
        },
      ),
    );
  }
}