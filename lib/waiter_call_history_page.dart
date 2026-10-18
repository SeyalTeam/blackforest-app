import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_config.dart';
import 'waiter_call_history_service.dart';
import 'waiter_live_call_service.dart';

enum ContactBookTab {
  contacts,
  allCalls,
  dialed,
  received,
  missed,
  tableOnly,
}

class ContactItem {
  final String userId;
  final String employeeId;
  final String name;
  final String role;
  final String? phone;
  final String? email;
  final String? branchName;
  final String? branchId;
  final bool isPunchedIn;

  const ContactItem({
    required this.userId,
    required this.employeeId,
    required this.name,
    required this.role,
    this.phone,
    this.email,
    this.branchName,
    this.branchId,
    this.isPunchedIn = false,
  });

  bool get isWaiter => role.trim().toLowerCase() == 'waiter';
  bool get isCashier => role.trim().toLowerCase() == 'cashier';
  bool get isKitchen =>
      role.trim().toLowerCase() == 'kitchen' || role.trim().toLowerCase() == 'chef';
  bool get isSupervisor => role.trim().toLowerCase() == 'supervisor';
  bool get isManager => role.trim().toLowerCase() == 'manager';

  ContactItem copyWith({bool? isPunchedIn}) {
    return ContactItem(
      userId: userId,
      employeeId: employeeId,
      name: name,
      role: role,
      phone: phone,
      email: email,
      branchName: branchName,
      branchId: branchId,
      isPunchedIn: isPunchedIn ?? this.isPunchedIn,
    );
  }

  static ContactItem? fromJson(
    dynamic json, {
    String? currentBranchId,
    String? currentBranchName,
    Set<String>? activePunchedInUserIds,
  }) {
    if (json is! Map<String, dynamic>) return null;

    final userId = _relId(json['id'] ?? json['_id']);
    final employee = json['employee'];
    final employeeId =
        _relId(employee is Map ? (employee['id'] ?? employee['_id']) : employee) ?? userId;

    // Filter out inactive or blocked employees
    if (json['loginBlocked'] == true) return null;
    if (json['status'] != null && json['status'].toString().trim().toLowerCase() == 'inactive') {
      return null;
    }
    if (json['isActive'] == false || json['active'] == false) return null;
    if (employee is Map) {
      final empStatus = employee['status']?.toString().trim().toLowerCase();
      if (empStatus != null && empStatus.isNotEmpty && empStatus != 'active') {
        return null;
      }
      if (employee['isActive'] == false || employee['active'] == false) {
        return null;
      }
    }

    String? name;
    if (employee is Map &&
        employee['name'] != null &&
        employee['name'].toString().trim().isNotEmpty) {
      name = employee['name'].toString().trim();
    } else if (json['name'] != null && json['name'].toString().trim().isNotEmpty) {
      name = json['name'].toString().trim();
    } else if (json['email'] != null && json['email'].toString().trim().isNotEmpty) {
      name = json['email'].toString().trim();
    }

    if (userId == null || name == null || name.isEmpty) return null;

    String? phone;
    if (employee is Map) {
      phone = employee['phone']?.toString().trim() ?? employee['mobile']?.toString().trim();
    }
    phone ??= json['phone']?.toString().trim() ?? json['mobile']?.toString().trim();

    String? branch;
    String? userBranchId;
    if (employee is Map && employee['branch'] != null) {
      final b = employee['branch'];
      userBranchId = _relId(b);
      branch = b is Map ? b['name']?.toString() : b.toString();
    } else if (json['branch'] != null) {
      final b = json['branch'];
      userBranchId = _relId(b);
      branch = b is Map ? b['name']?.toString() : b.toString();
    } else if (json['lastLoginBranch'] != null) {
      final b = json['lastLoginBranch'];
      userBranchId = _relId(b);
      branch = b is Map ? b['name']?.toString() : b.toString();
    }

    branch ??= currentBranchName;

    final isPunchedIn = activePunchedInUserIds?.contains(userId) ?? false;

    return ContactItem(
      userId: userId,
      employeeId: employeeId ?? userId,
      name: name,
      role: json['role']?.toString().trim() ?? 'Staff',
      phone: (phone == null || phone.isEmpty) ? null : phone,
      email: json['email']?.toString().trim(),
      branchName: (branch == null || branch.isEmpty) ? null : branch,
      branchId: userBranchId,
      isPunchedIn: isPunchedIn,
    );
  }

