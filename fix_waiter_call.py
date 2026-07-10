import re

path = '/Users/castromurugan/Documents/Blackforest/blackforest_app/lib/waiter_call_table_range_page.dart'
with open(path, 'r') as f:
    content = f.read()

# 1. Variables
content = re.sub(
    r'  List<_TableSectionViewModel> _sections = const <_TableSectionViewModel>\[\];\n  Set<String> _selectedTableKeys = <String>{};\n  Set<String> _initialSelectedTableKeys = <String>{};\n\n  Map<String, _TableCellViewModel> get _tableByKey \{.*?\n  \}\n\n  bool get _hasChanges =>\n      !_setEquals\(_selectedTableKeys, _initialSelectedTableKeys\);\n\n  int get _selectedCount => _selectedTableKeys\.length;\n\n  @override\n  void initState\(\) \{.*?  \}\n\n  Set<String> _readSavedSelectionKeys\(\{.*?\n    return keys;\n  \}',
    '''  List<_TableSectionViewModel> _sections = const <_TableSectionViewModel>[];
  String _userKey = '';
  List<String> _candidateKeys = const <String>[];

  int get _allocatedCount {
    int count = 0;
    for (final section in _sections) {
      count += section.tables.length;
    }
    return count;
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

      final candidateKeys = WaiterCallRangeFilterService.resolveCandidateUserKeysFromPrefs(prefs);
      final userKey = WaiterCallRangeFilterService.resolveUserKeyFromPrefs(prefs);

      if (!mounted) return;
      setState(() {
        _isLoading = true;
        _errorMessage = null;
        _userKey = userKey;
        _candidateKeys = candidateKeys;
      });

      final sections = await _loadTablesForBranch(
        prefs: prefs,
        branchId: branchId,
        token: token,
        candidateKeys: candidateKeys,
      );

      await _autoSaveAllocatedTables(
        prefs: prefs,
        branchId: branchId,
        sections: sections,
        userKeys: candidateKeys,
      );

      if (!mounted) return;
      setState(() {
        _branchId = branchId;
        _branchName = branchName;
        _sections = sections;
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
          selections.add(WaiterCallRangeSelection(
            rowId: '${table.sectionKey}|${table.tableNumber}',
            section: table.sectionName,
            label: table.tableLabel,
            tableRange: 'T${table.tableNumber}',
            startTable: table.tableNumber,
            endTable: table.tableNumber,
          ));
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
  }''',
    content,
    flags=re.DOTALL
)

# 2. _loadTablesForBranch signature
content = content.replace(
'''  Future<List<_TableSectionViewModel>> _loadTablesForBranch({
    required SharedPreferences prefs,
    required String branchId,
    required String token,
  }) async {
    Object? liveLoadError;
    List<_TableSectionViewModel> liveSections =
        const <_TableSectionViewModel>[];
    try {
      liveSections = await _fetchLiveTableSections(
        branchId: branchId,
        token: token,
      );''',
'''  Future<List<_TableSectionViewModel>> _loadTablesForBranch({
    required SharedPreferences prefs,
    required String branchId,
    required String token,
    required List<String> candidateKeys,
  }) async {
    Object? liveLoadError;
    List<_TableSectionViewModel> liveSections =
        const <_TableSectionViewModel>[];
    try {
      liveSections = await _fetchLiveTableSections(
        branchId: branchId,
        token: token,
        candidateKeys: candidateKeys,
      );'''
)

# 3. _fetchLiveTableSections signature & logic
content = content.replace(
'''  Future<List<_TableSectionViewModel>> _fetchLiveTableSections({
    required String branchId,
    required String token,
  }) async {''',
'''  Future<List<_TableSectionViewModel>> _fetchLiveTableSections({
    required String branchId,
    required String token,
    required List<String> candidateKeys,
  }) async {'''
)

content = content.replace(
'''      final byTableNumber = <int, _TableCellViewModel>{};
      for (final rawTable in _asMapList(rawSection['tables'])) {
        final rawNumber = _readText(rawTable['tableNumber']);''',
'''      final byTableNumber = <int, _TableCellViewModel>{};
      for (final rawTable in _asMapList(rawSection['tables'])) {
        final assignedWaiterId = _readText(rawTable['assignedWaiterId']);
        final assignedWaiterName = _readText(rawTable['assignedWaiterName']).toLowerCase();
        
        bool isAllocated = false;
        for (final candidate in candidateKeys) {
          if (candidate == assignedWaiterId || candidate == assignedWaiterName) {
            isAllocated = true;
            break;
          }
        }
        
        if (!isAllocated) continue;

        final rawNumber = _readText(rawTable['tableNumber']);'''
)

# 4. Remove toggle, save, setEquals
content = re.sub(
    r'  Future<void> _saveSelections\(\) async \{.*?\n  bool _setEquals\(Set<String> left, Set<String> right\) \{.*?\n    return true;\n  \}',
    '  // UI Selection & Saving logic removed as allocations are controlled by branch admin',
    content,
    flags=re.DOTALL
)

# 5. Build Table Tile (remove selection logic)
content = content.replace(
'''  Widget _buildTableTile(_TableCellViewModel table) {
    final isSelected = _selectedTableKeys.contains(table.key);
    final accentColor = _statusAccentColor(table);
    final subtitle = table.servedBy.isEmpty ? null : table.servedBy;

    return GestureDetector(
      onTap: () => _toggleTable(table),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: isSelected ? _selectedTileColor : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? const Color(0xFFF59E0B) : accentColor,
            width: isSelected ? 2 : 1.2,
          ),
          boxShadow: [''',
'''  Widget _buildTableTile(_TableCellViewModel table) {
    final accentColor = _statusAccentColor(table);
    final subtitle = table.servedBy.isEmpty ? null : table.servedBy;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        color: _selectedTileColor, // Highlight all allocated tables
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFF59E0B),
          width: 2,
        ),
        boxShadow: ['''
)
content = content.replace('''            ],
          ),
        ),
      ),
    );
  }''',
'''            ],
          ),
        ),
      );
  }''')

# 6. Build Content header
content = content.replace(
'''    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFF9FAFB),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Text(
              'Selected tables: $_selectedCount\\nTap a table to toggle waiter-call notifications.',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF374151),
              ),
            ),
          ),
        ),''',
'''    return Column(
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
              'Allocated Tables: $_allocatedCount\\nThese tables are assigned to you by the branch manager.',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF006C67),
              ),
            ),
          ),
        ),'''
)

# 7. Remove bottom nav bar
content = re.sub(
    r'      body: _buildContent\(\),\n      bottomNavigationBar: SafeArea\(.*?\n        \),\n      \),\n    \);\n  \}',
    '''      body: _buildContent(),
    );
  }''',
    content,
    flags=re.DOTALL
)

with open(path, 'w') as f:
    f.write(content)
print("Done")
