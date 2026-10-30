import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  final _onNotificationClick = StreamController<String?>.broadcast();
  Stream<String?> get onNotificationClick => _onNotificationClick.stream;

  Future<void> init() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    final DarwinInitializationSettings initializationSettingsDarwin =
        DarwinInitializationSettings(
          requestSoundPermission: true,
          requestBadgePermission: true,
          requestAlertPermission: true,
        );

    final InitializationSettings initializationSettings =
        InitializationSettings(
          android: initializationSettingsAndroid,
          iOS: initializationSettingsDarwin,
          macOS: initializationSettingsDarwin,
        );

    await flutterLocalNotificationsPlugin.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) async {
        _onNotificationClick.add(response.payload);
      },
    );

    // Check if app was launched from a notification
    final NotificationAppLaunchDetails? notificationAppLaunchDetails =
        await flutterLocalNotificationsPlugin.getNotificationAppLaunchDetails();
    if (notificationAppLaunchDetails?.didNotificationLaunchApp ?? false) {
      _onNotificationClick.add(
        notificationAppLaunchDetails?.notificationResponse?.payload,
      );
    }

    // Request permissions for Android 13+
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }

  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    const AndroidNotificationDetails androidNotificationDetails =
        AndroidNotificationDetails(
          'kitchen_updates', // channelId
          'Kitchen Updates', // channelName
          channelDescription: 'Notifications for kitchen status updates',
          importance: Importance.max,
          priority: Priority.high,
          ticker: 'Kitchen Update',
          playSound: false,
        );

    const NotificationDetails notificationDetails = NotificationDetails(
      android: androidNotificationDetails,
      iOS: DarwinNotificationDetails(),
      macOS: DarwinNotificationDetails(),
    );

    await flutterLocalNotificationsPlugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: notificationDetails,
      payload: payload,
    );
  }

  Future<void> showWaiterCallNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    const AndroidNotificationDetails androidNotificationDetails =
        AndroidNotificationDetails(
          'waiter_call_sos',
          'Waiter SOS Alerts',
          channelDescription: 'High priority alerts when customer calls waiter',
          importance: Importance.max,
          priority: Priority.max,
          ticker: 'Waiter Call SOS',
          playSound: true,
          enableVibration: true,
          fullScreenIntent: true,
          category: AndroidNotificationCategory.alarm,
          audioAttributesUsage: AudioAttributesUsage.alarm,
          visibility: NotificationVisibility.public,
          sound: RawResourceAndroidNotificationSound('table'),
        );

    const NotificationDetails notificationDetails = NotificationDetails(
      android: androidNotificationDetails,
      iOS: DarwinNotificationDetails(presentSound: true, sound: 'table.mp3'),
      macOS: DarwinNotificationDetails(presentSound: true),
    );

    await flutterLocalNotificationsPlugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: notificationDetails,
      payload: payload,
    );
  }

  Future<void> showChatNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    const AndroidNotificationDetails androidNotificationDetails =
        AndroidNotificationDetails(
          'chat_messages',
          'Chat Messages',
          channelDescription: 'Notifications for new chat messages',
          importance: Importance.max,
          priority: Priority.high,
          ticker: 'New Message',
          playSound: true,
          enableVibration: true,
          category: AndroidNotificationCategory.message,
          sound: RawResourceAndroidNotificationSound('message'),
        );

    const NotificationDetails notificationDetails = NotificationDetails(
      android: androidNotificationDetails,
      iOS: DarwinNotificationDetails(presentSound: true, sound: 'message.mp3'),
      macOS: DarwinNotificationDetails(presentSound: true),
    );

    await flutterLocalNotificationsPlugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: notificationDetails,
      payload: payload,
    );
  }

  Future<void> showOrderNotification({
    required int id,
    required String title,
    String? body,
    String? htmlTitle,
    String? payload,
    int timeoutMs = 3500,
  }) async {
    final AndroidNotificationDetails androidNotificationDetails =
        AndroidNotificationDetails(
          'order_realtime_alerts',
          'Order Alerts',
          channelDescription: 'High priority alerts for new orders and status updates',
          importance: Importance.max,
          priority: Priority.high,
          ticker: 'New Order Alert',
          playSound: true,
          enableVibration: true,
          fullScreenIntent: false,
          category: AndroidNotificationCategory.status,
          visibility: NotificationVisibility.public,
          sound: const RawResourceAndroidNotificationSound('order'),
          timeoutAfter: timeoutMs,
          autoCancel: true,
          styleInformation: BigTextStyleInformation(
            htmlTitle ?? title,
            htmlFormatBigText: htmlTitle != null,
            contentTitle: htmlTitle ?? title,
            htmlFormatContentTitle: htmlTitle != null,
            summaryText: (body != null && body.trim().isNotEmpty) ? body : null,
          ),
        );

    final NotificationDetails notificationDetails = NotificationDetails(
      android: androidNotificationDetails,
      iOS: const DarwinNotificationDetails(presentSound: true, sound: 'order.wav'),
      macOS: const DarwinNotificationDetails(presentSound: true),
    );

    final effectiveBody = (body != null && body.trim().isNotEmpty) ? body.trim() : null;

    await flutterLocalNotificationsPlugin.show(
      id: id,
      title: title,
      body: effectiveBody,
      notificationDetails: notificationDetails,
      payload: payload,
    );

    // Guaranteed auto-remove fallback after timeout so it never blocks the screen
    Future.delayed(Duration(milliseconds: timeoutMs), () {
      try {
        flutterLocalNotificationsPlugin.cancel(id: id);
      } catch (_) {}
    });
  }

  Future<void> cancelOrderNotifications() async {
    try {
      await flutterLocalNotificationsPlugin.cancelAll();
    } catch (_) {}
  }

  Future<void> showBackgroundNotification(
    int id,
    String title,
    String body,
  ) async {
    const androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'geofence_background',
      'Geofence Background',
      channelDescription: 'Used for background geofence events',
      importance: Importance.low,
      priority: Priority.low,
      showWhen: false,
    );
    const platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
    );
    await flutterLocalNotificationsPlugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: platformChannelSpecifics,
    );
  }
}
