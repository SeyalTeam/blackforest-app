import 'dart:async';
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

  static Future<List<WaiterCallHistoryEntry>> readHistory({bool syncRemote = true}) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _resolveStorageKey(prefs);
    final cached = _readEntriesFromPrefs(prefs, key);
    if (syncRemote) {
      unawaited(syncHistoryFromBackend());
    }
    return cached;
  }

  /// Syncs permanent call history (both Table Calls and Voice Calls) from MongoDB backend.
  /// Merges remote docs with local cache so history is NEVER lost upon app reinstallation.
  static Future<List<WaiterCallHistoryEntry>> syncHistoryFromBackend() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _resolveStorageKey(prefs);
      final token = prefs.getString('token')?.trim();
      final branchId = prefs.getString('branchId')?.trim() ?? '';
      final myUserId = (prefs.getString('user_id') ?? prefs.getString('userId'))?.trim() ?? '';

      final localEntries = _readEntriesFromPrefs(prefs, key).toList(growable: true);
      final Map<String, WaiterCallHistoryEntry> merged = {
        for (final e in localEntries) e.eventKey: e,
      };

      // 1. Fetch Table Calls from /api/waiter-calls
      try {
        final queryParams = <String>[
          'limit=300',
          'sort=-createdAt',
          'depth=1',
        ];
        if (branchId.isNotEmpty) {
          queryParams.add('where[branch][equals]=$branchId');
        }
        final uri = Uri.parse('${ApiConfig.baseUrl}/waiter-calls?${queryParams.join('&')}');
        final res = await http
            .get(uri, headers: ApiConfig.getHeaders(token))
            .timeout(const Duration(seconds: 6));

        if (res.statusCode == 200) {
          final decoded = jsonDecode(utf8.decode(res.bodyBytes));
          final docs = (decoded is Map ? decoded['docs'] : null) as List? ?? [];
          for (final item in docs) {
            if (item is! Map) continue;
            final doc = Map<String, dynamic>.from(item);
            final id = (doc['id'] ?? doc['_id'])?.toString().trim() ?? '';
            if (id.isEmpty) continue;

            final billing = doc['billing'];
            final billId = billing is Map
                ? (billing['id'] ?? billing['_id'])?.toString() ?? ''
                : billing?.toString() ?? '';

            String customerName = 'Guest';
            if (billing is Map) {
              final cust = billing['customer'];
              final custName = cust is Map ? cust['name']?.toString() : null;
              if (custName != null && custName.trim().isNotEmpty) {
                customerName = custName.trim();
              } else if (billing['customerName']?.toString().trim().isNotEmpty == true) {
                customerName = billing['customerName'].toString().trim();
              }
            }

            final rawStatus = (doc['status']?.toString() ?? '').toLowerCase();
            final status = (rawStatus == 'acknowledged' || rawStatus == 'resolved')
                ? 'accepted'
                : (rawStatus == 'declined' ? 'declined' : 'missed');

            final assigned = doc['assignedWaiter'];
            final ackBy = assigned is Map
                ? assigned['name']?.toString().trim()
                : (assigned is String && assigned.isNotEmpty ? assigned : null);

            final callTimestamp = doc['callTimestamp']?.toString() ??
                doc['createdAt']?.toString() ??
                DateTime.now().toIso8601String();
            final createdAt = doc['createdAt']?.toString() ?? callTimestamp;
            final updatedAt = doc['updatedAt']?.toString();

            final entry = WaiterCallHistoryEntry(
              eventKey: id,
              billId: billId,
              tableNumber: doc['tableNumber']?.toString() ?? '-',
              section: doc['section']?.toString() ?? '',
              customerName: customerName,
              callTimestampIso: callTimestamp,
              status: status,
              createdAtIso: createdAt,
              callType: 'table',
              durationSeconds: 0,
              acknowledgedBy: ackBy,
              acknowledgedAtIso: (status == 'accepted') ? updatedAt : null,
            );

            if (merged.containsKey(id)) {
              final existing = merged[id]!;
              merged[id] = existing.copyWith(
                billId: billId.isNotEmpty ? billId : existing.billId,
                tableNumber: entry.tableNumber.isNotEmpty ? entry.tableNumber : existing.tableNumber,
                section: entry.section.isNotEmpty ? entry.section : existing.section,
                customerName: customerName != 'Guest' ? customerName : existing.customerName,
                status: existing.isAccepted ? 'accepted' : status,
                acknowledgedBy: ackBy ?? existing.acknowledgedBy,
                acknowledgedAtIso: updatedAt ?? existing.acknowledgedAtIso,
              );
            } else {
              merged[id] = entry;
            }
          }
        }
      } catch (e) {
        debugPrint('WaiterCallHistoryService: error fetching table calls: $e');
      }

      // 2. Fetch Live Voice Calls from /api/call-logs
      try {
        final uri = Uri.parse('${ApiConfig.baseUrl}/call-logs?limit=300&sort=-createdAt&depth=0');
        final res = await http
            .get(uri, headers: ApiConfig.getHeaders(token))
            .timeout(const Duration(seconds: 6));

        if (res.statusCode == 200) {
          final decoded = jsonDecode(utf8.decode(res.bodyBytes));
          final docs = (decoded is Map ? decoded['docs'] : null) as List? ?? [];
          for (final item in docs) {
            if (item is! Map) continue;
            final doc = Map<String, dynamic>.from(item);
            final callId = (doc['callId'] ?? doc['id'] ?? doc['_id'])?.toString().trim() ?? '';
            if (callId.isEmpty) continue;

            final callerId = doc['callerUserId']?.toString() ??
                (doc['callerUser'] is Map
                    ? doc['callerUser']['id']?.toString()
                    : doc['callerUser']?.toString()) ??
                '';
            final receiverId = doc['receiverUserId']?.toString() ??
                (doc['receiverUser'] is Map
                    ? doc['receiverUser']['id']?.toString()
                    : doc['receiverUser']?.toString()) ??
                '';

            // If current user ID is known, filter to relevant calls
            if (myUserId.isNotEmpty && callerId.isNotEmpty && receiverId.isNotEmpty) {
              if (callerId != myUserId && receiverId != myUserId) {
                continue;
              }
            }

            final isCaller = (myUserId.isNotEmpty && callerId == myUserId);
            final otherUserId = isCaller ? receiverId : callerId;
            final displayName = isCaller
                ? (doc['receiverName']?.toString().trim().isNotEmpty == true
                    ? doc['receiverName'].toString().trim()
                    : 'Staff')
                : (doc['callerName']?.toString().trim().isNotEmpty == true
                    ? doc['callerName'].toString().trim()
                    : 'Super Admin');
            final role = isCaller
                ? (doc['receiverRole']?.toString() ?? 'Staff')
                : (doc['callerRole']?.toString() ?? 'Super Admin');

            final rawStatus = (doc['status']?.toString() ?? '').toLowerCase();
            final status = (rawStatus == 'connected' || rawStatus == 'ended')
                ? 'accepted'
                : (rawStatus == 'declined' ? 'declined' : 'missed');

            final durationSec = (doc['durationSeconds'] as num?)?.toInt() ?? 0;
            final startedAt = doc['startedAt']?.toString() ??
                doc['createdAt']?.toString() ??
                DateTime.now().toIso8601String();
            final endedAt = doc['endedAt']?.toString() ?? doc['updatedAt']?.toString();

            final entry = WaiterCallHistoryEntry(
              eventKey: callId,
              billId: '',
              tableNumber: 'Admin Call',
              section: '',
              customerName: displayName,
              callTimestampIso: startedAt,
              status: status,
              createdAtIso: startedAt,
              callType: 'admin_call',
              durationSeconds: durationSec,
              callerRole: role,
              callerUserId: otherUserId.isNotEmpty ? otherUserId : null,
              acknowledgedBy: displayName,
              acknowledgedAtIso: endedAt,
            );

            if (merged.containsKey(callId)) {
              final existing = merged[callId]!;
              final bestDuration =
                  durationSec > existing.durationSeconds ? durationSec : existing.durationSeconds;
              merged[callId] = existing.copyWith(
                customerName: displayName.isNotEmpty ? displayName : existing.customerName,
                callerRole: role.isNotEmpty ? role : existing.callerRole,
                callerUserId: otherUserId.isNotEmpty ? otherUserId : existing.callerUserId,
                status: existing.isAccepted ? 'accepted' : status,
                durationSeconds: bestDuration,
                callType: 'admin_call',
                acknowledgedAtIso: endedAt ?? existing.acknowledgedAtIso,
              );
            } else {
              merged[callId] = entry;
            }

            // Cache last admin caller user id for callback (never cache own waiter ID)
            if (otherUserId.isNotEmpty &&
                otherUserId != myUserId &&
                (role.toLowerCase().contains('admin') ||
                    displayName.toLowerCase().contains('admin'))) {
              await prefs.setString('last_admin_caller_user_id', otherUserId);
              await prefs.setString('last_admin_caller_name', displayName);
            }
          }
        }
      } catch (e) {
        debugPrint('WaiterCallHistoryService: error fetching voice call logs: $e');
      }

      final result = merged.values.toList()..sort(_sortEntriesDescending);
      await _saveEntriesToPrefs(prefs: prefs, key: key, entries: result);
      return result;
    } catch (e) {
      debugPrint('WaiterCallHistoryService: syncHistoryFromBackend error: $e');
      final prefs = await SharedPreferences.getInstance();
      final key = _resolveStorageKey(prefs);
      return _readEntriesFromPrefs(prefs, key);
    }
  }

  /// Sends call log updates to MongoDB so backend stays synchronized.
  static Future<void> syncVoiceCallToBackend({
    required String callId,
    required String callerName,
    String? callerRole,
    String? callerUserId,
    String status = 'missed',
    int durationSeconds = 0,
    String? timestampIso,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token')?.trim();
      final myUserId = (prefs.getString('user_id') ?? prefs.getString('userId'))?.trim() ?? '';
      final myName = prefs.getString('user_name') ?? prefs.getString('name') ?? 'Staff';
      final myRole = prefs.getString('role') ?? 'waiter';

      final uri = Uri.parse('${ApiConfig.baseUrl}/call-logs');
      final payload = {
        'callId': callId,
        'callerUserId': callerUserId ?? myUserId,
        'callerName': callerName,
        'callerRole': callerRole ?? 'admin',
        'receiverUserId': myUserId,
        'receiverName': myName,
        'receiverRole': myRole,
        'status': status == 'accepted' ? 'connected' : status,
        'durationSeconds': durationSeconds,
        'startedAt': timestampIso ?? DateTime.now().toIso8601String(),
      };
      await http
          .post(
            uri,
            headers: ApiConfig.getHeaders(token),
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 4));
    } catch (_) {}
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

    final myUserId = (prefs.getString('user_id') ?? prefs.getString('userId'))?.trim() ?? '';

    if (callerUserId != null && callerUserId.trim().isNotEmpty && callerUserId.trim() != myUserId) {
      await prefs.setString('last_admin_caller_user_id', callerUserId.trim());
    }
    if (callerName.trim().isNotEmpty && !callerName.toLowerCase().contains('waiter')) {
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

    unawaited(
      syncVoiceCallToBackend(
        callId: callId,
        callerName: normalizedCaller,
        callerRole: callerRole,
        callerUserId: callerUserId,
        status: status,
        durationSeconds: durationSeconds,
        timestampIso: timestamp,
      ),
    );
  }

  static Future<String?> getLastAdminUserId() async {
    final prefs = await SharedPreferences.getInstance();
    final myUserId = (prefs.getString('user_id') ?? prefs.getString('userId'))?.trim() ?? '';

    // If last_admin_caller_user_id was mistakenly set to myUserId, clear it
    final cachedId = prefs.getString('last_admin_caller_user_id')?.trim();
    if (cachedId != null && (cachedId == myUserId || cachedId.isEmpty)) {
      await prefs.remove('last_admin_caller_user_id');
    } else if (cachedId != null && cachedId.isNotEmpty) {
      return cachedId;
    }

    // 2. Check existing call history entries for any callerUserId != myUserId
    try {
      final entries = await readHistory(syncRemote: false);
      for (final e in entries) {
        final id = e.callerUserId?.trim();
        if (id != null && id.isNotEmpty && id != myUserId) {
          await prefs.setString('last_admin_caller_user_id', id);
          return id;
        }
      }
    } catch (_) {}

    // 3. Resolve Admin/Superadmin via API
    try {
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
            for (final d in docs) {
              if (d is! Map) continue;
              final adminId = (d['id'] ?? d['_id'])?.toString().trim();
              if (adminId != null && adminId.isNotEmpty && adminId != myUserId) {
                final adminName = (d['name'] ?? d['username'] ?? 'Super Admin').toString();
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
      final token = prefs.getString('token')?.trim();
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
                      if (sId != null && sId.isNotEmpty && sId != myUserId) {
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

    unawaited(
      syncVoiceCallToBackend(
        callId: callId,
        callerName: existing.customerName,
        callerRole: existing.callerRole,
        callerUserId: existing.callerUserId,
        status: status,
        durationSeconds: durationSeconds ?? existing.durationSeconds,
      ),
    );
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
