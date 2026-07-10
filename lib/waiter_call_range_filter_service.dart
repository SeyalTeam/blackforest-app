import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class WaiterCallRangeSelection {
  const WaiterCallRangeSelection({
    required this.rowId,
    required this.section,
    required this.label,
    required this.tableRange,
    required this.startTable,
    required this.endTable,
  });

  final String rowId;
  final String section;
  final String label;
  final String tableRange;
  final int startTable;
  final int endTable;

  String get storageKey =>
      '${rowId.trim()}|${WaiterCallRangeFilterService.normalizeSection(section)}|$startTable|$endTable';

  bool contains({required String sectionName, required int tableNumber}) {
    if (tableNumber <= 0) return false;
    if (WaiterCallRangeFilterService.normalizeSection(sectionName) !=
        WaiterCallRangeFilterService.normalizeSection(section)) {
      return false;
    }
    return tableNumber >= startTable && tableNumber <= endTable;
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'rowId': rowId,
      'section': section,
      'label': label,
      'tableRange': tableRange,
      'startTable': startTable,
      'endTable': endTable,
    };
  }

  static WaiterCallRangeSelection? fromJson(Map<String, dynamic> raw) {
    final rowId = WaiterCallRangeFilterService.toText(raw['rowId']);
    final section = WaiterCallRangeFilterService.toText(raw['section']);
    final label = WaiterCallRangeFilterService.toText(raw['label']);
    final tableRange = WaiterCallRangeFilterService.toText(raw['tableRange']);
    final start = WaiterCallRangeFilterService.toPositiveInt(raw['startTable']);
    final end = WaiterCallRangeFilterService.toPositiveInt(raw['endTable']);
    if (rowId.isEmpty || section.isEmpty || start == null || end == null) {
      return null;
    }

    final normalizedStart = start <= end ? start : end;
    final normalizedEnd = start <= end ? end : start;
    return WaiterCallRangeSelection(
      rowId: rowId,
      section: section,
      label: label,
      tableRange: tableRange,
      startTable: normalizedStart,
      endTable: normalizedEnd,
    );
  }
}

class WaiterCallRangeFilterService {
  WaiterCallRangeFilterService._();

  static const String _prefKeyPrefix = 'waiter_call_table_ranges_v1';
  static const String _anonymousUserKey = 'anonymous_waiter';

  static String resolveUserKeyFromPrefs(SharedPreferences prefs) {
    final userId = prefs.getString('user_id')?.trim() ?? '';
    if (userId.isNotEmpty) return userId;

    final employeeId = prefs.getString('employee_id')?.trim() ?? '';
    if (employeeId.isNotEmpty) return employeeId;

    final email = prefs.getString('email')?.trim() ?? '';
    if (email.isNotEmpty) return email.toLowerCase();

    final userName = prefs.getString('user_name')?.trim() ?? '';
    if (userName.isNotEmpty) return userName.toLowerCase();

    return _anonymousUserKey;
  }

  static List<String> resolveCandidateUserKeysFromPrefs(
    SharedPreferences prefs,
  ) {
    final candidates = <String>[];

    void addCandidate(String value) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return;
      if (candidates.contains(trimmed)) return;
      candidates.add(trimmed);
    }

    addCandidate(resolveUserKeyFromPrefs(prefs));
    addCandidate(prefs.getString('user_id') ?? '');
    addCandidate(prefs.getString('employee_id') ?? '');
    addCandidate((prefs.getString('email') ?? '').toLowerCase());
    addCandidate((prefs.getString('user_name') ?? '').toLowerCase());
    addCandidate(_anonymousUserKey);

