import 'dart:convert';

import 'package:blackforest_app/app_http.dart' as http;
import 'package:blackforest_app/waiter_call_range_filter_service.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WaiterCallTableRangePage extends StatefulWidget {
  const WaiterCallTableRangePage({super.key});

  @override
  State<WaiterCallTableRangePage> createState() =>
      _WaiterCallTableRangePageState();
}

class _WaiterCallTableRangePageState extends State<WaiterCallTableRangePage> {
  static const String _apiBase = 'https://blackforest3.vseyal.com/api';
  static const Color _selectedTileColor = Color(0xFFFFE082);
  static const String _tablePageCachedTablesPrefix = 'cached_tables_';

  bool _isLoading = true;
  String? _errorMessage;
  String _branchName = '';

  List<_TableSectionViewModel> _sections = const <_TableSectionViewModel>[];

  Set<String> _selectedTableKeys = <String>{};
  Set<String> _initialSelectedTableKeys = <String>{};
  bool _isSaving = false;

  Map<String, _TableCellViewModel> get _tableByKey {
    final map = <String, _TableCellViewModel>{};
    for (final section in _sections) {
      for (final table in section.tables) {
        map[table.key] = table;
      }
    }
    return map;
  }

  bool get _hasChanges => !_setEquals(_selectedTableKeys, _initialSelectedTableKeys);

  bool _setEquals(Set<String> left, Set<String> right) {
    if (left.length != right.length) return false;
    return left.containsAll(right);
  }

  @override
  void initState() {
    super.initState();
    _loadPage();
  }

  Future<void> _loadPage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final branchId = prefs.getString('branchId')?.trim() ?? '';
      final token = prefs.getString('token')?.trim() ?? '';
      final branchName = prefs.getString('branchName')?.trim() ?? '';

      if (branchId.isEmpty) {
        throw Exception('Branch not found. Please login again.');
      }
      if (token.isEmpty) {
        throw Exception('Session token missing. Please login again.');
      }

      final candidateKeys =
          WaiterCallRangeFilterService.resolveCandidateUserKeysFromPrefs(prefs);

