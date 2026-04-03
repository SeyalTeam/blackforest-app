import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/printer/bluetooth_printer_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
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
  bool _isCheckingLocation = true;
  bool _isLocationEnabled = false;
  bool _hasLocationPermission = false;
  String? _branchName;
  String? _printerName;
  String? _wifiPrinterIp;

  @override
  void initState() {
    super.initState();
    _loadSettingsSummary();
  }

  Future<void> _loadSettingsSummary() async {
    final prefs = await SharedPreferences.getInstance();

    if (mounted) {
      setState(() {
        _branchName = prefs.getString('branchName');
        _printerName = prefs.getString('bt_printer_name');
        _wifiPrinterIp = prefs.getString('printerIp');
        _isCheckingBluetooth = true;
        _isCheckingLocation = true;
      });
    }

    bool isBluetoothConnected = false;
    bool isLocationEnabled = false;
    bool hasLocationPermission = false;
    try {
      isBluetoothConnected = await PrintBluetoothThermal.connectionStatus
          .timeout(const Duration(seconds: 2), onTimeout: () => false);
    } catch (_) {
      isBluetoothConnected = false;
    }

    try {
      isLocationEnabled = await Geolocator.isLocationServiceEnabled().timeout(
        const Duration(seconds: 2),
        onTimeout: () => false,
      );
      final permission = await Geolocator.checkPermission().timeout(
        const Duration(seconds: 2),
        onTimeout: () => LocationPermission.denied,
      );
      hasLocationPermission =
          permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
    } catch (_) {
      isLocationEnabled = false;
      hasLocationPermission = false;
    }

    if (!mounted) return;
    setState(() {
      _isBluetoothConnected = isBluetoothConnected;
      if (!isBluetoothConnected) {
        _printerName = prefs.getString('bt_printer_name');
      }
      _isCheckingBluetooth = false;
      _isLocationEnabled = isLocationEnabled;
      _hasLocationPermission = hasLocationPermission;
      _isCheckingLocation = false;
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

  Future<void> _handleLocationCardTap() async {
    if (_isCheckingLocation) return;

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        await Geolocator.openLocationSettings();
        await _loadSettingsSummary();
        return;
      }

      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        await Geolocator.requestPermission();
        await _loadSettingsSummary();
        return;
      }

      if (permission == LocationPermission.deniedForever) {
        await Geolocator.openAppSettings();
        await _loadSettingsSummary();
        return;
      }

      await _loadSettingsSummary();
    } catch (_) {
      await _loadSettingsSummary();
    }
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

  Widget _buildWifiPrinterStatusCard() {
    final wifiPrinterIp = _wifiPrinterIp?.trim() ?? '';
    final hasWifiPrinter = wifiPrinterIp.isNotEmpty;

    return Container(
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
                Icons.wifi_rounded,
                color: hasWifiPrinter
                    ? const Color(0xFF1BA672)
                    : Colors.black87,
                size: 24,
              ),
              if (!hasWifiPrinter)
                const Positioned(
                  top: -2,
                  right: -2,
                  child: Icon(Icons.close, color: Colors.red, size: 10),
                ),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'WiFi Printer',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  hasWifiPrinter
                      ? 'IP: $wifiPrinterIp'
                      : 'WiFi printer not connected',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          if (hasWifiPrinter)
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
                Icon(Icons.wifi_rounded, color: Color(0xFF1BA672), size: 16),
              ],
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.grey[400]!),
              ),
              child: const Text(
                'Not connected',
                style: TextStyle(
                  color: Colors.black54,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLocationStatusCard() {
    final isLocationReady =
        !_isCheckingLocation && _isLocationEnabled && _hasLocationPermission;
    final branchLabel = (_branchName?.trim().isNotEmpty ?? false)
        ? _branchName!
        : 'Branch Location';
    final statusText = _isCheckingLocation
        ? 'Checking location status...'
        : isLocationReady
        ? 'Location enabled'
        : !_isLocationEnabled
        ? 'Location service disabled'
        : 'Location permission not allowed';

    return InkWell(
      onTap: _handleLocationCardTap,
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  Icons.location_on_outlined,
                  color: isLocationReady
                      ? const Color(0xFF1BA672)
                      : Colors.black87,
                  size: 24,
                ),
                if (!_isCheckingLocation && !isLocationReady)
                  const Positioned(
                    top: -2,
                    right: -2,
                    child: Icon(Icons.close, color: Colors.red, size: 10),
                  ),
              ],
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    branchLabel,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    statusText,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            if (_isCheckingLocation)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF1BA672),
                ),
              )
            else if (isLocationReady)
              const Row(
                children: [
                  Icon(Icons.check, color: Color(0xFF1BA672), size: 16),
                  SizedBox(width: 4),
                  Text(
                    'Enabled',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.black54,
                    ),
                  ),
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
                  'Enable',
                  style: TextStyle(
                    color: Color(0xFF1BA672),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
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
            const SizedBox(height: 16),
            _buildWifiPrinterStatusCard(),
            const SizedBox(height: 16),
            _buildLocationStatusCard(),
          ],
        ),
      ),
    );
  }
}
