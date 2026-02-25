import 'dart:async';
import 'dart:convert';
import 'dart:io' as io; // For Platform check
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:blackforest_app/app_http.dart' as http;
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
import 'package:blackforest_app/auth_flags.dart';
import 'package:blackforest_app/session_prefs.dart';

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
  String _employeeId = '';
  String? _photoUrl;
  String _branchName = '';
  String _role = '';
  Timer? _sessionCheckTimer;
  bool _isLoggingOut = false;

  @override
  void initState() {
    super.initState();
    _loadUsername();
    _resetTimer(); // Changed from _startTimer() to _resetTimer() as per original code
    _startKitchenSync();
    _startSessionCheck();
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
    _sessionCheckTimer?.cancel();
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

  void _startSessionCheck() {
    _checkSessionValidity();
    _sessionCheckTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      _checkSessionValidity();
    });
  }

  Future<void> _checkSessionValidity() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    final localDeviceId = prefs.getString('deviceId');

    if (token == null || localDeviceId == null) return;

    try {
      final response = await http
          .get(
            Uri.parse('https://blackforest.vseyal.com/api/users/me'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final user = data['user'];

        if (isForceLoggedOutUser(user)) {
          _logoutWithMessage("Your session was ended by admin.");
          return;
        }

        if (isLoginBlockedUser(user)) {
          _logoutWithMessage(
            "Login blocked by superadmin. Please contact administrator.",
          );
          return;
        }

        final serverDeviceId = user['deviceId'];

        if (serverDeviceId != null && serverDeviceId != localDeviceId) {
          debugPrint(
            "Session Conflict: Local ($localDeviceId) != Server ($serverDeviceId)",
          );
          _logoutWithMessage("Logged in on another device.");
        }
      } else if (response.statusCode == 401 || response.statusCode == 403) {
        _logoutWithMessage("Session expired. Please login again.");
      }
    } catch (e) {
      // Slient fail on network error
    }
  }

  void _logoutWithMessage(String msg) {
    if (mounted) {
      _showMessage(msg);
      _logout();
    }
  }

  Future<void> _loadUsername() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _username =
          prefs.getString('employee_name') ??
          prefs.getString('user_name') ??
          'Menu';
      _employeeId = prefs.getString('employee_code') ?? '';
      _photoUrl = prefs.getString('employee_photo_url');
      _branchName = prefs.getString('branchName') ?? '';
      _role = prefs.getString('role') ?? 'Role';
    });
  }

  void _resetTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(const Duration(hours: 7), _logout);
  }

  Future<void> _logout() async {
    if (_isLoggingOut) return;
    _isLoggingOut = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      final userId = prefs.getString('user_id');
      if (token != null && userId != null) {
        try {
          final now = DateTime.now();

          // 1. Find the log record that has an ACTIVE session
          final searchUrl =
              'https://blackforest.vseyal.com/api/attendance?where[user][equals]=$userId&where[activities.status][equals]=active&limit=1';
          final searchResp = await http
              .get(
                Uri.parse(searchUrl),
                headers: {'Authorization': 'Bearer $token'},
              )
              .timeout(const Duration(seconds: 3));

          if (searchResp.statusCode == 200) {
            final data = jsonDecode(searchResp.body);
            final docs = data['docs'] as List;
            if (docs.isNotEmpty) {
              final attendanceDoc = docs[0];
              final sessionId = attendanceDoc['id'];
              final activities = List<Map<String, dynamic>>.from(
                attendanceDoc['activities'] ?? [],
              );

              if (activities.isNotEmpty) {
                // Find the last active session
                for (int i = activities.length - 1; i >= 0; i--) {
                  if (activities[i]['type'] == 'session' &&
                      activities[i]['status'] == 'active') {
                    activities[i]['punchOut'] = now.toUtc().toIso8601String();
                    activities[i]['status'] = 'closed';

                    // Optional: calculate duration
                    final punchIn = DateTime.parse(activities[i]['punchIn']);
                    activities[i]['durationSeconds'] = now
                        .difference(punchIn)
                        .inSeconds;
                    break;
                  }
                }

                // 2. Update the document with the modified activities array
                final updateResp = await http
                    .patch(
                      Uri.parse(
                        'https://blackforest.vseyal.com/api/attendance/$sessionId',
                      ),
                      headers: {
                        'Authorization': 'Bearer $token',
                        'Content-Type': 'application/json',
                      },
                      body: jsonEncode({'activities': activities}),
                    )
                    .timeout(const Duration(seconds: 3));

                if (updateResp.statusCode != 200) {
                  debugPrint(
                    'Failed to update daily log: ${updateResp.statusCode} ${updateResp.body}',
                  );
                }
              }
            }
          }
        } catch (e) {
          debugPrint('Logout attendance error: $e');
        }
      }

      await clearSessionPreservingFavorites(prefs);
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/login');
      }
    } finally {
      _isLoggingOut = false;
    }
  }

  Future<void> _clearCache() async {
    try {
      // 1. Clear Flutter internal image cache
      PaintingBinding.instance.imageCache.clear();

      // 2. Clear Temporary Directory (OS Cache)
      final io.Directory tempDir = await getTemporaryDirectory();
      if (tempDir.existsSync()) {
        try {
          await tempDir.delete(recursive: true);
          await tempDir.create();
        } catch (e) {
          debugPrint("Non-critical: Failed to delete some temp files: $e");
        }
      }

      // 3. Selective SharedPreferences clear (to keep user logged in)
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      final authKeys = {
        'token',
        'role',
        'email',
        'branchId',
        'branchName',
        'lastLoginIp',
        'printerIp',
        'user_id',
        'user_name',
        'login_time',
        'employee_id',
        'employee_name',
        'employee_code',
        'employee_photo_url',
        'deviceId',
        'branchLat',
        'branchLng',
        'branchRadius',
      };

      for (String key in keys) {
        if (!authKeys.contains(key)) {
          await prefs.remove(key);
        }
      }

      // 4. Clear CartProvider in-memory state
      if (mounted) {
        Provider.of<CartProvider>(context, listen: false).clearCart();
        _showMessage('Cache and storage cleared');
      }
    } catch (e) {
      debugPrint('Error clearing cache: $e');
      if (mounted) _showMessage('Error occurred while clearing cache');
    }
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
          leading: Builder(
            builder: (context) => IconButton(
              icon: _photoUrl != null && _photoUrl!.isNotEmpty
                  ? CircleAvatar(
                      radius: 14,
                      backgroundImage: NetworkImage(_photoUrl!),
                      backgroundColor: Colors.grey[100],
                    )
                  : const Icon(Icons.menu, color: Colors.black87),
              onPressed: () {
                _resetTimer();
                Scaffold.of(context).openDrawer();
              },
            ),
          ),
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
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border(
                    bottom: BorderSide(color: Colors.grey[200]!, width: 1),
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircleAvatar(
                      radius: 35,
                      backgroundColor: Colors.grey[100],
                      backgroundImage:
                          _photoUrl != null && _photoUrl!.isNotEmpty
                          ? NetworkImage(_photoUrl!)
                          : null,
                      child: _photoUrl == null || _photoUrl!.isEmpty
                          ? Icon(
                              Icons.person,
                              size: 35,
                              color: Colors.grey[400],
                            )
                          : null,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_employeeId.isNotEmpty) ...[
                          Text(
                            'ID: $_employeeId',
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '|',
                            style: TextStyle(
                              color: Colors.grey[300],
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          _username,
                          style: const TextStyle(
                            color: Colors.black87,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '|',
                          style: TextStyle(
                            color: Colors.grey[300],
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey[50],
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: Colors.grey[200]!),
                          ),
                          child: Text(
                            _role.toUpperCase(),
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 8,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (_branchName.isNotEmpty)
                      Text(
                        _branchName,
                        style: const TextStyle(
                          color: Colors.blue,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.home_outlined, color: Colors.black87),
                title: const Text('Home'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (context) => const HomePage()),
                    (route) => false,
                  );
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.receipt_outlined,
                  color: Colors.black87,
                ),
                title: const Text('billings'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          const CategoriesPage(sourcePage: PageType.billing),
                    ),
                    (route) => false,
                  );
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.table_restaurant_outlined,
                  color: Colors.black87,
                ),
                title: const Text('Table'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (context) => const TablePage()),
                    (route) => false,
                  );
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.badge_outlined,
                  color: Colors.black87,
                ),
                title: const Text('Employee'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const EmployeePage(),
                    ),
                    (route) => false,
                  );
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.cleaning_services_outlined,
                  color: Colors.black87,
                ),
                title: const Text('Clear cache'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
                  _clearCache();
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.logout_outlined,
                  color: Colors.black87,
                ),
                title: const Text('logout'),
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
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: () {
        _resetTimer();
        if (onTap != null) {
          onTap();
        } else {
          Navigator.pushAndRemoveUntil(
            context,
            _createRoute(page),
            (route) => false,
          );
        }
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
