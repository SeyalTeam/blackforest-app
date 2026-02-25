import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:intl/intl.dart';

class EmployeePage extends StatefulWidget {
  const EmployeePage({super.key});

  @override
  State<EmployeePage> createState() => _EmployeePageState();
}

class _EmployeePageState extends State<EmployeePage> {
  bool _profileLoading = true;
  String? _employeeName;
  String? _employeeRole;
  String? _employeeId;
  String? _employeePhotoUrl;
  String? _branchName;

  Timer? _timer;
  Duration _workDuration = Duration.zero;
  Duration _breakDuration = Duration.zero;
  List<Map<String, dynamic>> _activities = [];

  @override
  void initState() {
    super.initState();
    _loadEmployeeData();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadEmployeeData() async {
    final prefs = await SharedPreferences.getInstance();
    final loginTimeMs = prefs.getInt('login_time');

    setState(() {
      _employeeName =
          prefs.getString('employee_name') ?? prefs.getString('user_name');
      _employeeRole = prefs.getString('role');
      _employeeId = prefs.getString('employee_code');
      _employeePhotoUrl = prefs.getString('employee_photo_url');
      _branchName = prefs.getString('branchName');
      _profileLoading = false;

      if (loginTimeMs != null) {
        // Fallback or initial set
        final loginTime = DateTime.fromMillisecondsSinceEpoch(loginTimeMs);
        if (_workDuration == Duration.zero) {
          _workDuration = DateTime.now().difference(loginTime);
        }
      }
    });

    await _fetchAttendance();
  }

  Future<void> _fetchAttendance() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    final userId = prefs.getString('user_id');

    if (token == null || userId == null) return;

    final now = DateTime.now();
    final localMidnight = DateTime(now.year, now.month, now.day);
    // Fetch logs from today and yesterday to be safe
    final queryDate = localMidnight
        .subtract(const Duration(days: 1))
        .toUtc()
        .toIso8601String();

    try {
      final response = await http.get(
        Uri.parse(
          'https://blackforest.vseyal.com/api/attendance?where[user][equals]=$userId&where[date][greater_than_equal]=$queryDate&sort=-date&limit=10',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final docs = data['docs'] as List;

        List<Map<String, dynamic>> allActivities = [];
        Duration totalWork = Duration.zero;
        Duration totalBreak = Duration.zero;

        // docs here will be the Daily Log documents (usually just one for today)
        for (var doc in docs) {
          final activities = doc['activities'] as List? ?? [];

          for (var activity in activities) {
            final type = activity['type'];
            final punchInStr = activity['punchIn'];
            final punchOutStr = activity['punchOut'];
            final status = activity['status'];
            final durationSeconds = activity['durationSeconds'] as int? ?? 0;

            if (punchInStr == null) continue;

            final punchIn = DateTime.parse(punchInStr).toLocal();
            final punchOut = punchOutStr != null
                ? DateTime.parse(punchOutStr).toLocal()
                : null;
            final inTimeStr = DateFormat('hh:mm a').format(punchIn);
            final outTimeStr = punchOut != null
                ? DateFormat('hh:mm a').format(punchOut)
                : 'Active';

            if (type == 'session') {
              final duration = punchOut != null
                  ? Duration(
                      seconds: durationSeconds > 0
                          ? durationSeconds
                          : punchOut.difference(punchIn).inSeconds,
                    )
                  : DateTime.now().difference(punchIn);

              totalWork += duration;

              // Only show if it overlaps with today
              if (punchIn.isAfter(localMidnight) ||
                  (punchOut != null && punchOut.isAfter(localMidnight))) {
                allActivities.add({
                  'type': 'session',
                  'inTime': inTimeStr,
                  'outTime': outTimeStr,
                  'color': Colors.white,
                  'startTime': punchIn,
                  'isActive': status == 'active',
                });
              }

              // If active, start the timer
              if (status == 'active') {
                final activeStart = punchIn;
                final pastWork =
                    totalWork - DateTime.now().difference(activeStart);

                _timer?.cancel();
                _timer = Timer.periodic(const Duration(seconds: 1), (_) {
                  if (mounted) {
                    setState(() {
                      _workDuration =
                          pastWork + DateTime.now().difference(activeStart);
                    });
                  }
                });
              }
            } else if (type == 'break') {
              final duration = punchOut != null
                  ? Duration(
                      seconds: durationSeconds > 0
                          ? durationSeconds
                          : punchOut.difference(punchIn).inSeconds,
                    )
                  : Duration.zero;

              totalBreak += duration;

              if (punchIn.isAfter(localMidnight)) {
                allActivities.add({
                  'type': 'break',
                  'title': duration.inMinutes > 0
                      ? '${duration.inMinutes} Min Break'
                      : '${duration.inSeconds} Sec Break',
                  'color': const Color(0xFFFFE0B2),
                  'textColor': Colors.orange[900],
                  'startTime': punchIn,
                });
              }
            }
          }
        }

        if (allActivities.where((s) => s['isActive'] == true).isEmpty) {
          _timer?.cancel();
        }

        if (mounted) {
          setState(() {
            allActivities.sort(
              (a, b) => (b['startTime'] as DateTime).compareTo(
                a['startTime'] as DateTime,
              ),
            );
            _activities = allActivities;
            _workDuration = totalWork;
            _breakDuration = totalBreak;
          });
        }
      }
    } catch (e) {
      debugPrint("Error fetching attendance: $e");
    }
  }

  String _formatTwoDigits(int n) {
    return n.toString().padLeft(2, '0');
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Profile',
      pageType: PageType.employee,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        color: const Color(0xFFF8F9FA),
        child: _profileLoading
            ? const Center(child: CircularProgressIndicator(color: Colors.blue))
            : SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24.0, 10.0, 24.0, 40.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.grey[300]!, width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 20,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                      child: Center(
                        child: CircleAvatar(
                          radius: 50,
                          backgroundColor: Colors.white,
                          backgroundImage:
                              _employeePhotoUrl != null &&
                                  _employeePhotoUrl!.isNotEmpty
                              ? NetworkImage(_employeePhotoUrl!)
                              : null,
                          child:
                              _employeePhotoUrl == null ||
                                  _employeePhotoUrl!.isEmpty
                              ? Icon(
                                  Icons.person,
                                  size: 50,
                                  color: Colors.grey[400],
                                )
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(height: 15),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_employeeId != null && _employeeId!.isNotEmpty) ...[
                          Text(
                            'ID: $_employeeId',
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '|',
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          _employeeName ?? 'User',
                          style: const TextStyle(
                            color: Colors.black87,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '|',
                          style: TextStyle(
                            color: Colors.grey[400],
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey[100],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey[300]!),
                          ),
                          child: Text(
                            (_employeeRole ?? 'Role').toUpperCase(),
                            style: TextStyle(
                              color: Colors.grey[700],
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_branchName != null && _branchName!.isNotEmpty)
                      Center(
                        child: Text(
                          _branchName!,
                          style: const TextStyle(
                            color: Colors.blue,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),

                    // Working Hours Card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 20,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        children: [
                          const Text(
                            'Working Hours',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _formatTwoDigits(_workDuration.inHours),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 32,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 6),
                                child: Text(
                                  ':',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 28,
                                    fontWeight: FontWeight.w300,
                                  ),
                                ),
                              ),
                              Text(
                                _formatTwoDigits(_workDuration.inMinutes % 60),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 32,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 6),
                                child: Text(
                                  ':',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 28,
                                    fontWeight: FontWeight.w300,
                                  ),
                                ),
                              ),
                              Text(
                                _formatTwoDigits(_workDuration.inSeconds % 60),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 32,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          const Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              Text(
                                'Hour',
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 10,
                                ),
                              ),
                              Text(
                                'Min',
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 10,
                                ),
                              ),
                              Text(
                                'Sec',
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Break Time & Shift
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 16,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFE0B2), // Light Orange
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.orange.withOpacity(0.1),
                            blurRadius: 5,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.coffee, color: Colors.orange[800]),
                          const SizedBox(width: 12),
                          Text(
                            'Total Break Time ${_formatTwoDigits(_breakDuration.inHours)}h:${_formatTwoDigits(_breakDuration.inMinutes % 60)}m',
                            style: const TextStyle(
                              color: Colors.black87,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Your activity',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Activity List
                    ..._activities.map((activity) {
                      if (activity['type'] == 'break') {
                        // Break Box
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: activity['color'],
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: Text(
                              activity['title'],
                              style: TextStyle(
                                color: activity['textColor'],
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                          ),
                        );
                      } else {
                        // Session Box (In + Out)
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.grey[200]!),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.03),
                                blurRadius: 10,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: IntrinsicHeight(
                            child: Row(
                              children: [
                                // Left: Punch In
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: Colors.green.withOpacity(0.1),
                                      borderRadius: const BorderRadius.only(
                                        topLeft: Radius.circular(12),
                                        bottomLeft: Radius.circular(12),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            const Icon(
                                              Icons.login,
                                              size: 18,
                                              color: Colors.green,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              "Punch In",
                                              style: TextStyle(
                                                color: Colors.green[800],
                                                fontWeight: FontWeight.bold,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          activity['inTime'],
                                          style: const TextStyle(
                                            color: Colors.black87,
                                            fontWeight: FontWeight.w600,
                                            fontSize: 16,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                // Divider
                                Container(width: 1, color: Colors.grey[300]),
                                // Right: Punch Out
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: activity['isActive'] == true
                                          ? Colors.white
                                          : Colors.red.withOpacity(0.08),
                                      borderRadius: const BorderRadius.only(
                                        topRight: Radius.circular(12),
                                        bottomRight: Radius.circular(12),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.logout,
                                              size: 18,
                                              color:
                                                  activity['isActive'] == true
                                                  ? Colors.grey
                                                  : Colors.red,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              "Punch Out",
                                              style: TextStyle(
                                                color:
                                                    activity['isActive'] == true
                                                    ? Colors.grey[600]
                                                    : Colors.red[800],
                                                fontWeight: FontWeight.bold,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          activity['outTime'],
                                          style: TextStyle(
                                            color: activity['isActive'] == true
                                                ? Colors.green[700]
                                                : Colors.red[700],
                                            fontWeight: FontWeight.w600,
                                            fontSize: 16,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }
                    }),
                  ],
                ),
              ),
      ),
    );
  }
}
