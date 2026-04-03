import 'package:flutter/material.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:blackforest_app/printer/bluetooth_printer_prefs.dart';

class BluetoothPrinterSettingsPage extends StatefulWidget {
  const BluetoothPrinterSettingsPage({super.key});

  @override
  State<BluetoothPrinterSettingsPage> createState() =>
      _BluetoothPrinterSettingsPageState();
}

class _BluetoothPrinterSettingsPageState
    extends State<BluetoothPrinterSettingsPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  bool _isBluetoothOn = false;
  bool _isScanning = false;
  bool _isConnecting = false;
  String _msj = '';
  bool _connected = false;
  List<BluetoothInfo> _items = [];
  String? _savedMacAddress;
  bool _printBilling = true;
  bool _printKot = true;

  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );

    _scaleAnimation =
        Tween<double>(begin: 0.8, end: 1.2).animate(
          CurvedAnimation(
            parent: _animationController,
            curve: Curves.easeInOut,
          ),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) {
            _animationController.reverse();
          } else if (status == AnimationStatus.dismissed) {
            _animationController.forward();
          }
        });

    _initBluetooth();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _animationController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _initBluetooth();
    }
  }

  Future<void> _turnOnBluetooth() async {
    try {
      const channel = MethodChannel('blackforest.app/bluetooth');
      await channel.invokeMethod('turnOnBluetooth');
      // Poll multiple times incase user accepts it fast
      for (int i = 0; i < 5; i++) {
        await Future.delayed(const Duration(seconds: 1));
        final state = await PrintBluetoothThermal.bluetoothEnabled;
        if (state) {
          setState(() {
            _isBluetoothOn = true;
          });
          _getDevices();
          break;
        }
      }
    } catch (e) {
      debugPrint("Failed to turn on bluetooth natively: $e");
    }
  }

  Future<void> _initBluetooth() async {
    final prefs = await SharedPreferences.getInstance();
    await ensureBluetoothPrinterRoutingPrefs(prefs);
    setState(() {
      _savedMacAddress = prefs.getString(btPrinterMacKey);
      _printBilling = isBluetoothBillingEnabled(prefs);
      _printKot = isBluetoothKotEnabled(prefs);
    });

    // Request permissions before querying state (For Android 12+)
    if (await Permission.bluetoothConnect.isDenied) {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetooth,
        Permission.location,
      ].request();
    }

    final state = await PrintBluetoothThermal.bluetoothEnabled;
    setState(() {
      _isBluetoothOn = state;
      if (state) {
        _getDevices();
      }
    });
  }

  Future<void> _getDevices() async {
    setState(() {
      _isScanning = true;
      _msj = 'Scanning...';
    });
    _animationController.forward();

    try {
      final devices = await PrintBluetoothThermal.pairedBluetooths;
      setState(() {
        _items = devices;
        if (_items.isEmpty) {
          _msj =
              'No paired devices found. Please pair the printer in your phone settings first.';
        } else {
          _msj = 'Found ${_items.length} devices, click to connect';
        }
      });
      _checkConnectionState();
    } catch (e) {
      setState(() {
        _msj = 'Error scanning devices: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
        _animationController.reset();
      }
    }
  }

  Future<void> _checkConnectionState() async {
    final isConnected = await PrintBluetoothThermal.connectionStatus;
    setState(() {
      _connected = isConnected;
    });

    if (!isConnected && _savedMacAddress != null && !_isConnecting) {
      // Try to auto-connect if we have a saved MAC
      final savedDevice = _items.firstWhere(
        (device) => device.macAdress == _savedMacAddress,
        orElse: () => BluetoothInfo(name: '', macAdress: ''),
      );
      if (savedDevice.macAdress.isNotEmpty) {
        _connect(savedDevice, isAutoConnect: true);
      }
    }
  }

  Future<void> _connect(
    BluetoothInfo selectedDevice, {
    bool isAutoConnect = false,
  }) async {
    if (_isConnecting) return;

    setState(() {
      _isConnecting = true;
      _msj = isAutoConnect ? 'Auto-connecting...' : 'Connecting...';
    });

    try {
      // 1. Mandatory Disconnect to clear any stale or "locked" sessions
      debugPrint('🖨️ Ensuring clean state for ${selectedDevice.name}...');
      await PrintBluetoothThermal.disconnect;
      await Future.delayed(const Duration(milliseconds: 600));

      // 2. Initial connection attempt
      bool result = await PrintBluetoothThermal.connect(
        macPrinterAddress: selectedDevice.macAdress,
      );

      // 3. Simple retry if first attempt failed (common with some BT modules)
      if (!result) {
        debugPrint('🖨️ First attempt failed, retrying in 1s...');
        await Future.delayed(const Duration(seconds: 1));
        result = await PrintBluetoothThermal.connect(
          macPrinterAddress: selectedDevice.macAdress,
        );
      }

      if (result) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(btPrinterMacKey, selectedDevice.macAdress);
        await prefs.setString(btPrinterNameKey, selectedDevice.name);
        await ensureBluetoothPrinterRoutingPrefs(prefs);
        if (mounted) {
          setState(() {
            _connected = true;
            _savedMacAddress = selectedDevice.macAdress;
            _printBilling = isBluetoothBillingEnabled(prefs);
            _printKot = isBluetoothKotEnabled(prefs);
            _msj = 'Connected';
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _msj =
                'Failed to connect. Please make sure the printer is turned on and paired.';
          });
        }
      }
    } catch (e) {
      debugPrint('🖨️ Connection error: $e');
      if (mounted) {
        setState(() {
          _msj = 'Connection error. Please restart the printer.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }
    }
  }

  Future<void> _disconnect() async {
    final result = await PrintBluetoothThermal.disconnect;
    final prefs = await SharedPreferences.getInstance();
    await clearBluetoothPrinterPrefs(prefs);

    setState(() {
      _connected = false;
      _savedMacAddress = null;
      _printBilling = true;
      _printKot = true;
      if (result) {
        _msj = 'Disconnected';
      } else {
        _msj = 'Failed to disconnect';
      }
    });
  }

  Future<void> _updatePrintRouting({
    required bool billingEnabled,
    required bool kotEnabled,
  }) async {
    if (!billingEnabled && !kotEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Select at least one option: Billing or KOT'),
          ),
        );
      }
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await saveBluetoothPrinterRoutingPrefs(
      prefs,
      billingEnabled: billingEnabled,
      kotEnabled: kotEnabled,
    );

    if (!mounted) return;
    setState(() {
      _printBilling = billingEnabled;
      _printKot = kotEnabled;
    });
  }

  Widget _buildRoutingOption({
    required String label,
    required bool value,
    required ValueChanged<bool?> onChanged,
  }) {
    return CheckboxListTile(
      value: value,
      onChanged: onChanged,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      dense: true,
      activeColor: const Color(0xFF16A34A),
      title: Text(
        label,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    BluetoothInfo? connectedDevice;
    if (_savedMacAddress != null && _items.isNotEmpty) {
      try {
        connectedDevice = _items.firstWhere(
          (d) => d.macAdress == _savedMacAddress,
        );
      } catch (_) {}
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect Printer'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              if (value == 'reset') {
                final messenger = ScaffoldMessenger.of(context);
                await _disconnect();
                _getDevices();
                if (mounted) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Printer settings reset')),
                  );
                }
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'reset',
                child: Row(
                  children: [
                    Icon(Icons.refresh, color: Colors.red, size: 20),
                    SizedBox(width: 8),
                    Text('Hard Reset Connection'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Container(
        color: const Color(0xFFF8F9FA),
        width: double.infinity,
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            if (!_isBluetoothOn) ...[
              // BLUETOOTH OFF STATE (Image 1)
              const SizedBox(height: 20),
              const Text(
                'Bluetooth is closed',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 40),
              // Mock Phone Frame
              Expanded(
                child: Container(
                  width: 280,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(30),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 12),
                      Container(
                        width: 60,
                        height: 6,
                        decoration: BoxDecoration(
                          color: Colors.grey[200],
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(height: 40),
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 24),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.04),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(6),
                              decoration: const BoxDecoration(
                                color: Color(0xFF16A34A),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.bluetooth,
                                color: Colors.white,
                                size: 16,
                              ),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text(
                                'Bluetooth',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black87,
                                ),
                              ),
                            ),
                            Container(
                              width: 44,
                              height: 24,
                              decoration: BoxDecoration(
                                color: const Color(0xFF16A34A),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Container(
                                  margin: const EdgeInsets.all(2),
                                  width: 20,
                                  height: 20,
                                  decoration: const BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _turnOnBluetooth,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF16A34A),
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26),
                    ),
                    elevation: 0,
                  ),
                  child: const Text(
                    'Open Bluetooth',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ] else if (_connected && connectedDevice != null) ...[
              // CONNECTED STATE (Image 3)
              const SizedBox(height: 40),
              Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 20,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: const Icon(Icons.print, size: 60, color: Colors.black87),
              ),
              const SizedBox(height: 24),
              Text(
                connectedDevice.name,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.check, color: Color(0xFF16A34A), size: 18),
                  const SizedBox(width: 4),
                  const Text(
                    'Connected',
                    style: TextStyle(fontSize: 14, color: Colors.black54),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.bluetooth,
                    color: Color(0xFF16A34A),
                    size: 16,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.grey[200]!),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Use this printer for',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Choose whether this Bluetooth printer should print Billing, KOT, or both.',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[600],
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildRoutingOption(
                      label: 'Billing',
                      value: _printBilling,
                      onChanged: (value) {
                        _updatePrintRouting(
                          billingEnabled: value ?? false,
                          kotEnabled: _printKot,
                        );
                      },
                    ),
                    _buildRoutingOption(
                      label: 'KOT',
                      value: _printKot,
                      onChanged: (value) {
                        _updatePrintRouting(
                          billingEnabled: _printBilling,
                          kotEnabled: value ?? false,
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _disconnect,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black87,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26),
                      side: BorderSide(color: Colors.grey[300]!),
                    ),
                    elevation: 0,
                  ),
                  child: const Text(
                    'Disconnect',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ] else ...[
              // DISCONNECTED / SCANNING STATE (Image 2)
              const SizedBox(height: 20),
              AnimatedBuilder(
                animation: _scaleAnimation,
                builder: (context, child) {
                  final scale = _isScanning ? _scaleAnimation.value : 1.0;
                  return Container(
                    width: 160 * scale,
                    height: 160 * scale,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEAF7F1),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Container(
                        width: 100 * scale,
                        height: 100 * scale,
                        decoration: BoxDecoration(
                          color: const Color(0xFFD4EFE3),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Container(
                            width: 50,
                            height: 50,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.search,
                              color: Color(0xFF16A34A),
                              size: 28,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 24),
              const Text(
                'Please make sure the printer is turned on',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _msj,
                style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Expanded(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _items.length,
                  itemBuilder: (context, index) {
                    final item = _items[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey[200]!),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        leading: const Icon(
                          Icons.print,
                          size: 32,
                          color: Colors.black87,
                        ),
                        title: Text(
                          item.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        subtitle: Row(
                          children: [
                            Icon(
                              Icons.bluetooth,
                              size: 14,
                              color: Colors.grey[500],
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Disconnected',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[500],
                              ),
                            ),
                          ],
                        ),
                        trailing: ElevatedButton(
                          onPressed: () => _connect(item),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFEAF7F1),
                            foregroundColor: const Color(0xFF16A34A),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                          ),
                          child: const Text('Connect'),
                        ),
                      ),
                    );
                  },
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _getDevices,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF16A34A),
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26),
                    ),
                    elevation: 0,
                  ),
                  child: const Text(
                    'Refresh Devices',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
