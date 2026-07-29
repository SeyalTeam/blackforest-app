import 'dart:convert';

import 'package:blackforest_app/api_server_prefs.dart';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:blackforest_app/raw_material_billing_page.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

// =============================================================================
// Bill List Page
// =============================================================================

class RawMaterialBillListPage extends StatefulWidget {
  final String? dealerId;
  final String? dealerName;
  const RawMaterialBillListPage({super.key, this.dealerId, this.dealerName});

  @override
  State<RawMaterialBillListPage> createState() =>
      _RawMaterialBillListPageState();
}

class _RawMaterialBillListPageState extends State<RawMaterialBillListPage> {
  List<Map<String, dynamic>> _bills = [];
  bool _isLoading = true;
  String _searchQuery = '';
  String? _companyId;

  @override
  void initState() {
    super.initState();
    _loadBills();
  }

  Future<Map<String, String>> _authHeaders() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token') ?? '';
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  Future<String?> _resolveCompanyId() async {
    if (_companyId != null) return _companyId;
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString('company_id')?.trim();
    if (cached != null && cached.isNotEmpty) {
      _companyId = cached;
      return cached;
    }

    final branchId = prefs.getString('branchId')?.trim();
    if (branchId == null || branchId.isEmpty) return null;

    final headers = await _authHeaders();
    final response = await http.get(
      Uri.parse('https://$apiHostPrimary/api/branches/$branchId?depth=1'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final company = data['company'];
      String? companyId;
      if (company is Map) {
        companyId = company['id']?.toString();
      } else if (company is String) {
        companyId = company;
      }
      if (companyId != null && companyId.isNotEmpty) {
        _companyId = companyId;
        await prefs.setString('company_id', companyId);
      }
      return companyId;
    }
    return null;
  }

  Future<void> _loadBills() async {
    setState(() => _isLoading = true);
    try {
      final companyId = await _resolveCompanyId();
      final headers = await _authHeaders();
      final response = await http.get(
        Uri.parse(
          'https://$apiHostPrimary/api/raw-material-billings?limit=1000&depth=2&sort=-date',
        ),
        headers: headers,
      );

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final docs = body['docs'] as List<dynamic>? ?? [];

        final loaded = <Map<String, dynamic>>[];
        for (var doc in docs) {
          // Filter by company
          if (companyId != null) {
            final billCompany = doc['company'];
            String? billCompanyId;
            if (billCompany is Map) {
              billCompanyId = billCompany['id']?.toString();
            } else if (billCompany is String) {
              billCompanyId = billCompany;
            }
            if (billCompanyId != null && billCompanyId != companyId) continue;
          }

          // Filter by dealer
          if (widget.dealerId != null) {
            final billDealer = doc['dealer'];
            String? billDealerId;
            if (billDealer is Map) {
              billDealerId = billDealer['id']?.toString();
            } else if (billDealer is String) {
              billDealerId = billDealer;
            }
            if (billDealerId != widget.dealerId) continue;
          }

          loaded.add(Map<String, dynamic>.from(doc as Map));
        }
        setState(() => _bills = loaded);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading bills: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<Map<String, dynamic>> get _filteredBills {
    if (_searchQuery.isEmpty) return _bills;
    final q = _searchQuery.toLowerCase();
    return _bills.where((bill) {
      final dealer = bill['dealer'];
      final dealerName =
          (dealer is Map ? dealer['companyName'] ?? dealer['name'] : '')
              .toString()
              .toLowerCase();
      // Search by invoice numbers if available
      final rawEntries = bill['entries'];
      bool invoiceMatches = false;
      if (rawEntries is List) {
        for (var entry in rawEntries) {
          if (entry is Map) {
            final invNum = (entry['invoiceNumber'] ?? '').toString().toLowerCase();
            if (invNum.contains(q)) {
              invoiceMatches = true;
              break;
            }
          }
        }
      }
      return dealerName.contains(q) || invoiceMatches;
    }).toList();
  }

  String _dealerName(Map<String, dynamic> bill) {
    final dealer = bill['dealer'];
    if (dealer is Map) {
      return dealer['companyName']?.toString() ??
          dealer['name']?.toString() ??
          'Unknown Dealer';
    }
    return 'Unknown Dealer';
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return '—';
    try {
      final dt = DateTime.parse(dateStr).toLocal();
      return DateFormat('dd MMM yyyy, hh:mm a').format(dt);
    } catch (_) {
      return dateStr;
    }
  }

  Color _statusColor(String? status) {
    switch (status?.toLowerCase()) {
      case 'paid':
        return const Color(0xFF2E7D32);
      case 'cancelled':
        return Colors.red;
      default:
        return const Color(0xFFF57C00);
    }
  }

  String _statusLabel(String? status) {
    if (status == null || status.isEmpty) return 'PENDING';
    return status.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredBills;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        title: Text(widget.dealerName != null
            ? '${widget.dealerName} Bills'
            : 'Raw Material Bills'),
        backgroundColor: const Color(0xFF2E7D32),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              decoration: InputDecoration(
                hintText: widget.dealerName != null
                    ? 'Search by invoice number...'
                    : 'Search by dealer name...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              onChanged: (v) => setState(() => _searchQuery = v),
            ),
          ),
          // List
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF2E7D32),
                    ),
                  )
                : filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.receipt_long,
                              size: 64,
                              color: Colors.grey.shade400,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _searchQuery.isEmpty
                                  ? 'No bills yet'
                                  : 'No bills matching "$_searchQuery"',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadBills,
                        color: const Color(0xFF2E7D32),
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            return _buildBillCard(filtered[index]);
                          },
                        ),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final result = await Navigator.push<bool>(
            context,
            MaterialPageRoute(
              builder: (_) => RawMaterialBillingPage(
                preselectedDealerId: widget.dealerId,
              ),
            ),
          );
          if (result == true) _loadBills();
        },
        backgroundColor: const Color(0xFF2E7D32),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text(
          'New Bill',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _buildBillCard(Map<String, dynamic> bill) {
    final dealerName = _dealerName(bill);
    final total = (bill['total'] ?? 0).toDouble();
    final dateStr = bill['date']?.toString();
    final status = bill['status']?.toString();

    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => _RawMaterialBillingDetailScreen(bill: bill),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Dealer icon
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFF2E7D32).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.store,
                  color: Color(0xFF2E7D32),
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      dealerName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: Color(0xFF1F2430),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatDate(dateStr),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Total + Status
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '₹${total.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: Color(0xFF1F2430),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: _statusColor(status).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _statusLabel(status),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: _statusColor(status),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Bill Detail Screen
// =============================================================================

class _RawMaterialBillingDetailScreen extends StatelessWidget {
  final Map<String, dynamic> bill;

  const _RawMaterialBillingDetailScreen({required this.bill});

  String _dealerName() {
    final dealer = bill['dealer'];
    if (dealer is Map) {
      return dealer['companyName']?.toString() ??
          dealer['name']?.toString() ??
          'Unknown';
    }
    return 'Unknown';
  }

  String _dealerContact() {
    final dealer = bill['dealer'];
    if (dealer is Map) {
      final parts = <String>[];
      if (dealer['contactName'] != null) parts.add(dealer['contactName']);
      if (dealer['phoneNumber'] != null) parts.add(dealer['phoneNumber']);
      if (dealer['email'] != null) parts.add(dealer['email']);
      return parts.join(' • ');
    }
    return '';
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return '—';
    try {
      final dt = DateTime.parse(dateStr).toLocal();
      return DateFormat('dd MMM yyyy, hh:mm a').format(dt);
    } catch (_) {
      return dateStr;
    }
  }

  Color _statusColor(String? status) {
    switch (status?.toLowerCase()) {
      case 'paid':
        return const Color(0xFF2E7D32);
      case 'cancelled':
        return Colors.red;
      default:
        return const Color(0xFFF57C00);
    }
  }

  String _statusLabel(String? status) {
    if (status == null || status.isEmpty) return 'PENDING';
    return status.toUpperCase();
  }

  String? _resolvePhotoUrl(dynamic photo) {
    if (photo is Map) {
      final url = photo['url']?.toString();
      if (url != null && url.isNotEmpty) {
        return resolveApiAssetUrl(url);
      }
    } else if (photo is String && photo.isNotEmpty) {
      return resolveApiAssetUrl(photo);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final status = bill['status']?.toString();
    final total = (bill['total'] ?? 0).toDouble();
    final dateStr = bill['date']?.toString();

    final rawMaterialsList =
        bill['rawMaterialsList'] as List<dynamic>? ?? [];
    final billsList = bill['bills'] as List<dynamic>? ?? [];

    // Photos
    final billCopyUrl = _resolvePhotoUrl(bill['billCopyPhoto']);
    final deliveryPersonUrl = _resolvePhotoUrl(bill['deliveryPersonPhoto']);
    final productPhotos = bill['productsPhoto'] as List<dynamic>? ?? [];

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        title: const Text('Bill Details'),
        backgroundColor: const Color(0xFF2E7D32),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Date & Status
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDate(dateStr),
                  style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: _statusColor(status).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _statusLabel(status),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: _statusColor(status),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Dealer info
            _sectionCard(
              title: 'Dealer',
              icon: Icons.store,
              children: [
                Text(
                  _dealerName(),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (_dealerContact().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    _dealerContact(),
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ],
            ),

            // Raw materials
            if (rawMaterialsList.isNotEmpty)
              _sectionCard(
                title: 'Purchased Raw Materials',
                icon: Icons.inventory_2,
                children: rawMaterialsList.map<Widget>((item) {
                  final material = item['rawMaterial'];
                  final materialName = material is Map
                      ? material['name']?.toString() ?? 'Unknown'
                      : 'Unknown';
                  final unit = material is Map
                      ? material['unit']?.toString() ?? ''
                      : '';
                  final qty =
                      (item['quantity'] ?? 0).toDouble();
                  final amt =
                      (item['totalAmount'] ?? 0).toDouble();

                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            materialName,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ),
                        Text(
                          '${qty.toStringAsFixed(qty.truncateToDouble() == qty ? 0 : 1)} $unit',
                          style: TextStyle(color: Colors.grey.shade700),
                        ),
                        const SizedBox(width: 16),
                        Text(
                          '₹${amt.toStringAsFixed(2)}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),

            // Financial summary
            _sectionCard(
              title: 'Financial Summary',
              icon: Icons.receipt_long,
              children: [
                ...billsList.map<Widget>((b) {
                  final inv = b['invoiceNumber']?.toString() ?? '—';
                  final amt = (b['amount'] ?? 0).toDouble();
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Invoice: $inv'),
                        Text(
                          '₹${amt.toStringAsFixed(2)}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  );
                }),
                const Divider(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Grand Total',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      '₹${total.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                        color: Color(0xFF2E7D32),
                      ),
                    ),
                  ],
                ),
              ],
            ),

            // Photos
            _sectionCard(
              title: 'Photos',
              icon: Icons.photo_library,
              children: [
                _buildPhotoGrid(context, [
                  if (billCopyUrl != null)
                    _PhotoEntry(label: 'Bill Copy', url: billCopyUrl),
                  if (deliveryPersonUrl != null)
                    _PhotoEntry(
                        label: 'Delivery Person', url: deliveryPersonUrl),
                  ...productPhotos.map((p) {
                    final url = _resolvePhotoUrl(p);
                    return url != null
                        ? _PhotoEntry(label: 'Product', url: url)
                        : null;
                  }).whereType<_PhotoEntry>(),
                ]),
              ],
            ),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 20, color: const Color(0xFF2E7D32)),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: Color(0xFF1F2430),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPhotoGrid(BuildContext context, List<_PhotoEntry> photos) {
    if (photos.isEmpty) {
      return const Text(
        'No photos available',
        style: TextStyle(color: Colors.grey),
      );
    }
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: photos.length,
      itemBuilder: (context, index) {
        final entry = photos[index];
        return GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => _FullScreenPhotoViewer(
                  url: entry.url,
                  label: entry.label,
                ),
              ),
            );
          },
          child: Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    entry.url,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    errorBuilder: (_, __, ___) => Container(
                      color: Colors.grey.shade200,
                      child: const Icon(Icons.broken_image, color: Colors.grey),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                entry.label,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PhotoEntry {
  final String label;
  final String url;

  const _PhotoEntry({required this.label, required this.url});
}

// =============================================================================
// Full Screen Photo Viewer
// =============================================================================

class _FullScreenPhotoViewer extends StatelessWidget {
  final String url;
  final String label;

  const _FullScreenPhotoViewer({required this.url, required this.label});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(label),
        elevation: 0,
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4.0,
          child: Image.network(
            url,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Icon(
              Icons.broken_image,
              color: Colors.grey,
              size: 64,
            ),
          ),
        ),
      ),
    );
  }
}
