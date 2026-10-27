import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_config.dart';
import 'geofence_util.dart';

class AttendanceManager {
  static final AttendanceManager instance = AttendanceManager._internal();
  AttendanceManager._internal();

  static final ValueNotifier<bool> isPunchedInNotifier =
      ValueNotifier<bool>(false);
  static bool get isPunchedIn => isPunchedInNotifier.value;

  final StreamController<Map<String, dynamic>> _updateController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onAttendanceUpdate =>
      _updateController.stream;

  Timer? _foregroundTimer;
  static bool _isExecuting = false;
  static DateTime? _lastActionTime;
  static int _consecutiveOutsideTicks = 0;
  static bool _hasActiveSessionCached = false;
  static DateTime? _lastServerFetchTime;
  static StreamSubscription<Position>? _positionStreamSubscription;

  /// Sets the global attendance punched-in state, notifies listeners, and persists.
  static Future<void> setPunchedInState(
    bool punchedIn, {
    String? punchInTime,
  }) async {
    isPunchedInNotifier.value = punchedIn;
    _hasActiveSessionCached = punchedIn;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_punched_in', punchedIn);
      const storage = FlutterSecureStorage();
      if (punchedIn) {
        if (punchInTime != null && punchInTime.isNotEmpty) {
          await prefs.setString('activePunchIn', punchInTime);
          await storage.write(key: 'activePunchIn', value: punchInTime);
        }
      } else {
        await prefs.remove('activePunchIn');
        await storage.delete(key: 'activePunchIn');
        await storage.delete(key: 'pastWorkSeconds');
      }
    } catch (e) {
      debugPrint('AttendanceManager setPunchedInState error: $e');
    }

