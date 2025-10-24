import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/categories_page.dart'; // Assuming this is your main page after login

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('token');
  runApp(MyApp(hasToken: token != null));
}

class MyApp extends StatelessWidget {
  final bool hasToken;

  const MyApp({super.key, required this.hasToken});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Black Forest App',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: hasToken ? const IdleTimeoutWrapper(child: CategoriesPage()) : const LoginPage(),
    );
  }
}

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

  Future<void> _login() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
      });

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
          final allowedRoles = ['branch', 'kitchen', 'cashier'];
          if (!allowedRoles.contains(user['role'])) {
            _showError('Access denied: App for branch-related users only (branch, kitchen, cashier)');
            setState(() {
              _isLoading = false;
            });
            return;
          }

          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('token', data['token']);
          await prefs.setString('role', user['role']);
          await prefs.setString('email', _emailController.text); // Store email

          if (user['branch'] != null) {
            // Assuming branch is an ID string; adjust if it's an object
            await prefs.setString('branchId', user['branch'].toString());
          }

          // Navigate to categories page wrapped with idle timeout
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => IdleTimeoutWrapper(
                child: const CategoriesPage(),
              ),
            ),
          );
        } else if (response.statusCode == 401) {
          _showError('Invalid credentials');
        } else {
          _showError('Server error');
        }
      } catch (e) {
        _showError('Network error: Check your internet');
      } finally {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.grey[800],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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