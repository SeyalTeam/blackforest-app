import 'dart:async';
import 'package:esc_pos_printer/esc_pos_printer.dart';
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class PrinterService {
  static Future<String?> getPrinterIp(String branchId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) return null;

      final response = await http.get(
        Uri.parse('https://admin.theblackforestcakes.com/api/branches/$branchId'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['printerIp']?.toString().trim();
      }
    } catch (e) {
      // Handle error silently or log
    }
    return null;
  }

  static Future<void> printReceipt(Map<String, dynamic> billing, String printerIp) async {
    const PaperSize paper = PaperSize.mm80;
    final profile = await CapabilityProfile.load(name: 'default');
    final printer = NetworkPrinter(paper, profile);

    final PosPrintResult res = await printer.connect(printerIp, port: 9100);
    if (res == PosPrintResult.success) {
      printer.text('Black Forest Cakes', styles: PosStyles(align: PosAlign.center, bold: true));
      printer.text('Invoice #: ${billing['invoiceNumber']}', styles: PosStyles(align: PosAlign.center));
      printer.text('Date: ${DateTime.now().toString()}', styles: PosStyles(align: PosAlign.center));
      printer.hr();
      for (var item in billing['items']) {
        printer.row([
          PosColumn(text: item['name'], width: 6),
          PosColumn(text: 'x${item['quantity']}', width: 2),
          PosColumn(text: '₹${item['subtotal']}', width: 4),
        ]);
      }
      printer.hr();
      printer.row([
        PosColumn(text: 'Total', width: 8, styles: PosStyles(bold: true)),
        PosColumn(text: '₹${billing['totalAmount']}', width: 4, styles: PosStyles(bold: true)),
      ]);
      printer.text('Payment: ${billing['paymentMethod']}', styles: PosStyles(align: PosAlign.center));
      printer.text('Thank You!', styles: PosStyles(align: PosAlign.center));
      printer.feed(2);
      printer.cut();
      printer.disconnect();
    } else {
      // Handle error, e.g., throw or return res
    }
  }
}