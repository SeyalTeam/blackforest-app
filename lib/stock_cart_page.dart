import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/stock_provider.dart';
import 'package:blackforest_app/printer/unified_printer.dart';
import 'package:blackforest_app/cart_provider.dart';

class StockCartPage extends StatefulWidget {
  const StockCartPage({super.key});

  @override
  State<StockCartPage> createState() => _StockCartPageState();
}

class _StockCartPageState extends State<StockCartPage> {
  static const Color _bg = Color(0xFF121212);
  static const Color _card = Color(0xFF1E1E1E);
  static const Color _accent = Color(0xFF0F766E);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<StockProvider>(context, listen: false).syncBranchId();
    });
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.inventory_2_outlined, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text(
            "Stock Order Cart is empty",
            style: TextStyle(color: Colors.grey, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Future<void> _printStockOrderReceipt(Map<String, dynamic> orderData) async {
    try {
      final cartProvider = Provider.of<CartProvider>(context, listen: false);
      String? printerIp = cartProvider.printerIp?.trim();
      int printerPort = cartProvider.printerPort;

      final prefs = await SharedPreferences.getInstance();
      final hasBluetooth = (prefs.getString('bt_printer_mac') ?? '').trim().isNotEmpty;

      if ((printerIp == null || printerIp.isEmpty) && !hasBluetooth) {
        return;
      }

      final profile = await CapabilityProfile.load();
      final candidatePorts = {printerPort, 9100, 9101}.toList();
      final printer = await UnifiedPrinter.connect(
        printerIp: printerIp,
        candidatePorts: candidatePorts,
        paperSize: PaperSize.mm80,
        profile: profile,
        jobType: PrintJobType.billing,
      );

      if (printer != null) {
        final now = DateTime.now();
        final branchName = prefs.getString('branchName') ?? 'Branch';
        final cashierName = orderData['cashierName'] ?? prefs.getString('employee_name') ?? 'Staff';

        printer.text('BLACK FOREST CAKES', styles: const PosStyles(align: PosAlign.center, bold: true));
        printer.text('Stock Order Receipt', styles: const PosStyles(align: PosAlign.center));
        printer.text('Branch: $branchName', styles: const PosStyles(align: PosAlign.center));
        printer.text('Staff: $cashierName', styles: const PosStyles(align: PosAlign.center));
        printer.text(
          'Date: ${DateFormat('dd-MM-yyyy hh:mm a').format(now)}',
          styles: const PosStyles(align: PosAlign.center),
        );
        printer.hr();

        final items = orderData['items'] as List<dynamic>? ?? [];
        for (var item in items) {
          final name = item['name'] ?? 'Item';
          final qty = item['requiredQty'] ?? item['quantity'] ?? 0;
          final price = item['price'] ?? 0.0;
          printer.row([
            PosColumn(text: name.toString(), width: 6),
            PosColumn(text: qty.toString(), width: 2, styles: const PosStyles(align: PosAlign.right)),
            PosColumn(text: (qty * price).toStringAsFixed(2), width: 4, styles: const PosStyles(align: PosAlign.right)),
          ]);
        }
        printer.hr();
        printer.feed(2);
        printer.cut();
        await printer.disconnectAndPrint();
      }
    } catch (e) {
      debugPrint('Optional stock order print exception: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Stock Order Cart',
      pageType: PageType.stock,
      body: Container(
        color: _bg,
        child: Consumer<StockProvider>(
          builder: (context, sp, _) {
            final selectedEntries =
                sp.selected.entries.where((e) => e.value).toList();

            if (selectedEntries.isEmpty) {
              return _buildEmptyState();
            }

            double totalAmount = 0.0;
            for (var entry in selectedEntries) {
              final pid = entry.key;
              final req = sp.quantities[pid] ?? 0;
              final price = sp.prices[pid] ?? 0.0;
              final baseQty = sp.baseQuantities[pid] ?? 1.0;
              totalAmount += ((req / baseQty) * price);
            }

            return SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: selectedEntries.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, index) {
                        final entry = selectedEntries[index];
                        final pid = entry.key;
                        final name = sp.productNames[pid] ?? "Unknown";
                        final req = sp.quantities[pid] ?? 0;
                        final price = sp.prices[pid] ?? 0.0;
                        final baseQty = sp.baseQuantities[pid] ?? 1.0;
                        final lineTotal = (req / baseQty) * price;

                        final ctrl = sp.qtyCtrl[pid];
                        if (ctrl != null &&
                            (double.tryParse(ctrl.text) ?? 0.0) != req) {
                          ctrl.text = (req % 1 == 0)
                              ? req.toInt().toString()
                              : req.toString();
                        }

                        return Dismissible(
                          key: Key(pid),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            padding: const EdgeInsets.only(right: 20),
                            alignment: Alignment.centerRight,
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.delete, color: Colors.white),
                          ),
                          onDismissed: (_) {
                            sp.toggleSelection(pid, false);
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color: _card,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.05),
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        name,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                          color: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        "₹ ${price.toStringAsFixed(2)} ${sp.units[pid] ?? ''}",
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Row(
                                      children: [
                                        SizedBox(
                                          width: 70,
                                          height: 40,
                                          child: TextField(
                                            controller: sp.stockCtrl[pid],
                                            keyboardType:
                                                const TextInputType.numberWithOptions(
                                              decimal: true,
                                            ),
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                            ),
                                            decoration: InputDecoration(
                                              labelText: 'In Stock',
                                              labelStyle: const TextStyle(
                                                color: Colors.white54,
                                                fontSize: 10,
                                              ),
                                              filled: true,
                                              fillColor: Colors.black12,
                                              border: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                borderSide: const BorderSide(
                                                  color: Colors.white24,
                                                ),
                                              ),
                                              enabledBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                borderSide: const BorderSide(
                                                  color: Colors.white24,
                                                ),
                                              ),
                                              focusedBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                borderSide: const BorderSide(
                                                  color: _accent,
                                                ),
                                              ),
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 4,
                                              ),
                                            ),
                                            onChanged: (val) {
                                              final newQty =
                                                  double.tryParse(val) ?? 0.0;
                                              sp.updateInStock(pid, newQty);
                                            },
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        SizedBox(
                                          width: 70,
                                          height: 40,
                                          child: TextField(
                                            controller: ctrl,
                                            keyboardType:
                                                const TextInputType.numberWithOptions(
                                              decimal: true,
                                            ),
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                            ),
                                            decoration: InputDecoration(
                                              labelText: 'Req',
                                              labelStyle: const TextStyle(
                                                color: Colors.white54,
                                                fontSize: 10,
                                              ),
                                              filled: true,
                                              fillColor: Colors.black12,
                                              border: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                borderSide: const BorderSide(
                                                  color: Colors.white24,
                                                ),
                                              ),
                                              enabledBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                borderSide: const BorderSide(
                                                  color: Colors.white24,
                                                ),
                                              ),
                                              focusedBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                borderSide: const BorderSide(
                                                  color: _accent,
                                                ),
                                              ),
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 8,
                                              ),
                                            ),
                                            onChanged: (val) {
                                              final newQty =
                                                  double.tryParse(val) ?? 0.0;
                                              sp.updateQuantity(pid, newQty);
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      "Total: ₹ ${lineTotal.toStringAsFixed(2)}",
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.white70,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: _bg,
                      border: Border(
                        top: BorderSide(
                          color: Colors.white.withValues(alpha: 0.1),
                        ),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              flex: 6,
                              child: GestureDetector(
                                onTap: () async {
                                  if (sp.isSameDay) {
                                    final selectedTime = await showTimePicker(
                                      context: context,
                                      initialTime: TimeOfDay.fromDateTime(
                                        sp.deliveryDate ?? DateTime.now(),
                                      ),
                                    );
                                    if (selectedTime != null) {
                                      final now = DateTime.now();
                                      sp.deliveryDate = DateTime(
                                        now.year,
                                        now.month,
                                        now.day,
                                        selectedTime.hour,
                                        selectedTime.minute,
                                      );
                                    }
                                    return;
                                  }

                                  final selectedDate = await showDatePicker(
                                    context: context,
                                    initialDate: sp.deliveryDate ??
                                        DateTime.now().add(const Duration(days: 1)),
                                    firstDate: DateTime.now(),
                                    lastDate: DateTime(2030),
                                  );
                                  if (selectedDate == null) return;
                                  if (!context.mounted) return;

                                  final selectedTime = await showTimePicker(
                                    context: context,
                                    initialTime: TimeOfDay.fromDateTime(
                                      sp.deliveryDate ??
                                          DateTime.now().add(const Duration(days: 1)),
                                    ),
                                  );
                                  if (selectedTime == null) return;

                                  sp.deliveryDate = DateTime(
                                    selectedDate.year,
                                    selectedDate.month,
                                    selectedDate.day,
                                    selectedTime.hour,
                                    selectedTime.minute,
                                  );
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _card,
                                    border: Border.all(
                                      color: Colors.white24,
                                      width: 0.5,
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        sp.isSameDay
                                            ? Icons.access_time
                                            : Icons.calendar_month,
                                        color: _accent,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          sp.isSameDay
                                              ? "Delivery: ${DateFormat.jm().format(sp.deliveryDate ?? DateTime.now())}"
                                              : (sp.deliveryDate == null
                                                  ? "Select Date & Time"
                                                  : DateFormat(
                                                      'dd/MM/yyyy  hh:mm a',
                                                    ).format(sp.deliveryDate!)),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                            fontSize: 13,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 4,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    "Total: ₹ ${totalAmount.toStringAsFixed(2)}",
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                      color: Colors.greenAccent,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    "${selectedEntries.length} Items",
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: Colors.orangeAccent,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton(
                                onPressed: () => sp.setStockMode(),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: !sp.isSameDay
                                      ? Colors.blue
                                      : Colors.blue.withValues(alpha: 0.3),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                                child: const Text(
                                  "Stock Mode",
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: () => sp.setLiveMode(),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: sp.isSameDay
                                      ? const Color(0xFFEF4444)
                                      : const Color(0xFFEF4444).withValues(alpha: 0.3),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                                child: const Text(
                                  "Live (Today)",
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: SizedBox(
                                height: 48,
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.redAccent,
                                    side: const BorderSide(color: Colors.redAccent),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  onPressed: sp.isSubmitting
                                      ? null
                                      : () => sp.clearCart(),
                                  child: const Icon(Icons.delete_outline),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 7,
                              child: SizedBox(
                                height: 48,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: sp.isSubmitting
                                        ? Colors.grey
                                        : const Color(0xFF0F766E),
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  onPressed: (sp.isSubmitting ||
                                          (sp.deliveryDate == null && !sp.isSameDay))
                                      ? null
                                      : () async {
                                          final orderData = await sp
                                              .submitStockOrder(context);
                                          if (orderData != null && context.mounted) {
                                            await _printStockOrderReceipt(orderData);
                                            if (context.mounted) {
                                              Navigator.pop(context);
                                            }
                                          }
                                        },
                                  child: sp.isSubmitting
                                      ? const SizedBox(
                                          width: 24,
                                          height: 24,
                                          child: CircularProgressIndicator(
                                            color: Colors.white,
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Text(
                                          "Confirm Stock Order",
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
