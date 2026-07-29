import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/api_server_prefs.dart';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:blackforest_app/raw_material_billing_page.dart';

class RawMaterialDealerListPage extends StatefulWidget {
  const RawMaterialDealerListPage({super.key});

  @override
  State<RawMaterialDealerListPage> createState() => _RawMaterialDealerListPageState();
}

class _RawMaterialDealerListPageState extends State<RawMaterialDealerListPage> {
  List<Map<String, dynamic>> _dealers = [];
  bool _isLoading = true;
  String _searchQuery = '';
  String? _companyId;

  @override
  void initState() {
    super.initState();
    _loadDealers();
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

  Future<void> _loadDealers() async {
    setState(() => _isLoading = true);
    try {
      final companyId = await _resolveCompanyId();
      final headers = await _authHeaders();
      final response = await http.get(
        Uri.parse(
          'https://$apiHostPrimary/api/raw-material-dealers?limit=200&depth=1',
        ),
        headers: headers,
      );

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final docs = body['docs'] as List<dynamic>? ?? [];
        final loaded = <Map<String, dynamic>>[];

        for (var doc in docs) {
          final allowedComps = doc['allowedCompanies'];
          bool isAllowed = false;
          if (companyId != null && allowedComps is List) {
            isAllowed = allowedComps.any((comp) {
              String? cId;
              if (comp is Map) {
                cId = comp['id']?.toString();
              } else if (comp is String) {
                cId = comp;
              }
              return cId == companyId;
            });
          }
          if (isAllowed) {
            loaded.add(Map<String, dynamic>.from(doc as Map));
          }
        }
        setState(() => _dealers = loaded);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading dealers: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<Map<String, dynamic>> get _filteredDealers {
    if (_searchQuery.isEmpty) return _dealers;
    final q = _searchQuery.toLowerCase();
    return _dealers.where((d) {
      final name = (d['name'] ?? '').toString().toLowerCase();
      final companyName = (d['companyName'] ?? '').toString().toLowerCase();
      return name.contains(q) || companyName.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredDealers;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        title: const Text('Select Dealer'),
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
                hintText: 'Search by dealer name...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
              onChanged: (val) {
                setState(() => _searchQuery = val.trim());
              },
            ),
          ),
          // Dealer list or loading / empty state
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
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.storefront,
                              size: 72,
                              color: Colors.grey.shade400,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _searchQuery.isEmpty
                                  ? 'No dealers available'
                                  : 'No matching dealers found',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey.shade600,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadDealers,
                        color: const Color(0xFF2E7D32),
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            return _buildDealerCard(filtered[index]);
                          },
                        ),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const RawMaterialBillingPage(),
            ),
          );
        },
        backgroundColor: const Color(0xFF2E7D32),
        foregroundColor: Colors.white,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildDealerCard(Map<String, dynamic> dealer) {
    final name = dealer['name']?.toString() ?? 'Unnamed Dealer';
    final companyName = dealer['companyName']?.toString();
    final contactName = dealer['contactName']?.toString();
    final phoneNumber = dealer['phoneNumber']?.toString();

    return Card(
      elevation: 1,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => RawMaterialBillingPage(
                preselectedDealerId: dealer['id'] as String,
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Avatar Icon
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFF2E7D32).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.business,
                  color: Color(0xFF2E7D32),
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              // Dealer details
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      companyName ?? name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1F2430),
                      ),
                    ),
                    if (companyName != null && name != companyName) ...[
                      const SizedBox(height: 2),
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                    if (contactName != null || phoneNumber != null) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            Icons.person_outline,
                            size: 14,
                            color: Colors.grey.shade500,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              [contactName, phoneNumber]
                                  .where((s) => s != null && s.isNotEmpty)
                                  .join(' - '),
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              // Arrow icon
              Icon(
                Icons.arrow_forward_ios,
                color: Colors.grey.shade400,
                size: 16,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
