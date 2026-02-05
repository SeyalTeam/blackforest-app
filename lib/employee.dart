import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:blackforest_app/common_scaffold.dart'; // Added import for header/footer consistency

class EmployeePage extends StatefulWidget {
  const EmployeePage({super.key});

  @override
  State<EmployeePage> createState() => _EmployeePageState();
}

class _EmployeePageState extends State<EmployeePage> {
  // String _userName = 'Unknown'; // Assigned but unused
  // DateTime _loginTime = DateTime.now(); // Assigned but unused
  Timer? _timer;
  Duration _workingDuration = Duration.zero;
  Duration _breakDuration = Duration.zero;

  List<Map<String, dynamic>> _activities =
      []; // List of punch in/out/break entries
  bool _isPunchedIn = false; // Track current state
  DateTime? _currentPunchInTime; // For calculating on punch out

  @override
  void initState() {
    super.initState();
    _loadUserData();
    _startWorkingTimer();
    // Load previous activities if stored (e.g., from backend or prefs)
    _activities = [
      {
        'type': 'in',
        'time': DateTime.now().subtract(const Duration(hours: 1, minutes: 25)),
      }, // Example data from screenshot
      {
        'type': 'out',
        'time': DateTime.now().subtract(const Duration(hours: 1, minutes: 4)),
      },
      {'type': 'break', 'duration': const Duration(minutes: 51)},
      {
        'type': 'in',
        'time': DateTime.now().subtract(const Duration(minutes: 44)),
      },
      {
        'type': 'out',
        'time': DateTime.now().subtract(const Duration(minutes: 40)),
      },
    ];
    _calculateTotals(); // Initial calculation based on activities
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadUserData() async {
    // Assuming name is derived from email or stored separately; adjust if you have 'name' field
    // setState(() {
    //   _userName = email.split('@')[0]; // Simple derivation; replace with actual name if available
    // });
    // Fetch login time if stored (e.g., prefs.setString('loginTime', DateTime.now().toIso8601String()) in login)
    // final loginTimeStr = prefs.getString('loginTime');
    // if (loginTimeStr != null) {
    //   _loginTime = DateTime.parse(loginTimeStr);
    // }
  }

  void _startWorkingTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isPunchedIn && _currentPunchInTime != null) {
        setState(() {
          _workingDuration = DateTime.now().difference(_currentPunchInTime!);
        });
      }
    });
  }

  void _calculateTotals() {
    Duration totalWorking = Duration.zero;
    Duration totalBreak = Duration.zero;
    DateTime? lastInTime;

    for (var activity in _activities) {
      if (activity['type'] == 'in') {
        lastInTime = activity['time'];
      } else if (activity['type'] == 'out' && lastInTime != null) {
        totalWorking += activity['time'].difference(lastInTime);
        lastInTime = null;
      } else if (activity['type'] == 'break') {
        totalBreak += activity['duration'];
      }
    }

    // Add current ongoing punch-in if active
    if (_isPunchedIn && _currentPunchInTime != null) {
      totalWorking += DateTime.now().difference(_currentPunchInTime!);
    }

    setState(() {
      _workingDuration = totalWorking;
      _breakDuration = totalBreak;
    });
  }

  /*
  void _punchIn() {
    if (!_isPunchedIn) {
      final now = DateTime.now();
      setState(() {
        _isPunchedIn = true;
        _currentPunchInTime = now;
        _activities.add({'type': 'in', 'time': now});
      });
      _calculateTotals();
    }
  }

  void _punchOut() {
    if (_isPunchedIn) {
      final now = DateTime.now();
      setState(() {
        _isPunchedIn = false;
        _activities.add({'type': 'out', 'time': now});
        _currentPunchInTime = null;
      });
      _calculateTotals();
    }
  }

  void _startBreak() {
    // Simulate break; add logic for break duration calculation if needed
    // For now, add a placeholder break (e.g., from screenshot: 51 min)
    setState(() {
      _activities.add({
        'type': 'break',
        'duration': const Duration(minutes: 51),
      });
    });
    _calculateTotals();
  }
  */

  String _formatDuration(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final mins = (d.inMinutes % 60).toString().padLeft(2, '0');
    final secs = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours : $mins : $secs';
  }

  String _formatBreak(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final mins = (d.inMinutes % 60).toString().padLeft(2, '0');
    return '${hours}h:${mins}m';
  }

  @override
  Widget build(BuildContext context) {
    // final currentDate = DateFormat('dd MMMM yyyy').format(DateTime.now()); // Unused

    return CommonScaffold(
      // Wrapped with CommonScaffold for header/footer consistency
      title: 'Employee Dashboard', // Custom title; adjust as needed
      pageType: PageType.employee, // Repurposed from home to employee
      onScanCallback:
          null, // No scan needed; set to null or a callback if required
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Card(
                  color: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        const Text(
                          'Working Hours',
                          style: TextStyle(color: Colors.white, fontSize: 16),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _formatDuration(_workingDuration),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            Text(
                              'Hour',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              'Min',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              'Sec',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                color: Colors.orange[100],
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.coffee, color: Colors.orange),
                      const SizedBox(width: 8),
                      Text(
                        'Total Break Time ${_formatBreak(_breakDuration)}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                color: Colors.blue[50],
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.access_time, color: Colors.blue),
                      const SizedBox(width: 8),
                      const Text(
                        'First shift timing is 10:00 am - 07:00 pm',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Your activity',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _activities.length,
                itemBuilder: (context, index) {
                  final activity = _activities[index];
                  if (activity['type'] == 'break') {
                    return Card(
                      color: Colors.yellow[100],
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Center(
                          child: Text(
                            '${activity['duration'].inMinutes} Min Break',
                            style: const TextStyle(color: Colors.orange),
                          ),
                        ),
                      ),
                    );
                  }
                  final isIn = activity['type'] == 'in';
                  final color = isIn ? Colors.green[100] : Colors.red[100];
                  final icon = isIn ? Icons.arrow_forward : Icons.arrow_back;
                  final label = isIn ? 'Punch In' : 'Punch Out';
                  final time = DateFormat('hh:mm a').format(activity['time']);
                  return Card(
                    color: color,
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Row(
                        children: [
                          Icon(icon, color: isIn ? Colors.green : Colors.red),
                          const SizedBox(width: 8),
                          Text(
                            label,
                            style: TextStyle(
                              color: isIn ? Colors.green : Colors.red,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          Text(time),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
