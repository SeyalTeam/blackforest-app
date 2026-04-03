import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/printer/bluetooth_printer_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';

class EmployeeSettingsPage extends StatefulWidget {
  const EmployeeSettingsPage({super.key});

  @override
  State<EmployeeSettingsPage> createState() => _EmployeeSettingsPageState();
}

class _EmployeeSettingsPageState extends State<EmployeeSettingsPage> {
  bool _isCheckingBluetooth = true;
  bool _isBluetoothConnected = false;
  String? _printerName;

  @override
  void initState() {
    super.initState();
    _loadSettingsSummary();
  }

  Future<void> _loadSettingsSummary() async {
    final prefs = await SharedPreferences.getInstance();

    if (mounted) {
      setState(() {
        _printerName = prefs.getString('bt_printer_name');
        _isCheckingBluetooth = true;
      });
    }

    bool isBluetoothConnected = false;
    try {
      isBluetoothConnected = await PrintBluetoothThermal.connectionStatus
          .timeout(const Duration(seconds: 2), onTimeout: () => false);
    } catch (_) {
      isBluetoothConnected = false;
    }

    if (!mounted) return;
    setState(() {
      _isBluetoothConnected = isBluetoothConnected;
      if (!isBluetoothConnected) {
        _printerName = prefs.getString('bt_printer_name');
      }
      _isCheckingBluetooth = false;
    });
  }

  Future<void> _openPrinterSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const BluetoothPrinterSettingsPage(),
      ),
    );
    _loadSettingsSummary();
  }

  Widget _buildBluetoothStatusCard() {
    return InkWell(
      onTap: _openPrinterSettings,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey[200]!),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  Icons.print,
                  color: _isBluetoothConnected
                      ? const Color(0xFF1BA672)
                      : Colors.black87,
                  size: 24,
                ),
                if (!_isBluetoothConnected)
                  const Positioned(
                    top: -2,
                    right: -2,
                    child: Icon(Icons.close, color: Colors.red, size: 10),
                  ),
              ],
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                _isCheckingBluetooth
                    ? ((_printerName?.trim().isNotEmpty ?? false)
                          ? _printerName!
                          : 'Bluetooth settings')
                    : _isBluetoothConnected &&
                          (_printerName?.trim().isNotEmpty ?? false)
                    ? _printerName!
                    : 'Device not connected',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ),
            if (_isCheckingBluetooth)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF1BA672),
                ),
              )
            else if (_isBluetoothConnected)
              const Row(
                children: [
                  Icon(Icons.check, color: Color(0xFF1BA672), size: 16),
                  SizedBox(width: 4),
                  Text(
                    'Connected',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.black54,
                    ),
                  ),
                  SizedBox(width: 8),
                  Icon(Icons.bluetooth, color: Color(0xFF1BA672), size: 16),
                ],
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF1BA672)),
                ),
                child: const Text(
                  'Connect',
                  style: TextStyle(
                    color: Color(0xFF1BA672),
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Settings',
      pageType: PageType.employee,
      hideBottomNavigationBar: true,
      showBackButtonInAppBar: true,
      showDefaultAppBarActions: false,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        color: const Color(0xFFF8F9FA),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          children: [
            const Text(
              'Settings',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 24),
            _buildBluetoothStatusCard(),
          ],
        ),
      ),
    );
  }
}
