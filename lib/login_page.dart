import 'dart:async';
import 'dart:convert';
import 'package:blackforest_app/categories_page.dart';
import 'package:flutter/material.dart';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:blackforest_app/home_navigation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/home_page.dart';
import 'package:blackforest_app/session_prefs.dart';
import 'package:blackforest_app/auth_flags.dart';
import 'package:blackforest_app/table_customer_details_visibility_service.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:math';

// ---------------------------------------------------------
//  IDLE TIMEOUT WRAPPER (UNCHANGED)
// ---------------------------------------------------------
class IdleTimeoutWrapper extends StatefulWidget {
  final Widget child;
  final Duration timeout;

  const IdleTimeoutWrapper({
    super.key,
    required this.child,
    this.timeout = const Duration(hours: 6),
  });

  @override
  State<IdleTimeoutWrapper> createState() => _IdleTimeoutWrapperState();
}

class _IdleTimeoutWrapperState extends State<IdleTimeoutWrapper>
    with WidgetsBindingObserver {
  Timer? _timer;
  DateTime? _pauseTime;

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer(widget.timeout, _logout);
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await clearSessionPreservingFavorites(prefs);
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const LoginPage()),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      _timer?.cancel();
      _pauseTime = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      if (_pauseTime != null) {
        final diff = DateTime.now().difference(_pauseTime!);
        if (diff > widget.timeout) {
          _logout();
        } else {
          _startTimer();
        }
        _pauseTime = null;
      } else {
        _startTimer();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _startTimer(),
      onPointerMove: (_) => _startTimer(),
      onPointerUp: (_) => _startTimer(),
      child: widget.child,
    );
  }
}

