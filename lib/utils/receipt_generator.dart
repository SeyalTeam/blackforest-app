import 'package:esc_pos_utils/esc_pos_utils.dart';

class ReceiptGenerator {
  static Future<List<int>> generateReceipt(Map<String, dynamic> billing) async {
    List<int> bytes = [];
    bytes += await _buildHeader(billing);
    bytes += await _buildItems(billing['items']);
    bytes += await _buildFooter(billing);
    return bytes;
  }

  static Future<List<int>> _buildHeader(Map<String, dynamic> billing) async {
    final profile = await CapabilityProfile.load(name: 'default');
    final generator = Generator(PaperSize.mm80, profile);
    List<int> bytes = [];
    bytes += generator.text('Black Forest Cakes', styles: PosStyles(align: PosAlign.center, bold: true));
    bytes += generator.text('Invoice #: ${billing['invoiceNumber']}', styles: PosStyles(align: PosAlign.center));
    bytes += generator.text('Date: ${DateTime.now()}', styles: PosStyles(align: PosAlign.center));
    bytes += generator.hr();
    return bytes;
  }

  static Future<List<int>> _buildItems(List<dynamic> items) async {
    final profile = await CapabilityProfile.load(name: 'default');
    final generator = Generator(PaperSize.mm80, profile);
    List<int> bytes = [];
    for (var item in items) {
      bytes += generator.row([
        PosColumn(text: item['name'], width: 6),
        PosColumn(text: 'x${item['quantity']}', width: 2),
        PosColumn(text: '₹${item['subtotal']}', width: 4),
      ]);
    }
    bytes += generator.hr();
    return bytes;
  }

  static Future<List<int>> _buildFooter(Map<String, dynamic> billing) async {
    final profile = await CapabilityProfile.load(name: 'default');
    final generator = Generator(PaperSize.mm80, profile);
    List<int> bytes = [];
    bytes += generator.row([
      PosColumn(text: 'Total', width: 8, styles: PosStyles(bold: true)),
      PosColumn(text: '₹${billing['totalAmount']}', width: 4, styles: PosStyles(bold: true)),
    ]);
    bytes += generator.text('Payment: ${billing['paymentMethod']}', styles: PosStyles(align: PosAlign.center));
    bytes += generator.text('Thank You!', styles: PosStyles(align: PosAlign.center));
    bytes += generator.feed(2);
    bytes += generator.cut();
    return bytes;
  }
}
