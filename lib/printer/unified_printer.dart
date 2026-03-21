import 'package:esc_pos_printer/esc_pos_printer.dart';
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

class UnifiedPrinter {
  final NetworkPrinter? networkPrinter;
  final Generator generator;
  final bool isBluetooth;

  final List<int> _bytes = [];

  UnifiedPrinter._({
    this.networkPrinter,
    required this.generator,
    required this.isBluetooth,
  });

  static Future<UnifiedPrinter?> connect({
    required String? printerIp,
    required List<int> candidatePorts,
    required PaperSize paperSize,
    required CapabilityProfile profile,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final generator = Generator(paperSize, profile);

    // 1. Try Bluetooth first if configured and connected
    final btMac = prefs.getString('bt_printer_mac');
    if (btMac != null && btMac.isNotEmpty) {
      try {
        bool isConnected = await PrintBluetoothThermal.connectionStatus;
        if (!isConnected) {
          debugPrint(
            '🖨️ Bluetooth disconnected, attempting to reconnect to $btMac...',
          );
          // Ensure clean state
          await PrintBluetoothThermal.disconnect;
          await Future.delayed(const Duration(milliseconds: 500));

          isConnected = await PrintBluetoothThermal.connect(
            macPrinterAddress: btMac,
          );

          // Retry once if first attempt failed
          if (!isConnected) {
            await Future.delayed(const Duration(seconds: 1));
            isConnected = await PrintBluetoothThermal.connect(
              macPrinterAddress: btMac,
            );
          }
        }
        if (isConnected) {
          debugPrint('🖨️ Connected via Bluetooth: $btMac');
          final printer = UnifiedPrinter._(
            generator: generator,
            isBluetooth: true,
          );
          printer._bytes.addAll(generator.reset());
          return printer;
        }
      } catch (e) {
        debugPrint('🖨️ Bluetooth connection error: $e');
      }
    }

    // 2. Fallback to WiFi / Network if IP is provided
    if (printerIp == null || printerIp.isEmpty) {
      debugPrint('🖨️ No Bluetooth and no IP address provided.');
      return null;
    }

    final networkPrinter = NetworkPrinter(paperSize, profile);
    PosPrintResult result = PosPrintResult.timeout;
    for (final port in candidatePorts) {
      debugPrint('🖨️ Connecting to Network Printer: $printerIp:$port');
      result = await networkPrinter
          .connect(printerIp, port: port)
          .timeout(
            const Duration(seconds: 4),
            onTimeout: () => PosPrintResult.timeout,
          );
      if (result == PosPrintResult.success) {
        debugPrint('🖨️ Connected via WiFi on $printerIp:$port');
        return UnifiedPrinter._(
          networkPrinter: networkPrinter,
          generator: generator,
          isBluetooth: false,
        );
      }
    }

    debugPrint('🖨️ Failed to connect to any printer.');
    return null;
  }

  void text(
    String text, {
    PosStyles styles = const PosStyles(),
    int linesAfter = 0,
    bool containsChinese = false,
    int? maxCharsPerLine,
  }) {
    if (isBluetooth) {
      _bytes.addAll(
        generator.text(
          text,
          styles: styles,
          linesAfter: linesAfter,
          containsChinese: containsChinese,
          maxCharsPerLine: maxCharsPerLine,
        ),
      );
    } else {
      networkPrinter?.text(
        text,
        styles: styles,
        linesAfter: linesAfter,
        containsChinese: containsChinese,
        maxCharsPerLine: maxCharsPerLine,
      );
    }
  }

  void hr({String ch = '-', int? len, int linesAfter = 0}) {
    if (isBluetooth) {
      _bytes.addAll(generator.hr(ch: ch, linesAfter: linesAfter));
    } else {
      networkPrinter?.hr(ch: ch, linesAfter: linesAfter);
    }
  }

  void row(List<PosColumn> cols) {
    if (isBluetooth) {
      _bytes.addAll(generator.row(cols));
    } else {
      networkPrinter?.row(cols);
    }
  }

  void feed(int n) {
    if (isBluetooth) {
      _bytes.addAll(generator.feed(n));
    } else {
      networkPrinter?.feed(n);
    }
  }

  void rawBytes(List<int> command) {
    if (isBluetooth) {
      _bytes.addAll(generator.rawBytes(command));
    } else {
      networkPrinter?.rawBytes(command);
    }
  }

  void emptyLines(int n) {
    if (isBluetooth) {
      _bytes.addAll(generator.emptyLines(n));
    } else {
      networkPrinter?.emptyLines(n);
    }
  }

  void smallRowGap({int dots = 8}) {
    final safeDots = dots.clamp(1, 255);
    rawBytes([27, 51, safeDots]);
    emptyLines(1);
    rawBytes([27, 50]);
  }

  void image(img.Image imgSrc, {PosAlign align = PosAlign.center}) {
    if (isBluetooth) {
      _bytes.addAll(generator.image(imgSrc, align: align));
    } else {
      networkPrinter?.image(imgSrc, align: align);
    }
  }

  void textEncoded(
    Uint8List textBytes, {
    PosStyles styles = const PosStyles(),
    int linesAfter = 0,
    int? maxCharsPerLine,
  }) {
    if (isBluetooth) {
      _bytes.addAll(
        generator.textEncoded(
          textBytes,
          styles: styles,
          linesAfter: linesAfter,
          maxCharsPerLine: maxCharsPerLine,
        ),
      );
    } else {
      networkPrinter?.textEncoded(
        textBytes,
        styles: styles,
        linesAfter: linesAfter,
        maxCharsPerLine: maxCharsPerLine,
      );
    }
  }

  void qrcode(
    String text, {
    PosAlign align = PosAlign.center,
    QRSize size = QRSize.Size4,
    QRCorrection cor = QRCorrection.L,
  }) {
    if (isBluetooth) {
      _bytes.addAll(generator.qrcode(text, align: align, size: size, cor: cor));
    } else {
      networkPrinter?.qrcode(text, align: align, size: size, cor: cor);
    }
  }

  void cut({PosCutMode mode = PosCutMode.full}) {
    if (isBluetooth) {
      _bytes.addAll(generator.cut(mode: mode));
    } else {
      networkPrinter?.cut(mode: mode);
    }
  }

  Future<void> disconnectAndPrint() async {
    if (isBluetooth) {
      if (_bytes.isNotEmpty) {
        try {
          debugPrint(
            '🖨️ Sending data to Bluetooth printer (${_bytes.length} bytes)',
          );
          await PrintBluetoothThermal.writeBytes(_bytes);
        } catch (e) {
          debugPrint('🖨️ Error writing to Bluetooth: $e');
        }
      }
    } else {
      networkPrinter?.disconnect();
    }
  }
}
