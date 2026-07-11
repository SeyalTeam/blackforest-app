import 'dart:async';
import 'dart:convert';
import 'dart:io' as io; // For Platform check
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:blackforest_app/waiter_call_history_page.dart';
import 'package:blackforest_app/waiter_call_history_service.dart';
import 'package:blackforest_app/waiter_call_range_filter_service.dart';
import 'package:blackforest_app/kot_status_source_prefs.dart';
import 'package:blackforest_app/api_server_prefs.dart';
import 'package:blackforest_app/auth_session_manager.dart';
import 'package:blackforest_app/auth_flags.dart';
import 'package:blackforest_app/session_prefs.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:intl/intl.dart';
import 'package:blackforest_app/notification_service.dart';

enum PageType {
  home,
  billing,
  cart,
  billsheet,
  table,
  kot,
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
  final bool showDefaultAppBarActions;
  final List<Widget> appBarActions;

  const CommonScaffold({
    super.key,
    required this.title,
    required this.body,
    this.onScanCallback,
    required this.pageType,
    this.showAppBar = true,
    this.hideBottomNavigationBar = false,
    this.showBackButtonInAppBar = false,
    this.showDefaultAppBarActions = true,
    this.appBarActions = const [],
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
  final Set<String> _pendingWaiterEventKeys = <String>{};
  final Set<String> _resolvedWaiterEventKeys = <String>{};
  static const MethodChannel _volumeChannel = MethodChannel('blackforest.app/volume');
  int? _originalAlarmVolume;
  int? _originalMusicVolume;
  final AudioPlayer _waiterCallPlayer = AudioPlayer();
  WaiterCallAlertPayload? _activeWaiterCallPayload;
  Completer<void>? _activeWaiterCallCompleter;
  Timer? _activeWaiterAutoCloseTimer;
  String _activeWaiterCustomerName = '';
  String _activeWaiterKotLabel = 'KOT00';
  String _activeWaiterSectionLabel = '-';
  _WaiterOverlayAction _activeWaiterAction = _WaiterOverlayAction.none;
  String? _activeWaiterStatusMessage;
  Color _activeWaiterStatusColor = const Color(0xFF9095A7);
  bool _isOverlayDisposedByNavigation = false;

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

      if (io.Platform.isAndroid) {
        SharedPreferences.getInstance().then((prefs) {
          final token = (prefs.getString('token') ?? '').trim();
          final branchId = (prefs.getString('branchId') ?? '').trim();
          if (token.isNotEmpty && branchId.isNotEmpty) {
            unawaited(KotAutoPrintService.startService());
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _inactivityTimer?.cancel();
    _kitchenSyncTimer?.cancel();
    _sessionCheckTimer?.cancel();
    _activeWaiterAutoCloseTimer?.cancel();
    _isOverlayDisposedByNavigation = true;
    final waiterCompleter = _activeWaiterCallCompleter;
    if (waiterCompleter != null && !waiterCompleter.isCompleted) {
      waiterCompleter.complete();
    }
    unawaited(_waiterCallPlayer.dispose());
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

    // Periodic sync every 10 seconds
    _kitchenSyncTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
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
    final isForegroundServiceRunning =
        io.Platform.isAndroid && await FlutterForegroundTask.isRunningService;
    final alerts = isForegroundServiceRunning
        ? await KotAutoPrintService.syncWaiterCallAlertsOnly()
        : await KotAutoPrintService.syncPendingWebsiteKots();
    if (!mounted || alerts.isEmpty) {
      return;
    }

    for (final alert in alerts) {
      if (alert.isWaiterCall) {
        final eventKey = alert.waiterCall!.eventKey;
        if (_resolvedWaiterEventKeys.contains(eventKey)) {
          continue;
        }
        if (_pendingWaiterEventKeys.contains(eventKey)) {
          continue;
        }
        _pendingWaiterEventKeys.add(eventKey);
      }
      _websiteAlertQueue.add(alert);
    }
    if (_websiteAlertQueue.isEmpty) {
      return;
    }

    if (_isDrainingWebsiteAlertQueue) {
      return;
    }

    _isDrainingWebsiteAlertQueue = true;
    final messenger = ScaffoldMessenger.of(context);
    try {
      while (mounted && _websiteAlertQueue.isNotEmpty) {
        final alert = _websiteAlertQueue.removeAt(0);
        if (alert.isWaiterCall) {
          final payload = alert.waiterCall!;
          if (_resolvedWaiterEventKeys.contains(payload.eventKey)) {
            _pendingWaiterEventKeys.remove(payload.eventKey);
            continue;
          }
          try {
            await _showWaiterCallDialog(payload);
          } finally {
            _pendingWaiterEventKeys.remove(payload.eventKey);
          }
          continue;
        }

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

  String _formatWaiterTimestamp(String rawTimestamp) {
    final parsed = DateTime.tryParse(rawTimestamp);
    if (parsed == null) {
      return rawTimestamp;
    }
    return DateFormat('hh:mm a').format(parsed.toLocal());
  }

  String _formatKotLabel(String rawKotNumber) {
    final raw = rawKotNumber.trim();
    if (raw.isEmpty) return 'KOT00';
    final upper = raw.toUpperCase();

    String compactToken;
    if (upper.contains('-')) {
      final segments = upper.split('-').where((segment) => segment.isNotEmpty);
      compactToken = segments.isNotEmpty ? segments.last.trim() : upper;
    } else {
      compactToken = upper.trim();
    }

    final tokenWithoutKot = compactToken.replaceAll('KOT', '');
    final digits = tokenWithoutKot.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) {
      return 'KOT00';
    }
    final shortDigits = digits.length > 2
        ? digits.substring(digits.length - 2)
        : digits.padLeft(2, '0');
    return 'KOT$shortDigits';
  }

  Future<void> _startWaiterRingtone() async {
    try {
      await _waiterCallPlayer.stop();
      try {
        await _waiterCallPlayer.setAudioContext(
          AudioContext(
            android: const AudioContextAndroid(
              usageType: AndroidUsageType.alarm,
              contentType: AndroidContentType.sonification,
              audioMode: AndroidAudioMode.normal,
            ),
            iOS: AudioContextIOS(
              category: AVAudioSessionCategory.playback,
              options: const {
                AVAudioSessionOptions.mixWithOthers,
              },
            ),
          ),
        );
      } catch (contextError) {
        debugPrint('Failed to set AudioContext: $contextError');
      }

      try {
        // Override alarm volume
        final int? currentAlarmVol = await _volumeChannel.invokeMethod<int>('getAlarmVolume');
        if (currentAlarmVol != null) {
          _originalAlarmVolume = currentAlarmVol;
        }
        final int? maxAlarmVol = await _volumeChannel.invokeMethod<int>('getMaxAlarmVolume');
        if (maxAlarmVol != null) {
          await _volumeChannel.invokeMethod('setAlarmVolume', {'volume': maxAlarmVol});
        }

        // Override music/media volume as well (in case audioplayers uses media stream on some devices)
        final int? currentMusicVol = await _volumeChannel.invokeMethod<int>('getMusicVolume');
        if (currentMusicVol != null) {
          _originalMusicVolume = currentMusicVol;
        }
        final int? maxMusicVol = await _volumeChannel.invokeMethod<int>('getMaxMusicVolume');
        if (maxMusicVol != null) {
          await _volumeChannel.invokeMethod('setMusicVolume', {'volume': maxMusicVol});
        }
      } catch (volumeError) {
        debugPrint('Failed to override stream volume: $volumeError');
      }

      await _waiterCallPlayer.setReleaseMode(ReleaseMode.loop);
      await _waiterCallPlayer.play(AssetSource('sounds/table.mp3'));
    } catch (error) {
      debugPrint('Waiter ringtone play failed: $error');
    }
  }

  Future<void> _stopWaiterRingtone() async {
    try {
      await _waiterCallPlayer.stop();
      
      // Restore alarm volume
      final restoreAlarmVol = _originalAlarmVolume;
      if (restoreAlarmVol != null) {
        _originalAlarmVolume = null;
        try {
          await _volumeChannel.invokeMethod('setAlarmVolume', {'volume': restoreAlarmVol});
        } catch (volumeError) {
          debugPrint('Failed to restore alarm volume: $volumeError');
        }
      }

      // Restore music/media volume
      final restoreMusicVol = _originalMusicVolume;
      if (restoreMusicVol != null) {
        _originalMusicVolume = null;
        try {
          await _volumeChannel.invokeMethod('setMusicVolume', {'volume': restoreMusicVol});
        } catch (volumeError) {
          debugPrint('Failed to restore music volume: $volumeError');
        }
      }
    } catch (_) {}
  }

  Future<void> _showWaiterCallDialog(WaiterCallAlertPayload payload) async {
    // Keep feedback loud and tactile for SOS requests.
    final customerName = payload.customerName.trim().isEmpty
        ? 'Guest'
        : payload.customerName;
    final historyCustomerName = payload.callerRole != null
        ? '$customerName (Called by ${payload.callerRole})'
        : customerName;
    final kotLabel = _formatKotLabel(payload.kotNumber);
    unawaited(HapticFeedback.heavyImpact());
    unawaited(HapticFeedback.vibrate());

    if (!mounted) return;
    final sectionLabel = payload.section.trim().isEmpty ? '-' : payload.section;

    await WaiterCallHistoryService.recordIncomingCall(
      eventKey: payload.eventKey,
      billId: payload.billId,
      tableNumber: payload.tableNumber,
      section: payload.section,
      customerName: historyCustomerName,
      callTimestampIso: payload.timestampIso,
    );

    await _startWaiterRingtone();
    if (!mounted) return;
    final overlayClosed = Completer<void>();
    _activeWaiterAutoCloseTimer?.cancel();
    setState(() {
      _activeWaiterCallPayload = payload;
      _activeWaiterCallCompleter = overlayClosed;
      _activeWaiterCustomerName = customerName;
      _activeWaiterKotLabel = kotLabel;
      _activeWaiterSectionLabel = sectionLabel;
      _activeWaiterAction = _WaiterOverlayAction.none;
      _activeWaiterStatusMessage = null;
      _activeWaiterStatusColor = const Color(0xFF9095A7);
    });

    try {
      await overlayClosed.future;
    } finally {
      if (!_isOverlayDisposedByNavigation) {
        await KotAutoPrintService.markWaiterCallPresented(
          eventKey: payload.eventKey,
        );
      }
    }
  }

  Future<void> _dismissActiveWaiterCallOverlay() async {
    _activeWaiterAutoCloseTimer?.cancel();
    _activeWaiterAutoCloseTimer = null;

    final dismissedPayload = _activeWaiterCallPayload;
    if (dismissedPayload != null) {
      _resolvedWaiterEventKeys.add(dismissedPayload.eventKey);
      try {
        await NotificationService()
            .flutterLocalNotificationsPlugin
            .cancel(id: dismissedPayload.eventKey.hashCode);
      } catch (e) {
        debugPrint('Failed to cancel local notification: $e');
      }
    }

    final overlayClosed = _activeWaiterCallCompleter;
    _activeWaiterCallCompleter = null;

    if (mounted) {
      setState(() {
        _activeWaiterCallPayload = null;
        _activeWaiterAction = _WaiterOverlayAction.none;
        _activeWaiterStatusMessage = null;
        _activeWaiterStatusColor = const Color(0xFF9095A7);
      });
    }

    await _stopWaiterRingtone();

    if (overlayClosed != null && !overlayClosed.isCompleted) {
      overlayClosed.complete();
    }
  }

  Future<void> _handleQrScanToAccept(WaiterCallAlertPayload payload) async {
    if (_activeWaiterAction != _WaiterOverlayAction.none) {
      return;
    }

    _resetTimer();
    if (!io.Platform.isAndroid && !io.Platform.isIOS) {
      setState(() {
        _activeWaiterStatusMessage = 'Scanner not supported on this platform';
        _activeWaiterStatusColor = const Color(0xFFE53935);
      });
      return;
    }

    final scannedValue = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      pageBuilder: (context, anim1, anim2) => const ScannerDialog(),
      transitionBuilder: (context, anim1, anim2, child) {
        return FadeTransition(opacity: anim1, child: child);
      },
    );

    if (scannedValue == null) {
      setState(() {
        _activeWaiterStatusMessage = 'Scan cancelled';
        _activeWaiterStatusColor = const Color(0xFFE53935);
      });
      return;
    }

    final targetTableNum = WaiterCallRangeFilterService.parseTableToken(payload.tableNumber);
    final scannedTableNum = _extractTableNumberFromQr(scannedValue);

    if (targetTableNum != null && scannedTableNum == targetTableNum) {
      setState(() {
        _activeWaiterStatusMessage = 'Table verified. Accepting...';
        _activeWaiterStatusColor = const Color(0xFF3CC14A);
      });
      await _handleAcceptWaiterCallOverlay();
    } else {
      setState(() {
        _activeWaiterStatusMessage = scannedTableNum == null
            ? 'Invalid QR code scanned'
            : 'Scanned Table $scannedTableNum (Expected: Table $targetTableNum)';
        _activeWaiterStatusColor = const Color(0xFFE53935);
      });
    }
  }

  int? _extractTableNumberFromQr(String rawCode) {
    final trimmed = rawCode.trim();
    if (trimmed.isEmpty) return null;

    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasQuery) {
      for (final param in ['table', 'tableNumber', 'table_number', 't']) {
        final val = uri.queryParameters[param];
        if (val != null) {
          final parsed = int.tryParse(val.trim());
          if (parsed != null && parsed > 0) return parsed;
        }
      }
    }

    final pathSegments = uri?.pathSegments ?? const <String>[];
    for (int i = 0; i < pathSegments.length - 1; i++) {
      if (pathSegments[i].toLowerCase() == 'table' || pathSegments[i].toLowerCase() == 't') {
        final nextSeg = pathSegments[i + 1].trim();
        final parsed = int.tryParse(nextSeg);
        if (parsed != null && parsed > 0) return parsed;
      }
    }

    return WaiterCallRangeFilterService.parseTableToken(trimmed);
  }

  Future<void> _handleAcceptWaiterCallOverlay() async {
    final payload = _activeWaiterCallPayload;
    if (payload == null || _activeWaiterAction != _WaiterOverlayAction.none) {
      return;
    }

    _resolvedWaiterEventKeys.add(payload.eventKey);
    _activeWaiterAutoCloseTimer?.cancel();
    // Close immediately on accept; send ACK in background.
    _activeWaiterAction = _WaiterOverlayAction.accepting;
    await _dismissActiveWaiterCallOverlay();
    unawaited(
      KotAutoPrintService.markWaiterCallHandled(eventKey: payload.eventKey),
    );

    final result = await _acknowledgeWaiterCall(payload);
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final isHandledConfirmation = result.ok || result.alreadyAcknowledged;
    if (!isHandledConfirmation) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(result.message),
          backgroundColor: const Color(0xFFC92A2A),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    await KotAutoPrintService.markWaiterCallHandled(eventKey: payload.eventKey);

    final acknowledgedBy = result.acknowledgedBy.trim().isEmpty
        ? 'Staff'
        : result.acknowledgedBy.trim();
    await WaiterCallHistoryService.markAccepted(
      eventKey: payload.eventKey,
      acknowledgedBy: acknowledgedBy,
    );

    if (!mounted) return;
    const acceptedText = 'Request accepted';
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(acceptedText),
        backgroundColor: const Color(0xFF1E8E3E),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildActiveWaiterCallOverlay() {
    final payload = _activeWaiterCallPayload;
    if (payload == null) {
      return const SizedBox.shrink();
    }
    final isSubmitting = _activeWaiterAction != _WaiterOverlayAction.none;
    final isAccepting = _activeWaiterAction == _WaiterOverlayAction.accepting;

    return Positioned(
      top: 8,
      left: 12,
      right: 12,
      child: SafeArea(
        bottom: false,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
            decoration: BoxDecoration(
              color: const Color(0xFF2F3136),
              borderRadius: BorderRadius.circular(26),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x40000000),
                  blurRadius: 22,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        payload.tableNumber == '0'
                            ? 'GENERAL CALL'
                            : 'TABLE - ${payload.tableNumber}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 23,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        payload.callerRole != null
                            ? 'Called by ${payload.callerRole}'
                            : '$_activeWaiterCustomerName - $_activeWaiterKotLabel',
                        style: const TextStyle(
                          color: Color(0xFFD7DDE8),
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'SECTION $_activeWaiterSectionLabel • ${_formatWaiterTimestamp(payload.timestampIso)}',
                        style: const TextStyle(
                          color: Color(0xFFB8C0CE),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (_activeWaiterStatusMessage != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          _activeWaiterStatusMessage!,
                          style: TextStyle(
                            color: _activeWaiterStatusColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      onTap: isSubmitting
                          ? null
                          : () => unawaited(_handleQrScanToAccept(payload)),
                      borderRadius: BorderRadius.circular(28),
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: const BoxDecoration(
                          color: Color(0xFF3CC14A),
                          shape: BoxShape.circle,
                        ),
                        child: isAccepting
                            ? const Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    color: Colors.white,
                                  ),
                                ),
                              )
                            : const Icon(
                                Icons.qr_code_scanner_rounded,
                                color: Colors.white,
                                size: 30,
                              ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<_WaiterAckResult> _acknowledgeWaiterCall(
    WaiterCallAlertPayload payload,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token')?.trim() ?? '';
      final branchId = prefs.getString('branchId')?.trim() ?? '';
      final lastLoginIp = prefs.getString('lastLoginIp')?.trim() ?? '';
      final deviceId = prefs.getString('deviceId')?.trim() ?? '';
      if (token.isEmpty || branchId.isEmpty) {
        return const _WaiterAckResult(
          ok: false,
          alreadyAcknowledged: false,
          acknowledgedBy: '',
          message: 'Session missing. Please login again.',
        );
      }

      final response = await http
          .post(
            Uri.parse('https://blackforest4.vseyal.com/api/call-waiter/ack'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'x-branch-id': branchId,
              'x-branch': branchId,
              if (lastLoginIp.isNotEmpty) 'x-private-ip': lastLoginIp,
              if (deviceId.isNotEmpty) 'x-device-id': deviceId,
            },
            body: jsonEncode({
              'branchId': branchId,
              'branch': branchId,
              'selectedBranchId': branchId,
              'billId': payload.billId,
              'callTimestamp': payload.timestampIso,
            }),
          )
          .timeout(const Duration(seconds: 12));

      Map<String, dynamic> body = const <String, dynamic>{};
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) {
          body = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        body = const <String, dynamic>{};
      }

      final ok = body['ok'] == true;
      final alreadyAcknowledged = body['alreadyAcknowledged'] == true;
      final acknowledgedBy = (body['acknowledgedBy'] ?? '').toString().trim();
      final backendError =
          body['errors'] is List && (body['errors'] as List).isNotEmpty
          ? (body['errors'] as List).first.toString()
          : '';
      final defaultMessage = ok || alreadyAcknowledged
          ? 'Waiter call acknowledged'
          : 'Unable to acknowledge waiter call';
      final message = (body['message'] ?? backendError).toString().trim();

      if (response.statusCode == 401 || response.statusCode == 403) {
        unawaited(
          AuthSessionManager.instance.handleUnauthorized(
            message: AuthSessionManager.defaultSessionExpiredMessage,
          ),
        );
        return _WaiterAckResult(
          ok: false,
          alreadyAcknowledged: false,
          acknowledgedBy: acknowledgedBy,
          message: message.isEmpty
              ? 'Not authorized to acknowledge this call.'
              : message,
        );
      }

      return _WaiterAckResult(
        ok: ok,
        alreadyAcknowledged: alreadyAcknowledged,
        acknowledgedBy: acknowledgedBy,
        message: message.isEmpty ? defaultMessage : message,
      );
    } catch (_) {
      return const _WaiterAckResult(
        ok: false,
        alreadyAcknowledged: false,
        acknowledgedBy: '',
        message: 'Network error. Please try again.',
      );
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
            Uri.parse('https://blackforest4.vseyal.com/api/users/me'),
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
        await AuthSessionManager.instance.handleUnauthorized(
          message: AuthSessionManager.defaultSessionExpiredMessage,
        );
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
              'https://blackforest4.vseyal.com/api/attendance?where[user][equals]=$userId&where[activities.status][equals]=active&limit=1';
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
                        'https://blackforest4.vseyal.com/api/attendance/$sessionId',
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

      if (mounted) {
        await Provider.of<CartProvider>(
          context,
          listen: false,
        ).clearAllDrafts(notify: false);
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
        'branchIp',
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
              'https://blackforest4.vseyal.com/api/branches/$branchId?depth=1',
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
              'https://blackforest4.vseyal.com/api/globals/branch-geo-settings',
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
    final defaultAppBarActions = <Widget>[
      IconButton(
        icon: const Icon(Icons.call_outlined, color: Colors.black87, size: 22),
        onPressed: () {
          _resetTimer();
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const WaiterCallHistoryPage(),
            ),
          );
        },
      ),
      Consumer<CartProvider>(
        builder: (context, cartProvider, child) {
          final int notifyCount = cartProvider.kitchenNotifications.length;

          return Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.notifications_none_outlined),
                onPressed: () {
                  _resetTimer();
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const KitchenNotificationsPage(),
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
                      style: const TextStyle(color: Colors.white, fontSize: 10),
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
                    MaterialPageRoute(builder: (context) => const CartPage()),
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
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ];
    final appBarActions = <Widget>[
      if (widget.showDefaultAppBarActions) ...defaultAppBarActions,
      ...widget.appBarActions,
    ];
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
                actions: appBarActions,
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
                    if (widget.pageType == PageType.home) {
                      return;
                    }
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
                  if (_isNavItemSelected(PageType.billing)) {
                    return;
                  }
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
                    if (widget.pageType == PageType.table) {
                      return;
                    }
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
        body: Stack(children: [widget.body, _buildActiveWaiterCallOverlay()]),
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
                icon: Icons.bolt_rounded,
                label: 'KOT',
                page: const KotPage(),
                type: PageType.kot,
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

class KotPage extends StatefulWidget {
  const KotPage({super.key});

  @override
  State<KotPage> createState() => _KotPageState();
}

class _KotPageState extends State<KotPage> {
  static const Duration _fallbackPollInterval = Duration(seconds: 30);
  static const Duration _wsRefreshDebounceInterval = Duration(
    milliseconds: 250,
  );
  static const int _maxTrackedEventIds = 500;
  static const String _kotRealtimeTopic = 'kot.item-status';
  bool _isLoading = true;
  String? _errorMessage;
  String _role = '';
  String _kotSourceStatus = kotStatusSourceConfirmed;
  String _authToken = '';
  final List<_KotConfirmedItem> _items = <_KotConfirmedItem>[];
  final Set<String> _updatingKeys = <String>{};
  final Set<String> _inFlightDeliveryTokens = <String>{};
  final Map<String, List<Map<String, dynamic>>> _billItemsCacheByBillId =
      <String, List<Map<String, dynamic>>>{};
  final Map<String, String> _productImageById = <String, String>{};
  final Map<String, String> _productImageByName = <String, String>{};
  final Set<String> _productImageMissingIds = <String>{};
  final Set<String> _productImageMissingNames = <String>{};
  final Set<String> _seenEventIds = <String>{};
  final List<String> _seenEventIdOrder = <String>[];
  final Map<String, int> _latestSeqByBillId = <String, int>{};
  final Map<String, int> _latestItemVersionById = <String, int>{};
  final Map<String, DateTime> _latestItemUpdatedAtById = <String, DateTime>{};
  Timer? _refreshTimer;
  Timer? _clockTimer;
  Timer? _wsReconnectTimer;
  Timer? _wsRefreshTimer;
  io.WebSocket? _wsSocket;
  StreamSubscription<dynamic>? _wsSocketSubscription;
  bool _wsConnecting = false;
  bool _wsSubscribed = false;
  bool _isRealtimeDisposed = false;
  int _wsConnectionGeneration = 0;
  int _wsReconnectAttempt = 0;
  String _wsToken = '';
  String _wsBranchId = '';
  String _wsKitchenId = '';
  String? _lastEventId;

  String _sourceStatusForRole(String role) {
    return normalizeKotStatusSource(_kotSourceStatus);
  }

  String _targetStatusForRole(String role) {
    return 'delivered';
  }

  String _actionLabelForStatus(String status) {
    final normalized = status.trim().toLowerCase();
    if (normalized == kotStatusSourceConfirmed) return 'CONFIRM';
    if (normalized == 'delivered') return 'DELIVER';
    return normalized.toUpperCase();
  }

  String _pastTenseStatusLabel(String status) {
    final normalized = status.trim().toLowerCase();
    if (normalized == kotStatusSourceConfirmed) return 'Confirmed';
    if (normalized == 'delivered') return 'Delivered';
    return normalized;
  }

  String _deliveryTokenForParts({
    required String billId,
    required String itemId,
    required String productId,
    required String productName,
  }) {
    final normalizedName = productName.trim().toLowerCase();
    if (itemId.trim().isNotEmpty) {
      return '${billId.trim()}|item:${itemId.trim()}';
    }
    if (productId.trim().isNotEmpty) {
      return '${billId.trim()}|product:${productId.trim()}|name:$normalizedName';
    }
    return '${billId.trim()}|name:$normalizedName';
  }

  String _deliveryTokenForItem(_KotConfirmedItem item) {
    return _deliveryTokenForParts(
      billId: item.billId,
      itemId: item.itemId,
      productId: item.productId,
      productName: item.productName,
    );
  }

  Future<List<dynamic>> _fetchBillItemsFromServer(
    String billId,
    String token,
  ) async {
    final billResponse = await http.get(
      Uri.parse('https://blackforest4.vseyal.com/api/billings/$billId'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
    );

    if (billResponse.statusCode != 200) {
      throw Exception(
        'Unable to open bill $billId (${billResponse.statusCode})',
      );
    }

    final billBody = jsonDecode(billResponse.body);
    final billMap = _asMap(billBody);
    final rawItems = billMap['items'] is List
        ? List<dynamic>.from(billMap['items'])
        : const <dynamic>[];
    if (rawItems.isEmpty) {
      throw Exception('No items found in this bill');
    }
    return rawItems;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_initializeKotDataFlow());
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _isRealtimeDisposed = true;
    _refreshTimer?.cancel();
    _clockTimer?.cancel();
    _wsReconnectTimer?.cancel();
    _wsRefreshTimer?.cancel();
    unawaited(_closeKotSocket(sendUnsubscribe: true));
    super.dispose();
  }

  Future<void> _initializeKotDataFlow() async {
    _startFallbackPolling();
    unawaited(_connectKotRealtime());
    await _refreshConfirmedItems(showLoader: true, hydrateImages: false);
    if (!mounted) return;
    await _connectKotRealtime();
  }

  void _startFallbackPolling() {
    if (_wsSubscribed) return;
    if (_refreshTimer != null) return;
    _refreshTimer = Timer.periodic(_fallbackPollInterval, (_) {
      if (!mounted) return;
      unawaited(_refreshConfirmedItems(hydrateImages: false));
    });
  }

  void _stopFallbackPolling() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  Future<void> _loadRealtimeSessionSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    _wsToken = _readText(prefs.getString('token'));
    _wsBranchId = _readText(prefs.getString('branchId'));
    _wsKitchenId = _readText(prefs.getString('kitchenId'));
    _kotSourceStatus = loadKotStatusSourceFromPrefs(prefs);
    final role = _readText(prefs.getString('role')).toLowerCase();
    if (role.isNotEmpty) {
      _role = role;
    }
    if (_wsToken.isNotEmpty) {
      _authToken = _wsToken;
    }
  }

  Future<void> _connectKotRealtime() async {
    if (_isRealtimeDisposed || !mounted) return;
    if (_wsConnecting) return;
    final activeSocket = _wsSocket;
    if (activeSocket != null && activeSocket.readyState == io.WebSocket.open) {
      return;
    }

    _wsReconnectTimer?.cancel();
    await _loadRealtimeSessionSnapshot();
    if (_wsToken.isEmpty || _wsBranchId.isEmpty) {
      _startFallbackPolling();
      return;
    }

    _wsConnecting = true;
    try {
      await ensureApiHostRoutingReady();

      final host = apiHostActive.trim().isNotEmpty
          ? apiHostActive.trim()
          : apiHostPrimary;
      final wsUri = Uri(scheme: 'wss', host: host, path: '/ws/v1');
      final generation = ++_wsConnectionGeneration;
      final socket = await io.WebSocket.connect(
        wsUri.toString(),
        headers: <String, dynamic>{'Authorization': 'Bearer $_wsToken'},
      );

      if (_isRealtimeDisposed || generation != _wsConnectionGeneration) {
        await socket.close();
        return;
      }

      await _closeKotSocket(sendUnsubscribe: false);
      _wsSocket = socket;
      _wsReconnectAttempt = 0;
      _wsSocketSubscription = socket.listen(
        (frame) => _handleKotRealtimeFrame(frame, generation),
        onError: (_) => _handleKotRealtimeSocketClosed(generation, socket),
        onDone: () => _handleKotRealtimeSocketClosed(generation, socket),
        cancelOnError: false,
      );
      _sendKotSubscribe();
    } catch (_) {
      _wsSubscribed = false;
      _startFallbackPolling();
      _scheduleKotRealtimeReconnect();
    } finally {
      _wsConnecting = false;
    }
  }

  Future<void> _closeKotSocket({bool sendUnsubscribe = false}) async {
    final socket = _wsSocket;
    final subscription = _wsSocketSubscription;
    _wsSocket = null;
    _wsSocketSubscription = null;
    _wsSubscribed = false;
    _wsConnecting = false;

    try {
      await subscription?.cancel();
    } catch (_) {}

    if (socket == null) return;
    if (sendUnsubscribe) {
      _sendKotUnsubscribe(socket);
    }
    try {
      await socket.close(io.WebSocketStatus.normalClosure, 'client_close');
    } catch (_) {}
  }

  void _sendKotSubscribe() {
    final socket = _wsSocket;
    if (socket == null || socket.readyState != io.WebSocket.open) return;
    if (_wsBranchId.isEmpty) return;
    final payload = <String, dynamic>{
      'action': 'subscribe',
      'topic': _kotRealtimeTopic,
      'branchId': _wsBranchId,
    };
    if (_wsKitchenId.isNotEmpty) {
      payload['kitchenId'] = _wsKitchenId;
    }
    final resumeCursor = _readText(_lastEventId);
    if (resumeCursor.isNotEmpty) {
      payload['lastEventId'] = resumeCursor;
    }
    try {
      socket.add(jsonEncode(payload));
    } catch (_) {}
  }

  void _sendKotUnsubscribe([io.WebSocket? explicitSocket]) {
    final socket = explicitSocket ?? _wsSocket;
    if (socket == null || socket.readyState != io.WebSocket.open) return;
    if (_wsBranchId.isEmpty) return;
    final payload = <String, dynamic>{
      'action': 'unsubscribe',
      'topic': _kotRealtimeTopic,
      'branchId': _wsBranchId,
    };
    if (_wsKitchenId.isNotEmpty) {
      payload['kitchenId'] = _wsKitchenId;
    }
    try {
      socket.add(jsonEncode(payload));
    } catch (_) {}
  }

  void _handleKotRealtimeSocketClosed(int generation, io.WebSocket socket) {
    if (_isRealtimeDisposed || !mounted) return;
    if (generation != _wsConnectionGeneration) return;

    _wsSocket = null;
    _wsSocketSubscription = null;
    _wsSubscribed = false;
    _wsConnecting = false;
    _startFallbackPolling();

    final closeCode = socket.closeCode;
    if (closeCode == 4401) {
      _lastEventId = null;
    }
    _scheduleKotRealtimeReconnect();
  }

  void _scheduleKotRealtimeReconnect({bool immediate = false}) {
    if (_isRealtimeDisposed || !mounted) return;
    if (_wsReconnectTimer?.isActive ?? false) return;

    final reconnectSeconds = immediate
        ? 1
        : (2 + (_wsReconnectAttempt * 2)).clamp(2, 30).toInt();
    _wsReconnectAttempt += 1;
    _wsReconnectTimer = Timer(Duration(seconds: reconnectSeconds), () {
      if (_isRealtimeDisposed || !mounted) return;
      unawaited(_connectKotRealtime());
    });
  }

  Map<String, dynamic>? _decodeKotRealtimeFrame(dynamic frame) {
    try {
      if (frame is String) {
        final decoded = jsonDecode(frame);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
        return null;
      }
      if (frame is List<int>) {
        final decoded = jsonDecode(utf8.decode(frame));
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  bool _markEventAsSeen(String eventId) {
    final key = eventId.trim();
    if (key.isEmpty) return true;
    if (_seenEventIds.contains(key)) return false;
    _seenEventIds.add(key);
    _seenEventIdOrder.add(key);
    if (_seenEventIdOrder.length > _maxTrackedEventIds) {
      final evicted = _seenEventIdOrder.removeAt(0);
      _seenEventIds.remove(evicted);
    }
    return true;
  }

  bool _shouldRefreshForStatusChange(String statusBefore, String statusAfter) {
    if (_role.trim().isEmpty) return true;
    final sourceStatus = _sourceStatusForRole(_role);
    return statusBefore == sourceStatus || statusAfter == sourceStatus;
  }

  bool _shouldApplyRealtimeItemState(
    String itemId,
    int? eventVersion,
    DateTime? eventUpdatedAt,
  ) {
    if (itemId.isEmpty) return true;
    final localVersion = _latestItemVersionById[itemId];
    final localUpdatedAt = _latestItemUpdatedAtById[itemId];

    if (localVersion != null && eventVersion != null) {
      if (eventVersion < localVersion) return false;
      if (eventVersion == localVersion &&
          localUpdatedAt != null &&
          eventUpdatedAt != null &&
          !eventUpdatedAt.isAfter(localUpdatedAt)) {
        return false;
      }
    } else if (eventVersion == null &&
        localUpdatedAt != null &&
        eventUpdatedAt != null &&
        !eventUpdatedAt.isAfter(localUpdatedAt)) {
      return false;
    }
    return true;
  }

  bool _shouldApplyKotRealtimeEvent(
    Map<String, dynamic> message,
    String eventType,
  ) {
    final topic = _readText(message['topic']);
    if (topic.isNotEmpty && topic != _kotRealtimeTopic) return false;

    final branchId = _readText(message['branchId']);
    if (_wsBranchId.isNotEmpty &&
        branchId.isNotEmpty &&
        branchId != _wsBranchId) {
      return false;
    }

    final kitchenId = _readText(message['kitchenId']);
    if (_wsKitchenId.isNotEmpty &&
        kitchenId.isNotEmpty &&
        kitchenId != _wsKitchenId) {
      return false;
    }

    final eventId = _readText(message['eventId']);
    if (!_markEventAsSeen(eventId)) return false;

    final billId = _readText(message['billingId']);
    final seq = _readInt(message['seq']);
    if (billId.isNotEmpty && seq != null) {
      final prevSeq = _latestSeqByBillId[billId];
      if (prevSeq != null && seq <= prevSeq) return false;
      _latestSeqByBillId[billId] = seq;
    }

    final itemId = _readText(message['itemId']);
    final itemVersion = _readInt(message['itemVersion']);
    final itemUpdatedAt = _parseDate(message['itemUpdatedAt']);
    if (!_shouldApplyRealtimeItemState(itemId, itemVersion, itemUpdatedAt)) {
      return false;
    }

    if (eventType == 'billing_item_status_changed') {
      final statusBefore = _readText(message['statusBefore']).toLowerCase();
      final statusAfter = _readText(message['statusAfter']).toLowerCase();
      if (!_shouldRefreshForStatusChange(statusBefore, statusAfter)) {
        return false;
      }
    }

    if (itemId.isNotEmpty) {
      if (itemVersion != null) {
        final currentVersion = _latestItemVersionById[itemId];
        if (currentVersion == null || itemVersion > currentVersion) {
          _latestItemVersionById[itemId] = itemVersion;
        }
      }
      if (itemUpdatedAt != null) {
        final currentUpdatedAt = _latestItemUpdatedAtById[itemId];
        if (currentUpdatedAt == null ||
            itemUpdatedAt.isAfter(currentUpdatedAt)) {
          _latestItemUpdatedAtById[itemId] = itemUpdatedAt;
        }
      }
    }

    final incomingEventId = _readText(message['eventId']);
    if (incomingEventId.isNotEmpty) {
      _lastEventId = incomingEventId;
    }
    return true;
  }

  Future<void> _handleResumeNack() async {
    _lastEventId = null;
    await _refreshConfirmedItems();
    if (!mounted || _isRealtimeDisposed) return;
    _sendKotSubscribe();
  }

  void _scheduleWsDrivenRefresh({bool immediate = false}) {
    if (_isRealtimeDisposed || !mounted) return;
    _wsRefreshTimer?.cancel();
    final delay = immediate ? Duration.zero : _wsRefreshDebounceInterval;
    _wsRefreshTimer = Timer(delay, () {
      if (!mounted) return;
      unawaited(_refreshConfirmedItems(hydrateImages: false));
    });
  }

  void _handleKotRealtimeFrame(dynamic frame, int generation) {
    if (_isRealtimeDisposed || !mounted) return;
    if (generation != _wsConnectionGeneration) return;
    final message = _decodeKotRealtimeFrame(frame);
    if (message == null) return;

    final eventType = _readText(message['eventType']).toLowerCase();
    if (eventType.isEmpty) return;

    if (eventType == 'subscription_ack') {
      final subscribed = message['subscribed'] == true;
      _wsSubscribed = subscribed;
      if (subscribed) {
        _wsReconnectAttempt = 0;
        _stopFallbackPolling();
        _scheduleWsDrivenRefresh(immediate: true);
      } else {
        _startFallbackPolling();
      }
      return;
    }

    if (eventType == 'subscription_nack') {
      final errorCode = _readText(message['error_code']).toLowerCase();
      final hasKitchenFilterIssue =
          errorCode.contains('kitchen') ||
          errorCode.contains('branch_mismatch');
      if (_wsKitchenId.isNotEmpty && hasKitchenFilterIssue) {
        _wsKitchenId = '';
        _sendKotSubscribe();
        return;
      }
      _wsSubscribed = false;
      _startFallbackPolling();
      return;
    }

    if (eventType == 'auth_expired') {
      _wsSubscribed = false;
      _startFallbackPolling();
      _lastEventId = null;
      _scheduleKotRealtimeReconnect(immediate: true);
      return;
    }

    if (eventType == 'resume_nack') {
      _wsSubscribed = false;
      _startFallbackPolling();
      unawaited(_handleResumeNack());
      return;
    }

    if (eventType == 'pong' || eventType == 'unsubscribe_ack') {
      return;
    }

    if (eventType != 'billing_item_status_changed' &&
        eventType != 'billing_item_preparing_time_changed' &&
        eventType != 'billing_status_changed') {
      return;
    }

    if (!_shouldApplyKotRealtimeEvent(message, eventType)) {
      return;
    }
    _scheduleWsDrivenRefresh();
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }

  String _readText(dynamic value) {
    return value?.toString().trim() ?? '';
  }

  String? _normalizeImageUrl(dynamic rawUrl) {
    if (rawUrl == null || rawUrl is Map || rawUrl is List) return null;
    final value = _readText(rawUrl);
    if (value.isEmpty) return null;
    if (value.startsWith('data:image/')) return value;
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return resolveApiAssetUrl(value);
    }
    if (value.startsWith('/')) {
      return resolveApiAssetUrl(value);
    }
    return resolveApiAssetUrl('/$value');
  }

  String? _extractImageFromAny(dynamic node) {
    final direct = _normalizeImageUrl(node);
    if (direct != null) return direct;

    if (node is List) {
      for (final entry in node) {
        final nested = _extractImageFromAny(entry);
        if (nested != null) return nested;
      }
      return null;
    }

    if (node is! Map) return null;
    final map = _asMap(node);
    const preferredKeys = <String>[
      'imageUrl',
      'imageURL',
      'productImage',
      'thumbnail',
      'thumbnailURL',
      'thumbnailUrl',
      'largeURL',
      'largeUrl',
      'mediumURL',
      'mediumUrl',
      'smallURL',
      'smallUrl',
      'featuredImage',
      'featured_image',
      'image',
      'images',
      'photo',
      'picture',
      'icon',
      'media',
      'url',
      'src',
      'file',
      'path',
      'filename',
      'asset',
      'product',
    ];

    for (final key in preferredKeys) {
      if (!map.containsKey(key)) continue;
      final nested = _extractImageFromAny(map[key]);
      if (nested != null) return nested;
    }

    for (final value in map.values) {
      final nested = _extractImageFromAny(value);
      if (nested != null) return nested;
    }
    return null;
  }

  double _readDouble(dynamic value, {double fallback = 0}) {
    if (value is num) return value.toDouble();
    if (value is String) {
      final parsed = double.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  int? _readInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      return int.tryParse(value.trim());
    }
    return null;
  }

  DateTime? _parseEpochLike(dynamic value) {
    if (value == null) return null;
    final asNum = value is num
        ? value.toDouble()
        : double.tryParse(_readText(value));
    if (asNum == null || !asNum.isFinite || asNum <= 0) return null;

    final rounded = asNum.round();
    final asMillis = rounded < 1000000000000 ? rounded * 1000 : rounded;
    try {
      return DateTime.fromMillisecondsSinceEpoch(asMillis, isUtc: true);
    } catch (_) {
      return null;
    }
  }

  String _normalizeTimerAlias(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  dynamic _readMapValueByAliases(
    Map<String, dynamic> map,
    List<String> aliases,
  ) {
    for (final alias in aliases) {
      if (map.containsKey(alias)) return map[alias];
    }

    final normalizedAliases = aliases.map(_normalizeTimerAlias).toSet();
    for (final entry in map.entries) {
      if (normalizedAliases.contains(_normalizeTimerAlias(entry.key))) {
        return entry.value;
      }
    }
    return null;
  }

  double? _readMinutesValue(dynamic value) {
    if (value == null) return null;
    if (value is num) {
      final minutes = value.toDouble();
      if (!minutes.isFinite || minutes < 0) return null;
      return minutes;
    }
    if (value is String) {
      final parsed = double.tryParse(value.trim());
      if (parsed == null || !parsed.isFinite || parsed < 0) return null;
      return parsed;
    }
    return null;
  }

  double? _resolveItemPreparationMinutes(
    Map<String, dynamic> itemMap,
    Map<String, dynamic> productMap,
  ) {
    const aliases = <String>[
      'preparingTime',
      'preparing_time',
      'preparationTime',
      'preparation_time',
      'preparationMinutes',
      'preparation_minutes',
      'preparationTimeMinutes',
      'preparation_time_minutes',
      'prepTime',
      'prep_time',
      'prepMinutes',
      'prep_minutes',
    ];

    final fromItem = _readMinutesValue(
      _readMapValueByAliases(itemMap, aliases),
    );
    if (fromItem != null) return fromItem;

    if (productMap.isNotEmpty) {
      final fromProduct = _readMinutesValue(
        _readMapValueByAliases(productMap, aliases),
      );
      if (fromProduct != null) return fromProduct;
    }

    final variantRaw = _readMapValueByAliases(itemMap, <String>[
      'variant',
      'selectedVariant',
      'productVariant',
      'selectedProductVariant',
    ]);
    if (variantRaw is Map) {
      final variantMap = _asMap(variantRaw);
      final fromVariant = _readMinutesValue(
        _readMapValueByAliases(variantMap, aliases),
      );
      if (fromVariant != null) return fromVariant;
    }

    return null;
  }

  DateTime? _resolveKotItemStartedAt(Map<String, dynamic> itemMap) {
    return _parseDate(
      _readMapValueByAliases(itemMap, const <String>[
        'itemStartedAt',
        'orderedAt',
        'orderedOn',
        'ordered_at',
        'orderPlacedAt',
        'orderPlacedOn',
        'order_placed_at',
        'orderedTimestamp',
        'orderTimestamp',
        'orderAt',
        'orderOn',
        'order_at',
        'orderedTime',
        'orderTime',
        'createdAt',
      ]),
    );
  }

  DateTime? _resolveKotTableStartedAt(Map<String, dynamic> bill) {
    return _parseDate(
      _readMapValueByAliases(bill, const <String>[
        'createdAt',
        'orderCreatedAt',
        'billingCreatedAt',
        'orderedAt',
        'orderPlacedAt',
      ]),
    );
  }

  DateTime? _parseTimeOfDayOnDate(
    String rawValue, {
    required DateTime baseDate,
  }) {
    final raw = rawValue.trim();
    if (raw.isEmpty) return null;

    final cleaned = raw.replaceAll(RegExp(r'\s+'), ' ');
    final match = RegExp(
      r'^(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\s*([AaPp][Mm]))?$',
    ).firstMatch(cleaned);
    if (match == null) return null;

    var hour = int.tryParse(match.group(1) ?? '');
    final minute = int.tryParse(match.group(2) ?? '');
    final second = int.tryParse(match.group(3) ?? '0') ?? 0;
    final amPm = (match.group(4) ?? '').toUpperCase();
    if (hour == null || minute == null) return null;
    if (minute < 0 || minute > 59 || second < 0 || second > 59) return null;

    if (amPm == 'AM' || amPm == 'PM') {
      if (hour < 1 || hour > 12) return null;
      if (amPm == 'AM') {
        if (hour == 12) hour = 0;
      } else {
        if (hour != 12) hour += 12;
      }
    } else if (hour < 0 || hour > 23) {
      return null;
    }

    // Bill item clock fields (e.g. orderedAt "17:46:28") are local business
    // times, so combine with local date context to avoid UTC drift to future.
    final baseLocal = baseDate.toLocal();
    final result = DateTime(
      baseLocal.year,
      baseLocal.month,
      baseLocal.day,
      hour,
      minute,
      second,
    );

    final twelveHours = const Duration(hours: 12);
    if (result.isBefore(baseLocal.subtract(twelveHours))) {
      return result.add(const Duration(days: 1));
    }
    if (result.isAfter(baseLocal.add(const Duration(days: 1)))) {
      return result.subtract(const Duration(days: 1));
    }
    return result;
  }

  DateTime? _resolveKotItemStartedAtWithBillContext(
    Map<String, dynamic> itemMap,
    Map<String, dynamic> bill,
  ) {
    final tableStartedAt = _resolveKotTableStartedAt(bill);
    final baseDate = tableStartedAt ?? _parseDate(bill['createdAt']);
    final direct = _resolveKotItemStartedAt(itemMap);
    if (direct != null) return direct;

    if (baseDate != null) {
      for (final aliases in const <List<String>>[
        <String>[
          'itemStartedAt',
          'orderedAt',
          'orderedOn',
          'ordered_at',
          'orderPlacedAt',
          'orderPlacedOn',
          'order_placed_at',
          'orderedTime',
          'orderTime',
        ],
      ]) {
        final raw = _readText(_readMapValueByAliases(itemMap, aliases));
        if (raw.isEmpty) continue;
        final clock = _parseTimeOfDayOnDate(raw, baseDate: baseDate);
        if (clock != null) return clock;
      }
    }

    for (final aliases in const <List<String>>[
      <String>[
        'itemUpdatedAt',
        'statusUpdatedAt',
        'status_updated_at',
        'updatedAt',
        'updated_at',
        'addedAt',
        'timestamp',
      ],
    ]) {
      final resolved = _parseDate(_readMapValueByAliases(itemMap, aliases));
      if (resolved != null) {
        return resolved;
      }
    }
    return null;
  }

  DateTime? _resolveKotItemFinalizedAt(
    Map<String, dynamic> itemMap,
    DateTime? startedAt,
  ) {
    final status = _readText(itemMap['status']).toLowerCase();
    final isFinalized =
        status == 'prepared' ||
        status == 'delivered' ||
        status == 'served' ||
        status == 'completed' ||
        status == 'cancelled' ||
        status == 'canceled';
    if (!isFinalized) return null;

    final finalizedAt = _parseDate(
      _readMapValueByAliases(itemMap, const <String>[
        'preparedAt',
        'preparedOn',
        'prepared_at',
        'preparedTime',
        'deliveredAt',
        'deliveredOn',
        'delivered_at',
        'deliveredTime',
        'completedAt',
        'completedOn',
        'completed_at',
        'completedTime',
        'cancelledAt',
        'cancelledOn',
        'cancelled_at',
        'canceledAt',
        'canceledOn',
        'canceled_at',
        'statusUpdatedAt',
        'status_updated_at',
        'updatedAt',
        'updated_at',
      ]),
    );
    if (finalizedAt == null) return null;
    if (startedAt != null && finalizedAt.isBefore(startedAt)) {
      return startedAt;
    }
    return finalizedAt;
  }

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;

    final epochDirect = _parseEpochLike(value);
    if (epochDirect != null) return epochDirect;

    if (value is Map) {
      final map = _asMap(value);
      for (final key in const <String>[
        r'$date',
        'date',
        'value',
        'timestamp',
        'time',
        'ts',
      ]) {
        if (!map.containsKey(key)) continue;
        final nested = _parseDate(map[key]);
        if (nested != null) return nested;
      }
      if (map.containsKey('seconds')) {
        final secondsValue = _parseEpochLike(map['seconds']);
        if (secondsValue != null) return secondsValue;
      }
      return null;
    }

    final raw = _readText(value);
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw) ?? _parseEpochLike(raw);
  }

  String _resolveId(dynamic value) {
    if (value == null) return '';
    if (value is String) return value.trim();
    if (value is num) return value.toString();
    if (value is Map) {
      final map = Map<String, dynamic>.from(value);
      final fromId = _readText(map['id']);
      if (fromId.isNotEmpty) return fromId;
      final fromUnderscore = _readText(map['_id']);
      if (fromUnderscore.isNotEmpty) return fromUnderscore;
      final fromOid = _readText(map[r'$oid']);
      if (fromOid.isNotEmpty) return fromOid;
      if (map.containsKey('value')) {
        final fromValue = _resolveId(map['value']);
        if (fromValue.isNotEmpty) return fromValue;
      }
      if (map.containsKey('product')) {
        final fromProduct = _resolveId(map['product']);
        if (fromProduct.isNotEmpty) return fromProduct;
      }
      return '';
    }
    return value.toString().trim();
  }

  String _resolveSectionLabel(Map<String, dynamic> bill) {
    final tableDetails = _asMap(bill['tableDetails']);
    final tableMap = _asMap(bill['table']);
    final tableSectionMap = _asMap(tableMap['section']);

    final sectionFromTableMap = _readText(tableSectionMap['name']);
    if (sectionFromTableMap.isNotEmpty) return sectionFromTableMap;

    final sectionFromDetails = _readText(tableDetails['section']);
    if (sectionFromDetails.isNotEmpty) return sectionFromDetails;

    final sectionFromTable = _readText(tableMap['section']);
    if (sectionFromTable.isNotEmpty) return sectionFromTable;

    return '-';
  }

  String _resolveSectionForRangeFilter(Map<String, dynamic> bill) {
    final resolved = _resolveSectionLabel(bill).trim();
    if (resolved == '-' || resolved.isEmpty) return '';
    return resolved;
  }

  String _resolveTableNumberTokenForRangeFilter(Map<String, dynamic> bill) {
    final tableDetails = _asMap(bill['tableDetails']);
    final fromDetails = _readText(tableDetails['tableNumber']);
    if (fromDetails.isNotEmpty) return fromDetails;

    final tableMap = _asMap(bill['table']);
    final tableName = _readText(tableMap['name']);
    if (tableName.isEmpty) return '';
    final parsed = WaiterCallRangeFilterService.parseTableToken(tableName);
    return parsed?.toString() ?? '';
  }

  bool _matchesSelectedTableRange(
    Map<String, dynamic> bill,
    List<WaiterCallRangeSelection> selectedRows,
  ) {
    if (selectedRows.isEmpty) return true;
    final section = _resolveSectionForRangeFilter(bill);
    final tableToken = _resolveTableNumberTokenForRangeFilter(bill);
    if (section.isEmpty || tableToken.isEmpty) return false;
    return WaiterCallRangeFilterService.shouldNotifyForCall(
      selections: selectedRows,
      section: section,
      tableNumber: tableToken,
    );
  }

  bool _isTableAllocatedToMe({
    required String sectionName,
    required int tableNumber,
    required List<dynamic> cachedTables,
    required List<String> candidateKeys,
  }) {
    if (candidateKeys.isEmpty) return false;
    final normalizedSearchSection = WaiterCallRangeFilterService.normalizeSection(sectionName);

    // 1. Check if the section even has any allocations.
    bool sectionHasAnyAllocations = false;
    for (final section in cachedTables) {
      if (section is! Map) continue;
      final name = WaiterCallRangeFilterService.normalizeSection(section['name']?.toString() ?? 'General');
      if (name == normalizedSearchSection) {
        final allocations = section['waiterAllocations'];
        if (allocations is List && allocations.isNotEmpty) {
          sectionHasAnyAllocations = true;
          break;
        }
      }
    }

    if (!sectionHasAnyAllocations) {
      // If the section doesn't have any allocations configured, then it is NOT restricted.
      return true;
    }

    // 2. Check if there is an allocation matching our waiter name/ID for this table.
    for (final section in cachedTables) {
      if (section is! Map) continue;
      final name = WaiterCallRangeFilterService.normalizeSection(section['name']?.toString() ?? 'General');
      if (name == normalizedSearchSection) {
        final allocations = section['waiterAllocations'];
        if (allocations is List) {
          for (final alloc in allocations) {
            if (alloc is! Map) continue;
            final rawNum = alloc['tableNumber']?.toString().trim() ?? '';
            if (rawNum != tableNumber.toString()) continue;

            final waiterVal = alloc['waiter'];
            String waiterId = '';
            String waiterName = '';
            if (waiterVal is String) {
              waiterId = waiterVal;
            } else if (waiterVal is Map) {
              waiterId = (waiterVal['id'] ?? waiterVal['_id'] ?? '').toString().trim();
              waiterName = (waiterVal['name'] ?? waiterVal['username'] ?? '').toString().trim().toLowerCase();
            }

            for (final candidate in candidateKeys) {
              if (candidate.isNotEmpty &&
                  (candidate == waiterId || candidate.toLowerCase() == waiterName)) {
                return true;
              }
            }
          }
        }
      }
    }

    return false;
  }

  String _resolveTableLabel(Map<String, dynamic> bill) {
    final tableMap = _asMap(bill['table']);
    final tableName = _readText(tableMap['name']);
    if (tableName.isNotEmpty) return tableName;

    final tableDetails = _asMap(bill['tableDetails']);
    final tableNumber = _readText(tableDetails['tableNumber']);
    if (tableNumber.isNotEmpty) return 'Table $tableNumber';

    return 'Kitchen';
  }

  String _resolveCustomerName(Map<String, dynamic> bill) {
    final directName = _readText(
      bill['customerName'] ?? bill['customer'] ?? bill['name'],
    );
    if (directName.isNotEmpty) return directName;

    final customerDetailsRaw = bill['customerDetails'];
    final customerDetails = customerDetailsRaw is Map
        ? _asMap(customerDetailsRaw)
        : (customerDetailsRaw is List &&
              customerDetailsRaw.isNotEmpty &&
              customerDetailsRaw.first is Map)
        ? _asMap(customerDetailsRaw.first)
        : <String, dynamic>{};

    if (customerDetails.isNotEmpty) {
      final detailName = _readText(
        customerDetails['name'] ??
            customerDetails['customerName'] ??
            customerDetails['fullName'] ??
            customerDetails['displayName'],
      );
      if (detailName.isNotEmpty) return detailName;
    }

    return '';
  }

  String _formatKotLabel(String rawKotNumber) {
    final raw = rawKotNumber.trim();
    if (raw.isEmpty) return 'KOT00';
    final upper = raw.toUpperCase();
    final digits = upper.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return upper.startsWith('KOT') ? upper : 'KOT-$upper';
    final shortDigits = digits.length > 2
        ? digits.substring(digits.length - 2)
        : digits.padLeft(2, '0');
    return 'KOT$shortDigits';
  }

  String _elapsedClock(DateTime? value) {
    if (value == null) return '--:--';
    final diff = DateTime.now().difference(value.toLocal());
    final totalSeconds = diff.inSeconds < 0 ? 0 : diff.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String _formatTimerClockFromSeconds(int seconds) {
    final safeSeconds = seconds < 0 ? 0 : seconds;
    final minutes = safeSeconds ~/ 60;
    final secs = safeSeconds % 60;
    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }

  int? _resolveKotElapsedSeconds(_KotConfirmedItem item) {
    final startedAt = item.startedAt ?? item.tableStartedAt;
    if (startedAt == null) return null;

    var endAt = DateTime.now();
    final finalizedAt = item.finalizedAt;
    if (finalizedAt != null && !finalizedAt.isBefore(startedAt)) {
      endAt = finalizedAt;
    }

    final totalSeconds = endAt.difference(startedAt).inSeconds;
    return totalSeconds < 0 ? 0 : totalSeconds;
  }

  String _kotElapsedLabel(_KotConfirmedItem item) {
    final elapsedSeconds = _resolveKotElapsedSeconds(item);
    if (elapsedSeconds == null) return '--:--';
    return _formatTimerClockFromSeconds(elapsedSeconds);
  }

  Color _kotElapsedColor(_KotConfirmedItem item) {
    final elapsedSeconds = _resolveKotElapsedSeconds(item);
    if (elapsedSeconds == null) return const Color(0xFF2E9C49);
    final minutes = elapsedSeconds ~/ 60;
    if (minutes >= 10) return const Color(0xFFC62828);
    if (minutes >= 5) return const Color(0xFFF57C00);
    return const Color(0xFF2E9C49);
  }

  int? _resolveKotPreparationRemainingSeconds(_KotConfirmedItem item) {
    final preparationMinutes = item.preparationMinutes;
    if (preparationMinutes == null) return null;

    final preparationSeconds = (preparationMinutes * 60).round();
    if (preparationSeconds < 0) return null;
    return preparationSeconds;
  }

  String? _kotPreparationCountdownLabel(_KotConfirmedItem item) {
    final remainingSeconds = _resolveKotPreparationRemainingSeconds(item);
    if (remainingSeconds == null) return null;
    return _formatTimerClockFromSeconds(remainingSeconds);
  }

  DateTime? _latestUpdatedAtForGroup(List<_KotConfirmedItem> items) {
    DateTime? latest;
    for (final item in items) {
      final time = item.updatedAt;
      if (time == null) continue;
      if (latest == null || time.isAfter(latest)) {
        latest = time;
      }
    }
    return latest;
  }

  DateTime? _tableStartedAtForGroup(List<_KotConfirmedItem> items) {
    for (final item in items) {
      if (item.tableStartedAt != null) return item.tableStartedAt;
    }
    return null;
  }

  Future<void> _hydrateMissingProductImages(
    List<_KotConfirmedItem> items,
    String token,
  ) async {
    final missingIds = <String>{};
    final missingNames = <String>{};
    final missingNameQueries = <String, Set<String>>{};

    String titleCase(String value) {
      final compact = value.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (compact.isEmpty) return compact;
      return compact
          .split(' ')
          .map((word) {
            if (word.isEmpty) return word;
            final lower = word.toLowerCase();
            return '${lower[0].toUpperCase()}${lower.substring(1)}';
          })
          .join(' ');
    }

    for (final item in items) {
      final currentImage = _readText(item.imageUrl);
      final hasImage = currentImage.isNotEmpty;
      if (hasImage) continue;
      if (item.productId.isNotEmpty &&
          !_productImageById.containsKey(item.productId) &&
          !_productImageMissingIds.contains(item.productId)) {
        missingIds.add(item.productId);
      }
      final productName = _readText(item.productName);
      final lowerName = productName.toLowerCase();
      if (lowerName.isNotEmpty &&
          !_productImageByName.containsKey(lowerName) &&
          !_productImageMissingNames.contains(lowerName)) {
        missingNames.add(lowerName);
        final variants = missingNameQueries.putIfAbsent(
          lowerName,
          () => <String>{},
        );
        variants.add(lowerName);
        variants.add(productName);
        variants.add(productName.toUpperCase());
        variants.add(titleCase(productName));
      }
    }

    if (missingIds.isNotEmpty) {
      final idsList = missingIds.toList(growable: false);
      const batchSize = 60;
      for (var start = 0; start < idsList.length; start += batchSize) {
        final end = (start + batchSize) > idsList.length
            ? idsList.length
            : (start + batchSize);
        final batch = idsList.sublist(start, end);
        if (batch.isEmpty) continue;

        final idsParam = batch.join(',');
        final foundIds = <String>{};
        final response = await http.get(
          Uri.parse(
            'https://blackforest4.vseyal.com/api/products?where[id][in]=$idsParam&depth=3&limit=100',
          ),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
        );

        List<dynamic> docs = const <dynamic>[];
        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body);
          docs = decoded is Map && decoded['docs'] is List
              ? List<dynamic>.from(decoded['docs'])
              : const <dynamic>[];
        }

        if (docs.isEmpty) {
          final fallbackResponse = await http.get(
            Uri.parse(
              'https://blackforest4.vseyal.com/api/products?where[_id][in]=$idsParam&depth=3&limit=100',
            ),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
          );
          if (fallbackResponse.statusCode == 200) {
            final fallbackDecoded = jsonDecode(fallbackResponse.body);
            docs = fallbackDecoded is Map && fallbackDecoded['docs'] is List
                ? List<dynamic>.from(fallbackDecoded['docs'])
                : const <dynamic>[];
          }
        }

        if (docs.isEmpty) {
          final productIdFallbackResponse = await http.get(
            Uri.parse(
              'https://blackforest4.vseyal.com/api/products?where[productId][in]=$idsParam&depth=3&limit=100',
            ),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
          );
          if (productIdFallbackResponse.statusCode == 200) {
            final productIdFallbackDecoded = jsonDecode(
              productIdFallbackResponse.body,
            );
            docs =
                productIdFallbackDecoded is Map &&
                    productIdFallbackDecoded['docs'] is List
                ? List<dynamic>.from(productIdFallbackDecoded['docs'])
                : const <dynamic>[];
          }
        }
        if (docs.isEmpty) continue;

        for (final rawDoc in docs) {
          final doc = _asMap(rawDoc);
          if (doc.isEmpty) continue;
          final canonicalProductId = _resolveId(doc['id']).isNotEmpty
              ? _resolveId(doc['id'])
              : _resolveId(doc['_id']);
          final productCode = _readText(doc['productId']);
          final upc = _readText(doc['upc']);
          final productNameLower = _readText(doc['name']).toLowerCase();
          final resolvedImage = _extractImageFromAny(doc);
          if (resolvedImage == null || resolvedImage.isEmpty) continue;
          final idAliases = <String>{
            canonicalProductId,
            productCode,
            upc,
          }.where((value) => value.isNotEmpty).toSet();
          for (final alias in idAliases) {
            _productImageById[alias] = resolvedImage;
            _productImageMissingIds.remove(alias);
            if (batch.contains(alias)) {
              foundIds.add(alias);
            }
          }
          if (productNameLower.isNotEmpty) {
            _productImageByName[productNameLower] = resolvedImage;
            _productImageMissingNames.remove(productNameLower);
            missingNames.remove(productNameLower);
          }
        }

        for (final id in batch) {
          if (foundIds.contains(id)) continue;
          Map<String, dynamic> productDoc = <String, dynamic>{};

          final idEndpointResponse = await http.get(
            Uri.parse(
              'https://blackforest4.vseyal.com/api/products/${Uri.encodeComponent(id)}?depth=3',
            ),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
          );
          if (idEndpointResponse.statusCode == 200) {
            productDoc = _asMap(jsonDecode(idEndpointResponse.body));
          }

          if (productDoc.isEmpty) {
            final productIdLookup = await http.get(
              Uri.parse(
                'https://blackforest4.vseyal.com/api/products?where[productId][equals]=${Uri.encodeQueryComponent(id)}&depth=3&limit=1',
              ),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
            );
            if (productIdLookup.statusCode == 200) {
              final lookupBody = _asMap(jsonDecode(productIdLookup.body));
              final docs = lookupBody['docs'] is List
                  ? List<dynamic>.from(lookupBody['docs'])
                  : const <dynamic>[];
              if (docs.isNotEmpty) {
                productDoc = _asMap(docs.first);
              }
            }
          }

          if (productDoc.isEmpty) {
            final upcLookup = await http.get(
              Uri.parse(
                'https://blackforest4.vseyal.com/api/products?where[upc][equals]=${Uri.encodeQueryComponent(id)}&depth=3&limit=1',
              ),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
            );
            if (upcLookup.statusCode == 200) {
              final lookupBody = _asMap(jsonDecode(upcLookup.body));
              final docs = lookupBody['docs'] is List
                  ? List<dynamic>.from(lookupBody['docs'])
                  : const <dynamic>[];
              if (docs.isNotEmpty) {
                productDoc = _asMap(docs.first);
              }
            }
          }

          if (productDoc.isEmpty) {
            _productImageMissingIds.add(id);
            continue;
          }

          final productNameLower = _readText(productDoc['name']).toLowerCase();
          final resolvedImage = _extractImageFromAny(productDoc);
          if (resolvedImage == null || resolvedImage.isEmpty) {
            _productImageMissingIds.add(id);
            continue;
          }
          final canonicalId = _resolveId(productDoc['id']).isNotEmpty
              ? _resolveId(productDoc['id'])
              : _resolveId(productDoc['_id']);
          final productCode = _readText(productDoc['productId']);
          final upc = _readText(productDoc['upc']);
          final idAliases = <String>{
            id,
            canonicalId,
            productCode,
            upc,
          }.where((value) => value.isNotEmpty).toSet();
          for (final alias in idAliases) {
            _productImageById[alias] = resolvedImage;
            _productImageMissingIds.remove(alias);
          }
          if (productNameLower.isNotEmpty) {
            _productImageByName[productNameLower] = resolvedImage;
            _productImageMissingNames.remove(productNameLower);
            missingNames.remove(productNameLower);
          }
        }
      }
    }

    if (missingNames.isNotEmpty) {
      for (final lowerName in missingNames) {
        final queryVariants = <String>{
          lowerName,
          ...?missingNameQueries[lowerName],
          titleCase(lowerName),
          lowerName.toUpperCase(),
        }.where((value) => value.trim().isNotEmpty).toList(growable: false);

        List<dynamic> docs = const <dynamic>[];
        for (final queryText in queryVariants) {
          const operators = <String>['equals', 'like'];
          for (final operator in operators) {
            final query = Uri.encodeQueryComponent(queryText);
            final response = await http.get(
              Uri.parse(
                'https://blackforest4.vseyal.com/api/products?where[name][$operator]=$query&depth=3&limit=18',
              ),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
            );
            if (response.statusCode != 200) {
              continue;
            }
            final decoded = jsonDecode(response.body);
            docs = decoded is Map && decoded['docs'] is List
                ? List<dynamic>.from(decoded['docs'])
                : const <dynamic>[];
            if (docs.isNotEmpty) break;
          }
          if (docs.isNotEmpty) break;
        }

        if (docs.isEmpty) {
          _productImageMissingNames.add(lowerName);
          continue;
        }

        String? resolvedImage;
        String? resolvedId;
        String? resolvedProductCode;
        String? resolvedUpc;
        for (final rawDoc in docs) {
          final doc = _asMap(rawDoc);
          if (doc.isEmpty) continue;
          final docNameLower = _readText(doc['name']).toLowerCase();
          final candidate = _extractImageFromAny(doc);
          if (candidate == null || candidate.isEmpty) continue;
          if (docNameLower == lowerName) {
            resolvedImage = candidate;
            resolvedId = _resolveId(doc['id']).isNotEmpty
                ? _resolveId(doc['id'])
                : _resolveId(doc['_id']);
            resolvedProductCode = _readText(doc['productId']);
            resolvedUpc = _readText(doc['upc']);
            break;
          }
          resolvedImage ??= candidate;
          resolvedId ??= _resolveId(doc['id']).isNotEmpty
              ? _resolveId(doc['id'])
              : _resolveId(doc['_id']);
          resolvedProductCode ??= _readText(doc['productId']);
          resolvedUpc ??= _readText(doc['upc']);
        }

        if (resolvedImage == null || resolvedImage.isEmpty) {
          _productImageMissingNames.add(lowerName);
          continue;
        }
        _productImageByName[lowerName] = resolvedImage;
        _productImageMissingNames.remove(lowerName);
        final idAliases = <String>{
          resolvedId ?? '',
          resolvedProductCode ?? '',
          resolvedUpc ?? '',
        }.where((value) => value.isNotEmpty).toSet();
        for (final alias in idAliases) {
          _productImageById[alias] = resolvedImage;
          _productImageMissingIds.remove(alias);
        }
      }
    }

    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (_readText(item.imageUrl).isNotEmpty) continue;
      String? resolvedImage;
      if (item.productId.isNotEmpty) {
        resolvedImage = _productImageById[item.productId];
      }
      resolvedImage ??= _productImageByName[item.productName.toLowerCase()];
      if (resolvedImage == null || resolvedImage.isEmpty) continue;
      items[i] = item.copyWith(imageUrl: resolvedImage);
    }
  }

  Future<void> _refreshConfirmedItems({
    bool showLoader = false,
    bool hydrateImages = true,
  }) async {
    if (showLoader && mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = _readText(prefs.getString('token'));
      final branchId = _readText(prefs.getString('branchId'));
      final sourceStatus = loadKotStatusSourceFromPrefs(prefs);
      final userKeys =
          WaiterCallRangeFilterService.resolveCandidateUserKeysFromPrefs(prefs);
      final selectedTableRows = branchId.isEmpty
          ? const <WaiterCallRangeSelection>[]
          : WaiterCallRangeFilterService.readSelectionsForAnyUser(
              prefs: prefs,
              userKeys: userKeys,
              branchId: branchId,
            );
      final role = _readText(prefs.getString('role')).toLowerCase();

      final cachedTablesRaw = prefs.getString('cached_tables_$branchId');
      List<dynamic> cachedTables = [];
      if (cachedTablesRaw != null) {
        try {
          cachedTables = jsonDecode(cachedTablesRaw) as List<dynamic>;
        } catch (_) {}
      }

      if (cachedTables.isEmpty && branchId.isNotEmpty && token.isNotEmpty) {
        try {
          final tablesResponse = await http.get(
            Uri.parse(
              'https://blackforest4.vseyal.com/api/tables?where[branch][equals]=$branchId&limit=1&depth=1',
            ),
            headers: {'Authorization': 'Bearer $token'},
          ).timeout(const Duration(seconds: 5));
          if (tablesResponse.statusCode == 200) {
            final tablesData = jsonDecode(tablesResponse.body);
            final List<dynamic> allDocs = tablesData['docs'] ?? [];
            final dynamic branchDoc = allDocs.isNotEmpty ? allDocs.first : null;
            if (branchDoc != null) {
              final List<dynamic> sections = branchDoc['sections'] ?? [];
              if (sections.isNotEmpty) {
                cachedTables = sections;
                unawaited(prefs.setString('cached_tables_$branchId', jsonEncode(sections)));
              }
            }
          }
        } catch (e) {
          debugPrint('Error fetching tables fallback in KOT page: $e');
        }
      }

      if (token.isEmpty) {
        throw Exception('Session missing. Please login again.');
      }

      _wsToken = token;
      _wsBranchId = branchId;

      final now = DateTime.now();
      final todayStartLocal = DateTime(now.year, now.month, now.day);
      final tomorrowStartLocal = todayStartLocal.add(const Duration(days: 1));
      final todayStartUtc = todayStartLocal.toUtc().toIso8601String();
      final tomorrowStartUtc = tomorrowStartLocal.toUtc().toIso8601String();

      const billStatusFilter = 'pending,ordered,confirmed,prepared,delivered';
      String urlString =
          'https://blackforest4.vseyal.com/api/billings?where[status][in]=$billStatusFilter&where[createdAt][greater_than_equal]=$todayStartUtc&where[createdAt][less_than]=$tomorrowStartUtc&limit=300&sort=-updatedAt&depth=3';
      if (branchId.isNotEmpty) {
        urlString += '&where[branch][equals]=$branchId';
      }

      final response = await http.get(
        Uri.parse(urlString),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode != 200) {
        throw Exception(
          'Failed to load ${sourceStatus.toUpperCase()} products (${response.statusCode})',
        );
      }

      final decoded = jsonDecode(response.body);
      final bills = decoded is Map && decoded['docs'] is List
          ? List<dynamic>.from(decoded['docs'])
          : const <dynamic>[];

      final nextItems = <_KotConfirmedItem>[];
      final nextBillItemsCache = <String, List<Map<String, dynamic>>>{};
      final nextItemVersionById = <String, int>{};
      final nextItemUpdatedAtById = <String, DateTime>{};
      for (final rawBill in bills) {
        final bill = _asMap(rawBill);
        if (bill.isEmpty) continue;
        if (!_matchesSelectedTableRange(bill, selectedTableRows)) continue;

        // Allocation Filter
        final sectionName = _resolveSectionForRangeFilter(bill);
        final tableNumStr = _resolveTableNumberTokenForRangeFilter(bill);
        final tableNumber = WaiterCallRangeFilterService.parseTableToken(tableNumStr) ?? 0;
        if (tableNumber > 0 && sectionName.isNotEmpty) {
          final isAllocated = _isTableAllocatedToMe(
            sectionName: sectionName,
            tableNumber: tableNumber,
            cachedTables: cachedTables,
            candidateKeys: userKeys,
          );
          if (!isAllocated) continue;
        }

        final billId = _resolveId(bill['id']).isNotEmpty
            ? _resolveId(bill['id'])
            : _resolveId(bill['_id']);
        if (billId.isEmpty) continue;

        final items = bill['items'] is List
            ? List<dynamic>.from(bill['items'])
            : const <dynamic>[];
        if (items.isEmpty) continue;
        final cachedItemsForBill = <Map<String, dynamic>>[];

        final tableLabel = _resolveTableLabel(bill);
        final sectionLabel = _resolveSectionLabel(bill);
        final kotLabel = _formatKotLabel(_readText(bill['kotNumber']));
        final tableStartedAt = _resolveKotTableStartedAt(bill);
        final customerName = _resolveCustomerName(bill);
        final createdBy = _asMap(bill['createdBy']);
        final waiterName = _readText(
          createdBy['name'] ?? createdBy['username'] ?? bill['waiterName'],
        );

        for (final rawItem in items) {
          final itemMap = _asMap(rawItem);
          if (itemMap.isEmpty) continue;
          cachedItemsForBill.add(Map<String, dynamic>.from(itemMap));

          final itemId = _resolveId(itemMap['id']);
          final itemVersion = _readInt(
            itemMap['itemVersion'] ?? itemMap['version'],
          );
          final itemUpdatedAt =
              _parseDate(itemMap['itemUpdatedAt']) ??
              _parseDate(itemMap['updatedAt']) ??
              _parseDate(itemMap['createdAt']);
          if (itemId.isNotEmpty) {
            if (itemVersion != null) {
              final previousVersion = nextItemVersionById[itemId];
              if (previousVersion == null || itemVersion > previousVersion) {
                nextItemVersionById[itemId] = itemVersion;
              }
            }
            if (itemUpdatedAt != null) {
              final previousUpdatedAt = nextItemUpdatedAtById[itemId];
              if (previousUpdatedAt == null ||
                  itemUpdatedAt.isAfter(previousUpdatedAt)) {
                nextItemUpdatedAtById[itemId] = itemUpdatedAt;
              }
            }
          }

          final status = _readText(itemMap['status']).toLowerCase();
          if (status != sourceStatus) continue;

          final productName = _readText(itemMap['name']);
          if (productName.isEmpty) continue;

          final quantity = _readDouble(itemMap['quantity'], fallback: 0);
          final unit = _readText(itemMap['unit']);
          final productMap = _asMap(itemMap['product']);
          final resolvedRelationProductId = _resolveId(itemMap['product']);
          final productCode = _readText(productMap['productId']);
          final productUpc = _readText(productMap['upc']);
          final productId = resolvedRelationProductId.isNotEmpty
              ? resolvedRelationProductId
              : (productCode.isNotEmpty
                    ? productCode
                    : (productUpc.isNotEmpty ? productUpc : ''));
          final imageUrlFromPayload =
              _extractImageFromAny(itemMap) ?? _extractImageFromAny(productMap);
          final imageUrl =
              imageUrlFromPayload ??
              (productId.isNotEmpty ? _productImageById[productId] : null) ??
              _productImageByName[productName.toLowerCase()];
          final startedAt = _resolveKotItemStartedAtWithBillContext(
            itemMap,
            bill,
          );
          final finalizedAt = _resolveKotItemFinalizedAt(itemMap, startedAt);
          final preparationMinutes = _resolveItemPreparationMinutes(
            itemMap,
            productMap,
          );
          if (imageUrlFromPayload != null && imageUrlFromPayload.isNotEmpty) {
            _productImageByName[productName.toLowerCase()] =
                imageUrlFromPayload;
            _productImageMissingNames.remove(productName.toLowerCase());
            if (productId.isNotEmpty) {
              _productImageById[productId] = imageUrlFromPayload;
              _productImageMissingIds.remove(productId);
            }
            if (productCode.isNotEmpty) {
              _productImageById[productCode] = imageUrlFromPayload;
              _productImageMissingIds.remove(productCode);
            }
            if (productUpc.isNotEmpty) {
              _productImageById[productUpc] = imageUrlFromPayload;
              _productImageMissingIds.remove(productUpc);
            }
          }
          final updatedAt =
              itemUpdatedAt ??
              _parseDate(bill['updatedAt']) ??
              _parseDate(bill['createdAt']);
          final deliveryToken = _deliveryTokenForParts(
            billId: billId,
            itemId: itemId,
            productId: productId,
            productName: productName,
          );
          if (_inFlightDeliveryTokens.contains(deliveryToken)) {
            continue;
          }
          final updatedToken =
              updatedAt?.millisecondsSinceEpoch.toString() ?? '0';
          final uniqueKey =
              '$billId|$itemId|$productId|$productName|$updatedToken';

          nextItems.add(
            _KotConfirmedItem(
              key: uniqueKey,
              billId: billId,
              itemId: itemId,
              productId: productId,
              status: status,
              productName: productName,
              quantity: quantity,
              unit: unit,
              tableLabel: tableLabel,
              sectionLabel: sectionLabel,
              kotLabel: kotLabel,
              waiterName: waiterName,
              customerName: customerName,
              imageUrl: imageUrl,
              updatedAt: updatedAt,
              startedAt: startedAt,
              finalizedAt: finalizedAt,
              preparationMinutes: preparationMinutes,
              tableStartedAt: tableStartedAt,
            ),
          );
        }

        if (cachedItemsForBill.isNotEmpty) {
          nextBillItemsCache[billId] = cachedItemsForBill;
        }
      }

      // Re-allow image hydration retries for currently visible items so
      // older "missing" cache decisions do not block future fixes.
      for (final item in nextItems) {
        if (_readText(item.imageUrl).isNotEmpty) continue;
        if (item.productId.isNotEmpty) {
          _productImageMissingIds.remove(item.productId);
        }
        final lowerName = item.productName.toLowerCase();
        if (lowerName.isNotEmpty) {
          _productImageMissingNames.remove(lowerName);
        }
      }

      if (hydrateImages) {
        await _hydrateMissingProductImages(nextItems, token);
      } else {
        unawaited(
          _hydrateMissingProductImages(nextItems, token).then((_) {
            if (!mounted) return;
            var changed = false;
            for (var i = 0; i < _items.length; i++) {
              final existing = _items[i];
              if (_readText(existing.imageUrl).isNotEmpty) continue;
              String? resolvedImage;
              if (existing.productId.isNotEmpty) {
                resolvedImage = _productImageById[existing.productId];
              }
              resolvedImage ??=
                  _productImageByName[existing.productName.toLowerCase()];
              if (resolvedImage == null || resolvedImage.isEmpty) continue;
              _items[i] = existing.copyWith(imageUrl: resolvedImage);
              changed = true;
            }
            if (changed) {
              setState(() {});
            }
          }),
        );
      }

      nextItems.sort((a, b) {
        final aTime = a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final timeCompare = bTime.compareTo(aTime);
        if (timeCompare != 0) return timeCompare;
        final tableCompare = a.tableLabel.compareTo(b.tableLabel);
        if (tableCompare != 0) return tableCompare;
        return a.productName.compareTo(b.productName);
      });

      if (!mounted) return;
      setState(() {
        _role = role;
        _kotSourceStatus = sourceStatus;
        _authToken = token;
        _billItemsCacheByBillId
          ..clear()
          ..addAll(nextBillItemsCache);
        _items
          ..clear()
          ..addAll(nextItems);
        _latestItemVersionById
          ..clear()
          ..addAll(nextItemVersionById);
        _latestItemUpdatedAtById
          ..clear()
          ..addAll(nextItemUpdatedAtById);
        _errorMessage = null;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString().replaceFirst('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  Map<String, dynamic> _toPatchItemPayload(
    Map<String, dynamic> source, {
    String? overrideStatus,
  }) {
    final itemId = _resolveId(source['id']);
    final productRaw = source['product'];
    final resolvedProductId = _resolveId(productRaw);
    final name = _readText(source['name']);
    final quantity = _readDouble(source['quantity'], fallback: 1);
    final unitPrice = _readDouble(
      source['unitPrice'] ?? source['price'],
      fallback: 0,
    );
    final status = (overrideStatus ?? _readText(source['status']))
        .toLowerCase()
        .trim();
    final note = _readText(source['specialNote']).isNotEmpty
        ? _readText(source['specialNote'])
        : _readText(source['notes']);

    final payload = <String, dynamic>{
      'product': resolvedProductId.isNotEmpty ? resolvedProductId : productRaw,
      'name': name,
      'quantity': quantity <= 0 ? 1 : quantity,
      'unitPrice': unitPrice,
    };

    if (status.isNotEmpty) {
      payload['status'] = status;
    }

    if (itemId.isNotEmpty) {
      payload['id'] = itemId;
    }

    final unit = _readText(source['unit']);
    if (unit.isNotEmpty) {
      payload['unit'] = unit;
    }

    if (source.containsKey('subtotal')) {
      payload['subtotal'] = _readDouble(source['subtotal'], fallback: 0);
    }

    if (note.isNotEmpty) {
      payload['specialNote'] = note;
      payload['notes'] = note;
      payload['note'] = note;
      payload['instructions'] = note;
    }

    final passthroughFields = <String>[
      'isOfferFreeItem',
      'offerRuleKey',
      'offerTriggerProduct',
      'isRandomCustomerOfferItem',
      'randomCustomerOfferCampaignCode',
      'isPriceOfferApplied',
      'priceOfferRuleKey',
      'priceOfferDiscountPerUnit',
      'priceOfferAppliedUnits',
      'effectiveUnitPrice',
      'lineSubtotal',
    ];
    for (final field in passthroughFields) {
      if (source.containsKey(field)) {
        payload[field] = source[field];
      }
    }

    return payload;
  }

  int _findTargetItemIndex(
    List<dynamic> rawItems,
    _KotConfirmedItem targetItem,
  ) {
    Map<String, dynamic> itemAt(int index) => _asMap(rawItems[index]);

    bool isExpectedStatusAt(int index) {
      final status = _readText(itemAt(index)['status']).toLowerCase();
      return status == targetItem.status;
    }

    if (targetItem.itemId.isNotEmpty) {
      for (int i = 0; i < rawItems.length; i++) {
        final existingId = _resolveId(itemAt(i)['id']);
        if (existingId == targetItem.itemId && isExpectedStatusAt(i)) {
          return i;
        }
      }
    }

    if (targetItem.productId.isNotEmpty) {
      for (int i = 0; i < rawItems.length; i++) {
        final existingProductId = _resolveId(itemAt(i)['product']);
        final existingName = _readText(itemAt(i)['name']);
        if (existingProductId == targetItem.productId &&
            existingName == targetItem.productName &&
            isExpectedStatusAt(i)) {
          return i;
        }
      }
    }

    for (int i = 0; i < rawItems.length; i++) {
      final existingName = _readText(itemAt(i)['name']);
      if (existingName == targetItem.productName && isExpectedStatusAt(i)) {
        return i;
      }
    }

    return -1;
  }

  Future<void> _markAsDelivered(_KotConfirmedItem item) async {
    if (_updatingKeys.contains(item.key)) return;
    final deliveryToken = _deliveryTokenForItem(item);
    setState(() {
      _updatingKeys.add(item.key);
      _inFlightDeliveryTokens.add(deliveryToken);
      _items.removeWhere((entry) => entry.key == item.key);
    });
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Updating ${item.productName}...'),
        backgroundColor: const Color(0xFF374151),
        duration: const Duration(milliseconds: 900),
      ),
    );

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = _readText(prefs.getString('token'));
      if (token.isEmpty) {
        throw Exception('Session missing. Please login again.');
      }

      final finalTargetStatus = _targetStatusForRole(_role);
      final currentStatus = item.status.toLowerCase().trim();

      final statusesToUpdate = <String>[];
      if (currentStatus == 'prepared' && finalTargetStatus == 'delivered') {
        statusesToUpdate.add('confirmed');
        statusesToUpdate.add('delivered');
      } else {
        statusesToUpdate.add(finalTargetStatus);
      }

      _KotConfirmedItem activeItem = item;
      http.Response? updateResponse;

      for (int s = 0; s < statusesToUpdate.length; s++) {
        final currentStepStatus = statusesToUpdate[s];

        List<Map<String, dynamic>>? legacyFallbackItems;
        Future<http.Response> runLegacyBillPatch() async {
          List<dynamic> rawItems =
              (_billItemsCacheByBillId[activeItem.billId] ??
                      const <Map<String, dynamic>>[])
                  .map((entry) => Map<String, dynamic>.from(entry))
                  .toList(growable: false);
          if (rawItems.isEmpty) {
            rawItems = await _fetchBillItemsFromServer(activeItem.billId, token);
          }

          var targetIndex = _findTargetItemIndex(rawItems, activeItem);
          if (targetIndex < 0) {
            rawItems = await _fetchBillItemsFromServer(activeItem.billId, token);
            targetIndex = _findTargetItemIndex(rawItems, activeItem);
            if (targetIndex < 0) {
              throw Exception(
                '${activeItem.status.toUpperCase()} item not found. Please refresh.',
              );
            }
          }

          final payloadItems = <Map<String, dynamic>>[];
          for (int i = 0; i < rawItems.length; i++) {
            final source = _asMap(rawItems[i]);
            if (source.isEmpty) continue;
            payloadItems.add(
              _toPatchItemPayload(
                source,
                overrideStatus: i == targetIndex ? currentStepStatus : null,
              ),
            );
          }
          legacyFallbackItems = payloadItems
              .map((entry) => Map<String, dynamic>.from(entry))
              .toList(growable: false);

          return http.patch(
            Uri.parse(
              'https://blackforest4.vseyal.com/api/billings/${activeItem.billId}',
            ),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              http.idempotencyHeaderName: http.generateIdempotencyKey(
                scope:
                    'billings-update-${activeItem.billId}-${activeItem.itemId}-$currentStepStatus',
              ),
            },
            body: jsonEncode({'items': payloadItems}),
            timeout: const Duration(seconds: 12),
          );
        }

        if (activeItem.itemId.trim().isNotEmpty) {
          final statusPayload = <String, dynamic>{
            'itemId': activeItem.itemId.trim(),
            'id': activeItem.itemId.trim(),
            'status': currentStepStatus,
          };
          if (_wsKitchenId.trim().isNotEmpty) {
            statusPayload['kitchenId'] = _wsKitchenId.trim();
          }

          updateResponse = await http.patch(
            Uri.parse(
              'https://blackforest4.vseyal.com/api/billings/${activeItem.billId}/items/status',
            ),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              http.idempotencyHeaderName: http.generateIdempotencyKey(
                scope:
                    'billings-item-status-${activeItem.billId}-${activeItem.itemId}-$currentStepStatus',
              ),
            },
            body: jsonEncode(statusPayload),
            timeout: const Duration(seconds: 12),
          );

          if (updateResponse.statusCode == 404 ||
              updateResponse.statusCode == 405) {
            updateResponse = await runLegacyBillPatch();
          }
        } else {
          updateResponse = await runLegacyBillPatch();
        }

        if (updateResponse.statusCode != 200) {
          String serverMessage = '';
          try {
            final body = _asMap(jsonDecode(updateResponse.body));
            serverMessage = _readText(body['error'] ?? body['message']);
          } catch (_) {}
          throw Exception(
            serverMessage.isNotEmpty
                ? serverMessage
                : 'Failed to mark ${_pastTenseStatusLabel(currentStepStatus)} (${updateResponse.statusCode})',
          );
        }

        try {
          final updateBody = _asMap(jsonDecode(updateResponse.body));
          final updatedItems = updateBody['items'] is List
              ? List<dynamic>.from(updateBody['items'])
              : const <dynamic>[];
          if (updatedItems.isNotEmpty) {
            _billItemsCacheByBillId[activeItem.billId] = updatedItems
                .map((entry) => _asMap(entry))
                .where((entry) => entry.isNotEmpty)
                .map((entry) => Map<String, dynamic>.from(entry))
                .toList(growable: false);
          } else if (legacyFallbackItems != null &&
              legacyFallbackItems!.isNotEmpty) {
            _billItemsCacheByBillId[activeItem.billId] = legacyFallbackItems!
                .map((entry) => Map<String, dynamic>.from(entry))
                .toList(growable: false);
          }
        } catch (_) {
          if (legacyFallbackItems != null && legacyFallbackItems!.isNotEmpty) {
            _billItemsCacheByBillId[activeItem.billId] = legacyFallbackItems!
                .map((entry) => Map<String, dynamic>.from(entry))
                .toList(growable: false);
          }
        }

        // Update activeItem for the next step if any
        activeItem = activeItem.copyWith(status: currentStepStatus);

        if (s < statusesToUpdate.length - 1) {
          // Short delay between sequential updates to allow backend to process
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }

      if (!mounted) return;
      unawaited(
        Provider.of<CartProvider>(
          context,
          listen: false,
        ).syncKitchenNotifications(),
      );

      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${item.productName} marked as ${_pastTenseStatusLabel(finalTargetStatus)}',
          ),
          backgroundColor: const Color(0xFF1E8E3E),
          duration: const Duration(seconds: 1),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        final alreadyVisible = _items.any((entry) => entry.key == item.key);
        if (!alreadyVisible) {
          _items.add(item);
          _items.sort((a, b) {
            final aTime = a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            final bTime = b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            final timeCompare = bTime.compareTo(aTime);
            if (timeCompare != 0) return timeCompare;
            final tableCompare = a.tableLabel.compareTo(b.tableLabel);
            if (tableCompare != 0) return tableCompare;
            return a.productName.compareTo(b.productName);
          });
        }
      });
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
          backgroundColor: const Color(0xFFC62828),
          duration: const Duration(seconds: 2),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _updatingKeys.remove(item.key);
          _inFlightDeliveryTokens.remove(deliveryToken);
        });
      }
    }
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
    bool showRetry = false,
  }) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 80),
      children: [
        Icon(icon, size: 58, color: const Color(0xFF9EA4B2)),
        const SizedBox(height: 14),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w700,
            color: Color(0xFF2E3441),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            color: Color(0xFF6B7280),
            height: 1.35,
          ),
        ),
        if (showRetry) ...[
          const SizedBox(height: 22),
          Center(
            child: ElevatedButton.icon(
              onPressed: () =>
                  unawaited(_refreshConfirmedItems(showLoader: true)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black87,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Retry'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTrackerDeliverCard(
    _KotConfirmedItem item, {
    required bool isUpdating,
  }) {
    final quantityText = item.quantity % 1 == 0
        ? item.quantity.toStringAsFixed(0)
        : item.quantity.toStringAsFixed(2);
    final redTimer = _kotPreparationCountdownLabel(item);
    final greenTimer = _kotElapsedLabel(item);
    final greenTimerColor = _kotElapsedColor(item);
    final targetStatus = _targetStatusForRole(_role);
    final actionLabel = _actionLabelForStatus(targetStatus);

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      elevation: 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: isUpdating ? null : () => unawaited(_markAsDelivered(item)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: Stack(
            children: [
              Positioned.fill(
                child: item.imageUrl == null
                    ? Container(
                        color: const Color(0xFFE5E7EB),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.fastfood_rounded,
                          size: 34,
                          color: Color(0xFF6B7280),
                        ),
                      )
                    : _KotCardImage(
                        url: item.imageUrl!,
                        bearerToken: _authToken,
                      ),
              ),
              if (redTimer != null)
                Positioned(
                  top: 0,
                  left: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: const BoxDecoration(
                      color: Color(0xFFE94F63),
                      borderRadius: BorderRadius.only(
                        bottomRight: Radius.circular(14),
                      ),
                    ),
                    child: Text(
                      redTimer,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: greenTimerColor,
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(14),
                    ),
                  ),
                  child: Text(
                    greenTimer,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              Center(
                child: Container(
                  constraints: const BoxConstraints(
                    minWidth: 42,
                    minHeight: 42,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    quantityText,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 40,
                child: Container(
                  color: Colors.black.withValues(alpha: 0.7),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 7,
                  ),
                  child: Text(
                    item.productName.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  height: 40,
                  color: const Color(0xFFD62828),
                  alignment: Alignment.center,
                  child: isUpdating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          actionLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.1,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    final sourceStatus = _sourceStatusForRole(_role);
    final visibleItems = _items
        .where((item) => item.status.toLowerCase() == sourceStatus)
        .toList(growable: false);

    if (_isLoading && visibleItems.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.black),
      );
    }

    if (_errorMessage != null && visibleItems.isEmpty) {
      final sourceStatusLabel = sourceStatus.toUpperCase();
      return _buildEmptyState(
        icon: Icons.error_outline_rounded,
        title: 'Unable to load $sourceStatusLabel items',
        subtitle: _errorMessage!,
        showRetry: true,
      );
    }

    if (visibleItems.isEmpty) {
      final isPreparedSource = sourceStatus == kotStatusSourcePrepared;
      return _buildEmptyState(
        icon: Icons.task_alt_rounded,
        title: isPreparedSource
            ? 'No prepared products'
            : 'No confirmed products',
        subtitle: isPreparedSource
            ? 'Chef-prepared products will appear here.'
            : 'Supervisor-confirmed products will appear here.',
      );
    }

    final groupedByBill = <String, List<_KotConfirmedItem>>{};
    for (final item in visibleItems) {
      groupedByBill
          .putIfAbsent(item.billId, () => <_KotConfirmedItem>[])
          .add(item);
    }

    final groupEntries = groupedByBill.entries.toList(growable: false)
      ..sort((a, b) {
        final aTime =
            _latestUpdatedAtForGroup(a.value) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bTime =
            _latestUpdatedAtForGroup(b.value) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final timeCompare = bTime.compareTo(aTime);
        if (timeCompare != 0) return timeCompare;
        return a.key.compareTo(b.key);
      });

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 18),
      itemCount: groupEntries.length,
      itemBuilder: (context, groupIndex) {
        final entry = groupEntries[groupIndex];
        final itemsForBill = List<_KotConfirmedItem>.from(entry.value)
          ..sort((a, b) => a.productName.compareTo(b.productName));
        final firstItem = itemsForBill.first;
        final customerLabel = firstItem.customerName.isNotEmpty
            ? firstItem.customerName
            : (firstItem.waiterName.isNotEmpty ? firstItem.waiterName : '-');
        final tableRunningStartedAt = _tableStartedAtForGroup(itemsForBill);
        final groupTime = tableRunningStartedAt != null
            ? _elapsedClock(tableRunningStartedAt)
            : _elapsedClock(_latestUpdatedAtForGroup(itemsForBill));
        final headerLabel =
            '${firstItem.tableLabel.toUpperCase()} - ${firstItem.kotLabel.toUpperCase()}';

        return Container(
          margin: EdgeInsets.only(
            bottom: groupIndex == groupEntries.length - 1 ? 0 : 20,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 210),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF111827),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        headerLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFFDE047),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.7,
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2E9C49),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.access_time,
                          size: 14,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          groupTime,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'CUSTOMER: ${customerLabel.toUpperCase()}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF1F2937),
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 10),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: itemsForBill.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 0.84,
                ),
                itemBuilder: (context, itemIndex) {
                  final item = itemsForBill[itemIndex];
                  final isUpdating = _updatingKeys.contains(item.key);
                  return _buildTrackerDeliverCard(item, isUpdating: isUpdating);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final sourceStatus = _sourceStatusForRole(_role);
    final title = sourceStatus == kotStatusSourcePrepared
        ? 'KOT Prepared'
        : 'KOT Confirmed';
    return CommonScaffold(
      title: title,
      pageType: PageType.kot,
      body: RefreshIndicator(
        onRefresh: _refreshConfirmedItems,
        child: _buildContent(),
      ),
    );
  }
}

class _KotCardImage extends StatefulWidget {
  const _KotCardImage({required this.url, required this.bearerToken});

  final String url;
  final String bearerToken;

  @override
  State<_KotCardImage> createState() => _KotCardImageState();
}

class _KotCardImageState extends State<_KotCardImage> {
  late List<String> _candidates;
  int _index = 0;
  bool _advanceQueued = false;

  Map<String, String>? _headersForCandidate(String candidate) {
    final parsed = Uri.tryParse(candidate);
    final host = parsed?.host.trim() ?? '';
    if (host.isEmpty || !isKnownApiHost(host)) {
      return null;
    }

    final token = widget.bearerToken.trim();
    if (token.isEmpty) return null;
    return <String, String>{'Authorization': 'Bearer $token'};
  }

  @override
  void initState() {
    super.initState();
    _candidates = _buildImageCandidates(widget.url);
  }

  @override
  void didUpdateWidget(covariant _KotCardImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url == widget.url) return;
    _candidates = _buildImageCandidates(widget.url);
    _index = 0;
    _advanceQueued = false;
  }

  List<String> _buildImageCandidates(String rawUrl) {
    final normalized = rawUrl.trim();
    final ordered = <String>[];
    final seen = <String>{};

    void addCandidate(String? value) {
      final candidate = _sanitizeUrl(value);
      if (candidate == null || candidate.isEmpty) return;
      if (seen.contains(candidate)) return;
      seen.add(candidate);
      ordered.add(candidate);
    }

    addCandidate(normalized);
    addCandidate(
      normalized.replaceFirst(
        RegExp(r'^http://', caseSensitive: false),
        'https://',
      ),
    );
    addCandidate(resolveApiAssetUrl(normalized));

    final parsed = Uri.tryParse(normalized);
    if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
      if (parsed.host.toLowerCase() != apiHostPrimary) {
        addCandidate(
          parsed.replace(scheme: 'https', host: apiHostPrimary).toString(),
        );
      }
      if (parsed.host.toLowerCase() != apiHostActive) {
        addCandidate(
          parsed.replace(scheme: 'https', host: apiHostActive).toString(),
        );
      }
    }

    if (normalized.startsWith('/')) {
      addCandidate('https://$apiHostPrimary$normalized');
      addCandidate('https://$apiHostActive$normalized');
    } else if (!normalized.startsWith('http://') &&
        !normalized.startsWith('https://')) {
      final looksLikeFilename = RegExp(
        r'\.(png|jpe?g|webp|gif|avif|svg)(\?.*)?$',
        caseSensitive: false,
      ).hasMatch(normalized);
      if (looksLikeFilename && !normalized.contains('/')) {
        final encodedFilename = Uri.encodeComponent(normalized);
        addCandidate('https://$apiHostPrimary/api/media/file/$encodedFilename');
        addCandidate('https://$apiHostActive/api/media/file/$encodedFilename');
      }
      addCandidate('https://$apiHostPrimary/$normalized');
      addCandidate('https://$apiHostActive/$normalized');
    }

    return ordered;
  }

  String? _sanitizeUrl(String? value) {
    if (value == null) return null;
    final input = value.trim();
    if (input.isEmpty) return null;
    if (input.startsWith('data:image/')) return input;

    final encodedSpaces = input.replaceAll(' ', '%20');
    if (encodedSpaces.startsWith('http://') ||
        encodedSpaces.startsWith('https://')) {
      final parsed = Uri.tryParse(encodedSpaces);
      if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
        return encodedSpaces;
      }
      final normalizedPath = parsed.pathSegments.isEmpty
          ? parsed.path
          : '/${parsed.pathSegments.map(Uri.encodeComponent).join('/')}';
      return parsed
          .replace(
            scheme: parsed.scheme.toLowerCase() == 'http'
                ? 'https'
                : parsed.scheme,
            path: normalizedPath,
          )
          .toString();
    }
    return encodedSpaces;
  }

  Widget _loadingPlaceholder() {
    return Container(
      color: const Color(0xFFE5E7EB),
      alignment: Alignment.center,
      child: const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Color(0xFF6B7280),
        ),
      ),
    );
  }

  Widget _brokenPlaceholder() {
    return Container(
      color: const Color(0xFFE5E7EB),
      alignment: Alignment.center,
      child: const Icon(
        Icons.image_not_supported_rounded,
        size: 30,
        color: Color(0xFF6B7280),
      ),
    );
  }

  void _queueAdvanceIfNeeded(Object error) {
    if (_index >= _candidates.length - 1) return;
    if (_advanceQueued) return;
    _advanceQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _index += 1;
        _advanceQueued = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_candidates.isEmpty) return _brokenPlaceholder();
    final candidate = _candidates[_index];

    return Image.network(
      candidate,
      fit: BoxFit.cover,
      headers: _headersForCandidate(candidate),
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return _loadingPlaceholder();
      },
      errorBuilder: (_, error, __) {
        _queueAdvanceIfNeeded(error);
        if (_index < _candidates.length - 1) {
          return _loadingPlaceholder();
        }
        return _brokenPlaceholder();
      },
    );
  }
}

