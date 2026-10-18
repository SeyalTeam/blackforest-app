import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'waiter_call_history_service.dart';
import 'waiter_live_call_service.dart';

enum _WaiterCallFilter {
  all,
  dialed,
  received,
  missed,
  tableOnly,
}

class WaiterCallHistoryPage extends StatefulWidget {
  const WaiterCallHistoryPage({super.key});

  @override
  State<WaiterCallHistoryPage> createState() => _WaiterCallHistoryPageState();
}

class _WaiterCallHistoryPageState extends State<WaiterCallHistoryPage> {
  bool _isLoading = true;
  String? _error;
  List<WaiterCallHistoryEntry> _allEntries = const <WaiterCallHistoryEntry>[];
  _WaiterCallFilter _activeFilter = _WaiterCallFilter.all;
  DateTime? _selectedDateFilter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool showLoader = true}) async {
    if (showLoader && mounted) {
      setState(() {
        _isLoading = _allEntries.isEmpty;
        _error = null;
      });
    }
    try {
      // 1. Instant local read so screen is populated immediately
      final cached = await WaiterCallHistoryService.readHistory(syncRemote: false);
      if (mounted && cached.isNotEmpty) {
        setState(() {
          _allEntries = cached;
          _isLoading = false;
        });
      }

      // 2. Sync permanent history from backend (table calls + voice calls)
      final remote = await WaiterCallHistoryService.syncHistoryFromBackend();
      if (!mounted) return;
      setState(() {
        _allEntries = remote;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        if (_allEntries.isEmpty) {
          _error = 'Unable to load call logs';
        }
      });
    }
  }

  List<WaiterCallHistoryEntry> get _filteredEntries {
    return _allEntries.where((entry) {
      // 1. Filter by top category buttons
      switch (_activeFilter) {
        case _WaiterCallFilter.all:
          break;
        case _WaiterCallFilter.dialed:
          if (!entry.isDialed) return false;
          break;
        case _WaiterCallFilter.received:
          if (!entry.isReceived) return false;
          break;
        case _WaiterCallFilter.missed:
          if (!entry.isIncomingMissed) return false;
          break;
        case _WaiterCallFilter.tableOnly:
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

      return true;
    }).toList();
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

  List<Widget> _buildHistoryList() {
    final children = <Widget>[];
    final entries = _filteredEntries;
    String? lastGroup;

    for (final entry in entries) {
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
    return children;
  }

  Widget _buildHistoryCard(WaiterCallHistoryEntry entry) {
    final callTime = entry.callTime ?? entry.createdAt ?? DateTime.now();
    final isTable = entry.isTableCall;

    // Status colors & icons
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
        : (entry.isDialed ? entry.customerName : 'Admin Live Call');
    final subtitleText = isTable
        ? '${entry.customerName.isEmpty ? "Guest" : entry.customerName} • Section ${entry.section.isEmpty ? "-" : entry.section} • ${_clockText(callTime)}'
        : (entry.isDialed
            ? '${entry.callerRole ?? "Super Admin"} • ${_clockText(callTime)}'
            : '${entry.customerName} (${entry.callerRole ?? "Super Admin"}) • ${_clockText(callTime)}');

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
        onTap: !isTable ? () => _callBackAdmin(entry) : null,
        trailing: !isTable
            ? InkWell(
                onTap: () => _callBackAdmin(entry),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAF8F1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF86EFAC)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
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
            : Icon(
                Icons.room_service_outlined,
                color: const Color(0xFF94A3B8),
                size: 22,
              ),
      ),
    );
  }

  Future<void> _callBackAdmin(WaiterCallHistoryEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final myUserId = (prefs.getString('user_id') ?? prefs.getString('userId'))?.trim() ?? '';

    String? adminId = entry.callerUserId;
    if (adminId == null || adminId.isEmpty || adminId == myUserId) {
      adminId = await WaiterCallHistoryService.getLastAdminUserId();
    }
    if (adminId == null || adminId.isEmpty || adminId == myUserId) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot call back: Admin contact ID unavailable.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final adminName = entry.customerName.isNotEmpty ? entry.customerName : 'Super Admin';
    try {
      await WaiterLiveCallService.instance.startCallToAdmin(
        adminUserId: adminId,
        adminName: adminName,
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

  Widget _buildTopFilterButton({
    required _WaiterCallFilter filter,
    required String label,
    required IconData icon,
    int? count,
    Color? countColor,
  }) {
    final isSelected = _activeFilter == filter;

    return InkWell(
      onTap: () {
        setState(() {
          _activeFilter = filter;
        });
      },
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF0F766E) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? const Color(0xFF0F766E) : const Color(0xFFCBD5E1),
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
              size: 15,
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
            if (count != null && count > 0) ...[
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

  @override
  Widget build(BuildContext context) {
    final dialedCount = _allEntries.where((e) => e.isDialed).length;
    final missedCount = _allEntries.where((e) => e.isIncomingMissed).length;
    final receivedCount = _allEntries.where((e) => e.isReceived).length;
    final tableCount = _allEntries.where((e) => e.isTableCall).length;
    final filtered = _filteredEntries;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Call History',
          style: TextStyle(
            color: Color(0xFF0F172A),
            fontWeight: FontWeight.w800,
            fontSize: 19,
          ),
        ),
        iconTheme: const IconThemeData(color: Color(0xFF0F172A)),
        actions: [
          // DATE FILTER BUTTON (Look previous dates permanently)
          IconButton(
            tooltip: 'Filter by Date (Look previous days)',
            icon: Icon(
              _selectedDateFilter != null
                  ? Icons.calendar_month
                  : Icons.calendar_month_outlined,
              color: _selectedDateFilter != null
                  ? const Color(0xFF0F766E)
                  : const Color(0xFF475569),
            ),
            onPressed: _pickDateFilter,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF475569)),
            onPressed: _load,
          ),
        ],
      ),
      body: Column(
        children: [
          // TOP CATEGORY BUTTONS: All | Dialed | Received | Missed | Table Calling
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildTopFilterButton(
                    filter: _WaiterCallFilter.all,
                    label: 'Call History',
                    icon: Icons.history_rounded,
                    count: _allEntries.isNotEmpty ? _allEntries.length : null,
                  ),
                  const SizedBox(width: 8),
                  _buildTopFilterButton(
                    filter: _WaiterCallFilter.dialed,
                    label: 'Dialed',
                    icon: Icons.call_made_rounded,
                    count: dialedCount > 0 ? dialedCount : null,
                    countColor: const Color(0xFF0284C7),
                  ),
                  const SizedBox(width: 8),
                  _buildTopFilterButton(
                    filter: _WaiterCallFilter.received,
                    label: 'Received',
                    icon: Icons.call_received_rounded,
                    count: receivedCount > 0 ? receivedCount : null,
                    countColor: const Color(0xFF14804A),
                  ),
                  const SizedBox(width: 8),
                  _buildTopFilterButton(
                    filter: _WaiterCallFilter.missed,
                    label: 'Missed',
                    icon: Icons.call_missed_rounded,
                    count: missedCount > 0 ? missedCount : null,
                    countColor: Colors.redAccent,
                  ),
                  const SizedBox(width: 8),
                  _buildTopFilterButton(
                    filter: _WaiterCallFilter.tableOnly,
                    label: 'Table Calling',
                    icon: Icons.room_service_rounded,
                    count: tableCount > 0 ? tableCount : null,
                    countColor: const Color(0xFF0F766E),
                  ),
                ],
              ),
            ),
          ),

          // ACTIVE DATE FILTER CHIP (if user selected previous date)
          if (_selectedDateFilter != null)
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

          // MAIN LOGS LIST
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF0F766E)))
                : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _error!,
                          style: const TextStyle(
                            color: Color(0xFF4B5563),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: _load,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0F766E),
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                : filtered.isEmpty
                ? RefreshIndicator(
                    onRefresh: _load,
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: Container(
                        height: MediaQuery.of(context).size.height * 0.6,
                        alignment: Alignment.center,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _activeFilter == _WaiterCallFilter.dialed
                                  ? Icons.call_made_rounded
                                  : (_activeFilter == _WaiterCallFilter.missed
                                      ? Icons.phone_missed_rounded
                                      : (_activeFilter == _WaiterCallFilter.received
                                          ? Icons.phone_in_talk_rounded
                                          : (_activeFilter == _WaiterCallFilter.tableOnly
                                              ? Icons.room_service_outlined
                                              : Icons.call_outlined))),
                              size: 56,
                              color: const Color(0xFF94A3B8),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _activeFilter == _WaiterCallFilter.dialed
                                  ? 'No dialed calls recorded'
                                  : (_activeFilter == _WaiterCallFilter.missed
                                      ? 'No missed calls recorded'
                                      : (_activeFilter == _WaiterCallFilter.received
                                          ? 'No received calls recorded'
                                          : (_activeFilter == _WaiterCallFilter.tableOnly
                                              ? 'No table calling requests recorded'
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
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.only(bottom: 24),
                      children: _buildHistoryList(),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
