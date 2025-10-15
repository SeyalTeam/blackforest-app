import 'dart:async';
import 'dart:io' as io; // For Platform check
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_scanner/mobile_scanner.dart'; // Import for scanner

class CommonScaffold extends StatefulWidget {
  final String title; // Custom title for the page
  final Widget body; // The main content
  final Function(String)? onScanCallback; // Optional callback for scan result (e.g., for UPC selection in ProductsPage)

  const CommonScaffold({
    super.key,
    required this.title,
    required this.body,
    this.onScanCallback,
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
          widget.onScanCallback!(result); // Call page-specific handler for UPC selection
        } else {
          _showMessage('Scanned barcode: $result');
        }
      } else {
        _showMessage('Scan cancelled');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector( // Detect taps to reset timer
      onTap: _resetTimer,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title, style: const TextStyle(color: Colors.white)),
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white), // White menu icon
          actions: [
            IconButton(
              icon: const Icon(Icons.qr_code_scanner, color: Colors.white), // Barcode scanner icon, white
              onPressed: _scanBarcode, // Launch scanner
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