      if (!mounted) return;
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });

      final sections = await _loadTablesForBranch(
        prefs: prefs,
        branchId: branchId,
        token: token,
        candidateKeys: candidateKeys,
      );

      // Initialize selected keys based on current server-side allocations matching user's keys
      final selectedKeys = <String>{};
      for (final section in sections) {
        for (final table in section.tables) {
          bool isAllocated = false;
          final waiterId = table.assignedWaiterId ?? '';
          final waiterName = (table.assignedWaiterName ?? '').toLowerCase();
          for (final candidate in candidateKeys) {
            if (candidate.isNotEmpty &&
                (candidate == waiterId || candidate == waiterName)) {
              isAllocated = true;
              break;
            }
          }
          if (isAllocated) {
            selectedKeys.add(table.key);
          }
        }
      }

      await _autoSaveAllocatedTables(
        prefs: prefs,
        branchId: branchId,
        sections: sections,
        userKeys: candidateKeys,
      );

      if (!mounted) return;
      setState(() {
        _branchName = branchName;
        _sections = sections;
        _selectedTableKeys = selectedKeys;
        _initialSelectedTableKeys = Set<String>.from(selectedKeys);
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

  Future<void> _autoSaveAllocatedTables({
    required SharedPreferences prefs,
    required String branchId,
    required List<_TableSectionViewModel> sections,
    required List<String> userKeys,
  }) async {
    try {
      final selections = <WaiterCallRangeSelection>[];
      for (final section in sections) {
        for (final table in section.tables) {
          selections.add(
            WaiterCallRangeSelection(
              rowId: '${table.sectionKey}|${table.tableNumber}',
              section: table.sectionName,
              label: table.tableLabel,
              tableRange: 'T${table.tableNumber}',
              startTable: table.tableNumber,
              endTable: table.tableNumber,
            ),
          );
        }
      }

      for (final key in userKeys) {
        await WaiterCallRangeFilterService.saveSelections(
          prefs: prefs,
          userId: key,
          branchId: branchId,
          selections: selections,
        );
      }
    } catch (e) {
      debugPrint('Failed to auto-save table allocations: $e');
    }
  }

  void _toggleTableSelection(String key) {
    setState(() {
      if (_selectedTableKeys.contains(key)) {
        _selectedTableKeys.remove(key);
      } else {
        _selectedTableKeys.add(key);
      }
    });
  }

  Future<void> _saveSelections() async {
    final prefs = await SharedPreferences.getInstance();
    final branchId = prefs.getString('branchId')?.trim() ?? '';
    final token = prefs.getString('token')?.trim() ?? '';
    final waiterId = WaiterCallRangeFilterService.resolveUserKeyFromPrefs(prefs);

    if (branchId.isEmpty || token.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Session expired. Please login again.')),
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final added = _selectedTableKeys.difference(_initialSelectedTableKeys);
      final removed = _initialSelectedTableKeys.difference(_selectedTableKeys);
      final allTables = _tableByKey;

      // 1. Unassign removed tables
      for (final key in removed) {
        final table = allTables[key];
        if (table == null) continue;
        await _allocateWaiter(
          token: token,
          branchId: branchId,
          sectionName: table.sectionName,
          tableNumber: table.tableNumber.toString(),
          waiterId: '',
        );
      }

      // 2. Assign added tables
      for (final key in added) {
        final table = allTables[key];
        if (table == null) continue;
        await _allocateWaiter(
          token: token,
          branchId: branchId,
          sectionName: table.sectionName,
          tableNumber: table.tableNumber.toString(),
          waiterId: waiterId,
        );
      }

      // 3. Save locally to SharedPreferences for waiter-call notifications filter
      final newSelections = <WaiterCallRangeSelection>[];
      for (final key in _selectedTableKeys) {
        final table = allTables[key];
        if (table != null) {
          newSelections.add(
            WaiterCallRangeSelection(
              rowId: '${table.sectionKey}|${table.tableNumber}',
              section: table.sectionName,
              label: table.tableLabel,
              tableRange: 'T${table.tableNumber}',
              startTable: table.tableNumber,
              endTable: table.tableNumber,
            ),
          );
        }
      }

      final candidateKeys = WaiterCallRangeFilterService.resolveCandidateUserKeysFromPrefs(prefs);
      for (final candidate in candidateKeys) {
        await WaiterCallRangeFilterService.saveSelections(
          prefs: prefs,
          userId: candidate,
          branchId: branchId,
          selections: newSelections,
        );
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Table allocations saved successfully.')),
      );

      // Reload page to get fresh status
      await _loadPage();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save allocations: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _allocateWaiter({
    required String token,
    required String branchId,
    required String sectionName,
    required String tableNumber,
    required String waiterId,
  }) async {
    final uri = Uri.parse('$_apiBase/widgets/allocate-table-waiter');
    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'branchId': branchId,
        'sectionName': sectionName,
        'tableNumber': tableNumber,
        'waiterId': waiterId,
      }),
    );

    if (response.statusCode != 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      throw Exception(body['message'] ?? 'Failed to allocate waiter');
    }
  }

  Future<List<_TableSectionViewModel>> _loadTablesForBranch({
    required SharedPreferences prefs,
    required String branchId,
    required String token,
    required List<String> candidateKeys,
  }) async {
    Object? liveLoadError;
    List<_TableSectionViewModel> liveSections =
        const <_TableSectionViewModel>[];
    bool liveSuccess = false;
    try {
      liveSections = await _fetchLiveTableSections(
        branchId: branchId,
        token: token,
      );
      liveSuccess = true;
    } catch (error) {
      liveLoadError = error;
    }
    if (liveSuccess) {
      return liveSections;
    }

    try {
      final fallbackSections = await _fetchTableMasterSections(
        branchId: branchId,
        token: token,
      );
      return fallbackSections;
    } catch (_) {
      final cachedSections = _readTableSectionsFromCache(
        prefs: prefs,
        branchId: branchId,
      );
      if (_hasAnyTable(cachedSections)) {
        return cachedSections;
      }

      if (liveLoadError != null) {
        throw liveLoadError;
      }
      rethrow;
    }
  }

  bool _hasAnyTable(List<_TableSectionViewModel> sections) {
    for (final section in sections) {
      if (section.tables.isNotEmpty) return true;
    }
    return false;
  }

  Future<List<_TableSectionViewModel>> _fetchLiveTableSections({
    required String branchId,
    required String token,
  }) async {
    final uri = Uri.parse(
      '$_apiBase/widgets/live-table-status?branchId=${Uri.encodeComponent(branchId)}',
    );
    final response = await http.get(uri, headers: _authHeaders(token));
    if (response.statusCode == 401) {
      throw Exception('Session expired. Please login again.');
    }
    if (response.statusCode == 403) {
      throw Exception(
        'You do not have access to table-range data for this branch.',
      );
    }
    if (response.statusCode != 200) {
      throw Exception(
        'Failed to fetch live table status (${response.statusCode}).',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      return const <_TableSectionViewModel>[];
    }

    final branches = _asMapList(decoded['branches']);
    if (branches.isEmpty) {
      return const <_TableSectionViewModel>[];
    }

    Map<String, dynamic>? selectedBranch;
    for (final branch in branches) {
      final branchValue = _readText(branch['branchId']);
      if (branchValue == branchId) {
        selectedBranch = branch;
        break;
      }
    }
    selectedBranch ??= branches.first;

    final sections = <_TableSectionViewModel>[];
    for (final rawSection in _asMapList(selectedBranch['sections'])) {
      final rawSectionName = _readText(rawSection['sectionName']).isNotEmpty
          ? _readText(rawSection['sectionName'])
          : _readText(rawSection['name']);
      final sectionName = rawSectionName.isEmpty ? 'Unknown' : rawSectionName;
      final sectionKey = WaiterCallRangeFilterService.normalizeSection(
        sectionName,
      );
      if (sectionKey.isEmpty) continue;

      final byTableNumber = <int, _TableCellViewModel>{};
      for (final rawTable in _asMapList(rawSection['tables'])) {
        final assignedWaiterId = _readText(rawTable['assignedWaiterId']);
        final assignedWaiterName = _readText(rawTable['assignedWaiterName']);

        final rawNumber = _readText(rawTable['tableNumber']);
        final rawLabel = _readText(rawTable['tableLabel']);
        final parsedNumber = WaiterCallRangeFilterService.parseTableToken(
          rawNumber.isNotEmpty ? rawNumber : rawLabel,
        );
        if (parsedNumber == null || parsedNumber <= 0) continue;

        final bool isOffline = rawTable['isOffline'] == true;
        final String tableLabel = rawLabel.isNotEmpty ? rawLabel : 'Table $parsedNumber';
        final bool occupied = rawTable['occupied'] == true;
        final String tableState = _readText(rawTable['tableState']);
        final String servedBy = _readText(rawTable['servedBy']);

        byTableNumber[parsedNumber] = _TableCellViewModel(
          sectionName: sectionName,
          sectionKey: sectionKey,
          tableNumber: parsedNumber,
          tableLabel: tableLabel,
          occupied: occupied,
          tableState: tableState,
          servedBy: servedBy.isNotEmpty ? servedBy : (assignedWaiterName.isNotEmpty ? assignedWaiterName : ''),
          assignedWaiterId: assignedWaiterId,
          assignedWaiterName: assignedWaiterName,
          isOffline: isOffline,
        );
      }

      if (byTableNumber.isEmpty) continue;
      final sortedTableNumbers = byTableNumber.keys.toList(growable: true)
        ..sort((a, b) => a.compareTo(b));
      sections.add(
        _TableSectionViewModel(
          sectionName: sectionName,
          sectionKey: sectionKey,
          tables: sortedTableNumbers
              .map((tableNumber) => byTableNumber[tableNumber]!)
              .toList(growable: false),
        ),
      );
    }

    return sections;
  }

  Future<List<_TableSectionViewModel>> _fetchTableMasterSections({
    required String branchId,
    required String token,
  }) async {
    final uri = Uri.parse(
      '$_apiBase/tables?where[branch][equals]=${Uri.encodeComponent(branchId)}&limit=1&depth=1',
    );
    final response = await http.get(uri, headers: _authHeaders(token));
    if (response.statusCode == 401) {
      throw Exception('Session expired. Please login again.');
    }
    if (response.statusCode == 403) {
      throw Exception(
        'You do not have access to table configuration for this branch.',
      );
    }
    if (response.statusCode != 200) {
      throw Exception(
        'Failed to fetch table configuration (${response.statusCode}).',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      return const <_TableSectionViewModel>[];
    }

    final docs = decoded['docs'];
    if (docs is! List || docs.isEmpty) {
      return const <_TableSectionViewModel>[];
    }
    final doc = docs.first;
    if (doc is! Map) {
      return const <_TableSectionViewModel>[];
    }

    final sections = <_TableSectionViewModel>[];
    for (final rawSection in _asMapList(doc['sections'])) {
      final rawSectionName = _readText(rawSection['name']);
      final sectionName = rawSectionName.isEmpty ? 'Unknown' : rawSectionName;
      final sectionKey = WaiterCallRangeFilterService.normalizeSection(
        sectionName,
      );
      if (sectionKey.isEmpty) continue;

      final tables = _parseSectionTablesWithAllocations(
        rawSection: rawSection,
        sectionName: sectionName,
        sectionKey: sectionKey,
      );
      if (tables.isEmpty) continue;

      sections.add(
        _TableSectionViewModel(
          sectionName: sectionName,
          sectionKey: sectionKey,
          tables: tables,
        ),
      );
    }

    return sections;
  }


  List<_TableSectionViewModel> _readTableSectionsFromCache({
    required SharedPreferences prefs,
    required String branchId,
  }) {
    final key = '$_tablePageCachedTablesPrefix$branchId';
    final cached = prefs.getString(key);
    if (cached == null || cached.trim().isEmpty) {
      return const <_TableSectionViewModel>[];
    }

    try {
      final decoded = jsonDecode(cached);
      final rawSections = _asMapList(decoded);
      if (rawSections.isEmpty) {
        return const <_TableSectionViewModel>[];
      }

      final sections = <_TableSectionViewModel>[];
      for (final rawSection in rawSections) {
        final rawSectionName = _readText(rawSection['name']).isNotEmpty
            ? _readText(rawSection['name'])
            : _readText(rawSection['sectionName']);
        final sectionName = rawSectionName.isEmpty ? 'Unknown' : rawSectionName;
        final sectionKey = WaiterCallRangeFilterService.normalizeSection(
          sectionName,
        );
        if (sectionKey.isEmpty) continue;

        final tables = _parseSectionTablesWithAllocations(
          rawSection: rawSection,
          sectionName: sectionName,
          sectionKey: sectionKey,
        );
        if (tables.isEmpty) continue;

        sections.add(
          _TableSectionViewModel(
            sectionName: sectionName,
            sectionKey: sectionKey,
            tables: tables,
          ),
        );
      }
      return sections;
    } catch (_) {
      return const <_TableSectionViewModel>[];
    }
  }

  List<_TableCellViewModel> _parseSectionTablesWithAllocations({
    required Map<String, dynamic> rawSection,
    required String sectionName,
    required String sectionKey,
  }) {
    final numbers = _resolveSectionTableNumbers(rawSection);
    final allocations = _asMapList(rawSection['waiterAllocations']);

    final offlineTablesRaw = rawSection['offlineTables'];
    final offlineTableSet = <String>{};
    if (offlineTablesRaw is List) {
      for (final val in offlineTablesRaw) {
        offlineTableSet.add(val.toString().trim());
      }
    }

    final tableWaiterMap = <int, _WaiterAllocationInfo>{};
    for (final alloc in allocations) {
      final rawNum = _readText(alloc['tableNumber']);
      final parsedNum = WaiterCallRangeFilterService.parseTableToken(rawNum);
      if (parsedNum == null || parsedNum <= 0) continue;

      final waiterVal = alloc['waiter'];
      String waiterId = '';
      String waiterName = '';
      if (waiterVal is String) {
        waiterId = waiterVal;
      } else if (waiterVal is Map) {
        waiterId = _readText(waiterVal['id'] ?? waiterVal['_id']);
        waiterName = _readText(waiterVal['name'] ?? waiterVal['username']);
      }

      if (waiterId.isNotEmpty) {
        tableWaiterMap[parsedNum] = _WaiterAllocationInfo(
          waiterId: waiterId,
          waiterName: waiterName.isNotEmpty ? waiterName : 'Waiter',
        );
      }
    }

    final tables = <_TableCellViewModel>[];
    for (final num in numbers) {
      final alloc = tableWaiterMap[num];
      final isOffline = offlineTableSet.contains(num.toString());
      tables.add(
        _TableCellViewModel(
          sectionName: sectionName,
          sectionKey: sectionKey,
          tableNumber: num,
          tableLabel: 'Table $num',
          occupied: false,
          tableState: 'available',
          servedBy: alloc?.waiterName ?? '',
          assignedWaiterId: alloc?.waiterId,
          assignedWaiterName: alloc?.waiterName,
          isOffline: isOffline,
        ),
      );
    }
    return tables;
  }

  List<int> _resolveSectionTableNumbers(Map<String, dynamic> section) {
    final fromExplicitRows = _resolveFromExplicitTableNumbers(
      section['tableNumbers'],
    );
    if (fromExplicitRows.isNotEmpty) {
      return fromExplicitRows;
    }

    final fromRangeRows = _resolveFromRangeRows(section['rangeRows']);
    if (fromRangeRows.isNotEmpty) {
      return fromRangeRows;
    }

    final count = WaiterCallRangeFilterService.toPositiveInt(
      section['tableCount'],
    );
    if (count == null || count <= 0) {
      return const <int>[];
    }
    return List<int>.generate(count, (index) => index + 1, growable: false);
  }

  List<int> _resolveFromExplicitTableNumbers(dynamic rawRows) {
    final numbers = <int>{};
    for (final row in _asMapList(rawRows)) {
      final rawNumber = _readText(row['tableNumber']);
      final parsed = WaiterCallRangeFilterService.parseTableToken(rawNumber);
      if (parsed == null || parsed <= 0) continue;
      numbers.add(parsed);
    }

    final sorted = numbers.toList(growable: true)
      ..sort((a, b) => a.compareTo(b));
    return sorted;
  }

  List<int> _resolveFromRangeRows(dynamic rawRows) {
    final numbers = <int>{};
    for (final row in _asMapList(rawRows)) {
      final rawRange = _readText(row['tableRange']);
      if (rawRange.isEmpty) continue;
      final bounds = _parseRangeBounds(rawRange);
      if (bounds == null) continue;
      for (
        int tableNumber = bounds.start;
        tableNumber <= bounds.end;
        tableNumber++
      ) {
        numbers.add(tableNumber);
      }
    }

    final sorted = numbers.toList(growable: true)
      ..sort((a, b) => a.compareTo(b));
    return sorted;
  }

  _RangeBounds? _parseRangeBounds(String rawRange) {
    final normalized = rawRange.trim();
    if (normalized.isEmpty) return null;

    final hyphenMatch = RegExp(
      r'T?\s*(\d+)\s*[-–—]\s*T?\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (hyphenMatch != null) {
      final start = int.tryParse(_readText(hyphenMatch.group(1)));
      final end = int.tryParse(_readText(hyphenMatch.group(2)));
      if (start == null || end == null || start <= 0 || end <= 0) return null;
      return _RangeBounds(
        start: start <= end ? start : end,
        end: start <= end ? end : start,
      );
    }

    final singleMatch = RegExp(
      r'^T?\s*(\d+)$',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (singleMatch != null) {
      final value = int.tryParse(_readText(singleMatch.group(1)));
      if (value == null || value <= 0) return null;
      return _RangeBounds(start: value, end: value);
    }

    return null;
  }



  List<Map<String, dynamic>> _asMapList(dynamic value) {
    if (value is! List) return const <Map<String, dynamic>>[];
    final rows = <Map<String, dynamic>>[];
    for (final item in value) {
      if (item is Map) {
        rows.add(Map<String, dynamic>.from(item));
      }
    }
    return rows;
  }

  String _readText(dynamic value) {
    return value?.toString().trim() ?? '';
  }

  Map<String, String> _authHeaders(String token) {
    final headers = <String, String>{
      http.skipUnauthorizedLogoutHeaderName: '1',
    };
    final trimmedToken = token.trim();
    if (trimmedToken.isEmpty) return headers;
    headers['Authorization'] = 'Bearer $trimmedToken';
    return headers;
  }

  Widget _buildTableTile(_TableCellViewModel table) {
    final isSelected = _selectedTableKeys.contains(table.key);
    final isOffline = table.isOffline;
    final subtitle = isOffline ? 'Offline' : (table.servedBy.isEmpty ? null : table.servedBy);

    return GestureDetector(
      onTap: isOffline ? null : () => _toggleTableSelection(table.key),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: isOffline ? const Color(0xFFF5F5F5) : (isSelected ? _selectedTileColor : Colors.white),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isOffline
                ? const Color(0xFFE0E0E0)
                : (isSelected ? const Color(0xFFF59E0B) : const Color(0xFFE0E0E0)),
            width: isSelected ? 2 : 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                table.tableLabel,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: isOffline ? Colors.grey[400] : Colors.black87,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: isOffline ? Colors.grey[400] : Colors.grey[700],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.redAccent,
                size: 36,
              ),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 14),
              ElevatedButton(onPressed: _loadPage, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    if (_sections.isEmpty) {
      return const Center(
        child: Text(
          'No tables found for this branch.',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFE0F5F0),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF006C67)),
            ),
            child: Text(
              'Selected tables: ${_selectedTableKeys.length}\nTap tables to select them and tap "Save Changes" at the bottom to save your assignments.',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF006C67),
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: _sections.length,
            itemBuilder: (context, index) {
              final section = _sections[index];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      section.sectionName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 1,
                        ),
                    itemCount: section.tables.length,
                    itemBuilder: (context, tableIndex) {
                      final table = section.tables[tableIndex];
                      return _buildTableTile(table);
                    },
                  ),
                  const SizedBox(height: 18),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _branchName.isEmpty ? 'Table Range' : 'Table Range - $_branchName',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _isLoading ? null : _loadPage,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _buildContent(),
      bottomNavigationBar: _hasChanges
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF006C67),
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 2,
                  ),
                  onPressed: _isSaving ? null : _saveSelections,
                  child: _isSaving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : const Text(
                          'Save Changes',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
            )
          : null,
    );
  }
}

class _TableSectionViewModel {
  const _TableSectionViewModel({
    required this.sectionName,
    required this.sectionKey,
    required this.tables,
  });

  final String sectionName;
  final String sectionKey;
  final List<_TableCellViewModel> tables;
}

class _TableCellViewModel {
  const _TableCellViewModel({
    required this.sectionName,
    required this.sectionKey,
    required this.tableNumber,
    required this.tableLabel,
    required this.occupied,
    required this.tableState,
    required this.servedBy,
    required this.isOffline,
    this.assignedWaiterId,
    this.assignedWaiterName,
  });

  final String sectionName;
  final String sectionKey;
  final int tableNumber;
  final String tableLabel;
  final bool occupied;
  final String tableState;
  final String servedBy;
  final bool isOffline;
  final String? assignedWaiterId;
  final String? assignedWaiterName;

  String get key => '$sectionKey|$tableNumber';
}

class _WaiterAllocationInfo {
  const _WaiterAllocationInfo({required this.waiterId, required this.waiterName});
  final String waiterId;
  final String waiterName;
}

class _RangeBounds {
  const _RangeBounds({required this.start, required this.end});

  final int start;
  final int end;
}

