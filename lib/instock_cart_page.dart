import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/instock_provider.dart';

class InstockCartPage extends StatefulWidget {
  const InstockCartPage({super.key});

  @override
  State<InstockCartPage> createState() => _InstockCartPageState();
}

class _InstockCartPageState extends State<InstockCartPage> {
  static const Color _bg = Color(0xFF121212);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<InstockProvider>(context, listen: false).syncBranchId();
    });
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Text(
        "Instock Cart is empty",
        style: TextStyle(color: Colors.grey, fontSize: 16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Instock Cart',
      pageType: PageType.instock,
      body: Container(
        color: _bg,
        child: Consumer<InstockProvider>(
          builder: (context, sp, child) {
            final items = sp.inStockQuery;

            return SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: items.isEmpty
                        ? _buildEmptyState()
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
                            itemCount: items.length,
                            itemBuilder: (context, index) {
                              final id = items.keys.elementAt(index);
                              final qty = items[id] ?? 0;
                              final name = sp.productNames[id] ?? 'Unknown';
                              final price = sp.prices[id] ?? 0;

                              return InstockCartItem(
                                key: ValueKey(id),
                                id: id,
                                name: name,
                                price: price,
                                quantity: qty,
                                onRemove: () => sp.updateInStock(id, 0),
                                onUpdate: (val) => sp.updateInStock(id, val),
                              );
                            },
                          ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _bg,
                      border: Border(
                        top: BorderSide(color: Colors.white.withOpacity(0.1)),
                      ),
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF11998e),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: sp.isSubmitting || items.isEmpty
                            ? null
                            : () async {
                                await sp.submitInstock(context);
                                // The provider clears cart on success
                                if (sp.inStockQuery.isEmpty && mounted) {
                                  Navigator.pop(context);
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
                                "Confirm Instock",
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
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

class InstockCartItem extends StatefulWidget {
  final String id;
  final String name;
  final double price;
  final double quantity;
  final VoidCallback onRemove;
  final Function(double) onUpdate;

  const InstockCartItem({
    super.key,
    required this.id,
    required this.name,
    required this.price,
    required this.quantity,
    required this.onRemove,
    required this.onUpdate,
  });

  @override
  State<InstockCartItem> createState() => _InstockCartItemState();
}

class _InstockCartItemState extends State<InstockCartItem> {
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _formatQty(widget.quantity));
  }

  @override
  void didUpdateWidget(covariant InstockCartItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.quantity != oldWidget.quantity) {
      final textVal = double.tryParse(_ctrl.text) ?? 0.0;
      if (textVal != widget.quantity) {
        _ctrl.text = _formatQty(widget.quantity);
      }
    }
  }

  String _formatQty(double val) {
    if (val == val.truncateToDouble()) {
      return val.toInt().toString();
    }
    return val.toString();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: widget.key!,
      direction: DismissDirection.endToStart,
      onDismissed: (_) => widget.onRemove(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: Colors.red,
      ),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.05)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '₹${widget.price % 1 == 0 ? widget.price.toInt() : widget.price}',
                    style: const TextStyle(color: Colors.grey, fontSize: 14),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Container(
              width: 80,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: TextField(
                controller: _ctrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.only(bottom: 8),
                ),
                onChanged: (val) {
                  final d = double.tryParse(val);
                  if (d != null) {
                    widget.onUpdate(d);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