    return candidates;
  }

  static String prefKey({required String userId, required String branchId}) {
    final normalizedUserId = userId.trim();
    final normalizedBranchId = branchId.trim();
    return '${_prefKeyPrefix}_${normalizedUserId}_$normalizedBranchId';
  }

  static bool hasStoredSelections({
    required SharedPreferences prefs,
    required String userId,
    required String branchId,
  }) {
    if (userId.trim().isEmpty || branchId.trim().isEmpty) return false;
    return prefs.containsKey(prefKey(userId: userId, branchId: branchId));
  }

  static bool hasStoredSelectionsForAnyUser({
    required SharedPreferences prefs,
    required List<String> userKeys,
    required String branchId,
  }) {
    final normalizedBranchId = branchId.trim();
    if (normalizedBranchId.isEmpty) return false;
    for (final userKey in userKeys) {
      if (hasStoredSelections(
        prefs: prefs,
        userId: userKey,
        branchId: normalizedBranchId,
      )) {
        return true;
      }
    }
    return false;
  }

  static List<WaiterCallRangeSelection> readSelections({
    required SharedPreferences prefs,
    required String userId,
    required String branchId,
  }) {
    if (userId.trim().isEmpty || branchId.trim().isEmpty) {
      return const <WaiterCallRangeSelection>[];
    }

    final raw = prefs.getString(prefKey(userId: userId, branchId: branchId));
    if (raw == null || raw.trim().isEmpty) {
      return const <WaiterCallRangeSelection>[];
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const <WaiterCallRangeSelection>[];
      }
      final byKey = <String, WaiterCallRangeSelection>{};
      for (final item in decoded) {
        if (item is! Map) continue;
        final selection = WaiterCallRangeSelection.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (selection == null) continue;
        byKey[selection.storageKey] = selection;
      }
      return byKey.values.toList(growable: false);
    } catch (_) {
      return const <WaiterCallRangeSelection>[];
    }
  }

  static List<WaiterCallRangeSelection> readSelectionsForAnyUser({
    required SharedPreferences prefs,
    required List<String> userKeys,
    required String branchId,
  }) {
    final normalizedBranchId = branchId.trim();
    if (normalizedBranchId.isEmpty) {
      return const <WaiterCallRangeSelection>[];
    }

    final mergedByKey = <String, WaiterCallRangeSelection>{};
    var hadAnyStored = false;
    for (final userKey in userKeys) {
      if (!hasStoredSelections(
        prefs: prefs,
        userId: userKey,
        branchId: normalizedBranchId,
      )) {
        continue;
      }
      hadAnyStored = true;
      final selections = readSelections(
        prefs: prefs,
        userId: userKey,
        branchId: normalizedBranchId,
      );
      for (final selection in selections) {
        mergedByKey[selection.storageKey] = selection;
      }
    }

    if (!hadAnyStored) {
      return const <WaiterCallRangeSelection>[];
    }
    return mergedByKey.values.toList(growable: false);
  }

  static Future<void> saveSelections({
    required SharedPreferences prefs,
    required String userId,
    required String branchId,
    required List<WaiterCallRangeSelection> selections,
  }) async {
    if (userId.trim().isEmpty || branchId.trim().isEmpty) return;
    final key = prefKey(userId: userId, branchId: branchId);
    final encoded = jsonEncode(
      selections.map((selection) => selection.toJson()).toList(growable: false),
    );
    await prefs.setString(key, encoded);
  }

  static bool shouldNotifyForCall({
    required List<WaiterCallRangeSelection> selections,
    required String section,
    required String tableNumber,
  }) {
    if (selections.isEmpty) {
      // Strict row-based behavior: no configured rows means no waiter-call alerts.
      return false;
    }
    final parsedTable = parseTableToken(tableNumber);
    if (parsedTable == null || parsedTable <= 0) {
      return false;
    }
    for (final selection in selections) {
      if (selection.contains(sectionName: section, tableNumber: parsedTable)) {
        return true;
      }
    }
    return false;
  }

  static WaiterCallRangeSelection? selectionFromRangeRow({
    required String sectionName,
    required Map<String, dynamic> rangeRow,
  }) {
    final normalizedSection = sectionName.trim();
    if (normalizedSection.isEmpty) return null;

    final label = toText(rangeRow['label']);
    final tableRange = toText(rangeRow['tableRange']);
    if (tableRange.isEmpty) return null;

    final bounds = _parseTableRangeBounds(tableRange);
    if (bounds == null) return null;

    var rowId = toText(rangeRow['id']);
    if (rowId.isEmpty) {
      rowId = toText(rangeRow['_id']);
    }
    if (rowId.isEmpty) {
      rowId = toText(rangeRow[r'$oid']);
    }
    if (rowId.isEmpty) {
      rowId = '$normalizedSection|$label|$tableRange';
    }

    return WaiterCallRangeSelection(
      rowId: rowId,
      section: normalizedSection,
      label: label,
      tableRange: tableRange,
      startTable: bounds.start,
      endTable: bounds.end,
    );
  }

  static _TableRangeBounds? _parseTableRangeBounds(String rawRange) {
    final normalized = rawRange.trim();
    if (normalized.isEmpty) return null;

    final hyphenMatch = RegExp(r'(\d+)\s*[-–—]\s*(\d+)').firstMatch(normalized);
    if (hyphenMatch != null) {
      final left = int.tryParse(toText(hyphenMatch.group(1)));
      final right = int.tryParse(toText(hyphenMatch.group(2)));
      if (left != null && right != null && left > 0 && right > 0) {
        final start = left <= right ? left : right;
        final end = left <= right ? right : left;
        return _TableRangeBounds(start: start, end: end);
      }
    }

    final toMatch = RegExp(r'(\d+)\s*(?:TO|to)\s*(\d+)').firstMatch(normalized);
    if (toMatch != null) {
      final left = int.tryParse(toText(toMatch.group(1)));
      final right = int.tryParse(toText(toMatch.group(2)));
      if (left != null && right != null && left > 0 && right > 0) {
        final start = left <= right ? left : right;
        final end = left <= right ? right : left;
        return _TableRangeBounds(start: start, end: end);
      }
    }

    final numbers = RegExp(r'\d+')
        .allMatches(normalized)
        .map((match) => int.tryParse(toText(match.group(0))))
        .whereType<int>()
        .where((value) => value > 0)
        .toList(growable: false);
    if (numbers.isEmpty) return null;

    if (numbers.length == 1) {
      return _TableRangeBounds(start: numbers.first, end: numbers.first);
    }

    final start = numbers.first <= numbers.last ? numbers.first : numbers.last;
    final end = numbers.first <= numbers.last ? numbers.last : numbers.first;
    return _TableRangeBounds(start: start, end: end);
  }

  static int? parseTableToken(String rawTableToken) {
    final raw = rawTableToken.trim();
    if (raw.isEmpty) return null;
    final direct = int.tryParse(raw);
    if (direct != null && direct > 0) return direct;

    final withoutPrefix = raw.replaceFirst(
      RegExp(r'^(?:TABLE|T)[\s\-_:#]*', caseSensitive: false),
      '',
    );
    final fromPrefix = int.tryParse(withoutPrefix.trim());
    if (fromPrefix != null && fromPrefix > 0) return fromPrefix;

    final digitMatch = RegExp(r'(\d+)').firstMatch(raw);
    if (digitMatch == null) return null;
    final parsed = int.tryParse(toText(digitMatch.group(1)));
    return (parsed != null && parsed > 0) ? parsed : null;
  }

  static String normalizeSection(String section) {
    return section.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }

  static int? toPositiveInt(dynamic value) {
    if (value is num) {
      final parsed = value.toInt();
      return parsed > 0 ? parsed : null;
    }
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed == null || parsed <= 0) return null;
      return parsed;
    }
    return null;
  }

  static String toText(dynamic value) {
    return value?.toString().trim() ?? '';
  }
}

class _TableRangeBounds {
  const _TableRangeBounds({required this.start, required this.end});

  final int start;
  final int end;
}
