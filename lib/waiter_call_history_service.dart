import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_config.dart';
import 'waiter_call_range_filter_service.dart';

class WaiterCallHistoryEntry {
  const WaiterCallHistoryEntry({
    required this.eventKey,
    required this.billId,
    required this.tableNumber,
    required this.section,
    required this.customerName,
    required this.callTimestampIso,
    required this.status,
    required this.createdAtIso,
    this.callType = 'table', // 'table' | 'admin_call'
    this.durationSeconds = 0,
    this.callerRole,
    this.callerUserId,
    this.acknowledgedBy,
    this.acknowledgedAtIso,
  });

  final String eventKey;
  final String billId;
  final String tableNumber;
  final String section;
  final String customerName;
  final String callTimestampIso;
  final String status; // missed | declined | accepted
  final String createdAtIso;
  final String callType; // 'table' | 'admin_call'
  final int durationSeconds;
  final String? callerRole;
  final String? callerUserId;
  final String? acknowledgedBy;
  final String? acknowledgedAtIso;

  bool get isTableCall => callType == 'table';
  bool get isAdminCall => callType == 'admin_call' || callType == 'voice_call';

  bool get isAccepted => status.toLowerCase() == 'accepted';
  bool get isDeclined => status.toLowerCase() == 'declined';
  bool get isMissed => status.toLowerCase() == 'missed';

  DateTime? get callTime => DateTime.tryParse(callTimestampIso)?.toLocal();
  DateTime? get createdAt => DateTime.tryParse(createdAtIso)?.toLocal();
  DateTime? get acknowledgedAt => acknowledgedAtIso == null
      ? null
      : DateTime.tryParse(acknowledgedAtIso!)?.toLocal();

  String get formattedDuration {
    if (durationSeconds <= 0) return '';
    final minutes = (durationSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (durationSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  WaiterCallHistoryEntry copyWith({
    String? eventKey,
    String? billId,
    String? tableNumber,
    String? section,
    String? customerName,
    String? callTimestampIso,
    String? status,
    String? createdAtIso,
    String? callType,
    int? durationSeconds,
    String? callerRole,
    String? callerUserId,
    String? acknowledgedBy,
    String? acknowledgedAtIso,
  }) {
    return WaiterCallHistoryEntry(
      eventKey: eventKey ?? this.eventKey,
      billId: billId ?? this.billId,
      tableNumber: tableNumber ?? this.tableNumber,
      section: section ?? this.section,
      customerName: customerName ?? this.customerName,
      callTimestampIso: callTimestampIso ?? this.callTimestampIso,
      status: status ?? this.status,
      createdAtIso: createdAtIso ?? this.createdAtIso,
      callType: callType ?? this.callType,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      callerRole: callerRole ?? this.callerRole,
      callerUserId: callerUserId ?? this.callerUserId,
      acknowledgedBy: acknowledgedBy ?? this.acknowledgedBy,
      acknowledgedAtIso: acknowledgedAtIso ?? this.acknowledgedAtIso,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'eventKey': eventKey,
      'billId': billId,
      'tableNumber': tableNumber,
      'section': section,
      'customerName': customerName,
      'callTimestampIso': callTimestampIso,
      'status': status,
      'createdAtIso': createdAtIso,
      'callType': callType,
      'durationSeconds': durationSeconds,
      'callerRole': callerRole,
      'callerUserId': callerUserId,
      'acknowledgedBy': acknowledgedBy,
      'acknowledgedAtIso': acknowledgedAtIso,
    };
  }

  static WaiterCallHistoryEntry? fromJson(Map<String, dynamic> raw) {
    String text(dynamic value) => value?.toString().trim() ?? '';

    final eventKey = text(raw['eventKey']);
    final billId = text(raw['billId']);
    final tableNumber = text(raw['tableNumber']);
    final section = text(raw['section']);
    final customerName = text(raw['customerName']);
    final callTimestampIso = text(raw['callTimestampIso']);
    final status = _normalizeStatus(text(raw['status']));
    final createdAtIso = text(raw['createdAtIso']);
    final callType = text(raw['callType']).isEmpty ? 'table' : text(raw['callType']);
    final durationSeconds = (raw['durationSeconds'] as num?)?.toInt() ?? 0;
    final callerRole = text(raw['callerRole']);
    final callerUserId = text(raw['callerUserId']);
    final acknowledgedBy = text(raw['acknowledgedBy']);
    final acknowledgedAtIso = text(raw['acknowledgedAtIso']);

    if (eventKey.isEmpty || callTimestampIso.isEmpty) {
      return null;
    }

    return WaiterCallHistoryEntry(
      eventKey: eventKey,
      billId: billId,
      tableNumber: tableNumber.isEmpty ? (callType == 'admin_call' ? 'Live Call' : '-') : tableNumber,
      section: section,
      customerName: customerName.isEmpty ? (callType == 'admin_call' ? 'Super Admin' : 'Guest') : customerName,
      callTimestampIso: callTimestampIso,
      status: status,
      createdAtIso: createdAtIso.isEmpty ? callTimestampIso : createdAtIso,
      callType: callType,
      durationSeconds: durationSeconds,
      callerRole: callerRole.isEmpty ? null : callerRole,
      callerUserId: callerUserId.isEmpty ? null : callerUserId,
      acknowledgedBy: acknowledgedBy.isEmpty ? null : acknowledgedBy,
      acknowledgedAtIso: acknowledgedAtIso.isEmpty ? null : acknowledgedAtIso,
    );
  }

  static String _normalizeStatus(String rawStatus) {
    final normalized = rawStatus.trim().toLowerCase();
    if (normalized == 'accepted') return 'accepted';
    if (normalized == 'declined') return 'declined';
    return 'missed';
  }
}

class WaiterCallHistoryService {
  WaiterCallHistoryService._();

  static const String _prefPrefix = 'waiter_call_history_v1';
  static const int _maxEntries = 1000;

  static String _resolveStorageKey(SharedPreferences prefs) {
    final branchId = prefs.getString('branchId')?.trim() ?? '';
    final userKey = WaiterCallRangeFilterService.resolveUserKeyFromPrefs(prefs);
    if (branchId.isNotEmpty && userKey.trim().isNotEmpty) {
      return '${_prefPrefix}_${userKey}_$branchId';
    }
    if (branchId.isNotEmpty) {
      return '${_prefPrefix}_branch_$branchId';
    }
    return '${_prefPrefix}_global';
  }

  static List<WaiterCallHistoryEntry> _readEntriesFromPrefs(
    SharedPreferences prefs,
    String key,
  ) {
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) {
      return <WaiterCallHistoryEntry>[];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return <WaiterCallHistoryEntry>[];
      }
      final entries = <WaiterCallHistoryEntry>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final parsed = WaiterCallHistoryEntry.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (parsed == null) continue;
        entries.add(parsed);
      }
      entries.sort(_sortEntriesDescending);
      return entries;
    } catch (_) {
      return <WaiterCallHistoryEntry>[];
    }
  }

