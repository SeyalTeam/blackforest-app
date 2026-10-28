import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:blackforest_app/api_server_prefs.dart';
import 'package:blackforest_app/notification_service.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/chat_page.dart';
import 'package:blackforest_app/auth_session_manager.dart';
import 'package:blackforest_app/kot_auto_print_service.dart';

class GlobalKotRealtimeService {
  static final GlobalKotRealtimeService _instance = GlobalKotRealtimeService._internal();
  static GlobalKotRealtimeService get instance => _instance;

  GlobalKotRealtimeService._internal();

  io.WebSocket? _wsSocket;
  StreamSubscription<dynamic>? _wsSocketSubscription;
  bool _wsConnecting = false;
  int _wsConnectionGeneration = 0;
  Timer? _wsReconnectTimer;
  Timer? _pingTimer;
  
  String _wsToken = '';
  String _wsBranchId = '';
  String _wsKitchenId = '';
  String _currentUserId = '';
  bool _isChef = false;
  final Set<String> _chefAssignedCategoryIds = {};
  
  final AudioPlayer _audioPlayer = AudioPlayer();
  final Set<String> _seenEventIds = <String>{};
  final List<String> _seenEventIdOrder = <String>[];
  static const int _maxTrackedEventIds = 500;
  static const String _kotRealtimeTopic = 'kot.item-status';
  
  final _updateController = StreamController<void>.broadcast();
  Stream<void> get onUpdate => _updateController.stream;

  final _orderEventController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onOrderEvent => _orderEventController.stream;

  final _chatMessageController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onChatMessage => _chatMessageController.stream;

  final _callSignalController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onCallSignal => _callSignalController.stream;

  bool get isConnected => _wsSocket != null && _wsSocket!.readyState == io.WebSocket.open;

  bool _markEventAsSeen(String eventId) {
    final trimmed = eventId.trim();
    if (trimmed.isEmpty) return true;
    if (_seenEventIds.contains(trimmed)) return false;
    _seenEventIds.add(trimmed);
    _seenEventIdOrder.add(trimmed);
    if (_seenEventIdOrder.length > _maxTrackedEventIds) {
      final removed = _seenEventIdOrder.removeAt(0);
      _seenEventIds.remove(removed);
    }
    return true;
  }
  
