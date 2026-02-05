import 'dart:async';
import 'dart:io' as io; // For Platform check
import 'package:flutter/material.dart';
import 'package:provider/provider.dart'; // For cart badge
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_scanner/mobile_scanner.dart'; // Import for scanner
import 'package:blackforest_app/categories_page.dart'; // Import CategoriesPage
import 'package:blackforest_app/cart_page.dart'; // Import CartPage
import 'package:blackforest_app/cart_provider.dart'; // Import CartProvider
import 'package:blackforest_app/employee.dart'; // Import EmployeePage
import 'package:blackforest_app/table.dart'; // Import TablePage
import 'package:blackforest_app/kot_bills_page.dart'; // Import KotBillsPage
import 'package:blackforest_app/home_page.dart';
import 'package:blackforest_app/kitchen_notifications_page.dart'; // Import HomePage

enum PageType { home, billing, cart, billsheet, table, editbill, employee }

class CommonScaffold extends StatefulWidget {
  final String title;
  final Widget body;
  final Function(String)? onScanCallback;
  final PageType pageType;

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
  Timer? _kitchenSyncTimer;
  String _username = 'Menu';

  @override
  void initState() {
    super.initState();
    _loadUsername();
    _resetTimer(); // Changed from _startTimer() to _resetTimer() as per original code
    _startKitchenSync();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final cartProvider = Provider.of<CartProvider>(context, listen: false);
      if (widget.pageType == PageType.billing) {
        cartProvider.setCartType(CartType.billing);
      } else if (widget.pageType == PageType.table) {
        cartProvider.setCartType(CartType.table);
      }
    });
  }

  @override
  void dispose() {
    _inactivityTimer?.cancel();
    _kitchenSyncTimer?.cancel();
    super.dispose();
  }

  void _startKitchenSync() {
    // Initial sync
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Provider.of<CartProvider>(
          context,
          listen: false,
        ).syncKitchenNotifications();
      }
    });

    // Periodic sync every 5 seconds
    _kitchenSyncTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (mounted) {
        Provider.of<CartProvider>(
          context,
          listen: false,
        ).syncKitchenNotifications();
      }
    });
  }

  Future<void> _loadUsername() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _username = prefs.getString('username') ?? 'Menu';
    });
  }

  void _resetTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(const Duration(hours: 7), _logout);
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    Navigator.pushReplacementNamed(context, '/login');
  }

  Future<void> _clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    PaintingBinding.instance.imageCache.clear();
    _showMessage('Cache and storage cleared');
    Navigator.pushReplacementNamed(context, '/login');
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.grey[800]),
    );
  }

  Future<void> _scanBarcode() async {
    _resetTimer();
    if (!io.Platform.isAndroid && !io.Platform.isIOS) {
      _showMessage('Scanner not supported on this platform');
      return;
    }
    final result = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      pageBuilder: (context, anim1, anim2) => const ScannerDialog(),
      transitionBuilder: (context, anim1, anim2, child) {
        return FadeTransition(opacity: anim1, child: child);
      },
    );
    if (result != null) {
      if (widget.onScanCallback != null) {
        widget.onScanCallback!(result);
      } else {
        _showMessage('Scanned barcode: $result');
      }
    } else {
      _showMessage('Scan cancelled');
    }
  }

  Route _createRoute(Widget page) {
    return PageRouteBuilder(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return child;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _resetTimer,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 1,
          title: Text(
            widget.title,
            style: const TextStyle(
              color: Colors.black87,
              fontWeight: FontWeight.w600,
            ),
          ),
          iconTheme: const IconThemeData(color: Colors.black87),
          actionsIconTheme: const IconThemeData(color: Colors.black87),
          actions: [
            Consumer<CartProvider>(
              builder: (context, cartProvider, child) {
                final int notifyCount =
                    cartProvider.kitchenNotifications.length;

                return Stack(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.notifications_none_outlined),
                      onPressed: () {
                        _resetTimer();
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) =>
                                const KitchenNotificationsPage(),
                          ),
                        );
                      },
                    ),
                    if (notifyCount > 0)
                      Positioned(
                        right: 8,
                        top: 8,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 16,
                            minHeight: 16,
                          ),
                          child: Text(
                            '$notifyCount',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.receipt_long_outlined),
              onPressed: () {
                _resetTimer();
                Navigator.pushAndRemoveUntil(
                  context,
                  _createRoute(const KotBillsPage()),
                  (route) => false,
                );
              },
            ),
            Consumer<CartProvider>(
              builder: (context, cartProvider, child) {
                final int itemCount = cartProvider.cartItems.length;

                return Stack(
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.shopping_cart_outlined,
                        color: Colors.black87,
                      ),
                      onPressed: () {
                        _resetTimer();
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const CartPage(),
                          ),
                        );
                      },
                    ),
                    if (itemCount > 0)
                      Positioned(
                        right: 8,
                        top: 8,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 16,
                            minHeight: 16,
                          ),
                          child: Text(
                            '$itemCount',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),

        drawer: Drawer(
          child: ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              DrawerHeader(
                decoration: const BoxDecoration(color: Colors.black),
                child: Text(
                  _username,
                  style: const TextStyle(color: Colors.white, fontSize: 24),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.shopping_cart, color: Colors.black),
                title: const Text('Products'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
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
              ListTile(
                leading: const Icon(
                  Icons.cleaning_services,
                  color: Colors.black,
                ),
                title: const Text('Clear Cache'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
                  _clearCache();
                },
              ),
              ListTile(
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
        body: widget.body,
        backgroundColor: Colors.white,
        bottomNavigationBar: Container(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Colors.grey, width: 1.0)),
          ),
          child: BottomAppBar(
            color: Colors.white,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildNavItem(
                  icon: Icons.home_outlined,
                  label: 'Home',
                  page: const HomePage(),
                  type: PageType.home,
                ),
                _buildNavItem(
                  icon: Icons.receipt_outlined,
                  label: 'Billing',
                  page: const CategoriesPage(),
                  type: PageType.billing,
                ),
                GestureDetector(
                  onTap: _scanBarcode,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(
                        Icons.qr_code_scanner_outlined,
                        color: Colors.black,
                        size: 32,
                      ),
                      Text(
                        'Scan',
                        style: TextStyle(color: Colors.black, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                _buildNavItem(
                  icon: Icons.table_restaurant_outlined,
                  label: 'Table',
                  page: const TablePage(),
                  type: PageType.table,
                ),
                _buildNavItem(
                  icon: Icons.badge_outlined,
                  label: 'Employee',
                  page: const EmployeePage(),
                  type: PageType.employee,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required IconData icon,
    required String label,
    required Widget page,
    required PageType type,
  }) {
    return GestureDetector(
      onTap: () {
        _resetTimer();
        Navigator.pushAndRemoveUntil(
          context,
          _createRoute(page),
          (route) => false,
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            color: widget.pageType == type ? Colors.blue : Colors.black,
            size: 32,
          ),
          Text(
            label,
            style: TextStyle(
              color: widget.pageType == type ? Colors.blue : Colors.black,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

// ScannerDialog for barcode scanning
class ScannerDialog extends StatefulWidget {
  const ScannerDialog({super.key});

  @override
  _ScannerDialogState createState() => _ScannerDialogState();
}

class _ScannerDialogState extends State<ScannerDialog> {
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
              Navigator.pop(context, barcode.rawValue);
              return;
            }
          }
        },
      ),
    );
  }
}
