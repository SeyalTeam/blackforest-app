import 'dart:convert';
import 'dart:math';
import 'dart:ui';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:blackforest_app/cart_provider.dart';
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import 'package:qr/qr.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/printer/unified_printer.dart';
import 'package:blackforest_app/printer/thermal_print_prefs.dart';
import 'package:blackforest_app/printer/bluetooth_printer_prefs.dart';
import 'package:blackforest_app/waiter_call_range_filter_service.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:blackforest_app/notification_service.dart';

@pragma('vm:entry-point')
void startCallback() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(PrintTaskHandler());
}

class PrintTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Service started
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    final alerts = await KotAutoPrintService.syncPendingWebsiteKots(isBackground: true);

    try {
      final isForeground = await FlutterForegroundTask.isAppOnForeground;
      if (isForeground) {
        return;
      }

      final waiterCallAlerts = alerts
          .where((alert) => alert.isWaiterCall && alert.waiterCall != null)
          .toList();
      if (waiterCallAlerts.isEmpty) {
        return;
      }

      final notificationService = NotificationService();
      await notificationService.init().timeout(const Duration(seconds: 5)).catchError((_) {});

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final branchId = prefs.getString('branchId')?.trim() ?? '';
      if (branchId.isEmpty) return;

      final notifiedKey = 'auto_waiter_call_notified_v1_$branchId';
      final notifiedEventKeys = prefs.getStringList(notifiedKey)?.toSet() ?? <String>{};

      var didUpdatePrefs = false;
      for (final alert in waiterCallAlerts) {
        final payload = alert.waiterCall!;
        if (notifiedEventKeys.contains(payload.eventKey)) {
          continue;
        }

        String title = 'Table ${payload.tableNumber} Calling';
        if (payload.tableNumber == '0') {
          title = 'Calling for Other Work';
        }

        String body = '';
        if (payload.callerRole != null) {
          body = 'Called by ${payload.callerRole}';
          if (payload.tableNumber != '0') {
            body += ' for Table ${payload.tableNumber}';
          }
          body += ' | Section: ${payload.section}';
        } else {
          body = 'Section: ${payload.section} | Customer: ${payload.customerName.trim().isEmpty ? 'Guest' : payload.customerName}';
        }

        await notificationService.showWaiterCallNotification(
          id: payload.eventKey.hashCode,
          title: title,
          body: body,
          payload: payload.billId,
        );

        notifiedEventKeys.add(payload.eventKey);
        didUpdatePrefs = true;
      }

      if (didUpdatePrefs) {
        await KotAutoPrintService._persistRememberedIds(
          prefs: prefs,
          key: notifiedKey,
          ids: notifiedEventKeys,
        );
      }
    } catch (error) {
      debugPrint('🛎️ Error processing background waiter notification: $error');
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isProfiled) async {
    // Service stopped
  }
}

class KotAutoPrintService {
  static const String _apiBase = 'https://blackforest4.vseyal.com/api';
  static const Duration _configCacheTtl = Duration(minutes: 2);
  static const int _maxRememberedItems = 1200;
  static const String _autoCompletedReceiptPrefKey =
      'auto_completed_bill_receipt_enabled';
  static final RegExp _waiterCallRegex = RegExp(
    r'WAITER_CALL_SOS\s+([0-9T:\.\+\-Z]+)\s+TABLE-([^\s|]+)\s+SECTION-([^|\n]+)(?:\s*\|\s*BY-([^\s|]+))?(?:\s*FOR-([^\n|]+))?',
    caseSensitive: false,
  );
  static final RegExp _waiterAckRegex = RegExp(
    r'WAITER_CALL_ACK\s+[0-9T:\.\+\-Z]+\s+FOR-([0-9T:\.\+\-Z]+)\s+TABLE-([^\s|]+)\s+SECTION-([^|\n]+?)(?=\s+BY-|\||\n|$)',
    caseSensitive: false,
  );

  static bool _isSyncing = false;
  static bool _isWaiterAlertSyncing = false;
  static _KotPrintConfig? _cachedConfig;
  static DateTime? _cachedConfigAt;
  static String? _cachedConfigBranchId;

  static Future<void> startService() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final notificationPermission = await FlutterForegroundTask.checkNotificationPermission();
      if (notificationPermission != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }

