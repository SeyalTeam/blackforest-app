import 'dart:async';
import 'dart:convert';
import 'dart:io' as io; // For Platform check
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:esc_pos_printer/esc_pos_printer.dart';
import 'package:esc_pos_utils/esc_pos_utils.dart' hide Barcode;
import 'package:provider/provider.dart'; // For cart badge
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_scanner/mobile_scanner.dart'; // Import for scanner
import 'package:blackforest_app/categories_page.dart'; // Import CategoriesPage
import 'package:blackforest_app/cart_page.dart'; // Import CartPage
import 'package:blackforest_app/cart_provider.dart'; // Import CartProvider
import 'package:blackforest_app/chat_page.dart';
import 'package:blackforest_app/employee.dart'; // Import EmployeePage
import 'package:blackforest_app/home_navigation_service.dart';
import 'package:blackforest_app/table.dart'; // Import TablePage
import 'package:blackforest_app/home_page.dart';
import 'package:blackforest_app/kitchen_notifications_page.dart'; // Import HomePage
import 'package:blackforest_app/kot_auto_print_service.dart';
import 'package:blackforest_app/auth_flags.dart';
import 'package:blackforest_app/session_prefs.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

enum PageType {
  home,
  billing,
  cart,
  billsheet,
  table,
  editbill,
  employee,
  chat,
}

class CommonScaffold extends StatefulWidget {
  final String title;
  final Widget body;
  final Function(String)? onScanCallback;
  final PageType pageType;
  final bool showAppBar;
  final bool hideBottomNavigationBar;
  final bool showBackButtonInAppBar;

  const CommonScaffold({
    super.key,
    required this.title,
    required this.body,
    this.onScanCallback,
    required this.pageType,
    this.showAppBar = true,
    this.hideBottomNavigationBar = false,
    this.showBackButtonInAppBar = false,
  });

  @override
  State<CommonScaffold> createState() => _CommonScaffoldState();
}

class _CommonScaffoldState extends State<CommonScaffold> {
  static const Color _navActiveColor = Color(0xFFEF4F5F);
  static const Color _navInactiveColor = Color(0xFF8C8C8C);
  static const Color _chatNavColor = Color(0xFF2AABEE);
  Timer? _inactivityTimer;
  Timer? _kitchenSyncTimer;
  String _username = 'Menu';
  String _employeeId = '';
  String? _photoUrl;
  String _branchName = '';
  String _role = '';
  bool _showHomeNavigation = true;
  bool _showTableNavigation = true;
  Timer? _sessionCheckTimer;
  bool _isLoggingOut = false;
  bool _isPrinterTestRunning = false;
  bool _isDrainingWebsiteAlertQueue = false;
  final List<AutoSyncAlert> _websiteAlertQueue = [];