  static Future<void> _saveEntriesToPrefs({
    required SharedPreferences prefs,
    required String key,
    required List<WaiterCallHistoryEntry> entries,
  }) async {
    final sorted = List<WaiterCallHistoryEntry>.from(entries, growable: true)
      ..sort(_sortEntriesDescending);
    final trimmed = sorted.length > _maxEntries
        ? sorted.sublist(0, _maxEntries)
        : sorted;
    await prefs.setString(
      key,
      jsonEncode(
        trimmed.map((entry) => entry.toJson()).toList(growable: false),
      ),
    );
  }

  static int _sortEntriesDescending(
    WaiterCallHistoryEntry a,
    WaiterCallHistoryEntry b,
  ) {
    final aTime =
        a.callTime?.millisecondsSinceEpoch ??
        a.createdAt?.millisecondsSinceEpoch ??
        0;
    final bTime =
        b.callTime?.millisecondsSinceEpoch ??
        b.createdAt?.millisecondsSinceEpoch ??
        0;
    return bTime.compareTo(aTime);
  }

  static Future<List<WaiterCallHistoryEntry>> readHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final key = _resolveStorageKey(prefs);
    return _readEntriesFromPrefs(prefs, key);
  }

  static Future<void> recordIncomingCall({
    required String eventKey,
    required String billId,
    required String tableNumber,
    required String section,
    required String customerName,
    required String callTimestampIso,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _resolveStorageKey(prefs);

    final entries = _readEntriesFromPrefs(prefs, key).toList(growable: true);
    final index = entries.indexWhere((entry) => entry.eventKey == eventKey);
    final normalizedCustomer = customerName.trim().isEmpty
        ? 'Guest'
        : customerName.trim();

    if (index >= 0) {
      final existing = entries[index];
      entries[index] = existing.copyWith(
        billId: billId,
        tableNumber: tableNumber,
        section: section,
        customerName: normalizedCustomer,
        callTimestampIso: callTimestampIso,
        callType: 'table',
      );
    } else {
      entries.add(
        WaiterCallHistoryEntry(
          eventKey: eventKey,
          billId: billId,
          tableNumber: tableNumber,
          section: section,
          customerName: normalizedCustomer,
          callTimestampIso: callTimestampIso,
          status: 'missed',
          createdAtIso: DateTime.now().toIso8601String(),
          callType: 'table',
        ),
      );
    }

    await _saveEntriesToPrefs(prefs: prefs, key: key, entries: entries);
  }

  static Future<void> recordVoiceCall({
    required String callId,
    required String callerName,
    String? callerRole,
    String? callerUserId,
    String status = 'missed',
    int durationSeconds = 0,
    String? callTimestampIso,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _resolveStorageKey(prefs);

    if (callerUserId != null && callerUserId.trim().isNotEmpty) {
      await prefs.setString('last_admin_caller_user_id', callerUserId.trim());
    }
    if (callerName.trim().isNotEmpty) {
      await prefs.setString('last_admin_caller_name', callerName.trim());
    }

    final entries = _readEntriesFromPrefs(prefs, key).toList(growable: true);
    final index = entries.indexWhere((entry) => entry.eventKey == callId);
    final normalizedCaller = callerName.trim().isEmpty ? 'Super Admin' : callerName.trim();
    final timestamp = callTimestampIso ?? DateTime.now().toIso8601String();

    if (index >= 0) {
      entries[index] = entries[index].copyWith(
        customerName: normalizedCaller,
        callerRole: callerRole ?? 'Super Admin',
        callerUserId: callerUserId ?? entries[index].callerUserId,
        status: status,
        durationSeconds: durationSeconds,
        callType: 'admin_call',
      );
    } else {
      entries.insert(
        0,
        WaiterCallHistoryEntry(
          eventKey: callId,
          billId: '',
          tableNumber: 'Admin Call',
          section: '',
          customerName: normalizedCaller,
          callTimestampIso: timestamp,
          status: status,
          createdAtIso: timestamp,
          callType: 'admin_call',
          durationSeconds: durationSeconds,
          callerRole: callerRole ?? 'Super Admin',
          callerUserId: callerUserId,
        ),
      );
    }

    await _saveEntriesToPrefs(prefs: prefs, key: key, entries: entries);
  }

  static Future<String?> getLastAdminUserId() async {
    // 1. Check SharedPreferences cached last admin user id
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString('last_admin_caller_user_id')?.trim();
      if (id != null && id.isNotEmpty) return id;
    } catch (_) {}

    // 2. Check existing call history entries for any callerUserId
    try {
      final entries = await readHistory();
      for (final e in entries) {
        final id = e.callerUserId?.trim();
        if (id != null && id.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('last_admin_caller_user_id', id);
          return id;
        }
      }
    } catch (_) {}

    // 3. Resolve Admin/Superadmin via API
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token')?.trim();
      if (token != null && token.isNotEmpty) {
        final uri = Uri.parse(
          '${ApiConfig.baseUrl}/users?where[role][in]=superadmin,admin&limit=5&depth=0',
        );
        final res = await http.get(
          uri,
          headers: ApiConfig.getHeaders(token),
        ).timeout(const Duration(seconds: 4));

        if (res.statusCode == 200) {
          final decoded = jsonDecode(utf8.decode(res.bodyBytes));
          final docs = decoded['docs'] as List?;
          if (docs != null && docs.isNotEmpty) {
            dynamic selectedDoc = docs.firstWhere(
              (d) => d is Map && d['role'] == 'superadmin',
              orElse: () => docs.first,
            );
            if (selectedDoc is Map) {
              final adminId = (selectedDoc['id'] ?? selectedDoc['_id'])?.toString().trim();
              final adminName = (selectedDoc['name'] ?? selectedDoc['username'] ?? 'Super Admin').toString();
              if (adminId != null && adminId.isNotEmpty) {
                await prefs.setString('last_admin_caller_user_id', adminId);
                await prefs.setString('last_admin_caller_name', adminName);
                debugPrint('WaiterCallHistoryService: fetched admin user ID via API: $adminId ($adminName)');
                return adminId;
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('WaiterCallHistoryService: error fetching admin user from API: $e');
    }

    // 4. Fallback: Check message threads & messages
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token')?.trim();
      final myUserId = (prefs.getString('user_id') ?? prefs.getString('userId'))?.trim() ?? '';
      if (token != null && token.isNotEmpty) {
        final threadUrl = Uri.parse(
          '${ApiConfig.baseUrl}/message-threads?limit=1&depth=0${myUserId.isNotEmpty ? "&where[staffUser][equals]=$myUserId" : ""}',
        );
        final threadRes = await http.get(
          threadUrl,
          headers: ApiConfig.getHeaders(token),
        ).timeout(const Duration(seconds: 4));

        if (threadRes.statusCode == 200) {
          final decoded = jsonDecode(utf8.decode(threadRes.bodyBytes));
          final docs = decoded['docs'] as List?;
          if (docs != null && docs.isNotEmpty) {
            final threadId = (docs.first['id'] ?? docs.first['_id'])?.toString() ?? '';
            if (threadId.isNotEmpty) {
              final msgsRes = await http.get(
                Uri.parse('${ApiConfig.baseUrl}/messages?limit=10&depth=1&sort=-createdAt&where[thread][equals]=$threadId'),
                headers: ApiConfig.getHeaders(token),
              ).timeout(const Duration(seconds: 4));
              if (msgsRes.statusCode == 200) {
                final mDecoded = jsonDecode(utf8.decode(msgsRes.bodyBytes));
                final mDocs = mDecoded['docs'] as List?;
                if (mDocs != null) {
                  for (final m in mDocs) {
                    if (m is! Map) continue;
                    final role = m['senderRole']?.toString() ?? '';
                    if (role == 'admin' || role == 'superadmin') {
                      final sUser = m['senderUser'];
                      final sId = sUser is Map ? (sUser['id'] ?? sUser['_id'])?.toString() : sUser?.toString();
                      if (sId != null && sId.isNotEmpty) {
                        await prefs.setString('last_admin_caller_user_id', sId);
                        return sId;
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    } catch (_) {}

    return null;
  }

  static Future<void> updateVoiceCallStatus({
    required String callId,
    required String status,
    int? durationSeconds,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _resolveStorageKey(prefs);

    final entries = _readEntriesFromPrefs(prefs, key).toList(growable: true);
    final index = entries.indexWhere((entry) => entry.eventKey == callId);
    if (index < 0) return;

    final existing = entries[index];
    entries[index] = existing.copyWith(
      status: status,
      durationSeconds: durationSeconds ?? existing.durationSeconds,
      acknowledgedAtIso: DateTime.now().toIso8601String(),
    );

    await _saveEntriesToPrefs(prefs: prefs, key: key, entries: entries);
  }

  static Future<void> markAccepted({
    required String eventKey,
    required String acknowledgedBy,
    String? acknowledgedAtIso,
  }) async {
    final trimmedEventKey = eventKey.trim();
    if (trimmedEventKey.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final key = _resolveStorageKey(prefs);

    final entries = _readEntriesFromPrefs(prefs, key).toList(growable: true);
    final index = entries.indexWhere(
      (entry) => entry.eventKey == trimmedEventKey,
    );
    if (index < 0) {
      return;
    }
    final ackBy = acknowledgedBy.trim().isEmpty
        ? 'Staff'
        : acknowledgedBy.trim();
    entries[index] = entries[index].copyWith(
      status: 'accepted',
      acknowledgedBy: ackBy,
      acknowledgedAtIso: acknowledgedAtIso ?? DateTime.now().toIso8601String(),
    );
    await _saveEntriesToPrefs(prefs: prefs, key: key, entries: entries);
  }

  static Future<void> markDeclined({
    required String eventKey,
    String? acknowledgedAtIso,
  }) async {
    final trimmedEventKey = eventKey.trim();
    if (trimmedEventKey.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final key = _resolveStorageKey(prefs);

    final entries = _readEntriesFromPrefs(prefs, key).toList(growable: true);
    final index = entries.indexWhere(
      (entry) => entry.eventKey == trimmedEventKey,
    );
    if (index < 0) {
      return;
    }

    entries[index] = entries[index].copyWith(
      status: 'declined',
      acknowledgedBy: null,
      acknowledgedAtIso: acknowledgedAtIso ?? DateTime.now().toIso8601String(),
    );
    await _saveEntriesToPrefs(prefs: prefs, key: key, entries: entries);
  }

  static Future<int> countMissed() async {
    final entries = await readHistory();
    return entries.where((entry) => entry.isMissed).length;
  }
}