      final isIgnoringBattery = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      if (!isIgnoringBattery) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    }

    if (!await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.startService(
        notificationTitle: 'Blackforest Printer Active',
        notificationText: 'App is monitoring website orders in background',
        callback: startCallback,
      );
    }
  }

  static Future<void> stopService() async {
    await FlutterForegroundTask.stopService();
  }

  static Future<List<AutoSyncAlert>> syncWaiterCallAlertsOnly() async {
    final alerts = <AutoSyncAlert>[];
    if (_isWaiterAlertSyncing) return alerts;
    _isWaiterAlertSyncing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token')?.trim() ?? '';
      final branchId = prefs.getString('branchId')?.trim() ?? '';
      if (token.isEmpty || branchId.isEmpty) {
        return alerts;
      }
      return _collectWaiterCallAlerts(
        prefs: prefs,
        token: token,
        branchId: branchId,
      );
    } catch (error) {
      debugPrint('🛎️ Waiter alert sync error: $error');
      return alerts;
    } finally {
      _isWaiterAlertSyncing = false;
    }
  }

  static Future<List<AutoSyncAlert>> syncPendingWebsiteKots({
    bool isBackground = false,
  }) async {
    final alerts = <AutoSyncAlert>[];
    if (_isSyncing) return alerts;
    _isSyncing = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token')?.trim() ?? '';
      final userId = prefs.getString('user_id')?.trim() ?? '';
      final branchId = prefs.getString('branchId')?.trim() ?? '';

      if (token.isEmpty || userId.isEmpty || branchId.isEmpty) {
        return alerts;
      }

      alerts.addAll(
        await _collectWaiterCallAlerts(
          prefs: prefs,
          token: token,
          branchId: branchId,
        ),
      );

      final bills = await _fetchCandidateBills(
        token: token,
        userId: userId,
        branchId: branchId,
      );
      if (bills.isEmpty) {
        alerts.addAll(
          await _collectCompletedBillAlerts(
            prefs: prefs,
            token: token,
            userId: userId,
            branchId: branchId,
          ),
        );
        return alerts;
      }

      final printedStateKey = _printedStateKey(userId, branchId);
      final seededKey = _seededKey(userId, branchId);
      final rememberedQuantities = _loadRememberedQuantities(
        prefs.getString(printedStateKey),
      );
      final isSeeded = prefs.getBool(seededKey) ?? false;

      if (!isSeeded) {
        for (final bill in bills) {
          final billId = _toText(bill['id']);
          if (billId.isEmpty) continue;
          for (final item in _extractPrintableItems(
            billId,
            bill['items'],
            rememberedQuantities: const <String, double>{},
          )) {
            rememberedQuantities[item.trackingKey] = item.currentQuantity;
          }
        }
        await _persistRememberedQuantities(
          prefs: prefs,
          key: printedStateKey,
          quantities: rememberedQuantities,
        );
        await prefs.setBool(seededKey, true);
        debugPrint(
          '🖨️ Auto KOT seed complete for branch $branchId (${rememberedQuantities.length} items remembered)',
        );
        alerts.addAll(
          await _collectCompletedBillAlerts(
            prefs: prefs,
            token: token,
            userId: userId,
            branchId: branchId,
          ),
        );
        return alerts;
      }

      final config = await _loadConfig(token: token, branchId: branchId);

      var didPersist = false;
      for (final bill in bills) {
        final billId = _toText(bill['id']);
        if (billId.isEmpty) continue;

        final freshItems = _extractPrintableItems(
          billId,
          bill['items'],
          rememberedQuantities: rememberedQuantities,
        ).where((item) => item.quantity > 0).toList();

        if (freshItems.isEmpty) {
          continue;
        }

        alerts.add(
          AutoSyncAlert(
            message:
                'Customer QR order received for ${_tableDisplayLabel(bill)}',
            isSuccess: true,
          ),
        );

        if (config == null || config.kotPrinters.isEmpty) {
          alerts.add(
            const AutoSyncAlert(
              message:
                  'KOT saved, but not printed (no KOT printer configured).',
              isSuccess: false,
            ),
          );
          continue;
        }

        final acknowledged = await _printBillItems(
          config: config,
          bill: bill,
          items: freshItems,
        );

        if (acknowledged.isNotEmpty) {
          rememberedQuantities.addAll(acknowledged);
          didPersist = true;
        }

        if (acknowledged.length == freshItems.length) {
          alerts.add(
            const AutoSyncAlert(
              message: 'KOT printed successfully',
              isSuccess: true,
            ),
          );
        } else if (acknowledged.isEmpty) {
          alerts.add(
            const AutoSyncAlert(
              message: 'KOT saved, but not printed. Check KOT printer.',
              isSuccess: false,
            ),
          );
        } else {
          alerts.add(
            AutoSyncAlert(
              message:
                  'KOT partially printed (${acknowledged.length}/${freshItems.length}).',
              isSuccess: false,
            ),
          );
        }
      }

      if (didPersist) {
        await _persistRememberedQuantities(
          prefs: prefs,
          key: printedStateKey,
          quantities: rememberedQuantities,
        );
      }
      alerts.addAll(
        await _collectCompletedBillAlerts(
          prefs: prefs,
          token: token,
          userId: userId,
          branchId: branchId,
        ),
      );
    } catch (error) {
      debugPrint('🖨️ Auto KOT sync error: $error');
    } finally {
      _isSyncing = false;
    }
    return alerts;
  }

  static Future<void> acknowledgeSubmittedKotItems({
    required String billId,
    required List<CartItem> items,
  }) async {
    final trimmedBillId = billId.trim();
    if (trimmedBillId.isEmpty || items.isEmpty) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final userId = WaiterCallRangeFilterService.resolveUserKeyFromPrefs(prefs);
    final branchId = prefs.getString('branchId')?.trim() ?? '';
    if (userId.isEmpty || branchId.isEmpty) {
      return;
    }

    final rememberedQuantities = _loadRememberedQuantities(
      prefs.getString(_printedStateKey(userId, branchId)),
    );
    for (final item in items) {
      final billingItemId = item.billingItemId?.trim() ?? '';
      if (billingItemId.isEmpty) continue;
      rememberedQuantities['$trimmedBillId::$billingItemId'] = item.quantity;
    }

    if (rememberedQuantities.isEmpty) {
      return;
    }

    await _persistRememberedQuantities(
      prefs: prefs,
      key: _printedStateKey(userId, branchId),
      quantities: rememberedQuantities,
    );
  }

  static Future<void> acknowledgeCompletedBill({required String billId}) async {
    final trimmedBillId = billId.trim();
    if (trimmedBillId.isEmpty) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id')?.trim() ?? '';
    final branchId = prefs.getString('branchId')?.trim() ?? '';
    if (userId.isEmpty || branchId.isEmpty) {
      return;
    }

    final notifiedIds =
        prefs
            .getStringList(_completedBillAlertsKey(userId, branchId))
            ?.toSet() ??
        <String>{};
    notifiedIds.add(trimmedBillId);
    await _persistRememberedIds(
      prefs: prefs,
      key: _completedBillAlertsKey(userId, branchId),
      ids: notifiedIds,
    );
    await prefs.setBool(_completedBillAlertsSeededKey(userId, branchId), true);
  }

  static Future<List<Map<String, dynamic>>> _fetchCandidateBills({
    required String token,
    required String userId,
    required String branchId,
  }) async {
    final now = DateTime.now();
    final todayStart = DateTime(
      now.year,
      now.month,
      now.day,
    ).toUtc().toIso8601String();

    final url = Uri.parse(
      '$_apiBase/billings'
      '?where[status][in]=pending,ordered'
      '&where[createdBy][equals]=$userId'
      '&where[branch][equals]=$branchId'
      '&where[createdAt][greater_than_equal]=$todayStart'
      '&limit=100'
      '&sort=createdAt'
      '&depth=3',
    );

    final response = await http.get(
      url,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
    );

    if (response.statusCode != 200) {
      debugPrint(
        '🖨️ Auto KOT fetch skipped: ${response.statusCode} ${response.body}',
      );
      return const <Map<String, dynamic>>[];
    }

    final decoded = jsonDecode(response.body);
    final docs = decoded is Map<String, dynamic> ? decoded['docs'] : null;
    if (docs is! List) {
      return const <Map<String, dynamic>>[];
    }

    return docs
        .whereType<Map>()
        .map((raw) => Map<String, dynamic>.from(raw))
        .toList(growable: false);
  }

  static Future<List<Map<String, dynamic>>> _fetchCompletedBills({
    required String token,
    required String userId,
    required String branchId,
  }) async {
    final now = DateTime.now();
    final todayStart = DateTime(
      now.year,
      now.month,
      now.day,
    ).toUtc().toIso8601String();

    final url = Uri.parse(
      '$_apiBase/billings'
      '?where[status][equals]=completed'
      '&where[createdBy][equals]=$userId'
      '&where[branch][equals]=$branchId'
      '&where[updatedAt][greater_than_equal]=$todayStart'
      '&limit=100'
      '&sort=updatedAt'
      '&depth=3',
    );

    final response = await http.get(
      url,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
    );

    if (response.statusCode != 200) {
      debugPrint(
        '🧾 Completed bill alert fetch skipped: ${response.statusCode} ${response.body}',
      );
      return const <Map<String, dynamic>>[];
    }

    final decoded = jsonDecode(response.body);
    final docs = decoded is Map<String, dynamic> ? decoded['docs'] : null;
    if (docs is! List) {
      return const <Map<String, dynamic>>[];
    }

    return docs
        .whereType<Map>()
        .map((raw) => Map<String, dynamic>.from(raw))
        .toList(growable: false);
  }

  static Future<List<Map<String, dynamic>>>
  _fetchActiveBranchBillsForWaiterAlerts({
    required String token,
    required String branchId,
  }) async {
    final now = DateTime.now();
    // Use 24 hours ago as start time to be safe against midnight shifts and timezone differences
    final todayStart = now.subtract(const Duration(hours: 24)).toUtc().toIso8601String();

    final url = Uri.parse(
      '$_apiBase/billings'
      '?where[status][in]=pending,ordered,confirmed,prepared,delivered'
      '&where[branch][equals]=$branchId'
      '&where[updatedAt][greater_than_equal]=$todayStart'
      '&limit=150'
      '&sort=-updatedAt'
      '&depth=1',
    );

    final response = await http.get(
      url,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
    );

    if (response.statusCode != 200) {
      debugPrint(
        '🛎️ Waiter alert fetch skipped: ${response.statusCode} ${response.body}',
      );
      return const <Map<String, dynamic>>[];
    }

    final decoded = jsonDecode(response.body);
    final docs = decoded is Map<String, dynamic> ? decoded['docs'] : null;
    if (docs is! List) {
      return const <Map<String, dynamic>>[];
    }

    return docs
        .whereType<Map>()
        .map((raw) => Map<String, dynamic>.from(raw))
        .toList(growable: false);
  }

  static Future<List<AutoSyncAlert>> _collectWaiterCallAlerts({
    required SharedPreferences prefs,
    required String token,
    required String branchId,
  }) async {
    await prefs.reload();
    final alerts = <AutoSyncAlert>[];
    final activeBills = await _fetchActiveBranchBillsForWaiterAlerts(
      token: token,
      branchId: branchId,
    );
    if (activeBills.isEmpty) {
      return alerts;
    }

    final idsKey = _waiterCallHandledKey(branchId);
    final presentedKey = _waiterCallPresentedKey(branchId);
    final seededKey = _waiterCallAlertsSeededKey(branchId);
    final handledEventKeys = prefs.getStringList(idsKey)?.toSet() ?? <String>{};
    final presentedEventKeys =
        prefs.getStringList(presentedKey)?.toSet() ?? <String>{};
    final isSeeded = prefs.getBool(seededKey) ?? false;
    final waiterUserKey = WaiterCallRangeFilterService.resolveUserKeyFromPrefs(
      prefs,
    );
    final selectedRangeRows = WaiterCallRangeFilterService.readSelections(
      prefs: prefs,
      userId: waiterUserKey,
      branchId: branchId,
    );
    final userKeys = WaiterCallRangeFilterService.resolveCandidateUserKeysFromPrefs(prefs);
    final cachedTablesRaw = prefs.getString('cached_tables_$branchId');
    List<dynamic> cachedTables = [];
    if (cachedTablesRaw != null) {
      try {
        cachedTables = jsonDecode(cachedTablesRaw) as List<dynamic>;
      } catch (_) {}
    }
    var didPersist = false;

    for (final bill in activeBills) {
      final billId = _toText(bill['id']);
      if (billId.isEmpty) continue;

      final notes = _toText(bill['notes']);
      if (notes.isEmpty || !notes.toUpperCase().contains('WAITER_CALL_SOS')) {
        continue;
      }

      final acknowledgedByNotes = _extractWaiterAckEventKeys(
        billId: billId,
        notes: notes,
      );
      for (final acknowledgedEventKey in acknowledgedByNotes) {
        if (handledEventKeys.contains(acknowledgedEventKey)) continue;
        handledEventKeys.add(acknowledgedEventKey);
        didPersist = true;
      }

      final parsedEntries = _extractWaiterCallEntries(
        bill: bill,
        billId: billId,
        notes: notes,
      );
      if (parsedEntries.isEmpty) {
        continue;
      }

      for (final entry in parsedEntries) {
        if (handledEventKeys.contains(entry.eventKey) ||
            presentedEventKeys.contains(entry.eventKey)) {
          continue;
        }

        if (!isSeeded) {
          // Initial seed should not alert for historical SOS entries.
          handledEventKeys.add(entry.eventKey);
          didPersist = true;
          continue;
        }

        final tableNumberInt = WaiterCallRangeFilterService.parseTableToken(entry.tableNumber) ?? 0;
        bool shouldNotify = false;

        if (entry.targetWaiterId != null && entry.targetWaiterId!.isNotEmpty) {
          shouldNotify = userKeys.contains(entry.targetWaiterId);
        } else if (tableNumberInt > 0 && entry.section.isNotEmpty) {
          final hasAllocations = _sectionHasAnyAllocations(
            sectionName: entry.section,
            cachedTables: cachedTables,
          );

          if (hasAllocations) {
            shouldNotify = _isTableAllocatedToMe(
              sectionName: entry.section,
              tableNumber: tableNumberInt,
              cachedTables: cachedTables,
              candidateKeys: userKeys,
            );
          } else {
            shouldNotify = WaiterCallRangeFilterService.shouldNotifyForCall(
              selections: selectedRangeRows,
              section: entry.section,
              tableNumber: entry.tableNumber,
            );
          }
        } else {
          shouldNotify = WaiterCallRangeFilterService.shouldNotifyForCall(
            selections: selectedRangeRows,
            section: entry.section,
            tableNumber: entry.tableNumber,
          );
        }

        if (!shouldNotify) {
          continue;
        }

        alerts.add(AutoSyncAlert.waiterCall(entry));
      }
    }

    if (didPersist) {
      await _persistRememberedIds(
        prefs: prefs,
        key: idsKey,
        ids: handledEventKeys,
      );
    }
    if (!isSeeded) {
      await prefs.setBool(seededKey, true);
    }

    return alerts;
  }

  static bool _sectionHasAnyAllocations({
    required String sectionName,
    required List<dynamic> cachedTables,
  }) {
    final normalizedSearchSection = WaiterCallRangeFilterService.normalizeSection(sectionName);
    for (final section in cachedTables) {
      if (section is! Map) continue;
      final name = WaiterCallRangeFilterService.normalizeSection(section['name']?.toString() ?? 'General');
      if (name == normalizedSearchSection) {
        final allocations = section['waiterAllocations'];
        if (allocations is List && allocations.isNotEmpty) {
          return true;
        }
      }
    }
    return false;
  }

  static bool _isTableAllocatedToMe({
    required String sectionName,
    required int tableNumber,
    required List<dynamic> cachedTables,
    required List<String> candidateKeys,
  }) {
    if (candidateKeys.isEmpty) return false;
    final normalizedSearchSection = WaiterCallRangeFilterService.normalizeSection(sectionName);

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

  static List<WaiterCallAlertPayload> _extractWaiterCallEntries({
    required Map<String, dynamic> bill,
    required String billId,
    required String notes,
  }) {
    final tableDetails = bill['tableDetails'] is Map
        ? Map<String, dynamic>.from(bill['tableDetails'])
        : const <String, dynamic>{};
    final fallbackTable = _toText(tableDetails['tableNumber']);
    final fallbackSection = _toText(tableDetails['section']);
    final customerName = _extractBillCustomerName(bill);
    final kotNumber = _toText(bill['kotNumber']);
    final entries = <WaiterCallAlertPayload>[];

    for (final match in _waiterCallRegex.allMatches(notes)) {
      final timestampIso = _toText(match.group(1));
      final tableFromNote = _toText(match.group(2));
      final sectionFromNote = _toText(
        match.group(3),
      ).replaceAll(RegExp(r'\s+'), ' ');
      final tableNumber = tableFromNote.isNotEmpty
          ? tableFromNote
          : fallbackTable;
      final section = sectionFromNote.isNotEmpty
          ? sectionFromNote
          : fallbackSection;

      final callerRoleVal = match.groupCount >= 4 ? match.group(4) : null;
      final targetWaiterVal = match.groupCount >= 5 ? match.group(5) : null;
      final callerRole = callerRoleVal != null ? _toText(callerRoleVal) : null;
      final targetWaiterId = targetWaiterVal != null ? _toText(targetWaiterVal) : null;

      if (timestampIso.isEmpty || tableNumber.isEmpty) {
        continue;
      }

      entries.add(
        WaiterCallAlertPayload(
          eventKey: '$billId|$timestampIso|$tableNumber|$section',
          billId: billId,
          timestampIso: timestampIso,
          tableNumber: tableNumber,
          section: section,
          customerName: customerName,
          kotNumber: kotNumber,
          callerRole: callerRole?.isEmpty == true ? null : callerRole,
          targetWaiterId: targetWaiterId?.isEmpty == true ? null : targetWaiterId,
        ),
      );
    }

    return entries;
  }

  static Set<String> _extractWaiterAckEventKeys({
    required String billId,
    required String notes,
  }) {
    final keys = <String>{};
    for (final match in _waiterAckRegex.allMatches(notes)) {
      final timestampIso = _toText(match.group(1));
      final table = _toText(match.group(2));
      final section = _toText(match.group(3)).replaceAll(RegExp(r'\s+'), ' ');
      if (timestampIso.isEmpty || table.isEmpty) continue;
      keys.add('$billId|$timestampIso|$table|$section');
    }
    return keys;
  }

  static Future<void> markWaiterCallHandled({required String eventKey}) async {
    final trimmedEventKey = eventKey.trim();
    if (trimmedEventKey.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final branchId = prefs.getString('branchId')?.trim() ?? '';
    if (branchId.isEmpty) return;

    final idsKey = _waiterCallHandledKey(branchId);
    final handledEventKeys = prefs.getStringList(idsKey)?.toSet() ?? <String>{};
    if (handledEventKeys.contains(trimmedEventKey)) {
      return;
    }
    handledEventKeys.add(trimmedEventKey);
    await _persistRememberedIds(
      prefs: prefs,
      key: idsKey,
      ids: handledEventKeys,
    );
    await markWaiterCallPresented(eventKey: trimmedEventKey);
    await prefs.setBool(_waiterCallAlertsSeededKey(branchId), true);
  }

  static Future<void> markWaiterCallPresented({
    required String eventKey,
  }) async {
    final trimmedEventKey = eventKey.trim();
    if (trimmedEventKey.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final branchId = prefs.getString('branchId')?.trim() ?? '';
    if (branchId.isEmpty) return;

    final presentedKey = _waiterCallPresentedKey(branchId);
    final presentedEventKeys =
        prefs.getStringList(presentedKey)?.toSet() ?? <String>{};
    if (presentedEventKeys.contains(trimmedEventKey)) {
      return;
    }

    presentedEventKeys.add(trimmedEventKey);
    await _persistRememberedIds(
      prefs: prefs,
      key: presentedKey,
      ids: presentedEventKeys,
    );
    await prefs.setBool(_waiterCallAlertsSeededKey(branchId), true);
  }

  static String _extractBillCustomerName(Map<String, dynamic> bill) {
    final prioritizedCandidates = <dynamic>[
      bill['customerDetails'],
      bill['customer'],
      bill['customerName'],
      bill['customerDetailsName'],
      bill['createdBy'],
    ];
    for (final candidate in prioritizedCandidates) {
      final name = _extractNameFromAny(candidate);
      if (name.isNotEmpty) {
        return name;
      }
    }
    return 'Guest';
  }

  static String _extractNameFromAny(dynamic value) {
    if (value == null) return '';
    if (value is String) return value.trim();
    if (value is Map) {
      final map = Map<String, dynamic>.from(value);
      const keys = <String>[
        'name',
        'customerName',
        'fullName',
        'displayName',
        'username',
      ];
      for (final key in keys) {
        final candidate = _toText(map[key]);
        if (candidate.isNotEmpty) {
          return candidate;
        }
      }
      return '';
    }
    return _toText(value);
  }

  static Future<List<AutoSyncAlert>> _collectCompletedBillAlerts({
    required SharedPreferences prefs,
    required String token,
    required String userId,
    required String branchId,
  }) async {
    final alerts = <AutoSyncAlert>[];
    final completedBills = await _fetchCompletedBills(
      token: token,
      userId: userId,
      branchId: branchId,
    );
    if (completedBills.isEmpty) {
      return alerts;
    }

    final idsKey = _completedBillAlertsKey(userId, branchId);
    final seededKey = _completedBillAlertsSeededKey(userId, branchId);
    final notifiedIds = prefs.getStringList(idsKey)?.toSet() ?? <String>{};
    final isSeeded = prefs.getBool(seededKey) ?? false;

    if (!isSeeded) {
      for (final bill in completedBills) {
        final billId = _toText(bill['id']);
        if (billId.isNotEmpty) {
          notifiedIds.add(billId);
        }
      }
      await _persistRememberedIds(prefs: prefs, key: idsKey, ids: notifiedIds);
      await prefs.setBool(seededKey, true);
      return alerts;
    }

    final config = await _loadConfig(token: token, branchId: branchId);
    final shouldAutoPrintCompletedReceipt =
        prefs.getBool(_autoCompletedReceiptPrefKey) ?? false;
    var didPersist = false;
    for (final bill in completedBills) {
      final billId = _toText(bill['id']);
      if (billId.isEmpty || notifiedIds.contains(billId)) {
        continue;
      }

      notifiedIds.add(billId);
      didPersist = true;
      final paymentMethod = _toText(bill['paymentMethod']).toUpperCase();
      final totalAmount = _toSafeDouble(bill['totalAmount']);
      final paymentSuffix = paymentMethod.isEmpty ? '' : ' via $paymentMethod';
      alerts.add(
        AutoSyncAlert(
          message:
              'Customer completed bill for ${_tableDisplayLabel(bill)}. Payable: ₹${totalAmount.toStringAsFixed(2)}$paymentSuffix',
          isSuccess: true,
        ),
      );
      if (shouldAutoPrintCompletedReceipt) {
        alerts.add(
          await _printCompletedBillReceipt(
            prefs: prefs,
            config: config,
            bill: bill,
          ),
        );
      }
    }

    if (didPersist) {
      await _persistRememberedIds(prefs: prefs, key: idsKey, ids: notifiedIds);
    }

    return alerts;
  }

  static Future<_KotPrintConfig?> _loadConfig({
    required String token,
    required String branchId,
  }) async {
    final now = DateTime.now();
    if (_cachedConfig != null &&
        _cachedConfigBranchId == branchId &&
        _cachedConfigAt != null &&
        now.difference(_cachedConfigAt!) < _configCacheTtl) {
      return _cachedConfig;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      String branchName = prefs.getString('branchName')?.trim() ?? '';
      String companyName = prefs.getString('company_name')?.trim() ?? '';
      String branchGst = '';
      String branchMobile = '';
      String receiptPrinterIp = '';
      int receiptPrinterPort = 9100;
      String receiptPrinterProtocol = 'esc_pos';
      List<dynamic> kotPrinters = const <dynamic>[];

      final geoResponse = await http.get(
        Uri.parse('$_apiBase/globals/branch-geo-settings'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      if (geoResponse.statusCode == 200) {
        final payload = jsonDecode(geoResponse.body);
        final locations = payload is Map<String, dynamic>
            ? payload['locations']
            : null;
        if (locations is List) {
          for (final rawLocation in locations) {
            if (rawLocation is! Map) continue;
            final location = Map<String, dynamic>.from(rawLocation);
            final branch = location['branch'];
            final locationBranchId = _relationId(branch);
            if (locationBranchId != branchId) continue;

            if (branchName.isEmpty && branch is Map) {
              branchName = _toText(branch['name']);
            }
            if (receiptPrinterIp.isEmpty) {
              receiptPrinterIp = _toText(location['printerIp']);
            }
            final rawReceiptPrinterPort = location['printerPort'];
            if (rawReceiptPrinterPort is num) {
              receiptPrinterPort = rawReceiptPrinterPort.toInt();
            } else if (rawReceiptPrinterPort is String) {
              receiptPrinterPort =
                  int.tryParse(rawReceiptPrinterPort.trim()) ??
                  receiptPrinterPort;
            }
            final locationPrinterProtocol = _toText(
              location['printerProtocol'],
            );
            if (locationPrinterProtocol.isNotEmpty) {
              receiptPrinterProtocol = locationPrinterProtocol;
            }
            final rawKotPrinters = location['kotPrinters'];
            if (rawKotPrinters is List) {
              kotPrinters = List<dynamic>.from(rawKotPrinters);
            }
            break;
          }
        }
      }

      if (branchName.isEmpty ||
          companyName.isEmpty ||
          branchGst.isEmpty ||
          branchMobile.isEmpty ||
          receiptPrinterIp.isEmpty) {
        final branchResponse = await http.get(
          Uri.parse('$_apiBase/branches/$branchId?depth=1'),
          headers: {'Authorization': 'Bearer $token'},
        );
        if (branchResponse.statusCode == 200) {
          final branch = jsonDecode(branchResponse.body);
          if (branch is Map<String, dynamic>) {
            branchName = _toText(branch['name']);
            branchGst = _toText(branch['gst']);
            branchMobile = _toText(branch['phone']);
            if (receiptPrinterIp.isEmpty) {
              receiptPrinterIp = _toText(branch['printerIp']);
            }
            final rawBranchPrinterPort = branch['printerPort'];
            if (rawBranchPrinterPort is num) {
              receiptPrinterPort = rawBranchPrinterPort.toInt();
            } else if (rawBranchPrinterPort is String) {
              receiptPrinterPort =
                  int.tryParse(rawBranchPrinterPort.trim()) ??
                  receiptPrinterPort;
            }
            final branchPrinterProtocol = _toText(branch['printerProtocol']);
            if (branchPrinterProtocol.isNotEmpty) {
              receiptPrinterProtocol = branchPrinterProtocol;
            }

            final company = branch['company'];
            if (company is Map<String, dynamic>) {
              companyName = _toText(company['name']);
            } else if (company is Map) {
              companyName = _toText(Map<String, dynamic>.from(company)['name']);
            }
          }
        }
      }

      final kitchenResponse = await http.get(
        Uri.parse(
          '$_apiBase/kitchens?where[branches][contains]=$branchId&limit=100',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );

      final categoryToKitchenMap = <String, String>{};
      if (kitchenResponse.statusCode == 200) {
        final payload = jsonDecode(kitchenResponse.body);
        final docs = payload is Map<String, dynamic> ? payload['docs'] : null;
        if (docs is List) {
          for (final rawKitchen in docs) {
            if (rawKitchen is! Map) continue;
            final kitchen = Map<String, dynamic>.from(rawKitchen);
            final kitchenId = _relationId(kitchen);
            if (kitchenId.isEmpty) continue;

            final categories = kitchen['categories'];
            if (categories is! List) continue;

            for (final rawCategory in categories) {
              final categoryId = _relationId(rawCategory);
              if (categoryId.isEmpty) continue;
              categoryToKitchenMap[categoryId] = kitchenId;
            }
          }
        }
      }

      final config = _KotPrintConfig(
        branchName: branchName,
        companyName: companyName,
        branchGst: branchGst,
        branchMobile: branchMobile,
        receiptPrinterIp: receiptPrinterIp,
        receiptPrinterPort: receiptPrinterPort,
        receiptPrinterProtocol: receiptPrinterProtocol,
        kotPrinters: kotPrinters,
        categoryToKitchenMap: categoryToKitchenMap,
      );

      _cachedConfig = config;
      _cachedConfigAt = now;
      _cachedConfigBranchId = branchId;
      return config;
    } catch (error) {
      debugPrint('🖨️ Auto KOT config load failed: $error');
      return null;
    }
  }

  static Future<AutoSyncAlert> _printCompletedBillReceipt({
    required SharedPreferences prefs,
    required _KotPrintConfig? config,
    required Map<String, dynamic> bill,
  }) async {
    final btMac = prefs.getString(btPrinterMacKey) ?? '';
    final btBillingEnabled = isBluetoothBillingEnabled(prefs);
    final hasBluetooth = btMac.isNotEmpty && btBillingEnabled;

    final target = _resolveReceiptPrinterTarget(config);
    if ((target == null || target.printerIp.isEmpty) && !hasBluetooth) {
      return const AutoSyncAlert(
        message:
            'Bill saved, but receipt not printed (printer not configured).',
        isSuccess: false,
      );
    }

    if (target != null &&
        target.printerProtocol.toLowerCase() != 'esc_pos' &&
        !hasBluetooth) {
      return const AutoSyncAlert(
        message:
            'Bill saved, but receipt not printed (unsupported printer setup).',
        isSuccess: false,
      );
    }

    final profile = await CapabilityProfile.load();
    UnifiedPrinter? printer;
    try {
      final prefsPort = int.tryParse(
        (prefs.getString('printerPort') ?? '').trim(),
      );
      final candidatePorts = <int>{
        if (target != null) target.printerPort,
        if (prefsPort != null) prefsPort,
        9100,
        9101,
      }.toList(growable: false);

      printer = await UnifiedPrinter.connect(
        printerIp: target?.printerIp,
        candidatePorts: candidatePorts,
        paperSize: PaperSize.mm80,
        profile: profile,
        jobType: PrintJobType.billing,
      );

      if (printer == null) {
        debugPrint(
          '⚠️ Auto receipt connect failed for ${target?.printerIp ?? 'Bluetooth'} on ports ${candidatePorts.join(", ")}',
        );
        return const AutoSyncAlert(
          message: 'Bill saved, but receipt not printed. Check printer.',
          isSuccess: false,
        );
      }

      final updatedAt = _parseBillDateTime(bill['updatedAt']) ?? DateTime.now();
      final invoiceNumber = _toText(bill['invoiceNumber']).isNotEmpty
          ? _toText(bill['invoiceNumber'])
          : _toText(bill['id']);
      final paymentMethod = _toText(bill['paymentMethod']).toUpperCase();
      final totalAmount = _toSafeDouble(bill['totalAmount']);
      final grossAmount = _toSafeDouble(bill['grossAmount']);
      final customerDetails = bill['customerDetails'] is Map
          ? Map<String, dynamic>.from(bill['customerDetails'])
          : const <String, dynamic>{};
      final customerName = _toText(customerDetails['name']);
      final customerPhone = _toText(customerDetails['phone']).isNotEmpty
          ? _toText(customerDetails['phone'])
          : _toText(customerDetails['phoneNumber']);

      String waiterName = prefs.getString('user_name')?.trim() ?? 'Unknown';
      if (_isQrOrWebsiteOrder(bill) && customerName.isNotEmpty) {
        waiterName = customerName;
      }

      printer.text(
        (config?.companyName.isNotEmpty ?? false)
            ? config!.companyName.toUpperCase()
            : 'BLACK FOREST CAKES',
        styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      );
      if ((config?.branchName.isNotEmpty ?? false)) {
        printer.text(
          'Branch: ${config!.branchName}',
          styles: const PosStyles(align: PosAlign.center),
        );
      }
      if ((config?.branchGst.isNotEmpty ?? false)) {
        printer.text(
          'GST: ${config!.branchGst}',
          styles: const PosStyles(align: PosAlign.center),
        );
      }
      if ((config?.branchMobile.isNotEmpty ?? false)) {
        printer.text(
          'Mobile: ${config!.branchMobile}',
          styles: const PosStyles(align: PosAlign.center),
        );
      }

      printer.hr(ch: '=');
      printer.row([
        PosColumn(
          text: 'Date: ${DateFormat('yyyy-MM-dd hh:mm a').format(updatedAt)}',
          width: 7,
          styles: const PosStyles(align: PosAlign.left),
        ),
        PosColumn(
          text: invoiceNumber,
          width: 5,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);
      printer.row([
        PosColumn(
          text: 'Assigned by: $waiterName',
          width: 7,
          styles: const PosStyles(align: PosAlign.left),
        ),
        PosColumn(
          text: _tableDisplayLabel(bill),
          width: 5,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);

      printer.hr(ch: '=');
      printer.row([
        PosColumn(text: 'Item', width: 5, styles: const PosStyles(bold: true)),
        PosColumn(
          text: 'Qty',
          width: 2,
          styles: const PosStyles(bold: true, align: PosAlign.center),
        ),
        PosColumn(
          text: 'Price',
          width: 2,
          styles: const PosStyles(bold: true, align: PosAlign.right),
        ),
        PosColumn(
          text: 'Amount',
          width: 3,
          styles: const PosStyles(bold: true, align: PosAlign.right),
        ),
      ]);
      printer.hr(ch: '-');

      final rawItems = bill['items'] is List
          ? List<dynamic>.from(bill['items'] as List)
          : const <dynamic>[];
      for (final rawItem in rawItems) {
        if (rawItem is! Map) continue;
        final item = Map<String, dynamic>.from(rawItem);
        if (_toText(item['status']).toLowerCase() == 'cancelled') continue;

        final itemName = _toText(item['name']);
        if (itemName.isEmpty) continue;

        final quantity = _toSafeDouble(item['quantity']);
        if (quantity <= 0) continue;

        final unitPrice = _resolveReceiptUnitPrice(item);
        final amount = _resolveReceiptLineAmount(item, unitPrice, quantity);
        final qtyText = quantity % 1 == 0
            ? quantity.toStringAsFixed(0)
            : quantity.toStringAsFixed(2);

        printer.row([
          PosColumn(text: itemName, width: 5),
          PosColumn(
            text: qtyText,
            width: 2,
            styles: const PosStyles(align: PosAlign.center),
          ),
          PosColumn(
            text: unitPrice.toStringAsFixed(2),
            width: 2,
            styles: const PosStyles(align: PosAlign.right),
          ),
          PosColumn(
            text: amount.toStringAsFixed(2),
            width: 3,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]);

        final specialNote = _toText(item['specialNote']).isNotEmpty
            ? _toText(item['specialNote'])
            : _toText(item['notes']);
        if (specialNote.isNotEmpty) {
          printer.text(
            '  Note - $specialNote',
            styles: const PosStyles(align: PosAlign.left),
          );
        }
      }

      printer.hr(ch: '-');
      if (grossAmount > totalAmount + 0.0001) {
        printer.row([
          PosColumn(
            text: 'GROSS RS ${grossAmount.toStringAsFixed(2)}',
            width: 12,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]);
        printer.row([
          PosColumn(
            text:
                'DISCOUNT RS ${(grossAmount - totalAmount).toStringAsFixed(2)}',
            width: 12,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]);
      }
      printer.row([
        PosColumn(
          text: 'PAID BY: ${paymentMethod.isEmpty ? 'N/A' : paymentMethod}',
          width: 5,
          styles: const PosStyles(align: PosAlign.left, bold: true),
        ),
        PosColumn(
          text: 'TOTAL RS ${totalAmount.toStringAsFixed(2)}',
          width: 7,
          styles: const PosStyles(
            align: PosAlign.right,
            bold: true,
            height: PosTextSize.size2,
            width: PosTextSize.size1,
          ),
        ),
      ]);
      printer.hr(ch: '=');

      if (customerName.isNotEmpty || customerPhone.isNotEmpty) {
        if (customerName.isNotEmpty) {
          printer.text('Customer: $customerName');
        }
        if (customerPhone.isNotEmpty) {
          printer.text('Phone: $customerPhone');
        }
        printer.hr(ch: '-');
      }

      printer.hr(ch: '=');

      // Feedback logic (Same as cart_page.dart)
      bool shouldShowFeedback = rawItems.any((rawItem) {
        if (rawItem is! Map) return false;

        // Extract department from nested product data
        String dept = '';
        final product = rawItem['product'];
        if (product is Map) {
          if (product['department'] != null) {
            dept = (product['department'] is Map)
                ? _toText(product['department']['name'])
                : _toText(product['department']);
          } else if (product['category'] != null &&
              product['category'] is Map) {
            final category = product['category'] as Map;
            if (category['department'] != null) {
              final catDept = category['department'];
              dept = (catDept is Map)
                  ? _toText(catDept['name'])
                  : _toText(catDept);
            }
          }
        }

        dept = dept.trim().toLowerCase();
        return dept.isEmpty || dept != 'others';
      });
      shouldShowFeedback =
          shouldShowFeedback && isThermalReviewPrintEnabled(prefs);

      if (shouldShowFeedback) {
        try {
          final ByteData data = await rootBundle.load(
            'assets/feedback_full.png',
          );
          final Uint8List bytes = data.buffer.asUint8List();
          final img.Image? image = img.decodeImage(bytes);
          if (image != null) {
            final img.Image resized = img.copyResize(image, width: 550);
            printer.image(resized, align: PosAlign.center);
          }
        } catch (e) {
          debugPrint("Error printing auto-bill feedback image: $e");
          printer.text(
            'THE CREATOR OF THIS PRODUCT IS WAITING FOR YOUR',
            styles: const PosStyles(align: PosAlign.center, bold: true),
          );
          printer.text(
            'FEEDBACK',
            styles: const PosStyles(
              align: PosAlign.center,
              bold: true,
              height: PosTextSize.size2,
              width: PosTextSize.size2,
            ),
          );
        }
        printer.feed(1);
      }

      // QR Code Logic (Same as cart_page.dart)
      String billingUrl = 'https://blackforest4.vseyal.com/billings';
      String? billingId = bill['id'] ?? bill['doc']?['id'] ?? bill['_id'];
      if (billingId != null) {
        billingUrl = '$billingUrl/$billingId';
      }

      if (shouldShowFeedback) {
        try {
          // 1. Generate QR Code Image
          final qrCode = QrCode(4, QrErrorCorrectLevel.L);
          qrCode.addData(billingUrl);
          final qrImageMatrix = QrImage(qrCode);

          const int pixelSize = 8;
          final int qrWidth = qrImageMatrix.moduleCount * pixelSize;
          final int qrHeight = qrImageMatrix.moduleCount * pixelSize;
          final img.Image qrImage = img.Image(qrWidth, qrHeight);
          img.fill(qrImage, img.getColor(255, 255, 255));

          for (int x = 0; x < qrImageMatrix.moduleCount; x++) {
            for (int y = 0; y < qrImageMatrix.moduleCount; y++) {
              if (qrImageMatrix.isDark(y, x)) {
                img.fillRect(
                  qrImage,
                  x * pixelSize,
                  y * pixelSize,
                  (x + 1) * pixelSize,
                  (y + 1) * pixelSize,
                  img.getColor(0, 0, 0),
                );
              }
            }
          }

          // 2. Load Chef Image
          final ByteData chefData = await rootBundle.load('assets/chef.png');
          final Uint8List chefBytes = chefData.buffer.asUint8List();
          final img.Image? chefImageRaw = img.decodeImage(chefBytes);

          if (chefImageRaw != null) {
            const int maxWidth = 550;
            const int gap = 10;
            final int remainingWidth = maxWidth - qrWidth - gap;
            final img.Image chefImage = img.copyResize(
              chefImageRaw,
              width: remainingWidth > 100 ? remainingWidth : 100,
            );

            const int canvasWidth = 550;
            final int contentWidth = qrWidth + gap + chefImage.width;
            final int startX = (canvasWidth - contentWidth) ~/ 2;
            const int textBlockHeight = 40;
            final int qrBlockHeight = qrHeight + textBlockHeight;
            final int totalHeight = max(qrBlockHeight, chefImage.height);

            final img.Image combinedImage = img.Image(canvasWidth, totalHeight);
            img.fill(combinedImage, img.getColor(255, 255, 255));

            final int qrBlockY = (totalHeight - qrBlockHeight) ~/ 2;
            final int chefY = (totalHeight - chefImage.height) ~/ 2;

            img.drawImage(combinedImage, qrImage, dstX: startX, dstY: qrBlockY);
            img.fillRect(
              combinedImage,
              startX,
              qrBlockY + qrHeight,
              startX + qrWidth,
              qrBlockY + qrHeight + textBlockHeight,
              img.getColor(0, 0, 0),
            );
            img.drawString(
              combinedImage,
              img.arial_24,
              startX + (qrWidth - (14 * 16)) ~/ 2,
              qrBlockY + qrHeight + (textBlockHeight - 24) ~/ 2,
              'SCAN TO REVIEW',
              color: img.getColor(255, 255, 255),
            );
            img.drawImage(
              combinedImage,
              chefImage,
              dstX: startX + qrWidth + gap,
              dstY: chefY,
            );

            printer.image(combinedImage, align: PosAlign.center);
          } else {
            printer.image(qrImage, align: PosAlign.center);
          }
        } catch (e) {
          debugPrint("Error generating auto-bill QR: $e");
          printer.qrcode(
            billingUrl,
            align: PosAlign.center,
            size: QRSize.Size6,
          );
        }
        printer.feed(1);
      }

      printer.text(
        'Thank you! Visit Again',
        styles: const PosStyles(align: PosAlign.center),
      );
      printer.cut();
      await printer.disconnectAndPrint();
      debugPrint(
        '🧾 Auto receipt printed on ${target?.printerIp ?? 'Bluetooth'} for ${_tableDisplayLabel(bill)}',
      );
      return const AutoSyncAlert(
        message: 'Bill printed successfully',
        isSuccess: true,
      );
    } catch (error) {
      debugPrint('🧾 Auto receipt print error: $error');
      try {
        await printer?.disconnectAndPrint();
      } catch (_) {}
      return const AutoSyncAlert(
        message: 'Bill saved, but receipt not printed. Check printer.',
        isSuccess: false,
      );
    }
  }

  static _ReceiptPrinterTarget? _resolveReceiptPrinterTarget(
    _KotPrintConfig? config,
  ) {
    if (config == null) {
      return null;
    }

    final billingPrinterIp = config.receiptPrinterIp.trim();
    if (billingPrinterIp.isNotEmpty) {
      return _ReceiptPrinterTarget(
        printerIp: billingPrinterIp,
        printerPort: config.receiptPrinterPort,
        printerProtocol: config.receiptPrinterProtocol,
      );
    }

    for (final rawPrinter in config.kotPrinters) {
      final ip = _extractPrinterIp(rawPrinter);
      if (ip == null || ip.isEmpty) continue;
      return _ReceiptPrinterTarget(
        printerIp: ip,
        printerPort: _extractPrinterPort(rawPrinter),
        printerProtocol: 'esc_pos',
      );
    }

    return null;
  }

  static List<_PrintableKotItem> _extractPrintableItems(
    String billId,
    dynamic rawItems, {
    required Map<String, double> rememberedQuantities,
  }) {
    if (rawItems is! List || rawItems.isEmpty) {
      return const <_PrintableKotItem>[];
    }

    final items = <_PrintableKotItem>[];
    for (final rawItem in rawItems) {
      if (rawItem is! Map) continue;
      final item = Map<String, dynamic>.from(rawItem);
      final status = _toText(item['status']).toLowerCase();
      if (status == 'cancelled') continue;

      final name = _toText(item['name']);
      if (name.isEmpty) continue;
      final currentQuantity = _toSafeDouble(item['quantity']);
      if (currentQuantity <= 0) continue;
      final trackingKey = _itemTrackingKey(billId, item);
      if (trackingKey.isEmpty) continue;
      final rememberedQuantity = rememberedQuantities[trackingKey] ?? 0.0;
      final quantityToPrint = rememberedQuantity <= 0
          ? currentQuantity
          : (currentQuantity - rememberedQuantity);
      if (quantityToPrint <= 0) continue;

      items.add(
        _PrintableKotItem(
          trackingKey: trackingKey,
          name: name,
          quantity: quantityToPrint,
          currentQuantity: currentQuantity,
          specialNote: _toText(item['specialNote']).isNotEmpty
              ? _toText(item['specialNote'])
              : _toText(item['notes']),
          categoryId: _extractCategoryId(item),
          isOfferFreeItem: item['isOfferFreeItem'] == true,
        ),
      );
    }

    return items;
  }

  static Future<Map<String, double>> _printBillItems({
    required _KotPrintConfig config,
    required Map<String, dynamic> bill,
    required List<_PrintableKotItem> items,
  }) async {
    if (items.isEmpty || config.kotPrinters.isEmpty) {
      return const <String, double>{};
    }

    final printerPortsByIp = <String, int>{};
    final kitchenToPrinterMap = <String, String>{};

    for (final printerConfig in config.kotPrinters) {
      final ip = _extractPrinterIp(printerConfig);
      if (ip == null || ip.isEmpty) continue;

      printerPortsByIp[ip] = _extractPrinterPort(printerConfig);
      if (printerConfig is! Map) continue;

      final map = Map<String, dynamic>.from(printerConfig);
      final kitchens = map['kitchens'];
      if (kitchens is! List) continue;

      for (final rawKitchen in kitchens) {
        final kitchenId = _relationId(rawKitchen);
        if (kitchenId.isEmpty) continue;
        kitchenToPrinterMap[kitchenId] = ip;
      }
    }

    if (printerPortsByIp.isEmpty) {
      return const <String, double>{};
    }

    final groupedItems = <String, List<_PrintableKotItem>>{};
    final fallbackPrinterIp = printerPortsByIp.keys.first;

    for (final item in items) {
      final kitchenId = config.categoryToKitchenMap[item.categoryId ?? ''];
      final printerIp = kitchenId == null || kitchenId.isEmpty
          ? fallbackPrinterIp
          : (kitchenToPrinterMap[kitchenId] ?? fallbackPrinterIp);
      groupedItems
          .putIfAbsent(printerIp, () => <_PrintableKotItem>[])
          .add(item);
    }

    final acknowledged = <String, double>{};
    for (final entry in groupedItems.entries) {
      final success = await _printKOTReceipt(
        items: entry.value,
        printerIp: entry.key,
        printerPort: printerPortsByIp[entry.key] ?? 9100,
        bill: bill,
        branchName: config.branchName,
      );
      if (success) {
        for (final item in entry.value) {
          acknowledged[item.trackingKey] = item.currentQuantity;
        }
      }
    }

    return acknowledged;
  }

  static Future<bool> _printKOTReceipt({
    required List<_PrintableKotItem> items,
    required String printerIp,
    required int printerPort,
    required Map<String, dynamic> bill,
    required String branchName,
  }) async {
    if (items.isEmpty) return true;

    final prefs = await SharedPreferences.getInstance();
    var waiterName = prefs.getString('user_name')?.trim() ?? '';
    final token = prefs.getString('token')?.trim() ?? '';

    if (waiterName.isEmpty && token.isNotEmpty) {
      try {
        final meResponse = await http.get(
          Uri.parse('$_apiBase/users/me'),
          headers: {'Authorization': 'Bearer $token'},
        );
        if (meResponse.statusCode == 200) {
          final payload = jsonDecode(meResponse.body);
          if (payload is Map<String, dynamic>) {
            final user = payload['user'];
            if (user is Map<String, dynamic>) {
              waiterName = _toText(user['name']).isNotEmpty
                  ? _toText(user['name'])
                  : _toText(user['username']);
            }
          }
        }
      } catch (_) {}
    }

    // For QR/website-origin orders, display customer name when present.
    final billCustDetails = bill['customerDetails'];
    if (_isQrOrWebsiteOrder(bill) &&
        billCustDetails is Map &&
        billCustDetails['name'] != null &&
        billCustDetails['name'].toString().trim().isNotEmpty) {
      waiterName = billCustDetails['name'].toString().trim();
    }

    const paper = PaperSize.mm80;
    final profile = await CapabilityProfile.load();
    final prefsPort = int.tryParse(
      (prefs.getString('printerPort') ?? '').trim(),
    );
    final candidatePorts = <int>{
      printerPort,
      if (prefsPort != null) prefsPort,
      9100,
      9101,
    }.toList(growable: false);

    final printer = await UnifiedPrinter.connect(
      printerIp: printerIp,
      candidatePorts: candidatePorts,
      paperSize: paper,
      profile: profile,
      jobType: PrintJobType.kot,
    );

    if (printer == null) {
      debugPrint(
        '🖨️ Auto KOT printer connect failed for $printerIp:${candidatePorts.join(",")}',
      );
      return false;
    }

    final invoiceNumber = _toText(bill['invoiceNumber']).isNotEmpty
        ? _toText(bill['invoiceNumber'])
        : _toText(bill['id']);
    var kotNumber = invoiceNumber;
    if (invoiceNumber.contains('-')) {
      kotNumber = invoiceNumber.split('-').last.replaceAll('KOT', '');
    }

    final tableDetails = bill['tableDetails'] is Map
        ? Map<String, dynamic>.from(bill['tableDetails'])
        : const <String, dynamic>{};
    final tableNumber = _toText(tableDetails['tableNumber']);
    final displayTable = tableNumber.isEmpty
        ? 'TABLE-N/A'
        : 'TABLE-${tableNumber.padLeft(2, '0')}';
    final timeStr = DateFormat('yyyy-MM-dd hh:mm a').format(DateTime.now());

    if (branchName.trim().isNotEmpty) {
      printer.text(
        branchName.trim().toUpperCase(),
        styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size1,
          width: PosTextSize.size1,
        ),
      );
    }

    printer.row([
      PosColumn(
        text: 'KOT NO: $kotNumber',
        width: 7,
        styles: const PosStyles(
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      ),
      PosColumn(
        text: displayTable,
        width: 5,
        styles: const PosStyles(
          align: PosAlign.right,
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      ),
    ]);
    printer.hr(ch: '=');
    printer.row([
      PosColumn(
        text: 'Ordered by: ${waiterName.trim()}',
        width: 6,
        styles: const PosStyles(bold: true, align: PosAlign.left),
      ),
      PosColumn(
        text: timeStr,
        width: 6,
        styles: const PosStyles(align: PosAlign.right),
      ),
    ]);
    printer.hr(ch: '=');
    printer.row([
      PosColumn(text: 'ITEM', width: 10, styles: const PosStyles(bold: true)),
      PosColumn(
        text: 'QTY',
        width: 2,
        styles: const PosStyles(bold: true, align: PosAlign.right),
      ),
    ]);
    printer.hr(ch: '-');

    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      final qtyText = item.quantity % 1 == 0
          ? item.quantity.toStringAsFixed(0)
          : item.quantity.toStringAsFixed(2);

      printer.row([
        PosColumn(
          text:
              '${index + 1}. ${item.name.toUpperCase()}${item.isOfferFreeItem ? " (FREE)" : ""}',
          width: 10,
          styles: const PosStyles(
            bold: true,
            fontType: PosFontType.fontA,
            height: PosTextSize.size1,
            width: PosTextSize.size1,
          ),
        ),
        PosColumn(
          text: qtyText,
          width: 2,
          styles: const PosStyles(bold: true, align: PosAlign.right),
        ),
      ]);

      if ((item.specialNote ?? '').trim().isNotEmpty) {
        printer.text(
          '   Note - ${item.specialNote!.trim()}',
          styles: const PosStyles(align: PosAlign.left),
        );
      }

      printer.feed(1);
    }

    printer.hr(ch: '=');
    final notes = _toText(bill['notes']);
    if (notes.isNotEmpty) {
      printer.text('NOTES: $notes', styles: const PosStyles(bold: true));
      printer.hr(ch: '=');
    }

    final customerDetails = bill['customerDetails'] is Map
        ? Map<String, dynamic>.from(bill['customerDetails'])
        : const <String, dynamic>{};
    final customerName = _toText(customerDetails['name']);
    final customerPhone = _toText(customerDetails['phone']) != ''
        ? _toText(customerDetails['phone'])
        : _toText(customerDetails['phoneNumber']);
    if (customerName.isNotEmpty || customerPhone.isNotEmpty) {
      printer.text('Customer: $customerName');
      printer.text('Phone: $customerPhone');
    }

    printer.feed(2);
    printer.cut();
    await printer.disconnectAndPrint();
    debugPrint('🖨️ Auto KOT printed on $printerIp');
    return true;
  }

  static Map<String, double> _loadRememberedQuantities(String? rawValue) {
    if (rawValue == null || rawValue.trim().isEmpty) {
      return <String, double>{};
    }
    try {
      final decoded = jsonDecode(rawValue);
      if (decoded is! Map) {
        return <String, double>{};
      }
      final remembered = <String, double>{};
      for (final entry in decoded.entries) {
        final key = _toText(entry.key);
        if (key.isEmpty) continue;
        remembered[key] = _toSafeDouble(entry.value);
      }
      return remembered;
    } catch (_) {
      return <String, double>{};
    }
  }

  static Future<void> _persistRememberedQuantities({
    required SharedPreferences prefs,
    required String key,
    required Map<String, double> quantities,
  }) async {
    final orderedEntries = quantities.entries.toList(growable: true);
    if (orderedEntries.length > _maxRememberedItems) {
      orderedEntries.removeRange(
        0,
        orderedEntries.length - _maxRememberedItems,
      );
    }
    await prefs.setString(
      key,
      jsonEncode({for (final entry in orderedEntries) entry.key: entry.value}),
    );
  }

  static Future<void> _persistRememberedIds({
    required SharedPreferences prefs,
    required String key,
    required Set<String> ids,
  }) async {
    final ordered = ids.toList(growable: false);
    final trimmed = ordered.length > _maxRememberedItems
        ? ordered.sublist(ordered.length - _maxRememberedItems)
        : ordered;
    await prefs.setStringList(key, trimmed);
  }

  static String _itemTrackingKey(String billId, Map<String, dynamic> item) {
    final itemId = _toText(item['id']);
    if (itemId.isNotEmpty) {
      return '$billId::$itemId';
    }

    final name = _toText(item['name']);
    final extractedCategoryId = _extractCategoryId(item);
    final categoryId = extractedCategoryId.isNotEmpty
        ? extractedCategoryId
        : 'uncategorized';
    final price = _toSafeDouble(item['price']).toStringAsFixed(2);
    return '$billId::$name::$categoryId::$price';
  }

  static String? _extractPrinterIp(dynamic rawConfig) {
    if (rawConfig is! Map) return null;
    final config = Map<String, dynamic>.from(rawConfig);
    final nestedPrinter = config['printer'] is Map
        ? Map<String, dynamic>.from(config['printer'])
        : null;
    final candidates = <dynamic>[
      config['printerIp'],
      config['ipAddress'],
      config['ip'],
      config['host'],
      nestedPrinter?['printerIp'],
      nestedPrinter?['ipAddress'],
      nestedPrinter?['ip'],
      nestedPrinter?['host'],
    ];

    for (final candidate in candidates) {
      final ip = _toText(candidate);
      if (ip.isNotEmpty) return ip;
    }
    return null;
  }

  static int _extractPrinterPort(dynamic rawConfig, {int defaultPort = 9100}) {
    if (rawConfig is! Map) return defaultPort;
    final config = Map<String, dynamic>.from(rawConfig);
    final nestedPrinter = config['printer'] is Map
        ? Map<String, dynamic>.from(config['printer'])
        : null;
    final candidates = <dynamic>[
      config['printerPort'],
      config['port'],
      nestedPrinter?['printerPort'],
      nestedPrinter?['port'],
    ];

    for (final candidate in candidates) {
      if (candidate is num) return candidate.toInt();
      if (candidate is String) {
        final parsed = int.tryParse(candidate.trim());
        if (parsed != null) return parsed;
      }
    }
    return defaultPort;
  }

  static String _extractCategoryId(Map<String, dynamic> item) {
    final directCategoryId = _relationId(item['category']);
    if (directCategoryId.isNotEmpty) {
      return directCategoryId;
    }

    final product = item['product'];
    if (product is Map<String, dynamic>) {
      return _relationId(product['category']);
    }
    if (product is Map) {
      return _relationId(Map<String, dynamic>.from(product)['category']);
    }
    return '';
  }

  static String _relationId(dynamic value) {
    if (value == null) return '';
    if (value is String) return value.trim();
    if (value is num) return value.toString();
    if (value is Map) {
      final map = Map<String, dynamic>.from(value);
      return _toText(map['id']).isNotEmpty
          ? _toText(map['id'])
          : (_toText(map['_id']).isNotEmpty
                ? _toText(map['_id'])
                : _toText(map[r'$oid']));
    }
    return '';
  }

  static double _toSafeDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim()) ?? 0.0;
    return 0.0;
  }

  static String _toText(dynamic value) {
    return value?.toString().trim() ?? '';
  }

  static DateTime? _parseBillDateTime(dynamic value) {
    final raw = _toText(value);
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  static double _resolveReceiptUnitPrice(Map<String, dynamic> item) {
    final candidates = <dynamic>[
      item['effectiveUnitPrice'],
      item['unitPrice'],
      item['price'],
    ];
    for (final candidate in candidates) {
      final value = _toSafeDouble(candidate);
      if (value > 0) return value;
    }
    return 0.0;
  }

  static double _resolveReceiptLineAmount(
    Map<String, dynamic> item,
    double unitPrice,
    double quantity,
  ) {
    final candidates = <dynamic>[
      item['lineTotal'],
      item['totalPrice'],
      item['amount'],
      item['total'],
    ];
    for (final candidate in candidates) {
      final value = _toSafeDouble(candidate);
      if (value > 0) return value;
    }
    return unitPrice * quantity;
  }

  static String _tableDisplayLabel(Map<String, dynamic> bill) {
    final tableDetails = bill['tableDetails'] is Map
        ? Map<String, dynamic>.from(bill['tableDetails'])
        : const <String, dynamic>{};
    final tableNumber = _toText(tableDetails['tableNumber']);
    final section = _toText(tableDetails['section']);
    if (tableNumber.isEmpty && section.isEmpty) {
      return 'the table';
    }
    if (tableNumber.isEmpty) {
      return section;
    }
    if (section.isEmpty) {
      return 'Table $tableNumber';
    }
    return 'Table $tableNumber ($section)';
  }

  static bool _isQrOrWebsiteOrder(Map<String, dynamic> rawBill) {
    Map<String, dynamic> asMap(dynamic value) => value is Map
        ? Map<String, dynamic>.from(value)
        : const <String, dynamic>{};

    bool isTruthy(dynamic value) {
      if (value is bool) return value;
      final normalized = value?.toString().trim().toLowerCase() ?? '';
      return normalized == 'true' || normalized == '1' || normalized == 'yes';
    }

    bool hasSourceHint(dynamic value) {
      final normalized = value?.toString().trim().toLowerCase() ?? '';
      if (normalized.isEmpty) return false;
      return normalized.contains('qr') ||
          normalized.contains('website') ||
          normalized.contains('web') ||
          normalized.contains('online');
    }

    bool containsQrHints(Map<String, dynamic> bill) {
      const boolKeys = <String>[
        'isQrOrder',
        'isQRorder',
        'isQR',
        'qrOrder',
        'isWebsiteOrder',
        'websiteOrder',
        'isWebOrder',
        'isOnlineOrder',
      ];
      const sourceKeys = <String>[
        'source',
        'orderSource',
        'sourceType',
        'orderChannel',
        'channel',
        'origin',
        'platform',
        'placedVia',
        'createdFrom',
        'mode',
      ];

      for (final key in boolKeys) {
        if (bill.containsKey(key) && isTruthy(bill[key])) {
          return true;
        }
      }
      for (final key in sourceKeys) {
        if (bill.containsKey(key) && hasSourceHint(bill[key])) {
          return true;
        }
      }
      return false;
    }

    if (containsQrHints(rawBill)) return true;

    final doc = asMap(rawBill['doc']);
    if (containsQrHints(doc)) return true;

    return false;
  }

  static String _printedStateKey(String userId, String branchId) =>
      'auto_kot_printed_state_v2_${userId}_$branchId';

  static String _seededKey(String userId, String branchId) =>
      'auto_kot_seeded_v2_${userId}_$branchId';

  static String _completedBillAlertsKey(String userId, String branchId) =>
      'auto_kot_completed_bill_alerts_v1_${userId}_$branchId';

  static String _completedBillAlertsSeededKey(String userId, String branchId) =>
      'auto_kot_completed_bill_alerts_seeded_v1_${userId}_$branchId';

  static String _waiterCallHandledKey(String branchId) =>
      'auto_waiter_call_handled_v1_$branchId';

  static String _waiterCallPresentedKey(String branchId) =>
      'auto_waiter_call_presented_v1_$branchId';

  static String _waiterCallAlertsSeededKey(String branchId) =>
      'auto_waiter_call_alerts_seeded_v1_$branchId';
}

enum AutoSyncAlertType { general, waiterCall }

class AutoSyncAlert {
  const AutoSyncAlert({
    required this.message,
    required this.isSuccess,
    this.type = AutoSyncAlertType.general,
    this.waiterCall,
  });

  AutoSyncAlert.waiterCall(WaiterCallAlertPayload payload)
    : this(
        message:
            'Table ${payload.tableNumber} Customer: ${payload.customerName} Calling',
        isSuccess: false,
        type: AutoSyncAlertType.waiterCall,
        waiterCall: payload,
      );

  final String message;
  final bool isSuccess;
  final AutoSyncAlertType type;
  final WaiterCallAlertPayload? waiterCall;

  bool get isWaiterCall =>
      type == AutoSyncAlertType.waiterCall && waiterCall != null;
}

class WaiterCallAlertPayload {
  const WaiterCallAlertPayload({
    required this.eventKey,
    required this.billId,
    required this.timestampIso,
    required this.tableNumber,
    required this.section,
    required this.customerName,
    required this.kotNumber,
    this.callerRole,
    this.targetWaiterId,
  });

  final String eventKey;
  final String billId;
  final String timestampIso;
  final String tableNumber;
  final String section;
  final String customerName;
  final String kotNumber;
  final String? callerRole;
  final String? targetWaiterId;
}

class _KotPrintConfig {
  const _KotPrintConfig({
    required this.branchName,
    required this.companyName,
    required this.branchGst,
    required this.branchMobile,
    required this.receiptPrinterIp,
    required this.receiptPrinterPort,
    required this.receiptPrinterProtocol,
    required this.kotPrinters,
    required this.categoryToKitchenMap,
  });

  final String branchName;
  final String companyName;
  final String branchGst;
  final String branchMobile;
  final String receiptPrinterIp;
  final int receiptPrinterPort;
  final String receiptPrinterProtocol;
  final List<dynamic> kotPrinters;
  final Map<String, String> categoryToKitchenMap;
}

class _ReceiptPrinterTarget {
  const _ReceiptPrinterTarget({
    required this.printerIp,
    required this.printerPort,
    required this.printerProtocol,
  });

  final String printerIp;
  final int printerPort;
  final String printerProtocol;
}

class _PrintableKotItem {
  const _PrintableKotItem({
    required this.trackingKey,
    required this.name,
    required this.quantity,
    required this.currentQuantity,
    required this.specialNote,
    required this.categoryId,
    required this.isOfferFreeItem,
  });

  final String trackingKey;
  final String name;
  final double quantity;
  final double currentQuantity;
  final String? specialNote;
  final String? categoryId;
  final bool isOfferFreeItem;
}
