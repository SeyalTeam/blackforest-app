import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as raw_http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:blackforest_app/api_server_prefs.dart';
import 'package:blackforest_app/session_prefs.dart';
import 'package:blackforest_app/app_update_required_page.dart';
import 'package:blackforest_app/app_version.dart';

class AuthSessionManager {
  AuthSessionManager._();

  static final AuthSessionManager instance = AuthSessionManager._();
  static const String pendingLogoutMessageKey = 'pendingLogoutMessage';
  static const String defaultSessionExpiredMessage =
      'Session expired. Please login again.';

  static const Duration _heartbeatInterval = Duration(seconds: 45);
  static const Duration _meTimeout = Duration(seconds: 8);
  static const Duration _locationTimeout = Duration(seconds: 6);
  static const Set<String> _strictGeoRoles = <String>{
    'branch',
    'waiter',
    'cashier',
  };
  static const double _geoFenceGraceMeters = 12;

  GlobalKey<NavigatorState>? _navigatorKey;
  Timer? _heartbeatTimer;
  bool _isHandlingUnauthorized = false;
  bool _isHandlingAppOutdated = false;
  bool _isSessionCheckRunning = false;

  void attachNavigatorKey(GlobalKey<NavigatorState> key) {
    _navigatorKey = key;
  }

  void startHeartbeat() {
    _heartbeatTimer?.cancel();
    unawaited(verifySession(force: true));
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
      // 1. Check app version first — works for both logged-in and logged-out states
      await _checkAppVersion();

      final timeout = force ? _meTimeout : const Duration(seconds: 5);
      final response = await _verifyMe(token: token, timeout: timeout);

      if (response.statusCode == 426) {
        // App version is outdated — _interceptResponse in app_http.dart handles this,
        // but catch it here too in case it slips through.
        String? msg;
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map) msg = decoded['message']?.toString();
        } catch (_) {}
        await handleAppOutdated(message: msg);
        return;
      }

      if (response.statusCode == 401 || response.statusCode == 403) {
        await handleUnauthorized(message: defaultSessionExpiredMessage);
        return;
      }

      await _enforceStrictGeoFenceIfNeeded(prefs);
    } catch (_) {
      // Keep current session on transient network failures.
    } finally {
      _isSessionCheckRunning = false;
    }
  }

  /// Calls the dedicated version-check endpoint and triggers the update
  /// screen if the server says this app version is no longer supported.
  Future<void> _checkAppVersion() async {
    if (_isHandlingAppOutdated) return;
    try {
      await ensureApiHostRoutingReady();
      final baseUri = Uri.https(apiHostPrimary, '/api/check-app-version');
      final candidateUris = buildApiHostCandidateUris(baseUri);
      final requestUri = candidateUris.first;

      final response = await raw_http
          .get(requestUri, headers: {'x-app-version': AppVersion.current})
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 426) {
        String? msg;
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map) msg = decoded['message']?.toString();
        } catch (_) {}
        await handleAppOutdated(message: msg);
      }
    } catch (_) {
      // Network error — do not block the session on transient failures.
    }
  }

  Future<raw_http.Response> _verifyMe({
    required String token,
    required Duration timeout,
  }) async {
    await ensureApiHostRoutingReady();
    final baseUri = Uri.https(apiHostPrimary, '/api/users/me');
    final candidateUris = buildApiHostCandidateUris(baseUri);

    TimeoutException? lastTimeout;
    Object? lastError;

    for (var index = 0; index < candidateUris.length; index++) {
      final requestUri = candidateUris[index];
      try {
        final response = await raw_http
            .get(requestUri, headers: {
              'Authorization': 'Bearer $token',
              'x-app-version': AppVersion.current,
            })
            .timeout(timeout);

        if (response.statusCode < 500) {
          return response;
        }

        if (index == candidateUris.length - 1) {
          return response;
        }
      } on TimeoutException catch (error) {
        lastTimeout = error;
        lastError = error;
      } catch (error) {
        lastError = error;
      }
    }

    if (lastTimeout != null) {
      throw lastTimeout;
    }

    throw lastError ?? Exception('Unable to verify active session');
  }

  Future<void> _enforceStrictGeoFenceIfNeeded(SharedPreferences prefs) async {
    final normalizedRole = (prefs.getString('role') ?? '').trim().toLowerCase();
    if (!_strictGeoRoles.contains(normalizedRole)) return;

    final branchLat = prefs.getDouble('branchLat');
    final branchLng = prefs.getDouble('branchLng');
    final configuredRadius = prefs.getInt('branchRadius') ?? 100;
    final branchRadius = configuredRadius <= 0 ? 100 : configuredRadius;
    if (branchLat == null || branchLng == null) return;

    final isLocationServiceEnabled =
        await Geolocator.isLocationServiceEnabled();
    if (!isLocationServiceEnabled) {
      await handleUnauthorized(
        message:
            'Session ended: location services are required while logged in.',
      );
      return;
    }

    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      await handleUnauthorized(
        message:
            'Session ended: location permission is required while logged in.',
      );
      return;
    }

    Position? position;
    try {
      position = await Geolocator.getLastKnownPosition();
      position ??= await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      ).timeout(_locationTimeout);
    } catch (_) {
      // Ignore transient location fetch issues and keep the active session.
      return;
    }
    final distance = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      branchLat,
      branchLng,
    );
    final allowedDistance = branchRadius + _geoFenceGraceMeters;
    if (distance <= allowedDistance) return;

    await handleUnauthorized(
      message:
          'Session ended: you are outside the allowed branch location. Please login again from your branch.',
    );
  }

  Future<void> handleUnauthorized({String? message}) async {
    if (_isHandlingUnauthorized) return;
    _isHandlingUnauthorized = true;

    try {
      final resolvedMessage = (message?.trim().isNotEmpty ?? false)
          ? message!.trim()
          : defaultSessionExpiredMessage;
      stopHeartbeat();
      final prefs = await SharedPreferences.getInstance();
      await clearSessionPreservingFavorites(prefs);
      await prefs.setString(pendingLogoutMessageKey, resolvedMessage);

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

  /// Navigates to the full-screen "Update Required" page and stops the
  /// heartbeat. The user cannot go back — they must update the app.
  Future<void> handleAppOutdated({String? message}) async {
    if (_isHandlingAppOutdated) return;
    _isHandlingAppOutdated = true;

    try {
      stopHeartbeat();

      final nav = _navigatorKey?.currentState;
      if (nav != null) {
        nav.pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => AppUpdateRequiredPage(
              message: message?.trim().isNotEmpty == true
                  ? message!
                  : 'This version of the app is no longer supported. Please update to continue.',
            ),
          ),
          (route) => false,
        );
      }
    } finally {
      _isHandlingAppOutdated = false;
    }
  }
}