// ---------------------------------------------------------
//  PREMIUM LOGIN PAGE + USERNAME-ONLY LOGIN
// ---------------------------------------------------------
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  static const String _appVersion = '1.0.0+1';

  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController(); // username input
  final _passwordController = TextEditingController();

  bool _isLoading = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _checkExistingSession();
  }

  // ---------------------------------------------------------
  //  CHECK EXISTING SESSION
  // ---------------------------------------------------------
  Future<void> _checkExistingSession() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString("token");

    if (token != null) {
      try {
        final res = await http
            .get(
              Uri.parse(
                "https://blackforest.vseyal.com/api/users/me?depth=5&showHiddenFields=true",
              ),
              headers: {"Authorization": "Bearer $token"},
            )
            .timeout(const Duration(seconds: 12));

        if (res.statusCode == 200) {
          final body = jsonDecode(res.body);
          final user = body is Map<String, dynamic>
              ? (body['user'] ?? body)
              : null;
          if (user is Map<String, dynamic>) {
            if (isForceLoggedOutUser(user)) {
              await clearSessionPreservingFavorites(prefs);
              if (mounted) {
                _showError(
                  "Your session was ended by admin. Please login again.",
                );
              }
              return;
            }

            if (isLoginBlockedUser(user)) {
              await clearSessionPreservingFavorites(prefs);
              if (mounted) {
                _showError(
                  "Login blocked by superadmin. Please contact administrator.",
                );
              }
              return;
            }

            // Store user-level name as a secondary identifier
            final name = user['name'] ?? user['username'];
            if (name != null) {
              await prefs.setString('user_name', name.toString());
            }

            // Ensure login timestamp exists for current session
            if (prefs.getInt('login_time') == null) {
              await prefs.setInt(
                'login_time',
                DateTime.now().millisecondsSinceEpoch,
              );
            }

            final userId =
                user['id']?.toString() ??
                user['_id']?.toString() ??
                user[r'$oid']?.toString();
            if (userId != null && userId.isNotEmpty) {
              await prefs.setString('user_id', userId);
            }

            final role = user['role']?.toString();
            if (role != null && role.isNotEmpty) {
              await prefs.setString('role', role);
            }

            // Extract Branch ID and Name
            dynamic branchRef = user["branch"];
            String? branchId;
            String? branchName;
            if (branchRef is Map) {
              branchId =
                  (branchRef["id"] ?? branchRef["_id"] ?? branchRef["\$oid"])
                      ?.toString();
              branchName = branchRef["name"]?.toString();
            } else {
              branchId = branchRef?.toString();
            }
            if (branchId != null) {
              await prefs.setString('branchId', branchId);
              if (branchName != null) {
                await prefs.setString('branchName', branchName);
              }
              debugPrint("Existing session: Branch ID recovered: $branchId");
            } else {
              debugPrint(
                "Existing session: No Branch ID found in user profile.",
              );
            }

            final emp = user['employee'];
            if (emp is Map<String, dynamic>) {
              final empId =
                  emp['id']?.toString() ??
                  emp['_id']?.toString() ??
                  emp[r'$oid']?.toString();
              if (empId != null && empId.isNotEmpty) {
                await prefs.setString('employee_id', empId);
              }

              // Strictly prioritize name from employee collection
              final empName = emp['name']?.toString();
              if (empName != null && empName.isNotEmpty) {
                await prefs.setString('employee_name', empName);
              }

              final empCode =
                  emp['employeeId']?.toString() ??
                  emp['employeeID']?.toString() ??
                  emp['empId']?.toString();
              if (empCode != null && empCode.isNotEmpty) {
                await prefs.setString('employee_code', empCode);
              }

              final photo = emp['photo'];
              String? photoUrl;
              if (photo is Map<String, dynamic>) {
                photoUrl =
                    photo['thumbnailURL']?.toString() ??
                    photo['thumbnailUrl']?.toString() ??
                    photo['url']?.toString();
              } else if (photo is String) {
                photoUrl = photo;
              }

              if (photoUrl != null && photoUrl.isNotEmpty) {
                if (photoUrl.startsWith('/')) {
                  photoUrl = 'https://blackforest.vseyal.com$photoUrl';
                }
                await prefs.setString('employee_photo_url', photoUrl);
              }
            }
          }

          final navigationVisibility = await Future.wait<bool>([
            HomeNavigationService.loadVisibilityForCurrentBranch(
              prefs: prefs,
              forceRefresh: true,
            ),
            HomeNavigationService.loadTableVisibilityForCurrentBranch(
              prefs: prefs,
              forceRefresh: true,
            ),
          ]);
          final showHomeNavigation = navigationVisibility[0];
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => IdleTimeoutWrapper(
                child: showHomeNavigation
                    ? const HomePage()
                    : const CategoriesPage(),
              ),
            ),
          );
          return;
        }
      } catch (_) {}

      await clearSessionPreservingFavorites(prefs);
    }
  }

  // ---------------------------------------------------------
  //  IP ALERT POPUP
  // ---------------------------------------------------------
  Future<void> _showIpAlert(
    String connectionType,
    String deviceIp,
    String branchInfo,
    String? printerIp,
  ) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          "Verification Success",
          style: TextStyle(
            color: Color(0xFF1A202C),
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          "Internet: $connectionType\n"
          "Device IP: $deviceIp\n$branchInfo\nPrinter IP: ${printerIp ?? 'Not Set'}",
          style: const TextStyle(color: Color(0xFF4A5568), fontSize: 15),
        ),
        actions: [
          TextButton(
            child: const Text(
              "OK",
              style: TextStyle(
                color: Color(0xFF1A202C),
                fontWeight: FontWeight.bold,
              ),
            ),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------
  //  HELPER FUNCTIONS
  // ---------------------------------------------------------
  int _ipToInt(String ip) {
    final p = ip.split('.').map(int.parse).toList();
    return p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3];
  }

  bool _isIpInRange(String deviceIp, String range) {
    final parts = range.split("-");
    if (parts.length != 2) return false;

    final start = _ipToInt(parts[0].trim());
    final end = _ipToInt(parts[1].trim());
    final dev = _ipToInt(deviceIp);

    return dev >= start && dev <= end;
  }

  Future<String> _getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? deviceId = prefs.getString('deviceId');
    if (deviceId == null) {
      final random = Random();
      deviceId =
          'dev_${DateTime.now().millisecondsSinceEpoch}_${random.nextInt(999999)}';
      await prefs.setString('deviceId', deviceId);
    }
    return deviceId;
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: const TextStyle(
            fontWeight: FontWeight.w500,
            color: Colors.white,
          ),
        ),
        backgroundColor: const Color(0xFF1A202C),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  Future<bool> _checkLocationPermission() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _showError('Location services are disabled.');
      return false;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        _showError('Location permissions are denied');
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      _showError(
        'Location permissions are permanently denied. Please enable in settings.',
      );
      return false;
    }

    return true;
  }

  // ---------------------------------------------------------
  //  LOGIN FUNCTION - USERNAME ONLY -> username@bf.com
  // ---------------------------------------------------------
  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    final info = NetworkInfo();
    String? deviceIp = await info.getWifiIP();

    // Check actual connectivity type
    final connectivityResults = await Connectivity().checkConnectivity();
    bool isWifi = connectivityResults.contains(ConnectivityResult.wifi);
    bool isMobile = connectivityResults.contains(ConnectivityResult.mobile);

    // Fallback: if connectivity check says nothing but we have an IP, assume WiFi
    // If it says both, prioritize WiFi for branch logic
    if (!isWifi && !isMobile && deviceIp != null) {
      isWifi = true;
    }

    // USERNAME / EMAIL PROCESSING
    String input = _emailController.text.trim();

    // If user typed only username → convert
    String finalEmail = input.contains("@") ? input : "$input@bf.com";

    // Enforce domain
    if (!finalEmail.endsWith("@bf.com")) {
      _showError("Only @bf.com domain allowed");
      setState(() => _isLoading = false);
      return;
    }

    final deviceId = await _getDeviceId();

    // Fetch Location for Backend Logging
    Position? currentPos;
    if (await _checkLocationPermission()) {
      try {
        currentPos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
          ),
        );
      } catch (e) {
        debugPrint("Optional location fetch failed: $e");
      }
    }

    try {
      final response = await http.post(
        Uri.parse("https://blackforest.vseyal.com/api/users/login"),
        headers: {
          "Content-Type": "application/json",
          "x-device-id": deviceId,
          if (deviceIp != null) "x-private-ip": deviceIp,
          if (currentPos != null) "x-latitude": currentPos.latitude.toString(),
          if (currentPos != null)
            "x-longitude": currentPos.longitude.toString(),
        },
        body: jsonEncode({
          "email": finalEmail,
          "password": _passwordController.text,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final user = data["user"];
        final role = user["role"];

        if (isForceLoggedOutUser(user)) {
          _showError("Your session was ended by admin. Please try again.");
          setState(() => _isLoading = false);
          return;
        }

        if (isLoginBlockedUser(user)) {
          _showError(
            "Login blocked by superadmin. Please contact administrator.",
          );
          setState(() => _isLoading = false);
          return;
        }

        // Allowed roles
        const allowedRoles = ["branch", "kitchen", "cashier", "waiter"];
        if (!allowedRoles.contains(role)) {
          _showError("Access denied: only branch-related users allowed.");
          setState(() => _isLoading = false);
          return;
        }

        dynamic branchRef = user["branch"];
        String? branchId;
        String? branchName;
        if (branchRef is Map) {
          branchId =
              branchRef["id"]?.toString() ??
              branchRef["_id"]?.toString() ??
              (branchRef["\$oid"]?.toString());
          // Some structures might have {"$oid": "..."} inside another map or just as a value
          if (branchId == null && branchRef.containsKey("\$oid")) {
            branchId = branchRef["\$oid"]?.toString();
          }
          branchName = branchRef["name"]?.toString();
        } else {
          branchId = branchRef?.toString();
        }

        if (branchId == null && role == "waiter") {
          // Attempt to identify branch
          try {
            final gRes = await http.get(
              Uri.parse(
                "https://blackforest.vseyal.com/api/globals/branch-geo-settings",
              ),
              headers: {
                "Authorization": "Bearer ${data['token']}",
                "Content-Type": "application/json",
              },
            );

            if (gRes.statusCode == 200) {
              final settings = jsonDecode(gRes.body);
              final locations = settings['locations'] as List?;
              if (locations != null) {
                // 1. Try IP Identification (First Priority for ALL connections)
                if (deviceIp != null) {
                  final ipMatchLoc = locations.firstWhere((loc) {
                    final locIp = loc['ipAddress']?.toString().trim();
                    return locIp != null &&
                        locIp.isNotEmpty &&
                        _isIpInRange(deviceIp, locIp);
                  }, orElse: () => null);

                  if (ipMatchLoc != null) {
                    final locBranch = ipMatchLoc['branch'];
                    if (locBranch is Map) {
                      branchId =
                          (locBranch['id'] ??
                                  locBranch['_id'] ??
                                  locBranch['\$oid'])
                              ?.toString();
                      branchName = locBranch['name']?.toString();
                    } else {
                      branchId = locBranch?.toString();
                    }
                    debugPrint("Auto-identified branch via IP: $branchId");
                  }
                }

                // 2. Try GPS Identification (Fallback for Mobile/Other only)
                if (branchId == null && !isWifi) {
                  Position? pos;
                  if (await _checkLocationPermission()) {
                    try {
                      pos = await Geolocator.getCurrentPosition(
                        locationSettings: const LocationSettings(
                          accuracy: LocationAccuracy.high,
                        ),
                      );
                    } catch (e) {
                      debugPrint("GPS fetch failed during identification: $e");
                    }
                  }

                  if (pos != null) {
                    final geoMatchLoc = locations.firstWhere((loc) {
                      final lat2 = loc['latitude'] != null
                          ? (loc['latitude'] as num).toDouble()
                          : null;
                      final lng2 = loc['longitude'] != null
                          ? (loc['longitude'] as num).toDouble()
                          : null;
                      final radius = loc['radius'] != null
                          ? (loc['radius'] as num).toInt()
                          : 100;

                      if (lat2 != null && lng2 != null) {
                        final dist = Geolocator.distanceBetween(
                          pos!.latitude,
                          pos.longitude,
                          lat2,
                          lng2,
                        );
                        return dist <= radius;
                      }
                      return false;
                    }, orElse: () => null);

                    if (geoMatchLoc != null) {
                      final locBranch = geoMatchLoc['branch'];
                      if (locBranch is Map) {
                        branchId =
                            (locBranch['id'] ??
                                    locBranch['_id'] ??
                                    locBranch['\$oid'])
                                ?.toString();
                        branchName = locBranch['name']?.toString();
                      } else {
                        branchId = locBranch?.toString();
                      }
                      debugPrint("Auto-identified branch via GPS: $branchId");
                    } else {
                      debugPrint(
                        "GPS Identification failed: No matching location found within radius.",
                      );
                    }
                  } else {
                    debugPrint("GPS fetch failed or permission denied.");
                  }
                }
              } else {
                debugPrint(
                  "Global branch-geo-settings returned empty locations list.",
                );
              }
            } else {
              debugPrint(
                "Failed to fetch branch-geo-settings: ${gRes.statusCode}",
              );
            }
          } catch (e) {
            debugPrint("Error auto-identifying waiter branch: $e");
          }
        }

        String? branchIpRange;
        String? printerIp;

        if (branchId != null) {
          // 1. Fetch from Priority Global Settings
          try {
            final gRes = await http.get(
              Uri.parse(
                "https://blackforest.vseyal.com/api/globals/branch-geo-settings",
              ),
              headers: {
                "Authorization": "Bearer ${data['token']}",
                "Content-Type": "application/json",
              },
            );

            if (gRes.statusCode == 200) {
              final settings = jsonDecode(gRes.body);
              final locations = settings['locations'] as List?;
              if (locations != null) {
                final branchConfig = locations.firstWhere((loc) {
                  final locBranch = loc['branch'];
                  String? locBranchId;
                  if (locBranch is Map) {
                    locBranchId =
                        locBranch['id']?.toString() ??
                        locBranch['_id']?.toString() ??
                        locBranch['\$oid']?.toString();
                  } else {
                    locBranchId = locBranch?.toString();
                  }
                  return locBranchId == branchId;
                }, orElse: () => null);

                if (branchConfig != null) {
                  branchIpRange = branchConfig['ipAddress']?.toString().trim();
                  printerIp = branchConfig['printerIp']?.toString().trim();
                  final configBranch = branchConfig['branch'];
                  if ((branchName?.trim().isEmpty ?? true) &&
                      configBranch is Map) {
                    branchName = configBranch['name']?.toString();
                  }
                  if (branchName?.trim().isEmpty ?? true) {
                    branchName =
                        branchConfig['branchName']?.toString() ??
                        branchConfig['name']?.toString();
                  }

                  // Store Geo settings for future use
                  final prefs = await SharedPreferences.getInstance();
                  if (branchConfig['latitude'] != null) {
                    await prefs.setDouble(
                      'branchLat',
                      (branchConfig['latitude'] as num).toDouble(),
                    );
                  }
                  if (branchConfig['longitude'] != null) {
                    await prefs.setDouble(
                      'branchLng',
                      (branchConfig['longitude'] as num).toDouble(),
                    );
                  }
                  if (branchConfig['radius'] != null) {
                    await prefs.setInt(
                      'branchRadius',
                      (branchConfig['radius'] as num).toInt(),
                    );
                  }
                }
              }
            }
          } catch (e) {
            debugPrint("Error fetching global settings: $e");
          }

          // 2. Fallback to Branches Collection if not found in global
          final shouldFetchBranchDetails =
              branchIpRange == null ||
              branchIpRange.isEmpty ||
              (branchName?.trim().isEmpty ?? true);
          if (shouldFetchBranchDetails) {
            final bRes = await http.get(
              Uri.parse(
                "https://blackforest.vseyal.com/api/branches/$branchId",
              ),
              headers: {
                "Authorization": "Bearer ${data['token']}",
                "Content-Type": "application/json",
              },
            );

            if (bRes.statusCode == 200) {
              final branch = jsonDecode(bRes.body);
              if (branchIpRange == null || branchIpRange.isEmpty) {
                branchIpRange = branch["ipAddress"]?.toString().trim();
              }
              if (printerIp == null || printerIp.isEmpty) {
                printerIp = branch["printerIp"]?.toString().trim();
              }
              final fetchedBranchName = branch["name"]?.toString();
              if (fetchedBranchName != null &&
                  fetchedBranchName.trim().isNotEmpty) {
                branchName = fetchedBranchName;
              }
            }
          }

          // --- VERIFICATION PHASE ---

          // 1. Try IP Verification (High Priority for BOTH WiFi and Mobile)
          bool isIpMatch = false;
          if (deviceIp != null &&
              branchIpRange != null &&
              branchIpRange.isNotEmpty) {
            isIpMatch = _isIpInRange(deviceIp, branchIpRange);
          }

          if (isIpMatch && deviceIp != null) {
            // SUCCESS via IP
            await _showIpAlert(
              isWifi ? "WiFi" : "Mobile Internet (IP Match)",
              deviceIp,
              "Branch IP matched",
              printerIp,
            );
          } else {
            // 2. Fallback to GPS Verification (for both WiFi and Mobile)
            final prefs = await SharedPreferences.getInstance();
            final branchLat = prefs.getDouble('branchLat');
            final branchLng = prefs.getDouble('branchLng');
            final branchRadius = prefs.getInt('branchRadius') ?? 100;

            if (branchLat != null && branchLng != null) {
              if (await _checkLocationPermission()) {
                try {
                  final pos = await Geolocator.getCurrentPosition(
                    locationSettings: const LocationSettings(
                      accuracy: LocationAccuracy.high,
                    ),
                  );
                  final distance = Geolocator.distanceBetween(
                    pos.latitude,
                    pos.longitude,
                    branchLat,
                    branchLng,
                  );

                  if (distance <= branchRadius) {
                    // SUCCESS via GPS
                    await _showIpAlert(
                      isWifi
                          ? "WiFi (GPS Match)"
                          : "Mobile Internet (GPS Match)",
                      "GPS Verified",
                      "Distance: ${distance.toStringAsFixed(1)}m",
                      printerIp,
                    );
                  } else {
                    _showError(
                      "Access Denied: You are ${distance.toStringAsFixed(0)}m away from branch",
                    );
                    setState(() => _isLoading = false);
                    return;
                  }
                } catch (e) {
                  _showError("GPS Error: $e");
                  setState(() => _isLoading = false);
                  return;
                }
              } else {
                setState(() => _isLoading = false);
                return;
              }
            } else {
              _showError("Access Denied: Branch Location not configured");
              setState(() => _isLoading = false);
              return;
            }
          }
        }

        // Save Session
        final prefs = await SharedPreferences.getInstance();
        TableCustomerDetailsVisibilityService.clearCache();
        await prefs.setString("token", data["token"]);
        await prefs.setString("role", role);
        await prefs.setString("email", finalEmail);
        if (branchId != null) await prefs.setString("branchId", branchId);
        if (branchName != null) await prefs.setString("branchName", branchName);
        if (deviceIp != null) await prefs.setString("lastLoginIp", deviceIp);
        if (printerIp != null) await prefs.setString("printerIp", printerIp);
        if (user['id'] != null) {
          await prefs.setString("user_id", user['id'].toString());
        }

        // Store user-level name as a secondary identifier
        final name = user['name'] ?? user['username'];
        if (name != null) {
          await prefs.setString('user_name', name.toString());
        }

        // Store login moment for working hours timer
        await prefs.setInt('login_time', DateTime.now().millisecondsSinceEpoch);

        // Store employee relation info if present
        final emp = user['employee'];
        if (emp != null) {
          if (emp is Map) {
            final empId =
                emp['id']?.toString() ??
                emp['_id']?.toString() ??
                emp[r'$oid']?.toString();
            if (empId != null) {
              await prefs.setString('employee_id', empId);
            }
            final empName = emp['name']?.toString();
            if (empName != null && empName.isNotEmpty) {
              await prefs.setString('employee_name', empName);
            }
            final empCode =
                emp['employeeId']?.toString() ??
                emp['employeeID']?.toString() ??
                emp['empId']?.toString();
            if (empCode != null && empCode.isNotEmpty) {
              await prefs.setString('employee_code', empCode);
            }

            final photo = emp['photo'];
            String? photoUrl;
            if (photo is Map) {
              photoUrl =
                  photo['thumbnailURL']?.toString() ??
                  photo['thumbnailUrl']?.toString() ??
                  photo['url']?.toString();
            } else if (photo is String) {
              photoUrl = photo;
            }
            if (photoUrl != null && photoUrl.isNotEmpty) {
              if (photoUrl.startsWith('/')) {
                photoUrl = 'https://blackforest.vseyal.com$photoUrl';
              }
              await prefs.setString('employee_photo_url', photoUrl);
            }
          } else {
            await prefs.setString('employee_id', emp.toString());
          }
        }

        // Navigate to the correct landing page.
        final navigationVisibility = await Future.wait<bool>([
          HomeNavigationService.loadVisibilityForCurrentBranch(
            prefs: prefs,
            forceRefresh: true,
          ),
          HomeNavigationService.loadTableVisibilityForCurrentBranch(
            prefs: prefs,
            forceRefresh: true,
          ),
        ]);
        final showHomeNavigation = navigationVisibility[0];
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => IdleTimeoutWrapper(
              child: showHomeNavigation
                  ? const HomePage()
                  : const CategoriesPage(),
            ),
          ),
        );
      } else {
        String errMsg = "Invalid credentials";
        try {
          final data = jsonDecode(response.body);
          if (data["errors"] != null &&
              data["errors"] is List &&
              data["errors"].isNotEmpty) {
            errMsg = data["errors"][0]["message"] ?? errMsg;
          } else if (data["message"] != null) {
            errMsg = data["message"];
          }
        } catch (_) {}
        _showError(errMsg);
      }
    } catch (e) {
      _showError("Network error: Check your internet");
    }

    if (mounted) setState(() => _isLoading = false);
  }

  // ---------------------------------------------------------
  //  PREMIUM UI
  // ---------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Gradient BG
          Container(
            decoration: const BoxDecoration(
              color: Color(0xFF2D0A0A), // Deep Maroon from Logo
            ),
          ),

          // Glass Card
          Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 380,
              padding: const EdgeInsets.all(22),
              decoration: const BoxDecoration(color: Colors.transparent),

              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white, width: 1.5),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(15),
                        child: Image.asset(
                          'assets/logo.png',
                          width: double.infinity,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                    const SizedBox(height: 25),

                    // USERNAME FIELD
                    _premiumInput(
                      controller: _emailController,
                      hint: "Enter your username ...",
                      icon: Icons.person_outline,
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) {
                          return "Enter username";
                        }

                        // If they type email manually, force domain
                        if (v.contains("@") && !v.endsWith("@bf.com")) {
                          return "Only @bf.com domain allowed";
                        }

                        return null;
                      },
                    ),

                    const SizedBox(height: 15),

                    // PASSWORD FIELD
                    _premiumInput(
                      controller: _passwordController,
                      hint: "Enter your password ...",
                      icon: Icons.lock_outline,
                      obscure: _obscurePassword,
                      suffix: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          color: const Color(0xFF718096),
                        ),
                        onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                      ),
                      validator: (v) => v!.isEmpty ? "Enter password" : null,
                    ),

                    const SizedBox(height: 25),

                    // LOGIN BUTTON
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _login,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF2D0A0A),
                          elevation: 4,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                        ),
                        child: _isLoading
                            ? const CircularProgressIndicator(
                                color: Color(0xFF2D0A0A),
                              )
                            : const Text(
                                "SIGN IN",
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1.2,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          Positioned(
            left: 0,
            right: 0,
            bottom: 10,
            child: SafeArea(
              child: Text(
                'Version $_appVersion',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // INPUT FIELD WIDGET
  Widget _premiumInput({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscure = false,
    Widget? suffix,
    FormFieldValidator<String>? validator,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: TextFormField(
        controller: controller,
        obscureText: obscure,
        validator: validator,
        style: const TextStyle(
          color: Color(0xFF4A5568),
          fontWeight: FontWeight.w500,
        ),
        decoration: InputDecoration(
          prefixIcon: Icon(icon, color: const Color(0xFF718096)),
          suffixIcon: suffix,
          hintText: hint,
          hintStyle: const TextStyle(
            color: Color(0xFFA0AEC0),
            fontWeight: FontWeight.w400,
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 15,
          ),
        ),
      ),
    );
  }
}