    if (!instance._updateController.isClosed) {
      instance._updateController.add({
        'type': punchedIn ? 'punch_in' : 'punch_out',
        'isPunchedIn': punchedIn,
        'timestamp': DateTime.now().toIso8601String(),
      });
    }
  }

  /// Synchronous check from SharedPreferences whether user is punched in for today.
  static bool isPunchedInFromPrefs(SharedPreferences prefs) {
    final flag = prefs.getBool('is_punched_in');
    final punchInStr = prefs.getString('activePunchIn');
    if (punchInStr != null && punchInStr.isNotEmpty) {
      final punchInTime = DateTime.tryParse(punchInStr)?.toLocal();
      if (punchInTime != null) {
        final now = DateTime.now();
        final localMidnight = DateTime(now.year, now.month, now.day);
        if (punchInTime.isAfter(localMidnight)) {
          return flag ?? true;
        }
      }
    }
    return false;
  }

  /// Checks whether user is currently punched in for today.
  /// First checks local storage for instant result, then verifies with server if possible.
  Future<bool> checkAttendanceStatus({
    SharedPreferences? prefs,
    bool forceRefresh = false,
  }) async {
    final p = prefs ?? await SharedPreferences.getInstance();
    const storage = FlutterSecureStorage();

    // 1. Check local cache first
    String? cachedPunchIn = p.getString('activePunchIn');
    if (cachedPunchIn == null || cachedPunchIn.isEmpty) {
      cachedPunchIn = await storage.read(key: 'activePunchIn');
      if (cachedPunchIn != null && cachedPunchIn.isNotEmpty) {
        await p.setString('activePunchIn', cachedPunchIn);
      }
    }

    bool localActive = false;
    if (cachedPunchIn != null && cachedPunchIn.isNotEmpty) {
      final activeStart = DateTime.tryParse(cachedPunchIn)?.toLocal();
      if (activeStart != null) {
        final now = DateTime.now();
        final localMidnight = DateTime(now.year, now.month, now.day);
        if (activeStart.isAfter(localMidnight)) {
          localActive = p.getBool('is_punched_in') ?? true;
        }
      }
    }

    isPunchedInNotifier.value = localActive;
    _hasActiveSessionCached = localActive;

    // 2. Query server if token & userId exist
    final token = p.getString('token') ?? (await storage.read(key: 'token'));
    final userId = p.getString('userId') ??
        p.getString('user_id') ??
        (await storage.read(key: 'userId'));

    if (token == null || token.isEmpty || userId == null || userId.isEmpty) {
      await setPunchedInState(false);
      return false;
    }

    try {
      final now = DateTime.now();
      final localMidnight = DateTime(now.year, now.month, now.day);
      final queryDate = localMidnight
          .subtract(const Duration(days: 1))
          .toUtc()
          .toIso8601String();
      final queryDateStr = DateFormat('yyyy-MM-dd').format(localMidnight);

      final url =
          '${ApiConfig.baseUrl}/attendance?where[user][equals]=$userId&where[date][greater_than_equal]=$queryDate&sort=-date&limit=5';

      final response = await http
          .get(
            Uri.parse(url),
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final docs =
            (data is Map<String, dynamic> ? data['docs'] : null) as List?;
        if (docs != null) {
          Map<String, dynamic>? activeSession;
          for (final dynamic doc in docs) {
            if (doc is! Map<String, dynamic>) continue;
            final docDateStr = doc['dateString']?.toString() ?? '';
            final docDate = doc['date']?.toString() ?? '';
            final isTodayDoc = docDateStr == queryDateStr ||
                docDate.startsWith(queryDateStr);
            if (!isTodayDoc) continue;

            final acts = (doc['activities'] as List?) ?? [];
            for (int i = acts.length - 1; i >= 0; i--) {
              final a = acts[i];
              if (a is Map<String, dynamic> &&
                  a['type'] == 'session' &&
                  a['status'] == 'active') {
                final punchIn =
                    DateTime.tryParse(a['punchIn']?.toString() ?? '')?.toLocal();
                if (punchIn != null && punchIn.isAfter(localMidnight)) {
                  activeSession = a;
                  break;
                }
              }
            }
            if (activeSession != null) break;
          }

          final hasActive = activeSession != null;
          await setPunchedInState(
            hasActive,
            punchInTime: activeSession?['punchIn']?.toString(),
          );
          return hasActive;
        }
      }
    } catch (e) {
      debugPrint('AttendanceManager checkAttendanceStatus error: $e');
    }

    return localActive;
  }

  /// Starts the app-wide movement-stream watcher for instant geofence exit detection.
  void startForegroundWatcher() {
    _foregroundTimer?.cancel();
    _foregroundTimer = null;

    debugPrint('AttendanceManager: Starting movement-stream attendance watcher...');
    // Initial immediate check
    checkNow();

    // Start movement stream (triggers immediately when user moves 10 meters)
    startPositionStream(isBackground: false);
  }

  /// Stops the foreground attendance watcher (e.g. on user logout).
  void stopForegroundWatcher() {
    debugPrint('AttendanceManager: Stopping foreground attendance watcher.');
    _foregroundTimer?.cancel();
    _foregroundTimer = null;
    _positionStreamSubscription?.cancel();
    _positionStreamSubscription = null;
    _consecutiveOutsideTicks = 0;
  }

  /// Starts native movement stream with 10-meter distance filter for instant exit detection
  static void startPositionStream({bool isBackground = false}) {
    _positionStreamSubscription?.cancel();
    _positionStreamSubscription = null;

    try {
      const locationSettings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10, // Notifies immediately when user moves 10 meters
      );

      _positionStreamSubscription = Geolocator.getPositionStream(
        locationSettings: locationSettings,
      ).listen(
        (Position position) {
          unawaited(
            checkAndProcessAttendance(
              isBackground: isBackground,
              position: position,
            ),
          );
        },
        onError: (e) {
          debugPrint('AttendanceManager positionStream error: $e');
        },
      );
    } catch (e) {
      debugPrint('AttendanceManager startPositionStream error: $e');
    }
  }

  /// Immediately triggers a check and auto-punch-in / auto-punch-out evaluation.
  Future<void> checkNow() async {
    await checkAndProcessAttendance(isBackground: false);
  }

  /// Core logic executed by both the foreground manager and the background service.
  static Future<void> checkAndProcessAttendance({
    bool isBackground = false,
    Position? position,
  }) async {
    const storage = FlutterSecureStorage();
    if (_isExecuting) {
      debugPrint(
        'AttendanceManager: Check already in progress, skipping tick.',
      );
      return;
    }

    _isExecuting = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = (await storage.read(key: 'token')) ?? prefs.getString('token');
      final userId = (await storage.read(key: 'userId')) ?? prefs.getString('userId');
      final userRole = ((await storage.read(key: 'userRole')) ?? prefs.getString('userRole'))?.toLowerCase();
      
      if (userRole == 'watcher') {
        return;
      }

      if (token == null || token.isEmpty || userId == null || userId.isEmpty) {
        // User not logged in, nothing to do
        return;
      }

      // 1. Check GPS position & Geofence
      final geo = await GeofenceUtil.checkLocationAndGeofence(
        existingPosition: position,
      );
      final currentPos = geo.position;

      if (currentPos == null) {
        debugPrint(
          'AttendanceManager: Could not get GPS fix. Skipping attendance check.',
        );
        return;
      }

      final isInside = geo.isInside;
      final now = DateTime.now();

      // If user is safely inside branch and already has an active session, skip server query!
      if (isInside) {
        _consecutiveOutsideTicks = 0;
        final lastSync = _lastServerFetchTime;
        if (_hasActiveSessionCached &&
            lastSync != null &&
            now.difference(lastSync).inMinutes < 15) {
          // Still safely inside with active shift - no server query needed!
          return;
        }
      }

      // 2. Fetch today's attendance document for this user
      final localMidnight = DateTime(now.year, now.month, now.day);
      final queryDate = localMidnight
          .subtract(const Duration(days: 1))
          .toUtc()
          .toIso8601String();
      final queryDateStr = DateFormat('yyyy-MM-dd').format(localMidnight);

      final url =
          '${ApiConfig.baseUrl}/attendance?where[user][equals]=$userId&where[date][greater_than_equal]=$queryDate&sort=-date&limit=5';

      final response = await http
          .get(
            Uri.parse(url),
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        debugPrint(
          'AttendanceManager: Failed to fetch attendance (${response.statusCode})',
        );
        return;
      }

      final data = jsonDecode(response.body);
      final docs =
          (data is Map<String, dynamic> ? data['docs'] : null) as List?;
      if (docs == null) return;

      // 3. Stale session auto-close (past days active sessions)
      for (final dynamic doc in docs) {
        if (doc is! Map<String, dynamic>) continue;
        final acts = (doc['activities'] as List?) ?? [];
        bool modified = false;

        for (final dynamic a in acts) {
          if (a is Map<String, dynamic> &&
              a['type'] == 'session' &&
              a['status'] == 'active') {
            final punchIn = DateTime.tryParse(
              a['punchIn']?.toString() ?? '',
            )?.toLocal();
            if (punchIn != null && punchIn.isBefore(localMidnight)) {
              final endOfDay = DateTime(
                punchIn.year,
                punchIn.month,
                punchIn.day,
                23,
                59,
                59,
              );
              a['punchOut'] = endOfDay.toUtc().toIso8601String();
              a['status'] = 'closed';
              a['durationSeconds'] = endOfDay.difference(punchIn).inSeconds;
              a['punchOutType'] = 'auto';
              modified = true;
            }
          }
        }

        if (modified && doc['id'] != null) {
          try {
            await http.patch(
              Uri.parse(
                '${ApiConfig.baseUrl}/attendance/${doc['id']}',
              ),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'activities': acts}),
            );
          } catch (e) {
            debugPrint('AttendanceManager: Stale session close error: $e');
          }
        }
      }

      // 4. Resolve today's document and current session state
      String? docId;
      List<dynamic> rawActivities = [];

      if (docs.isNotEmpty && docs.first is Map<String, dynamic>) {
        final firstDoc = docs.first as Map<String, dynamic>;
        final docDateStr = firstDoc['dateString']?.toString() ?? '';
        if (docDateStr == queryDateStr ||
            (firstDoc['date']?.toString().startsWith(queryDateStr) == true)) {
          docId = firstDoc['id']?.toString();
          rawActivities = List<dynamic>.from(
            (firstDoc['activities'] as List?) ?? [],
          );
        }
      }

      Map<String, dynamic>? activeSession;
      bool activePhotoFound = true;
      String? latestPunchOutType;

      for (int i = rawActivities.length - 1; i >= 0; i--) {
        final a = rawActivities[i];
        if (a is Map<String, dynamic> &&
            a['type'] == 'session' &&
            a['status'] == 'active') {
          activeSession = a;
          final img = a['capturedImage'];
          activePhotoFound = img != null && img.toString().trim().isNotEmpty;
          break;
        }
      }

      if (activeSession == null) {
        // Find latest closed session punchOutType from today or previous doc
        for (final doc in docs) {
          final acts = (doc is Map ? doc['activities'] : null) as List?;
          if (acts == null) continue;
          for (int i = acts.length - 1; i >= 0; i--) {
            final a = acts[i];
            if (a is Map && a['type'] == 'session' && a['status'] == 'closed') {
              latestPunchOutType = a['punchOutType']?.toString();
              break;
            }
          }
          if (latestPunchOutType != null) break;
        }

        latestPunchOutType ??= await storage.read(key: 'lastPunchOutType');
      }

      _lastServerFetchTime = now;
      _hasActiveSessionCached = activeSession != null;
      unawaited(
        setPunchedInState(
          activeSession != null,
          punchInTime: activeSession?['punchIn']?.toString(),
        ),
      );

      debugPrint(
        'AttendanceManager tick: [bg=$isBackground] isInside=$isInside, hasActive=${activeSession != null}, hasPhoto=$activePhotoFound, lastPunchOut=$latestPunchOutType',
      );

      // ── 5. AUTO PUNCH OUT EVALUATION ──────────────────────────────────────
      if (activeSession != null) {
        final isApiError = geo.errorMessage != null && geo.errorMessage!.contains('API error');
        if (!isInside && !isApiError) {
          _consecutiveOutsideTicks++;

          // Immediate exit detection: trigger on 1 confirmed outside reading
          const int requiredTicks = 1;
          if (_consecutiveOutsideTicks >= requiredTicks) {
            // Punch out
            final punchInStr = activeSession['punchIn']?.toString() ?? '';
            final punchInTime = DateTime.tryParse(punchInStr)?.toLocal() ?? now;
            final durationSecs = now.difference(punchInTime).inSeconds;

            activeSession['punchOut'] = now.toUtc().toIso8601String();
            activeSession['status'] = 'closed';
            activeSession['durationSeconds'] = durationSecs > 0
                ? durationSecs
                : 0;
            activeSession['punchOutType'] = 'auto';

            final patchUrl =
                '${ApiConfig.baseUrl}/attendance/$docId';
            final patchRes = await http.patch(
              Uri.parse(patchUrl),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'activities': rawActivities}),
            );

            if (patchRes.statusCode == 200) {
              debugPrint('AttendanceManager: Auto punch-out SUCCESS!');
              await storage.write(key: 'lastPunchOutType', value: 'auto');
              _consecutiveOutsideTicks = 0;
              _hasActiveSessionCached = false;
              unawaited(setPunchedInState(false));

              await _showLocalNotification(
                id: 991,
                title: '🏢 Auto Punched Out',
                body:
                    'You left the branch area. Your work session has been automatically punched out.',
                payload: 'profile',
              );

              if (!isBackground) {
                instance._updateController.add({
                  'type': 'auto_punch_out',
                  'docId': docId,
                  'timestamp': now.toIso8601String(),
                });
              }
            } else {
              debugPrint(
                'AttendanceManager: Auto punch-out failed on server (${patchRes.statusCode}): ${patchRes.body}',
              );
            }
          }
        } else {
          // Inside branch
          _consecutiveOutsideTicks = 0;
        }
      }
      // ── 6. AUTO PUNCH IN EVALUATION ───────────────────────────────────────
      else {
        _consecutiveOutsideTicks = 0;
        // User rule: Auto punch-in only proceeds IF previous session ended via AUTO punch-out
        // AND it's NOT the first punch of the day (docId != null)
        final shouldAutoPunchIn = latestPunchOutType == 'auto' && docId != null;

        if (shouldAutoPunchIn && isInside) {
          // Debounce to prevent rapid re-triggering
          if (_lastActionTime != null &&
              now.difference(_lastActionTime!).inSeconds < 25) {
            debugPrint(
              'AttendanceManager: Auto punch-in debounced (recently executed).',
            );
            return;
          }
          _lastActionTime = now;

          final newActivity = {
            'type': 'session',
            'punchIn': now.toUtc().toIso8601String(),
            'status': 'active',
            'capturedImage': null,
            'punchInType': 'auto',
            'latitude': currentPos.latitude,
            'longitude': currentPos.longitude,
          };

          final updatedActivities = List<dynamic>.from(rawActivities)
            ..add(newActivity);
          final patchUrl = '${ApiConfig.baseUrl}/attendance/$docId';
          final patchRes = await http.patch(
            Uri.parse(patchUrl),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'activities': updatedActivities}),
          );

          if (patchRes.statusCode == 200) {
            debugPrint('AttendanceManager: Auto punch-in SUCCESS (patched)!');
            _hasActiveSessionCached = true;
            unawaited(setPunchedInState(true, punchInTime: now.toIso8601String()));
            await storage.delete(key: 'lastPunchOutType');

            await _showLocalNotification(
              id: 992,
              title: '⚡ Auto Punched In',
              body:
                  'You arrived at the branch! Session started. Tap here to add your selfie.',
              payload: 'auto_punch_in',
            );

            if (!isBackground) {
              instance._updateController.add({
                'type': 'auto_punch_in',
                'docId': docId,
                'timestamp': now.toIso8601String(),
              });
            }
          } else {
            debugPrint(
              'AttendanceManager: Auto punch-in PATCH failed (${patchRes.statusCode}): ${patchRes.body}',
            );
          }
        }
      }
    } catch (e) {
      debugPrint('AttendanceManager error: $e');
    } finally {
      _isExecuting = false;
    }
  }

  static Future<void> _showLocalNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    try {
      final notificationsPlugin = FlutterLocalNotificationsPlugin();

      const AndroidNotificationChannel channel = AndroidNotificationChannel(
        'auto_attendance_channel',
        'Auto Attendance Alerts',
        description:
            'Notifications for automatic punch-in and punch-out based on geofence',
        importance: Importance.max,
      );

      await notificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(channel);

      const AndroidNotificationDetails
      androidDetails = AndroidNotificationDetails(
        'auto_attendance_channel',
        'Auto Attendance Alerts',
        channelDescription:
            'Notifications for automatic punch-in and punch-out based on geofence',
        importance: Importance.max,
        priority: Priority.high,
        ticker: 'Attendance Alert',
        icon: '@mipmap/launcher_icon',
      );

      const NotificationDetails platformDetails = NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      );

      await notificationsPlugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: platformDetails,
        payload: payload,
      );
    } catch (e) {
      debugPrint('AttendanceManager notification error: $e');
    }
  }
}