  static String? _relId(dynamic val) {
    if (val == null) return null;
    if (val is String && val.trim().isNotEmpty) return val.trim();
    if (val is Map) {
      final id = val['id'] ?? val['_id'];
      if (id != null && id.toString().trim().isNotEmpty) return id.toString().trim();
    }
    return null;
  }
}

class WaiterCallHistoryPage extends StatefulWidget {
  final ContactBookTab initialTab;
  const WaiterCallHistoryPage({
    super.key,
    this.initialTab = ContactBookTab.contacts,
  });

  @override
  State<WaiterCallHistoryPage> createState() => _WaiterCallHistoryPageState();
}

class _WaiterCallHistoryPageState extends State<WaiterCallHistoryPage> {
  late ContactBookTab _activeTab;
  final TextEditingController _searchController = TextEditingController();

  // Contacts state
  bool _isLoadingContacts = true;
  String? _contactLoadError;
  List<ContactItem> _contacts = [];
  String _selectedRoleFilter = 'ALL';
  String? _currentBranchName;

  // History state
  bool _isLoadingHistory = true;
  String? _historyError;
  List<WaiterCallHistoryEntry> _allEntries = const <WaiterCallHistoryEntry>[];
  DateTime? _selectedDateFilter;

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTab;
    _loadContacts();
    _loadHistory();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<String?> _readToken() async {
    try {
      const storage = FlutterSecureStorage();
      final token = await storage.read(key: 'token');
      if (token != null && token.trim().isNotEmpty) return token.trim();
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token') ?? prefs.getString('auth_token');
      if (token != null && token.trim().isNotEmpty) return token.trim();
    } catch (_) {}
    return null;
  }

  Future<void> _loadContacts({bool showLoader = true}) async {
    if (showLoader && mounted) {
      setState(() {
        _isLoadingContacts = true;
        _contactLoadError = null;
      });
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = await _readToken();
      if (token == null) {
        throw Exception('Session expired. Please log in again.');
      }

      final myUserId = (prefs.getString('user_id') ?? prefs.getString('userId'))?.trim() ?? '';
      final branchId = (prefs.getString('branchId') ??
              prefs.getString('branch') ??
              prefs.getString('userBranchId'))
          ?.trim();
      final branchName = prefs.getString('branchName')?.trim();

      _currentBranchName = branchName;

      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());

      // 1. Fetch today's attendances to identify live punched-in staff
      final activePunchedInUserIds = <String>{};
      final attendedBranchUserIds = <String>{};

      try {
        final attUrl = Uri.parse(
          '${ApiConfig.baseUrl}/attendance?where[dateString][equals]=$today&limit=500&depth=1',
        );
        final attRes = await http.get(attUrl, headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        });

        if (attRes.statusCode == 200) {
          final attData = jsonDecode(utf8.decode(attRes.bodyBytes));
          final attDocs = (attData is Map ? attData['docs'] : null) as List? ?? [];

          for (final doc in attDocs) {
            if (doc is! Map) continue;
            final uId = ContactItem._relId(doc['user']);
            final logBranchId = ContactItem._relId(doc['loginBranch']);

            if (branchId != null &&
                branchId.isNotEmpty &&
                logBranchId != null &&
                logBranchId == branchId &&
                uId != null) {
              attendedBranchUserIds.add(uId);
            }

            final activities = doc['activities'] as List? ?? [];
            final isCurrentlyPunchedIn = activities.any((a) {
              if (a is! Map) return false;
              final type = a['type']?.toString();
              if (type != null && type != 'session') return false;
              final punchOut = a['punchOut'];
              return punchOut == null || punchOut.toString().trim().isEmpty;
            });

            if (isCurrentlyPunchedIn && uId != null) {
              activePunchedInUserIds.add(uId);
            }
          }
        }
      } catch (attErr) {
        debugPrint('WaiterCallHistoryPage: error fetching attendance: $attErr');
      }