class _KotConfirmedItem {
  final String key;
  final String billId;
  final String itemId;
  final String productId;
  final String status;
  final String productName;
  final double quantity;
  final String unit;
  final String tableLabel;
  final String sectionLabel;
  final String kotLabel;
  final String waiterName;
  final String customerName;
  final String? imageUrl;
  final DateTime? updatedAt;
  final DateTime? startedAt;
  final DateTime? finalizedAt;
  final double? preparationMinutes;
  final DateTime? tableStartedAt;

  const _KotConfirmedItem({
    required this.key,
    required this.billId,
    required this.itemId,
    required this.productId,
    required this.status,
    required this.productName,
    required this.quantity,
    required this.unit,
    required this.tableLabel,
    required this.sectionLabel,
    required this.kotLabel,
    required this.waiterName,
    required this.customerName,
    required this.imageUrl,
    required this.updatedAt,
    required this.startedAt,
    required this.finalizedAt,
    required this.preparationMinutes,
    required this.tableStartedAt,
  });

  _KotConfirmedItem copyWith({String? imageUrl, String? status}) {
    return _KotConfirmedItem(
      key: key,
      billId: billId,
      itemId: itemId,
      productId: productId,
      status: status ?? this.status,
      productName: productName,
      quantity: quantity,
      unit: unit,
      tableLabel: tableLabel,
      sectionLabel: sectionLabel,
      kotLabel: kotLabel,
      waiterName: waiterName,
      customerName: customerName,
      imageUrl: imageUrl ?? this.imageUrl,
      updatedAt: updatedAt,
      startedAt: startedAt,
      finalizedAt: finalizedAt,
      preparationMinutes: preparationMinutes,
      tableStartedAt: tableStartedAt,
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

enum _WaiterOverlayAction { none, accepting }

class _WaiterAckResult {
  final bool ok;
  final bool alreadyAcknowledged;
  final String acknowledgedBy;
  final String message;

  const _WaiterAckResult({
    required this.ok,
    required this.alreadyAcknowledged,
    required this.acknowledgedBy,
    required this.message,
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