  Future<void> _loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    _wsToken = (prefs.getString('token') ?? prefs.getString('auth_token') ?? '').trim();
    if (_wsToken.isEmpty) {
      try {
        const storage = FlutterSecureStorage();
        _wsToken = (await storage.read(key: 'token') ?? '').trim();
      } catch (_) {}
    }
    _wsBranchId = (prefs.getString('branchId') ?? prefs.getString('branch') ?? prefs.getString('userBranchId') ?? '').trim();
    _wsKitchenId = (prefs.getString('kitchenId') ?? '').trim();
    _currentUserId = (prefs.getString('user_id') ?? prefs.getString('userId') ?? prefs.getString('employee_id') ?? '').trim();
    final userRole = (prefs.getString('role') ?? '').trim().toLowerCase();
    final chefCatList = prefs.getStringList('chef_assigned_category_ids') ?? <String>[];
    _chefAssignedCategoryIds.clear();
    _chefAssignedCategoryIds.addAll(chefCatList);
    _isChef = userRole == 'chef' || (userRole == 'kitchen' && _chefAssignedCategoryIds.isNotEmpty);
  }

  Future<void> connect() async {
    if (_wsConnecting) return;
    if (_wsSocket != null && _wsSocket!.readyState == io.WebSocket.open) return;
    
    _wsReconnectTimer?.cancel();
    await _loadSession();
    if (_wsToken.isEmpty) {
      debugPrint('GlobalKotRealtimeService: no token found, scheduling reconnect');
      _scheduleReconnect();
      return;
    }
    
    _wsConnecting = true;
    try {
      await ensureApiHostRoutingReady();
      final primaryHost = apiHostActive.trim().isNotEmpty ? apiHostActive.trim() : apiHostPrimary;
      final candidateHosts = <String>[
        primaryHost,
        if (primaryHost != 'blackforest-api.vseyal.com') 'blackforest-api.vseyal.com',
        if (primaryHost != 'blackforest.vseyal.com') 'blackforest.vseyal.com',
      ];

      io.WebSocket? connectedSocket;
      for (final host in candidateHosts) {
        try {
          final wsUri = Uri(scheme: 'wss', host: host, path: '/ws/v1');
          debugPrint('GlobalKotRealtimeService: connecting to $wsUri');
          final s = await io.WebSocket.connect(
            wsUri.toString(),
            headers: <String, dynamic>{'Authorization': 'Bearer $_wsToken'},
          ).timeout(const Duration(seconds: 6));
          connectedSocket = s;
          debugPrint('GlobalKotRealtimeService: connected successfully to $host');
          break;
        } catch (e) {
          debugPrint('GlobalKotRealtimeService: failed connecting to $host: $e');
        }
      }

      if (connectedSocket == null) {
        throw Exception('All candidate WebSocket hosts failed');
      }

      final generation = ++_wsConnectionGeneration;
      final socket = connectedSocket;
      
      if (generation != _wsConnectionGeneration) {
        await socket.close();
        return;
      }
      
      await _closeSocket(sendUnsubscribe: false);
      _wsSocket = socket;
      
      _wsSocketSubscription = socket.listen(
        (frame) => _handleFrame(frame, generation),
        onError: (_) => _handleClosed(generation, socket),
        onDone: () => _handleClosed(generation, socket),
        cancelOnError: false,
      );
      
      _sendSubscribe();
      _startPingTimer();
    } catch (_) {
      _scheduleReconnect();
    } finally {
      _wsConnecting = false;
    }
  }

  void _scheduleReconnect() {
    _wsReconnectTimer?.cancel();
    _wsReconnectTimer = Timer(const Duration(seconds: 5), connect);
  }

  void _handleClosed(int generation, io.WebSocket socket) {
    if (generation != _wsConnectionGeneration) return;
    _closeSocket();
    _scheduleReconnect();
  }

  Future<void> _closeSocket({bool sendUnsubscribe = false}) async {
    _pingTimer?.cancel();
    _pingTimer = null;
    final socket = _wsSocket;
    final sub = _wsSocketSubscription;
    _wsSocket = null;
    _wsSocketSubscription = null;
    
    try { await sub?.cancel(); } catch (_) {}
    if (socket == null) return;
    if (sendUnsubscribe) _sendUnsubscribe(socket);
    try { await socket.close(); } catch (_) {}
  }
  
  void _sendSubscribe() {
    if (_wsSocket == null || _wsSocket!.readyState != io.WebSocket.open) return;
    if (_wsBranchId.isEmpty) return;
    final payload = <String, dynamic>{
      'type': 'subscribe',
      'topic': _kotRealtimeTopic,
      'branchId': _wsBranchId,
    };
    if (_wsKitchenId.isNotEmpty) {
      payload['kitchenId'] = _wsKitchenId;
    }
    _wsSocket!.add(jsonEncode(payload));
  }
  
  void _sendUnsubscribe(io.WebSocket socket) {
    if (socket.readyState != io.WebSocket.open) return;
    if (_wsBranchId.isEmpty) return;
    final payload = <String, dynamic>{
      'type': 'unsubscribe',
      'topic': _kotRealtimeTopic,
      'branchId': _wsBranchId,
    };
    if (_wsKitchenId.isNotEmpty) {
      payload['kitchenId'] = _wsKitchenId;
    }
    socket.add(jsonEncode(payload));
  }

  void sendJsonMessage(Map<String, dynamic> data) {
    if (_wsSocket != null && _wsSocket!.readyState == io.WebSocket.open) {
      try {
        _wsSocket!.add(jsonEncode(data));
      } catch (e) {
        debugPrint('GlobalKotRealtimeService: error sending message: $e');
      }
    }
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_wsSocket != null && _wsSocket!.readyState == io.WebSocket.open) {
        try {
          _wsSocket!.add(jsonEncode({'action': 'ping', 'type': 'ping'}));
        } catch (_) {}
      }
    });
  }

  void _handleFrame(dynamic frame, int generation) {
    if (generation != _wsConnectionGeneration) return;
    
    Map<String, dynamic>? message;
    try {
      if (frame is String) {
        final decoded = jsonDecode(frame);
        if (decoded is Map) message = Map<String, dynamic>.from(decoded);
      } else if (frame is List<int>) {
        final decoded = jsonDecode(utf8.decode(frame));
        if (decoded is Map) message = Map<String, dynamic>.from(decoded);
      }
    } catch (_) { return; }
    
    if (message == null) return;
    
    final eventType = (message['eventType']?.toString() ?? '').toLowerCase();
    if (eventType.isEmpty) return;
    
    if (eventType == 'subscription_nack') {
      _scheduleReconnect();
      return;
    }
    
    if (eventType == 'session_conflict' ||
        eventType == 'session_terminated' ||
        eventType == 'account_blocked' ||
        eventType == 'auth_expired') {
      final reason = (message['reason'] ??
              message['message'] ??
              'Session ended. Please login again.')
          .toString();
      unawaited(
        AuthSessionManager.instance.handleUnauthorized(message: reason),
      );
      return;
    }
    
    if (eventType == 'resume_nack') {
      _scheduleReconnect();
      return;
    }
    
    if (eventType == 'pong' || eventType == 'unsubscribe_ack' || eventType == 'subscription_ack') {
      return;
    }

    if (eventType == 'chat_message_received') {
      unawaited(_handleChatMessage(message));
      return;
    }

    if (eventType == 'call_signal') {
      _callSignalController.add(message);
      return;
    }
    
    final isBillingOrOrderEvent = eventType == 'billing_item_status_changed' ||
        eventType == 'billing_item_preparing_time_changed' ||
        eventType == 'billing_status_changed' ||
        eventType == 'waiter_call_received' ||
        eventType.contains('billing') ||
        eventType.contains('order');

    if (!isBillingOrOrderEvent) {
      return;
    }
    
    final topic = message['topic']?.toString() ?? '';
    if (topic.isNotEmpty && topic != _kotRealtimeTopic) return;
    
    final branchId = message['branchId']?.toString() ?? '';
    if (_wsBranchId.isNotEmpty && branchId.isNotEmpty && branchId != _wsBranchId) return;
    
    final kitchenId = message['kitchenId']?.toString() ?? '';
    if (_wsKitchenId.isNotEmpty && kitchenId.isNotEmpty && kitchenId != _wsKitchenId) return;
    
    final eventId = message['eventId']?.toString() ?? '';
    if (!_markEventAsSeen(eventId)) return;

    // Handle instant Waiter Call Alert
    if (eventType == 'waiter_call_received') {
      try {
        _audioPlayer.play(AssetSource('sounds/alert.wav'));
      } catch (_) {}
      unawaited(KotAutoPrintService.syncWaiterCallAlertsOnly());
      _updateController.add(null);
      return;
    }
    
    // Play alert and show notification
    final statusAfter = (message['statusAfter']?.toString() ?? '').toLowerCase();
    final billingId = message['billingId']?.toString() ?? '';
    final tableName = (message['tableName'] ?? message['tableNo'] ?? message['table'])?.toString() ?? '';
    
    if (statusAfter == 'ordered' || statusAfter == 'pending' || statusAfter == 'confirmed') {
      if (_isChef) {
        if (_chefAssignedCategoryIds.isEmpty) {
          _updateController.add(null);
          return;
        }
        final notifCatId = (message['categoryId'] ?? '').toString().trim();
        if (notifCatId.isNotEmpty && !_chefAssignedCategoryIds.contains(notifCatId)) {
          _updateController.add(null);
          return;
        }
      }

      try {
        _audioPlayer.play(AssetSource('sounds/order.wav'));
      } catch (_) {}
      
      try {
        final notifTitle = (statusAfter == 'ordered' || statusAfter == 'pending')
            ? '🔔 New Order Received!'
            : '✅ Order Status Updated: ${statusAfter.toUpperCase()}';
        final notifBody = tableName.isNotEmpty
            ? 'Table: $tableName • Status: ${statusAfter.toUpperCase()}'
            : 'Order #${billingId.isNotEmpty ? billingId : ''} • Status: ${statusAfter.toUpperCase()}';
            
        NotificationService().showOrderNotification(
          id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          title: notifTitle,
          body: notifBody,
        );
      } catch (nErr) {
        debugPrint('Failed to display order notification: $nErr');
      }

      // Event-driven auto-printing: print instantly upon WebSocket event arrival
      unawaited(KotAutoPrintService.syncPendingWebsiteKots());
    }
    
    _updateController.add(null);
    _orderEventController.add(message);
  }

  Future<void> _handleChatMessage(Map<String, dynamic> message) async {
    final senderId = (message['senderId'] ?? '').toString();
    final senderName = (message['senderName'] ?? 'Admin').toString();
    final text = (message['text'] ?? '').toString();
    final threadId = (message['threadId'] ?? '').toString();
    final messageId = (message['messageId'] ?? '').toString();

    // Deduplicate event
    if (messageId.isNotEmpty && !_markEventAsSeen(messageId)) return;

    // Stream event to any active listeners (like open ChatPage)
    _chatMessageController.add(message);

    // If the message was sent by this device's user, don't alert themselves
    if (_currentUserId.isNotEmpty && senderId == _currentUserId) return;

    final prefs = await SharedPreferences.getInstance();
    final isChatPageActive = prefs.getBool('is_chat_page_active') ?? false;

    // Only play sound and show notification if user is NOT currently in the chat screen
    if (!isChatPageActive) {
      try {
        _audioPlayer.play(AssetSource('sounds/message.mp3'));
      } catch (_) {}

      try {
        NotificationService().showChatNotification(
          id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          title: senderName.isNotEmpty ? senderName : 'New Message',
          body: text.isNotEmpty ? text : 'New message received',
          payload: 'chat:$threadId',
        );
      } catch (e) {
        debugPrint('Failed to display chat notification: $e');
      }

      // Realtime increment of unread counter badge
      final currentUnread = CommonScaffold.unreadChatNotifier.value;
      CommonScaffold.setUnreadChatCount(currentUnread + 1);
      ChatPage.setUnreadChatCount(currentUnread + 1);
    }
  }
}