  @override
  void initState() {
    super.initState();
    _loadUsername();
    _loadNavigationVisibility();
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
        unawaited(_syncWebsiteOrderSignals());
      }
    });

    // Periodic sync every 5 seconds
    _kitchenSyncTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (mounted) {
        Provider.of<CartProvider>(
          context,
          listen: false,
        ).syncKitchenNotifications();
        unawaited(_syncWebsiteOrderSignals());
      }
    });
  }

  Future<void> _syncWebsiteOrderSignals() async {
    if (io.Platform.isAndroid && await FlutterForegroundTask.isRunningService) {
      return;
    }

    final alerts = await KotAutoPrintService.syncPendingWebsiteKots();
    if (!mounted || alerts.isEmpty) {
      return;
    }

    _websiteAlertQueue.addAll(alerts);
    if (_isDrainingWebsiteAlertQueue) {
      return;
    }

    _isDrainingWebsiteAlertQueue = true;
    final messenger = ScaffoldMessenger.of(context);
    try {
      while (mounted && _websiteAlertQueue.isNotEmpty) {
        final alert = _websiteAlertQueue.removeAt(0);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: Text(alert.message),
            backgroundColor: alert.isSuccess ? Colors.green : Colors.redAccent,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 3200));
      }
    } finally {
      _isDrainingWebsiteAlertQueue = false;
    }
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

  Future<void> _loadNavigationVisibility() async {
    final prefs = await SharedPreferences.getInstance();
    final branchId = prefs.getString('branchId')?.trim() ?? '';
    final cachedHomeVisibility = HomeNavigationService.readCachedVisibility(
      prefs,
      branchId: branchId,
      fallback: true,
    );
    final cachedTableVisibility =
        HomeNavigationService.readCachedTableVisibility(
          prefs,
          branchId: branchId,
          fallback: true,
        );

    if (mounted &&
        (_showHomeNavigation != cachedHomeVisibility ||
            _showTableNavigation != cachedTableVisibility)) {
      setState(() {
        _showHomeNavigation = cachedHomeVisibility;
        _showTableNavigation = cachedTableVisibility;
      });
    }

    final visibility = await Future.wait<bool>([
      HomeNavigationService.loadVisibilityForCurrentBranch(
        prefs: prefs,
        fallback: cachedHomeVisibility,
      ),
      HomeNavigationService.loadTableVisibilityForCurrentBranch(
        prefs: prefs,
        fallback: cachedTableVisibility,
      ),
    ]);
    final refreshedHomeVisibility = visibility[0];
    final refreshedTableVisibility = visibility[1];

    if (!mounted ||
        (_showHomeNavigation == refreshedHomeVisibility &&
            _showTableNavigation == refreshedTableVisibility)) {
      return;
    }

    setState(() {
      _showHomeNavigation = refreshedHomeVisibility;
      _showTableNavigation = refreshedTableVisibility;
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

  String? _toIdString(dynamic value) {
    if (value == null) return null;
    if (value is Map) {
      final map = Map<String, dynamic>.from(value);
      return (map['id'] ?? map['_id'] ?? map[r'$oid'])?.toString();
    }
    return value.toString();
  }

  int _parsePort(dynamic value, {int fallback = 9100}) {
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  String? _extractPrinterIp(dynamic rawConfig) {
    if (rawConfig is! Map) return null;
    final config = Map<String, dynamic>.from(rawConfig);
    final nestedPrinter = config['printer'] is Map
        ? Map<String, dynamic>.from(config['printer'])
        : null;
    final candidates = [
      config['printerIp'],
      config['ipAddress'],
      config['ip'],
      config['host'],
      nestedPrinter?['printerIp'],
      nestedPrinter?['ipAddress'],
      nestedPrinter?['ip'],
      nestedPrinter?['host'],
    ];
    for (final value in candidates) {
      final ip = value?.toString().trim() ?? '';
      if (ip.isNotEmpty) return ip;
    }
    return null;
  }

  int _extractPrinterPort(dynamic rawConfig, {int fallback = 9100}) {
    if (rawConfig is! Map) return fallback;
    final config = Map<String, dynamic>.from(rawConfig);
    final nestedPrinter = config['printer'] is Map
        ? Map<String, dynamic>.from(config['printer'])
        : null;
    final candidates = [
      config['printerPort'],
      config['port'],
      nestedPrinter?['printerPort'],
      nestedPrinter?['port'],
    ];
    for (final value in candidates) {
      if (value is num) return value.toInt();
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null) return parsed;
      }
    }
    return fallback;
  }

  String _posPrintResultLabel(PosPrintResult result) {
    return '${result.msg} (code: ${result.value})';
  }

  Future<List<_PrinterTarget>> _resolvePrinterTargetsForTest() async {
    final prefs = await SharedPreferences.getInstance();
    final targetsByKey = <String, _PrinterTarget>{};

    void addTarget(String label, dynamic ipRaw, [dynamic portRaw]) {
      final ip = ipRaw?.toString().trim() ?? '';
      if (ip.isEmpty) return;
      final port = _parsePort(portRaw, fallback: 9100);
      final key = '$ip:$port';
      targetsByKey.putIfAbsent(
        key,
        () => _PrinterTarget(label: label, ip: ip, port: port),
      );
    }

    addTarget(
      'Saved Receipt',
      prefs.getString('printerIp'),
      prefs.getString('printerPort'),
    );

    final token = prefs.getString('token');
    final branchId = prefs.getString('branchId');
    if (token == null ||
        token.isEmpty ||
        branchId == null ||
        branchId.isEmpty) {
      return targetsByKey.values.toList(growable: false);
    }

    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };

    try {
      final branchRes = await http
          .get(
            Uri.parse(
              'https://blackforest.vseyal.com/api/branches/$branchId?depth=1',
            ),
            headers: headers,
          )
          .timeout(const Duration(seconds: 5));
      if (branchRes.statusCode == 200) {
        final branch = jsonDecode(branchRes.body);
        addTarget('Branch Receipt', branch['printerIp'], branch['printerPort']);
      }
    } catch (e) {
      debugPrint('Printer test branch fetch failed: $e');
    }

    try {
      final globalRes = await http
          .get(
            Uri.parse(
              'https://blackforest.vseyal.com/api/globals/branch-geo-settings',
            ),
            headers: headers,
          )
          .timeout(const Duration(seconds: 5));
      if (globalRes.statusCode == 200) {
        final settings = jsonDecode(globalRes.body);
        final locations = settings['locations'];
        if (locations is List) {
          for (final rawLoc in locations) {
            if (rawLoc is! Map) continue;
            final loc = Map<String, dynamic>.from(rawLoc);
            final locBranchId = _toIdString(loc['branch']);
            if (locBranchId != branchId) continue;

            addTarget('Global Receipt', loc['printerIp'], loc['printerPort']);

            final kotPrinters = loc['kotPrinters'];
            if (kotPrinters is List) {
              for (var i = 0; i < kotPrinters.length; i++) {
                final printer = kotPrinters[i];
                addTarget(
                  'KOT ${i + 1}',
                  _extractPrinterIp(printer),
                  _extractPrinterPort(printer),
                );
              }
            }
            break;
          }
        }
      }
    } catch (e) {
      debugPrint('Printer test global fetch failed: $e');
    }

    return targetsByKey.values.toList(growable: false);
  }

  Future<_PrinterProbeResult> _probePrinterTarget(_PrinterTarget target) async {
    final profile = await CapabilityProfile.load();
    final printer = NetworkPrinter(PaperSize.mm80, profile);
    final candidatePorts = <int>{
      target.port,
      9100,
      9101,
    }.where((p) => p > 0).toList(growable: false);

    PosPrintResult lastResult = PosPrintResult.timeout;
    int? connectedPort;

    try {
      for (final port in candidatePorts) {
        debugPrint('Printer test connect attempt: ${target.ip}:$port');
        lastResult = await printer
            .connect(target.ip, port: port)
            .timeout(
              const Duration(seconds: 2),
              onTimeout: () => PosPrintResult.timeout,
            );
        debugPrint(
          'Printer test connect result: ${target.ip}:$port -> ${_posPrintResultLabel(lastResult)}',
        );
        if (lastResult == PosPrintResult.success) {
          connectedPort = port;
          break;
        }
      }
    } catch (e) {
      return _PrinterProbeResult(
        target: target,
        success: false,
        connectedPort: null,
        result: null,
        errorMessage: e.toString(),
      );
    } finally {
      // esc_pos_printer keeps socket as late-initialized; avoid disconnect when
      // connect never succeeded, otherwise it can throw LateInitializationError.
      if (connectedPort != null) {
        try {
          printer.disconnect();
        } catch (e) {
          debugPrint('Printer test disconnect error: $e');
        }
      }
    }

    return _PrinterProbeResult(
      target: target,
      success: connectedPort != null,
      connectedPort: connectedPort,
      result: lastResult,
      errorMessage: null,
    );
  }

  Future<void> _runPrinterTest() async {
    if (_isPrinterTestRunning) {
      _showMessage('Printer test already running');
      return;
    }
    _isPrinterTestRunning = true;
    _showMessage('Testing configured printers...');

    try {
      final targets = await _resolvePrinterTargetsForTest();
      if (targets.isEmpty) {
        _showMessage('No printer configured for this branch');
        return;
      }

      final results = <_PrinterProbeResult>[];
      for (final target in targets) {
        results.add(await _probePrinterTarget(target));
      }

      if (!mounted) return;
      final successCount = results.where((r) => r.success).length;
      final lines = <String>[];

      for (final result in results) {
        if (result.success) {
          final usedPort = result.connectedPort ?? result.target.port;
          final usedFallbackPort = usedPort != result.target.port;
          lines.add(
            'OK  ${result.target.label}: ${result.target.ip}:$usedPort${usedFallbackPort ? ' (fallback)' : ''}',
          );
        } else {
          final reason =
              result.errorMessage ??
              (result.result != null
                  ? _posPrintResultLabel(result.result!)
                  : 'Unknown error');
          lines.add(
            'FAIL ${result.target.label}: ${result.target.ip}:${result.target.port} -> $reason',
          );
        }
      }

      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Printer Test Result'),
          content: SingleChildScrollView(
            child: Text(
              'Reachable: $successCount/${results.length}\n\n${lines.join('\n')}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } finally {
      _isPrinterTestRunning = false;
    }
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
    final appBarLeading = widget.showBackButtonInAppBar
        ? Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
            child: InkWell(
              onTap: () {
                _resetTimer();
                Navigator.of(context).maybePop();
              },
              borderRadius: BorderRadius.circular(18),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFE2E5EA)),
                ),
                child: const Icon(
                  Icons.arrow_back_ios_new_rounded,
                  size: 15,
                  color: Colors.black87,
                ),
              ),
            ),
          )
        : Builder(
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
                Navigator.pushAndRemoveUntil(
                  context,
                  _createRoute(const EmployeePage()),
                  (route) => false,
                );
              },
            ),
          );
    return GestureDetector(
      onTap: _resetTimer,
      child: Scaffold(
        appBar: widget.showAppBar
            ? AppBar(
                backgroundColor: Colors.white,
                elevation: 1,
                leadingWidth: widget.showBackButtonInAppBar ? 46 : null,
                leading: appBarLeading,
                title: Text(
                  widget.title,
                  style: TextStyle(
                    color: Colors.black87,
                    fontWeight: FontWeight.w600,
                    fontSize: widget.showBackButtonInAppBar ? 16 : null,
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
              )
            : null,

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
              if (_showHomeNavigation)
                ListTile(
                  leading: const Icon(
                    Icons.home_outlined,
                    color: Colors.black87,
                  ),
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
              if (_showTableNavigation)
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
                      MaterialPageRoute(
                        builder: (context) => const TablePage(),
                      ),
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
                  Icons.print_outlined,
                  color: Colors.black87,
                ),
                title: const Text('Test Printer'),
                onTap: () {
                  _resetTimer();
                  Navigator.pop(context);
                  _runPrinterTest();
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
        bottomNavigationBar: widget.hideBottomNavigationBar
            ? null
            : _buildBottomNavigationBar(),
      ),
    );
  }

  bool _isNavItemSelected(PageType type) {
    switch (type) {
      case PageType.billing:
        return widget.pageType == PageType.billing ||
            widget.pageType == PageType.billsheet ||
            widget.pageType == PageType.editbill;
      default:
        return widget.pageType == type;
    }
  }

  Widget _buildBottomNavigationBar() {
    return Container(
      decoration: const BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 16,
            offset: Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Color(0xFFEAEAEA))),
          ),
          child: Row(
            children: [
              if (_showHomeNavigation)
                _buildNavItem(
                  icon: Icons.home_rounded,
                  label: 'Home',
                  page: const HomePage(),
                  type: PageType.home,
                ),
              _buildNavItem(
                icon: Icons.receipt_long_rounded,
                label: 'Billing',
                page: const CategoriesPage(),
                type: PageType.billing,
              ),
              _buildNavItem(
                icon: Icons.qr_code_scanner_rounded,
                label: 'Scan',
                onTap: _scanBarcode,
              ),
              if (_showTableNavigation)
                _buildNavItem(
                  icon: Icons.table_restaurant_rounded,
                  label: 'Table',
                  page: const TablePage(),
                  type: PageType.table,
                ),
              _buildNavItem(
                icon: Icons.forum_rounded,
                label: 'Chat',
                page: const ChatPage(),
                type: PageType.chat,
                activeColor: _chatNavColor,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required IconData icon,
    required String label,
    Widget? page,
    PageType? type,
    VoidCallback? onTap,
    Color? activeColor,
    Color? inactiveColor,
  }) {
    final bool isSelected = type != null && _isNavItemSelected(type);
    final Color foregroundColor = isSelected
        ? (activeColor ?? _navActiveColor)
        : (inactiveColor ?? _navInactiveColor);

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () {
            _resetTimer();
            if (onTap != null) {
              onTap();
              return;
            }
            if (page == null) return;
            Navigator.pushAndRemoveUntil(
              context,
              _createRoute(page),
              (route) => false,
            );
          },
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TweenAnimationBuilder<Color?>(
                  duration: const Duration(milliseconds: 180),
                  tween: ColorTween(end: foregroundColor),
                  builder: (context, color, child) {
                    return Icon(icon, color: color, size: 29);
                  },
                ),
                const SizedBox(height: 5),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  style: TextStyle(
                    color: foregroundColor,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.1,
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
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

class _PrinterTarget {
  final String label;
  final String ip;
  final int port;

  const _PrinterTarget({
    required this.label,
    required this.ip,
    required this.port,
  });
}

class _PrinterProbeResult {
  final _PrinterTarget target;
  final bool success;
  final int? connectedPort;
  final PosPrintResult? result;
  final String? errorMessage;

  const _PrinterProbeResult({
    required this.target,
    required this.success,
    required this.connectedPort,
    required this.result,
    required this.errorMessage,
  });
}

// ScannerDialog for barcode scanning
class ScannerDialog extends StatefulWidget {
  const ScannerDialog({super.key});

  @override
  State<ScannerDialog> createState() => _ScannerDialogState();
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
