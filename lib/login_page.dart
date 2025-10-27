import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/categories_page.dart'; // Assuming this is your main page after login

class IdleTimeoutWrapper extends StatefulWidget {
  final Widget child;
  final Duration timeout;

  const IdleTimeoutWrapper({
    super.key,
    required this.child,
    this.timeout = const Duration(hours: 6),
  });

  @override
  _IdleTimeoutWrapperState createState() => _IdleTimeoutWrapperState();
}

class _IdleTimeoutWrapperState extends State<IdleTimeoutWrapper> with WidgetsBindingObserver {
  Timer? _timer;
  DateTime? _pauseTime;

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer(widget.timeout, _logout);
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
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
        final duration = DateTime.now().difference(_pauseTime!);
        if (duration > widget.timeout) {
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

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  _LoginPageState createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;

  Future<void> _showIpAlert(String deviceIp, String branchInfo) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('IP Verification'),
          content: Text(
            'Fetched Device IP: $deviceIp\n$branchInfo',
            style: const TextStyle(fontSize: 16),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('OK'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _login() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
      });

      String? deviceIp;
      try {
        // Fetch device public IP address FIRST
        final ipResponse = await http.get(Uri.parse('https://api.ipify.org?format=json')).timeout(const Duration(seconds: 10));
        if (ipResponse.statusCode == 200) {
          final ipData = jsonDecode(ipResponse.body);
          deviceIp = ipData['ip']?.toString().trim(); // Trim any whitespace
          debugPrint('Fetched Device IP: $deviceIp'); // Enhanced logging
        } else {
          debugPrint('Failed to fetch IP address: ${ipResponse.statusCode}');
          deviceIp = null;
        }
      } on TimeoutException {
        debugPrint('IP fetch timeout');
        deviceIp = null;
      } catch (e) {
        debugPrint('IP Fetch Error: $e');
        deviceIp = null;
      }

      try {
        final response = await http.post(
          Uri.parse('https://admin.theblackforestcakes.com/api/users/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'email': _emailController.text,
            'password': _passwordController.text,
          }),
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final user = data['user'];
          final allowedRoles = ['branch', 'kitchen', 'cashier', 'waiter']; // Added 'waiter'
          if (!allowedRoles.contains(user['role'])) {
            _showError('Access denied: App for branch-related users only (branch, kitchen, cashier, waiter)');
            setState(() {
              _isLoading = false;
            });
            return;
          }

          dynamic branchRef = user['branch'];
          String? branchId;
          if (branchRef is Map) {
            branchId = branchRef['id']?.toString() ?? branchRef['_id']?.toString();
          } else {
            branchId = branchRef?.toString();
          }

          // For non-waiter roles that depend on branch
          String? branchIp;
          if (user['role'] != 'waiter' && branchId != null && branchId.isNotEmpty) {
            // Fetch branch details using the token (Payload CMS uses Bearer JWT)
            final branchResponse = await http.get(
              Uri.parse('https://admin.theblackforestcakes.com/api/branches/$branchId'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ${data['token']}',
              },
            ).timeout(const Duration(seconds: 10));

            if (branchResponse.statusCode == 200) {
              final branchData = jsonDecode(branchResponse.body);
              branchIp = branchData['ipAddress']?.toString().trim();
              debugPrint('Fetched Branch IP: $branchIp');
            } else {
              _showError('Failed to fetch branch details: ${branchResponse.statusCode}');
              setState(() {
                _isLoading = false;
              });
              return;
            }

            // IP restriction logic for non-waiter (only if branch has ipAddress set)
            if (branchIp != null && branchIp.isNotEmpty) {
              if (deviceIp == null) {
                _showError('Unable to fetch device IP for verification');
                setState(() {
                  _isLoading = false;
                });
                return;
              }

              debugPrint('IP Check - Device: "$deviceIp" vs Branch: "$branchIp"');
              if (deviceIp != branchIp) {
                _showError('Login restricted: Device IP ($deviceIp) does not match branch IP ($branchIp)');
                setState(() {
                  _isLoading = false;
                });
                return;
              }

              // Show alert on successful match for non-waiter
              debugPrint('IP Match Successful');
              await _showIpAlert(deviceIp, 'Branch IP: $branchIp (Matched)');
            } else {
              debugPrint('No IP restriction set for this branch - proceeding');
              if (deviceIp != null) {
                await _showIpAlert(deviceIp, 'Branch IP: Not Set (No Restriction)');
              }
            }
          } else if (user['role'] == 'waiter') {
            // For waiter: Fetch device IP and check against ALL branches
            if (deviceIp == null) {
              _showError('Unable to fetch device IP');
              setState(() {
                _isLoading = false;
              });
              return;
            }

            // Fetch all branches
            final allBranchesResponse = await http.get(
              Uri.parse('https://admin.theblackforestcakes.com/api/branches'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ${data['token']}',
              },
            ).timeout(const Duration(seconds: 10));

            String branchInfo = 'Matching Branches: None';
            if (allBranchesResponse.statusCode == 200) {
              final branchesData = jsonDecode(allBranchesResponse.body);
              if (branchesData['docs'] != null && branchesData['docs'] is List) {
                List<String> matchingBranches = [];
                for (var branch in branchesData['docs']) {
                  String? bIp = branch['ipAddress']?.toString().trim();
                  if (bIp != null && bIp == deviceIp) {
                    matchingBranches.add(branch['name']?.toString() ?? 'Unnamed Branch');
                  }
                }
                if (matchingBranches.isNotEmpty) {
                  branchInfo = 'Matching Branches: ${matchingBranches.join(', ')}';
                }
              }
            } else {
              debugPrint('Failed to fetch all branches: ${allBranchesResponse.statusCode}');
              branchInfo = 'Matching Branches: Unable to fetch';
            }

            // Show alert for waiter with IP and matching branches
            await _showIpAlert(deviceIp, branchInfo);
          }

          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('token', data['token']);
          await prefs.setString('role', user['role']);
          await prefs.setString('email', _emailController.text); // Store email
          if (branchId != null) {
            await prefs.setString('branchId', branchId);
          }
          if (deviceIp != null) {
            await prefs.setString('lastLoginIp', deviceIp);
          }

          // Navigate to categories page wrapped with idle timeout
          if (mounted) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => IdleTimeoutWrapper(
                  child: const CategoriesPage(),
                ),
              ),
            );
          }
        } else if (response.statusCode == 401) {
          _showError('Invalid credentials');
        } else {
          _showError('Server error: ${response.statusCode}');
        }
      } on TimeoutException {
        _showError('Request timeout: Check your internet');
      } catch (e) {
        _showError('Network error: Check your internet - $e');
      } finally {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.grey[800],
        duration: const Duration(seconds: 10),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Container(
              // Transparent container
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.grey.withOpacity(0.1),
                    spreadRadius: 2,
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Welcome Team',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.black,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Login',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.black,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _emailController,
                        decoration: InputDecoration(
                          labelText: 'Enter email',
                          labelStyle: const TextStyle(color: Color(0xFF4A4A4A)),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(4),
                            borderSide: const BorderSide(color: Color(0xFF4A4A4A)),
                          ),
                          filled: true, // Enable fill
                          fillColor: Colors.white, // White background
                          prefixIcon: const Icon(Icons.email, color: Colors.black),
                        ),
                        validator: (value) => value!.isEmpty ? 'Email required' : null,
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _passwordController,
                        decoration: InputDecoration(
                          labelText: 'Enter password',
                          labelStyle: const TextStyle(color: Color(0xFF4A4A4A)),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(4),
                            borderSide: const BorderSide(color: Color(0xFF4A4A4A)),
                          ),
                          filled: true, // Enable fill
                          fillColor: Colors.white, // White background
                          prefixIcon: const Icon(Icons.lock, color: Colors.black),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword ? Icons.visibility_off : Icons.visibility,
                              color: Colors.black,
                            ),
                            onPressed: () {
                              setState(() {
                                _obscurePassword = !_obscurePassword;
                              });
                            },
                          ),
                        ),
                        obscureText: _obscurePassword, // Toggle based on state
                        validator: (value) => value!.isEmpty ? 'Password required' : null,
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: _isLoading ? null : _login,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.black,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 48),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: _isLoading
                            ? const CircularProgressIndicator(color: Colors.white)
                            : const Text('Login', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}