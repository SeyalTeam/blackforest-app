import 'dart:convert';

import 'package:blackforest_app/waiter_call_range_filter_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  final String? acknowledgedBy;
  final String? acknowledgedAtIso;

  bool get isAccepted => status.toLowerCase() == 'accepted';
  bool get isDeclined => status.toLowerCase() == 'declined';
  bool get isMissed => status.toLowerCase() == 'missed';

  DateTime? get callTime => DateTime.tryParse(callTimestampIso)?.toLocal();
  DateTime? get createdAt => DateTime.tryParse(createdAtIso)?.toLocal();
  DateTime? get acknowledgedAt => acknowledgedAtIso == null
      ? null
      : DateTime.tryParse(acknowledgedAtIso!)?.toLocal();

  WaiterCallHistoryEntry copyWith({
    String? eventKey,
    String? billId,
    String? tableNumber,
    String? section,
    String? customerName,
    String? callTimestampIso,
    String? status,
    String? createdAtIso,
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
    final acknowledgedBy = text(raw['acknowledgedBy']);
    final acknowledgedAtIso = text(raw['acknowledgedAtIso']);

    if (eventKey.isEmpty ||
        billId.isEmpty ||
        tableNumber.isEmpty ||
        callTimestampIso.isEmpty ||
        createdAtIso.isEmpty) {
      return null;
    }

    return WaiterCallHistoryEntry(
      eventKey: eventKey,
      billId: billId,
      tableNumber: tableNumber,
      section: section,
      customerName: customerName,
      callTimestampIso: callTimestampIso,
      status: status,
      createdAtIso: createdAtIso,
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
  static const int _maxEntries = 250;

  static String? _resolveStorageKey(SharedPreferences prefs) {
    final branchId = prefs.getString('branchId')?.trim() ?? '';
    if (branchId.isEmpty) return null;

    final userKey = WaiterCallRangeFilterService.resolveUserKeyFromPrefs(prefs);
    if (userKey.trim().isEmpty) return null;
    return '${_prefPrefix}_${userKey}_$branchId';
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
    if (key == null) return <WaiterCallHistoryEntry>[];
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
    if (key == null) return;

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
        ),
      );
    }

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
    if (key == null) return;

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
    if (key == null) return;

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
