import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/printer/bluetooth_printer_settings_page.dart';
import 'package:blackforest_app/printer/thermal_print_prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';

class EmployeeSettingsPage extends StatefulWidget {
  const EmployeeSettingsPage({super.key});

  @override
  State<EmployeeSettingsPage> createState() => _EmployeeSettingsPageState();
}

class _EmployeeSettingsPageState extends State<EmployeeSettingsPage> {
  static const MethodChannel _locationChannel = MethodChannel(
    'blackforest.app/location',
  );

  bool _isCheckingBluetooth = true;
  bool _isBluetoothConnected = false;
  bool _isCheckingWifiPrinter = true;
  bool _isWifiPrinterConnected = false;
  bool _isCheckingLocation = true;
  bool _isLocationEnabled = false;
  bool _hasLocationPermission = false;
  bool _isReviewPrintEnabled = true;
  String? _branchName;
  String? _branchIpRange;
  String? _deviceWifiIp;
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
        _branchIpRange = prefs.getString('branchIp');
        _printerName = prefs.getString('bt_printer_name');
        _wifiPrinterIp = prefs.getString('printerIp');
        _isReviewPrintEnabled = isThermalReviewPrintEnabled(prefs);
      });
    }

    await Future.wait<void>([
      _refreshBluetoothStatus(prefs: prefs),
      _refreshWifiPrinterStatus(prefs: prefs),
      _refreshLocationStatus(),
    ]);
  }

  Future<void> _refreshWifiPrinterStatus({
    SharedPreferences? prefs,
    bool showLoader = true,
  }) async {
    final resolvedPrefs = prefs ?? await SharedPreferences.getInstance();

    if (mounted) {
      setState(() {
        _wifiPrinterIp = resolvedPrefs.getString('printerIp');
        _branchIpRange = resolvedPrefs.getString('branchIp');
        if (showLoader) {
          _isCheckingWifiPrinter = true;
        }
      });
    }

    String? deviceWifiIp;
    try {
      deviceWifiIp = await NetworkInfo().getWifiIP().timeout(
        const Duration(seconds: 2),
        onTimeout: () => null,
      );
    } catch (_) {
      deviceWifiIp = null;
    }

    final savedPrinterIp = resolvedPrefs.getString('printerIp')?.trim() ?? '';
    final savedBranchIpRange =
        resolvedPrefs.getString('branchIp')?.trim() ?? '';
    final currentWifiIp = deviceWifiIp?.trim() ?? '';

    final isWifiPrinterConnected =
        savedPrinterIp.isNotEmpty &&
        currentWifiIp.isNotEmpty &&
        ((savedBranchIpRange.isNotEmpty &&
                _isIpInRange(currentWifiIp, savedBranchIpRange)) ||
            _isSameSubnet(currentWifiIp, savedPrinterIp));

    if (!mounted) return;
    setState(() {
      _deviceWifiIp = currentWifiIp.isEmpty ? null : currentWifiIp;
      _isWifiPrinterConnected = isWifiPrinterConnected;
      _isCheckingWifiPrinter = false;
    });
  }

  Future<void> _refreshBluetoothStatus({
    SharedPreferences? prefs,
    bool showLoader = true,
  }) async {
    final resolvedPrefs = prefs ?? await SharedPreferences.getInstance();

    if (mounted) {
      setState(() {
        _printerName = resolvedPrefs.getString('bt_printer_name');
        if (showLoader) {
          _isCheckingBluetooth = true;
        }
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
        _printerName = resolvedPrefs.getString('bt_printer_name');
      }
      _isCheckingBluetooth = false;
    });
  }

  Future<void> _refreshLocationStatus({bool showLoader = true}) async {
    if (mounted && showLoader) {
      setState(() {
        _isCheckingLocation = true;
      });
    }

    bool isLocationEnabled = false;
    bool hasLocationPermission = false;
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
      var serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        await _turnOnLocationServices();
        serviceEnabled = await Geolocator.isLocationServiceEnabled();
      }

      if (!serviceEnabled) {
        await _refreshLocationStatus();
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.deniedForever) {
        await Geolocator.openAppSettings();
      }

      await _refreshLocationStatus();
    } catch (_) {
      await _refreshLocationStatus();
    }
  }

  Future<void> _turnOnLocationServices() async {
    try {
      await _locationChannel.invokeMethod('turnOnLocation');
      for (int i = 0; i < 5; i++) {
        await Future.delayed(const Duration(seconds: 1));
        final enabled = await Geolocator.isLocationServiceEnabled();
        if (enabled) {
          break;
        }
      }
    } catch (_) {
      await Geolocator.openLocationSettings();
    }
  }

  Future<void> _toggleReviewPrint(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await setThermalReviewPrintEnabled(prefs, enabled);
    if (!mounted) return;
    setState(() {
      _isReviewPrintEnabled = enabled;
    });
  }

  int? _ipToInt(String ip) {
    final octets = ip
        .split('.')
        .map((part) => int.tryParse(part.trim()))
        .toList(growable: false);

    if (octets.length != 4 || octets.any((part) => part == null)) {
      return null;
    }

    final values = octets.cast<int>();
    if (values.any((part) => part < 0 || part > 255)) {
      return null;
    }

    return values[0] << 24 | values[1] << 16 | values[2] << 8 | values[3];
  }

  List<String> _extractIpAddresses(String value) {
    final matches = RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}\b').allMatches(value);
    return matches.map((match) => match.group(0)!).toList(growable: false);
  }

  bool _isIpInRange(String deviceIp, String range) {
    final rangeIps = _extractIpAddresses(range);
    if (rangeIps.isEmpty) {
      return false;
    }

    final deviceValue = _ipToInt(deviceIp);
    if (deviceValue == null) {
      return false;
    }

    if (rangeIps.length == 1) {
      final singleRangeIp = _ipToInt(rangeIps.first);
      return singleRangeIp != null && deviceValue == singleRangeIp;
    }

    final start = _ipToInt(rangeIps.first);
    final end = _ipToInt(rangeIps.last);
    if (start == null || end == null) {
      return false;
    }

    return deviceValue >= start && deviceValue <= end;
  }

  bool _isSameSubnet(String firstIp, String secondIp) {
    final firstParts = firstIp.split('.');
    final secondParts = secondIp.split('.');
    if (firstParts.length != 4 || secondParts.length != 4) {
      return false;
    }

    return firstParts[0] == secondParts[0] &&
        firstParts[1] == secondParts[1] &&
        firstParts[2] == secondParts[2];
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
    final hasSavedWifiPrinter = wifiPrinterIp.isNotEmpty;
    final currentWifiIp = _deviceWifiIp?.trim() ?? '';
    final branchIpRange = _branchIpRange?.trim() ?? '';

    final subtitle = !hasSavedWifiPrinter
        ? 'WiFi printer not configured'
        : _isWifiPrinterConnected
        ? 'IP: $wifiPrinterIp'
        : currentWifiIp.isNotEmpty
        ? 'Saved printer IP: $wifiPrinterIp\nCurrent WiFi IP: $currentWifiIp'
        : 'Saved printer IP: $wifiPrinterIp';

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
                color: _isWifiPrinterConnected
                    ? const Color(0xFF1BA672)
                    : Colors.black87,
                size: 24,
              ),
              if (!_isCheckingWifiPrinter && !_isWifiPrinterConnected)
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
                  subtitle,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (!_isWifiPrinterConnected &&
                    branchIpRange.isNotEmpty &&
                    !_isCheckingWifiPrinter)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Branch range: $branchIpRange',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[500],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_isCheckingWifiPrinter)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFF1BA672),
              ),
            )
          else if (_isWifiPrinterConnected)
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

  Widget _buildReviewPrintCard() {
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
          Icon(
            Icons.rate_review_outlined,
            color: _isReviewPrintEnabled
                ? const Color(0xFF1BA672)
                : Colors.black87,
            size: 24,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Print Review on Receipt',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _isReviewPrintEnabled
                      ? 'Feedback banner and review QR will print'
                      : 'Feedback banner and review QR will not print',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: _isReviewPrintEnabled,
            activeThumbColor: const Color(0xFF1BA672),
            activeTrackColor: const Color(0xFF1BA672).withValues(alpha: 0.35),
            onChanged: _toggleReviewPrint,
          ),
        ],
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
            const SizedBox(height: 16),
            _buildReviewPrintCard(),
          ],
        ),
      ),
    );
  }
}