      // 2. Fetch all staff users
      final usersUrl = Uri.parse('${ApiConfig.baseUrl}/users?limit=1000&depth=1&sort=name');
      final usersRes = await http.get(usersUrl, headers: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      });

      if (usersRes.statusCode != 200) {
        throw Exception('Failed to load contacts (${usersRes.statusCode})');
      }

      final decoded = jsonDecode(utf8.decode(usersRes.bodyBytes));
      final docs = (decoded is Map ? decoded['docs'] : null) as List? ?? [];

      final list = <ContactItem>[];
      for (final doc in docs) {
        if (doc is! Map) continue;
        final uId = ContactItem._relId(doc['id'] ?? doc['_id']);

        // Exclude currently logged in user from their own contact book
        if (uId == null || (myUserId.isNotEmpty && uId == myUserId)) continue;

        // Check if user belongs to this branch
        bool belongsToBranch = false;
        if (branchId == null || branchId.isEmpty) {
          belongsToBranch = true; // Show all if branch is not scoped
        } else {
          final userBranch = ContactItem._relId(doc['branch']);
          final lastBranch = ContactItem._relId(doc['lastLoginBranch']);
          final empBranch = ContactItem._relId(doc['employee'] is Map ? doc['employee']['branch'] : null);
          final kitchenBranches = doc['kitchenBranches'];
          final isKitchenBranchMatch = kitchenBranches is List &&
              kitchenBranches.any((kb) => ContactItem._relId(kb) == branchId);

          if (userBranch == branchId ||
              lastBranch == branchId ||
              empBranch == branchId ||
              isKitchenBranchMatch ||
              attendedBranchUserIds.contains(uId)) {
            belongsToBranch = true;
          }
        }

        if (!belongsToBranch) continue;

        final c = ContactItem.fromJson(
          doc,
          currentBranchId: branchId,
          currentBranchName: branchName,
          activePunchedInUserIds: activePunchedInUserIds,
        );
        if (c != null) {
          list.add(c);
        }
      }

      // Sort: Punched-in staff first, then alphabetically by name
      list.sort((a, b) {
        if (a.isPunchedIn != b.isPunchedIn) {
          return a.isPunchedIn ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      if (!mounted) return;
      setState(() {
        _contacts = list;
        _isLoadingContacts = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _contactLoadError = e.toString().replaceFirst('Exception: ', '');
        _isLoadingContacts = false;
      });
    }
  }

  Future<void> _loadHistory({bool showLoader = true}) async {
    if (showLoader && mounted && _allEntries.isEmpty) {
      setState(() {
        _isLoadingHistory = true;
        _historyError = null;
      });
    }
    try {
      // 1. Instant local read so screen is populated immediately
      final cached = await WaiterCallHistoryService.readHistory(syncRemote: false);
      if (mounted && cached.isNotEmpty) {
        setState(() {
          _allEntries = cached;
          _isLoadingHistory = false;
        });
      }

      // 2. Sync permanent history from backend (table calls + voice calls)
      final remote = await WaiterCallHistoryService.syncHistoryFromBackend();
      if (!mounted) return;
      setState(() {
        _allEntries = remote;
        _isLoadingHistory = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingHistory = false;
        if (_allEntries.isEmpty) {
          _historyError = 'Unable to load call logs';
        }
      });
    }
  }

  List<ContactItem> get _filteredContacts {
    final q = _searchController.text.trim().toLowerCase();
    return _contacts.where((c) {
      // Filter by role / punch-in status
      if (_selectedRoleFilter == 'ON_DUTY') {
        if (!c.isPunchedIn) return false;
      } else if (_selectedRoleFilter == 'WAITER') {
        if (!c.isWaiter) return false;
      } else if (_selectedRoleFilter == 'CASHIER') {
        if (!c.isCashier) return false;
      } else if (_selectedRoleFilter == 'KITCHEN') {
        if (!c.isKitchen) return false;
      } else if (_selectedRoleFilter == 'SUPERVISOR') {
        if (!c.isSupervisor) return false;
      } else if (_selectedRoleFilter == 'MANAGER') {
        if (!c.isManager) return false;
      }

      if (q.isEmpty) return true;
      return c.name.toLowerCase().contains(q) ||
          c.role.toLowerCase().contains(q) ||
          (c.phone ?? '').toLowerCase().contains(q) ||
          (c.branchName ?? '').toLowerCase().contains(q);
    }).toList();
  }

  List<WaiterCallHistoryEntry> get _filteredHistory {
    final q = _searchController.text.trim().toLowerCase();
    return _allEntries.where((entry) {
      // 1. Filter by top category buttons
      switch (_activeTab) {
        case ContactBookTab.contacts:
          return true;
        case ContactBookTab.allCalls:
          break;
        case ContactBookTab.dialed:
          if (!entry.isDialed) return false;
          break;
        case ContactBookTab.received:
          if (!entry.isReceived) return false;
          break;
        case ContactBookTab.missed:
          if (!entry.isIncomingMissed) return false;
          break;
        case ContactBookTab.tableOnly:
          if (!entry.isTableCall) return false;
          break;
      }

      // 2. Filter by date if selected
      if (_selectedDateFilter != null) {
        final callTime = entry.callTime ?? entry.createdAt;
        if (callTime == null) return false;
        final target = _selectedDateFilter!;
        if (callTime.year != target.year ||
            callTime.month != target.month ||
            callTime.day != target.day) {
          return false;
        }
      }

      // 3. Search query
      if (q.isEmpty) return true;
      return entry.customerName.toLowerCase().contains(q) ||
          (entry.callerRole ?? '').toLowerCase().contains(q) ||
          entry.tableNumber.toLowerCase().contains(q);
    }).toList();
  }

  void _initiateCall(String userId, String name, String role) {
    WaiterLiveCallService.instance
        .startCallToUser(
      targetUserId: userId,
      targetName: name,
      targetRole: role,
    )
        .then((_) => _loadHistory(showLoader: false))
        .catchError((err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Call failed: $err'),
          backgroundColor: Colors.redAccent,
        ),
      );
    });
  }

  Future<void> _callBackUser(WaiterCallHistoryEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final myUserId = (prefs.getString('user_id') ?? prefs.getString('userId'))?.trim() ?? '';

    String? targetId = entry.callerUserId;
    if (targetId == null || targetId.isEmpty || targetId == myUserId) {
      targetId = await WaiterCallHistoryService.getLastAdminUserId();
    }
    if (targetId == null || targetId.isEmpty || targetId == myUserId) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot call back: Contact ID is unavailable.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final targetName = entry.customerName.isNotEmpty ? entry.customerName : 'Staff';
    final targetRole = entry.callerRole ?? 'Staff';

    try {
      await WaiterLiveCallService.instance.startCallToUser(
        targetUserId: targetId,
        targetName: targetName,
        targetRole: targetRole,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Call failed: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  String _groupLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final diffDays = today.difference(day).inDays;
    if (diffDays == 0) return 'Today';
    if (diffDays == 1) return 'Yesterday';
    return DateFormat('dd MMMM yyyy').format(date);
  }

  String _clockText(DateTime date) {
    return DateFormat('h:mm a').format(date);
  }

  Future<void> _pickDateFilter() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDateFilter ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: now,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF0F766E),
              onPrimary: Colors.white,
              onSurface: Color(0xFF1E293B),
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _selectedDateFilter = picked;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final onDutyCount = _contacts.where((c) => c.isPunchedIn).length;
    final dialedCount = _allEntries.where((e) => e.isDialed).length;
    final receivedCount = _allEntries.where((e) => e.isReceived).length;
    final missedCount = _allEntries.where((e) => e.isIncomingMissed).length;
    final tableCount = _allEntries.where((e) => e.isTableCall).length;

    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: const Color(0xFF0F766E),
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Branch Contacts & Calls',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                letterSpacing: 0.3,
              ),
            ),
            if (_currentBranchName != null && _currentBranchName!.isNotEmpty)
              Text(
                _currentBranchName!,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.normal,
                  color: Colors.white70,
                ),
              ),
          ],
        ),
        actions: [
          if (_activeTab != ContactBookTab.contacts)
            IconButton(
              tooltip: 'Filter by Date',
              icon: Icon(
                _selectedDateFilter != null
                    ? Icons.calendar_month
                    : Icons.calendar_month_outlined,
                color: _selectedDateFilter != null ? Colors.amberAccent : Colors.white,
              ),
              onPressed: _pickDateFilter,
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              _loadContacts();
              _loadHistory();
            },
          ),
          if (_activeTab != ContactBookTab.contacts && _allEntries.isNotEmpty)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (val) async {
                if (val == 'clear') {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Clear Call History?'),
                      content: const Text('All local call records will be cleared permanently.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Clear', style: TextStyle(color: Colors.red)),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await WaiterCallHistoryService.clearHistory();
                    await _loadHistory();
                  }
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                  value: 'clear',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline_rounded, color: Colors.red, size: 20),
                      SizedBox(width: 8),
                      Text('Clear call history', style: TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          // TOP SEGMENT BUTTONS: Contacts | Call History | Dialed | Received | Missed | Table Calls
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildTopTabButton(
                    tab: ContactBookTab.contacts,
                    label: 'Contacts',
                    icon: Icons.contacts_rounded,
                    count: _contacts.isNotEmpty ? _contacts.length : null,
                  ),
                  const SizedBox(width: 8),
                  _buildTopTabButton(
                    tab: ContactBookTab.allCalls,
                    label: 'Call History',
                    icon: Icons.history_rounded,
                    count: _allEntries.isNotEmpty ? _allEntries.length : null,
                  ),
                  const SizedBox(width: 8),
                  _buildTopTabButton(
                    tab: ContactBookTab.dialed,
                    label: 'Dialed',
                    icon: Icons.call_made_rounded,
                    count: dialedCount > 0 ? dialedCount : null,
                    countColor: const Color(0xFF0284C7),
                  ),
                  const SizedBox(width: 8),
                  _buildTopTabButton(
                    tab: ContactBookTab.received,
                    label: 'Received',
                    icon: Icons.call_received_rounded,
                    count: receivedCount > 0 ? receivedCount : null,
                    countColor: const Color(0xFF059669),
                  ),
                  const SizedBox(width: 8),
                  _buildTopTabButton(
                    tab: ContactBookTab.missed,
                    label: 'Missed',
                    icon: Icons.call_missed_rounded,
                    count: missedCount > 0 ? missedCount : null,
                    countColor: Colors.redAccent,
                  ),
                  const SizedBox(width: 8),
                  _buildTopTabButton(
                    tab: ContactBookTab.tableOnly,
                    label: 'Table SOS',
                    icon: Icons.room_service_rounded,
                    count: tableCount > 0 ? tableCount : null,
                    countColor: const Color(0xFF0F766E),
                  ),
                ],
              ),
            ),
          ),

          // SEARCH BAR & ROLE CHIPS
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: _activeTab == ContactBookTab.contacts
                        ? 'Search contacts by name, role, phone...'
                        : 'Search call records...',
                    prefixIcon:
                        const Icon(Icons.search_rounded, color: Color(0xFF64748B), size: 22),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 20),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {});
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                    ),
                  ),
                ),
                if (_activeTab == ContactBookTab.contacts) ...[
                  const SizedBox(height: 10),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _buildRoleChip('ALL', 'All'),
                        _buildRoleChip('ON_DUTY', 'Punched In ($onDutyCount)'),
                        _buildRoleChip('WAITER', 'Waiters'),
                        _buildRoleChip('CASHIER', 'Cashiers'),
                        _buildRoleChip('SUPERVISOR', 'Supervisors'),
                        _buildRoleChip('KITCHEN', 'Kitchen'),
                        _buildRoleChip('MANAGER', 'Managers'),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          // ACTIVE DATE FILTER CHIP (if user selected previous date)
          if (_activeTab != ContactBookTab.contacts && _selectedDateFilter != null)
            Container(
              color: const Color(0xFFF0FDF4),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.event_available_rounded, size: 18, color: Color(0xFF0F766E)),
                  const SizedBox(width: 8),
                  Text(
                    'Showing calls for: ${DateFormat('dd MMM yyyy').format(_selectedDateFilter!)}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF0F766E),
                    ),
                  ),
                  const Spacer(),
                  InkWell(
                    onTap: () {
                      setState(() {
                        _selectedDateFilter = null;
                      });
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Text(
                        'Show All Dates',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF0F766E),
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          const Divider(height: 1, thickness: 1, color: Color(0xFFE2E8F0)),

          // MAIN BODY
          Expanded(
            child: _activeTab == ContactBookTab.contacts
                ? _buildContactsList()
                : _buildHistoryList(),
          ),
        ],
      ),
    );
  }

  Widget _buildTopTabButton({
    required ContactBookTab tab,
    required String label,
    required IconData icon,
    int? count,
    Color? countColor,
  }) {
    final isSelected = _activeTab == tab;

    return InkWell(
      onTap: () {
        setState(() {
          _activeTab = tab;
        });
      },
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF0F766E) : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? const Color(0xFF0F766E) : const Color(0xFFE2E8F0),
            width: 1.2,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: const Color(0xFF0F766E).withValues(alpha: 0.25),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? Colors.white : const Color(0xFF475569),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : const Color(0xFF1E293B),
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
              ),
            ),
            if (count != null) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isSelected
                      ? Colors.white.withValues(alpha: 0.25)
                      : (countColor ?? const Color(0xFF64748B)).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  count.toString(),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isSelected ? Colors.white : (countColor ?? const Color(0xFF475569)),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRoleChip(String roleKey, String label) {
    final isSelected = _selectedRoleFilter == roleKey;
    final isOnDuty = roleKey == 'ON_DUTY';

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isOnDuty) ...[
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: Color(0xFF16A34A),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
            ],
            Text(label),
          ],
        ),
        selected: isSelected,
        onSelected: (_) {
          setState(() {
            _selectedRoleFilter = roleKey;
          });
        },
        backgroundColor: const Color(0xFFF8FAFC),
        selectedColor: const Color(0xFF0F766E).withValues(alpha: 0.15),
        labelStyle: TextStyle(
          color: isSelected ? const Color(0xFF0F766E) : const Color(0xFF64748B),
          fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
          fontSize: 12,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        side: BorderSide(
          color: isSelected ? const Color(0xFF0F766E) : const Color(0xFFE2E8F0),
        ),
      ),
    );
  }

  Color _getRoleColor(String role) {
    final r = role.toLowerCase();
    if (r == 'waiter') return const Color(0xFF059669);
    if (r == 'cashier') return const Color(0xFF0284C7);
    if (r == 'kitchen' || r == 'chef') return const Color(0xFFD97706);
    if (r == 'supervisor') return const Color(0xFF7C3AED);
    if (r == 'manager') return const Color(0xFF0F766E);
    return const Color(0xFF475569);
  }

  Color _getRoleBgColor(String role) {
    final r = role.toLowerCase();
    if (r == 'waiter') return const Color(0xFFDCFCE7);
    if (r == 'cashier') return const Color(0xFFE0F2FE);
    if (r == 'kitchen' || r == 'chef') return const Color(0xFFFEF3C7);
    if (r == 'supervisor') return const Color(0xFFF3E8FF);
    if (r == 'manager') return const Color(0xFFCCFBF1);
    return const Color(0xFFF1F5F9);
  }

  // CONTACTS LIST
  Widget _buildContactsList() {
    if (_isLoadingContacts) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF0F766E)));
    }

    if (_contactLoadError != null && _contacts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 48, color: Colors.redAccent),
              const SizedBox(height: 12),
              Text(
                _contactLoadError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF334155), fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () => _loadContacts(),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0F766E),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final contacts = _filteredContacts;
    if (contacts.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.person_search_rounded, size: 56, color: Color(0xFF94A3B8)),
            const SizedBox(height: 12),
            Text(
              _searchController.text.isEmpty
                  ? (_selectedRoleFilter == 'ON_DUTY'
                      ? 'No employees are currently punched in'
                      : 'No branch contacts found')
                  : 'No contacts match "${_searchController.text}"',
              style: const TextStyle(
                fontSize: 15,
                color: Color(0xFF64748B),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _loadContacts(showLoader: false),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        itemCount: contacts.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final c = contacts[index];
          final roleColor = _getRoleColor(c.role);
          final roleBg = _getRoleBgColor(c.role);

          return Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: c.isPunchedIn ? const Color(0xFF86EFAC) : const Color(0xFFE2E8F0),
                width: c.isPunchedIn ? 1.4 : 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.02),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              leading: Stack(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: roleBg,
                    foregroundColor: roleColor,
                    child: Text(
                      c.name.isNotEmpty ? c.name[0].toUpperCase() : '?',
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: c.isPunchedIn ? const Color(0xFF16A34A) : const Color(0xFF94A3B8),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      c.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: Color(0xFF0F172A),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: roleBg,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: roleColor.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      c.role.toUpperCase(),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: roleColor,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ],
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // LIVE STATUS BADGE: Punched In vs Not Punched In
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: c.isPunchedIn
                                ? const Color(0xFFDCFCE7)
                                : const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: c.isPunchedIn
                                  ? const Color(0xFF86EFAC)
                                  : const Color(0xFFE2E8F0),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: c.isPunchedIn
                                      ? const Color(0xFF16A34A)
                                      : const Color(0xFF94A3B8),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                c.isPunchedIn ? 'Punched In • On Duty' : 'Not Punched In',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: c.isPunchedIn
                                      ? const Color(0xFF15803D)
                                      : const Color(0xFF64748B),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (c.phone != null && c.phone!.isNotEmpty) ...[
                          const Icon(Icons.phone_iphone_rounded,
                              size: 13, color: Color(0xFF94A3B8)),
                          const SizedBox(width: 4),
                          Text(
                            c.phone!,
                            style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (c.branchName != null && c.branchName!.isNotEmpty) ...[
                          const Icon(Icons.storefront_rounded,
                              size: 13, color: Color(0xFF94A3B8)),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              c.branchName!,
                              style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              trailing: Material(
                color: const Color(0xFF10B981),
                borderRadius: BorderRadius.circular(22),
                child: InkWell(
                  borderRadius: BorderRadius.circular(22),
                  onTap: () => _initiateCall(c.userId, c.name, c.role),
                  child: const Padding(
                    padding: EdgeInsets.all(9),
                    child: Icon(
                      Icons.call_rounded,
                      size: 20,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // CALL HISTORY LIST (All Calls / Missed / Received / Table Calls)
  Widget _buildHistoryList() {
    if (_isLoadingHistory) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF0F766E)));
    }

    if (_historyError != null && _allEntries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _historyError!,
              style: const TextStyle(
                color: Color(0xFF4B5563),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _loadHistory,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0F766E),
                foregroundColor: Colors.white,
              ),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final history = _filteredHistory;
    if (history.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadHistory,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Container(
            height: MediaQuery.of(context).size.height * 0.55,
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _activeTab == ContactBookTab.dialed
                      ? Icons.call_made_rounded
                      : (_activeTab == ContactBookTab.missed
                          ? Icons.phone_missed_rounded
                          : (_activeTab == ContactBookTab.received
                              ? Icons.phone_in_talk_rounded
                              : (_activeTab == ContactBookTab.tableOnly
                                  ? Icons.room_service_outlined
                                  : Icons.call_outlined))),
                  size: 56,
                  color: const Color(0xFF94A3B8),
                ),
                const SizedBox(height: 12),
                Text(
                  _activeTab == ContactBookTab.dialed
                      ? 'No dialed calls recorded'
                      : (_activeTab == ContactBookTab.missed
                          ? 'No missed calls recorded'
                          : (_activeTab == ContactBookTab.received
                              ? 'No received calls recorded'
                              : (_activeTab == ContactBookTab.tableOnly
                                  ? 'No table SOS requests recorded'
                                  : 'No call records found'))),
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_selectedDateFilter != null) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _selectedDateFilter = null;
                      });
                    },
                    child: const Text('Clear Date Filter'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    final children = <Widget>[];
    String? lastGroup;

    for (final entry in history) {
      final callTime = entry.callTime ?? entry.createdAt ?? DateTime.now();
      final group = _groupLabel(callTime);
      if (group != lastGroup) {
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                Text(
                  group,
                  style: const TextStyle(
                    color: Color(0xFF475569),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Divider(
                    thickness: 1,
                    color: Colors.grey.shade300,
                  ),
                ),
              ],
            ),
          ),
        );
        lastGroup = group;
      }
      children.add(_buildHistoryCard(entry));
    }

    return RefreshIndicator(
      onRefresh: _loadHistory,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: children,
      ),
    );
  }

  Widget _buildHistoryCard(WaiterCallHistoryEntry entry) {
    final callTime = entry.callTime ?? entry.createdAt ?? DateTime.now();
    final isTable = entry.isTableCall;

    final Color statusColor;
    final IconData statusIcon;
    final String statusText;

    if (entry.isDialed) {
      if (entry.isDialedAnswered) {
        statusColor = const Color(0xFF14804A);
        statusIcon = Icons.call_made_rounded;
        statusText = entry.durationSeconds > 0
            ? 'Dialed • ${entry.formattedDuration}'
            : 'Dialed • Answered';
      } else {
        statusColor = const Color(0xFF64748B);
        statusIcon = Icons.call_made_rounded;
        statusText = 'Dialed • No Answer';
      }
    } else if (entry.isAccepted) {
      statusColor = const Color(0xFF14804A);
      statusIcon = isTable ? Icons.call_received_rounded : Icons.phone_in_talk_rounded;
      if (isTable) {
        final who = (entry.acknowledgedBy ?? '').isNotEmpty
            ? 'by ${entry.acknowledgedBy}'
            : '';
        statusText = who.isEmpty ? 'Accepted' : 'Accepted $who';
      } else {
        statusText = entry.durationSeconds > 0
            ? 'Answered • ${entry.formattedDuration}'
            : 'Answered';
      }
    } else if (entry.isDeclined) {
      statusColor = const Color(0xFFC53030);
      statusIcon = isTable ? Icons.call_end_rounded : Icons.phone_disabled_rounded;
      statusText = 'Declined';
    } else {
      statusColor = const Color(0xFFDC2626);
      statusIcon = isTable ? Icons.call_missed_rounded : Icons.phone_missed_rounded;
      statusText = 'Missed';
    }

    final titleText = isTable
        ? 'Table ${entry.tableNumber}'
        : (entry.isDialed ? entry.customerName : entry.customerName.isNotEmpty ? entry.customerName : 'Live Call');
    final subtitleText = isTable
        ? '${entry.customerName.isEmpty ? "Guest" : entry.customerName} • Section ${entry.section.isEmpty ? "-" : entry.section} • ${_clockText(callTime)}'
        : (entry.isDialed
            ? '${entry.callerRole ?? "Staff"} • ${_clockText(callTime)}'
            : '${entry.customerName} (${entry.callerRole ?? "Staff"}) • ${_clockText(callTime)}');

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: CircleAvatar(
          radius: 22,
          backgroundColor: entry.isDialed
              ? (entry.isDialedAnswered ? const Color(0xFFEAF8F1) : const Color(0xFFF1F5F9))
              : (entry.isAccepted
                  ? const Color(0xFFEAF8F1)
                  : entry.isDeclined
                      ? const Color(0xFFFDECEC)
                      : const Color(0xFFFFF5E5)),
          child: Icon(
            statusIcon,
            color: statusColor,
            size: 20,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                titleText,
                style: const TextStyle(
                  color: Color(0xFF1E293B),
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: isTable
                    ? const Color(0xFFF0FDF4)
                    : (entry.isDialed ? const Color(0xFFF0F9FF) : const Color(0xFFEFF6FF)),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isTable
                      ? const Color(0xFF86EFAC)
                      : (entry.isDialed ? const Color(0xFFBAE6FD) : const Color(0xFF93C5FD)),
                ),
              ),
              child: Text(
                isTable
                    ? 'TABLE SOS'
                    : (entry.isDialed ? 'DIALED' : 'VOICE CALL'),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: isTable
                      ? const Color(0xFF15803D)
                      : (entry.isDialed ? const Color(0xFF0284C7) : const Color(0xFF1D4ED8)),
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                subtitleText,
                style: const TextStyle(
                  color: Color(0xFF64748B),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 3),
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    statusText,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        onTap: !isTable ? () => _callBackUser(entry) : null,
        trailing: !isTable
            ? InkWell(
                onTap: () => _callBackUser(entry),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAF8F1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF86EFAC)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.call_rounded,
                        color: Color(0xFF15803D),
                        size: 15,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'Call',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF15803D),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : const Icon(
                Icons.room_service_outlined,
                color: Color(0xFF94A3B8),
                size: 22,
              ),
      ),
    );
  }
}
