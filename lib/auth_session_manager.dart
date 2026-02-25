import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as raw_http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:blackforest_app/session_prefs.dart';

class AuthSessionManager {
  AuthSessionManager._();

  static final AuthSessionManager instance = AuthSessionManager._();

  static const Duration _heartbeatInterval = Duration(seconds: 45);
  static const Duration _meTimeout = Duration(seconds: 8);

  GlobalKey<NavigatorState>? _navigatorKey;
  Timer? _heartbeatTimer;
  bool _isHandlingUnauthorized = false;
  bool _isSessionCheckRunning = false;

  void attachNavigatorKey(GlobalKey<NavigatorState> key) {
    _navigatorKey = key;
  }

  void startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      verifySession(force: true);
    });
  }

  void stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> verifySession({bool force = false}) async {
    if (_isSessionCheckRunning) return;

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    if (token == null || token.isEmpty) return;

    _isSessionCheckRunning = true;
    try {
      final timeout = force ? _meTimeout : const Duration(seconds: 5);
      final response = await raw_http
          .get(
            Uri.parse('https://blackforest.vseyal.com/api/users/me'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(timeout);

      if (response.statusCode == 401 || response.statusCode == 403) {
        await handleUnauthorized(
          message: 'Session expired. Please login again.',
        );
      }
    } catch (_) {
      // Keep current session on transient network failures.
    } finally {
      _isSessionCheckRunning = false;
    }
  }

  Future<void> handleUnauthorized({String? message}) async {
    if (_isHandlingUnauthorized) return;
    _isHandlingUnauthorized = true;

    try {
      stopHeartbeat();
      final prefs = await SharedPreferences.getInstance();
      await clearSessionPreservingFavorites(prefs);

      final nav = _navigatorKey?.currentState;
      if (nav != null) {
        nav.pushNamedAndRemoveUntil('/login', (route) => false);
      }

      // Intentionally no post-clear UI work here; keep this safe from context
      // lifecycle races while forced logout events can come from background calls.
    } finally {
      _isHandlingUnauthorized = false;
    }
  }
}
