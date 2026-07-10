import 'package:blackforest_app/waiter_call_history_service.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class WaiterCallHistoryPage extends StatefulWidget {
  const WaiterCallHistoryPage({super.key});

  @override
  State<WaiterCallHistoryPage> createState() => _WaiterCallHistoryPageState();
}

class _WaiterCallHistoryPageState extends State<WaiterCallHistoryPage> {
  bool _isLoading = true;
  String? _error;
  List<WaiterCallHistoryEntry> _entries = const <WaiterCallHistoryEntry>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }
    try {
      final entries = await WaiterCallHistoryService.readHistory();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Unable to load call logs';
      });
    }
  }

  String _groupLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final diffDays = today.difference(day).inDays;
    if (diffDays == 0) return 'Today';
    if (diffDays == 1) return 'Yesterday';
    return DateFormat('dd MMM yyyy').format(date);
  }

  String _clockText(DateTime date) {
    return DateFormat('h:mm a').format(date);
  }

  List<Widget> _buildHistoryList() {
    final children = <Widget>[];
    String? lastGroup;

    for (final entry in _entries) {
      final callTime = entry.callTime ?? entry.createdAt ?? DateTime.now();
      final group = _groupLabel(callTime);
      if (group != lastGroup) {
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Text(
              group,
              style: const TextStyle(
                color: Color(0xFF53657D),
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
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
    final statusColor = entry.isAccepted
        ? const Color(0xFF14804A)
        : entry.isDeclined
        ? const Color(0xFFC53030)
        : const Color(0xFFB26B00);
    final statusText = entry.isAccepted
        ? 'Accepted'
        : entry.isDeclined
        ? 'Declined'
        : 'Missed';
    final whoText = entry.isAccepted && (entry.acknowledgedBy ?? '').isNotEmpty
        ? ' by ${entry.acknowledgedBy}'
        : '';
    final sectionText = entry.section.trim().isEmpty ? '-' : entry.section;
    final customerText = entry.customerName.trim().isEmpty
        ? 'Guest'
        : entry.customerName;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE9EDF3)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: CircleAvatar(
          radius: 20,
          backgroundColor: entry.isAccepted
              ? const Color(0xFFEAF8F1)
              : entry.isDeclined
              ? const Color(0xFFFDECEC)
              : const Color(0xFFFFF5E5),
          child: Icon(
            entry.isAccepted
                ? Icons.call_received_rounded
                : entry.isDeclined
                ? Icons.call_end_rounded
                : Icons.call_missed,
            color: statusColor,
            size: 20,
          ),
        ),
        title: Text(
          'Table ${entry.tableNumber}',
          style: const TextStyle(
            color: Color(0xFF1F2937),
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$customerText • Section $sectionText • ${_clockText(callTime)}',
                style: const TextStyle(
                  color: Color(0xFF667085),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '$statusText$whoText',
                style: TextStyle(
                  color: statusColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        trailing: const Icon(Icons.call_outlined, color: Color(0xFF4A5568)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Call History',
          style: TextStyle(color: Colors.black87, fontWeight: FontWeight.w700),
        ),
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
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
                  ElevatedButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
            )
          : _entries.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.call_outlined, size: 56, color: Color(0xFF97A2B2)),
                  SizedBox(height: 10),
                  Text(
                    'No call logs yet',
                    style: TextStyle(
                      color: Color(0xFF667085),
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 20),
                children: _buildHistoryList(),
              ),
            ),
    );
  }
}
