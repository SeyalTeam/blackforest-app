import 'dart:async';
import 'dart:ui';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'attendance_manager.dart';

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'my_foreground', // id
    'TRACKER BACKGROUND SERVICE', // title
    description:
        'Maintains background location monitoring for auto attendance.',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'my_foreground',
      initialNotificationTitle: 'Blackforest Tracker Active',
      initialNotificationContent: 'Monitoring geofence for auto attendance',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await AttendanceManager.checkAndProcessAttendance(isBackground: true);
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();

  const storage = FlutterSecureStorage();

  // 1. Immediately start native movement-based position stream (instant geofence detection)
  AttendanceManager.startPositionStream(isBackground: true);

  // 2. Initial check on startup if user is logged in
  try {
    final prefs = await SharedPreferences.getInstance();
    final token = (await storage.read(key: 'token')) ?? prefs.getString('token');
    if (token != null && token.isNotEmpty) {
      await AttendanceManager.checkAndProcessAttendance(isBackground: true);
    }
  } catch (e) {
    debugPrint('Background attendance initial check error: $e');
  }

  // 3. Fallback heartbeat timer: 5 minutes (relieves battery & server load)
  Timer.periodic(const Duration(minutes: 5), (timer) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = (await storage.read(key: 'token')) ?? prefs.getString('token');
      if (token == null || token.isEmpty) return; // User not logged in

      await AttendanceManager.checkAndProcessAttendance(isBackground: true);
    } catch (e) {
      debugPrint('Background attendance service error: $e');
    }
  });
}
