import 'dart:convert';
import 'dart:io';

import 'package:blackforest_app/api_server_prefs.dart';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:blackforest_app/camera_capture_page.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http_parser/http_parser.dart';
import 'package:image/image.dart' as img_lib;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Photo slot helper
// ---------------------------------------------------------------------------

class _PhotoSlot {
  final String label;
  final String prefix;
  File? file;
  String? mediaId;
  String? url;

  _PhotoSlot({required this.label, required this.prefix});
}

// ---------------------------------------------------------------------------
// Raw Material Billing Page
// ---------------------------------------------------------------------------

class RawMaterialBillingPage extends StatefulWidget {
  final String? preselectedDealerId;
  const RawMaterialBillingPage({super.key, this.preselectedDealerId});

  @override
  State<RawMaterialBillingPage> createState() => _RawMaterialBillingPageState();
}

class _RawMaterialBillingPageState extends State<RawMaterialBillingPage> {
  final _formKey = GlobalKey<FormState>();

  // Dealers
  List<Map<String, dynamic>> _dealers = [];
  String? _selectedDealerId;
  bool _isLoadingDealers = false;

  // Raw materials
  List<Map<String, dynamic>> _products = [];
  Map<String, Map<String, double>> _selectedRawMaterialQuantities = {};
  bool _isLoadingProducts = false;

  // Bill entries
  final List<TextEditingController> _billControllers = [];
  final List<TextEditingController> _invoiceNumberControllers = [];

  // Photos
  late final _PhotoSlot _billCopySlot;
  late final _PhotoSlot _deliveryPersonSlot;
  final List<File> _productPhotos = [];

  bool _isSubmitting = false;

  // Company info resolved from branch
  String? _resolvedCompanyId;

  @override
  void initState() {
    super.initState();
    _billCopySlot =
        _PhotoSlot(label: 'Dealer Bill Copy', prefix: 'dealerbill');
    _deliveryPersonSlot =
        _PhotoSlot(label: 'Delivery Person Photo', prefix: 'deliveryperson');
    _addBillField();
    
    if (widget.preselectedDealerId != null) {
      _selectedDealerId = widget.preselectedDealerId;
      _fetchProducts(widget.preselectedDealerId!);
    }
    
    _fetchDealers();
  }

  @override
  void dispose() {
    for (var c in _billControllers) {
      c.dispose();
    }
    for (var c in _invoiceNumberControllers) {
      c.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<Map<String, String>> _authHeaders() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token') ?? '';
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  void _viewFullImage(File file, String title) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(12),
          child: Stack(
            alignment: Alignment.center,
            children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: InteractiveViewer(
                  maxScale: 4.0,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.file(
                      file,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 16,
                right: 16,
                child: CircleAvatar(
                  backgroundColor: Colors.black.withValues(alpha: 0.6),
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ),
              Positioned(
                top: 24,
                left: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<String?> _resolveCompanyId() async {
    if (_resolvedCompanyId != null) return _resolvedCompanyId;
    final prefs = await SharedPreferences.getInstance();

    // Try cached company_id first
    final cached = prefs.getString('company_id')?.trim();
    if (cached != null && cached.isNotEmpty) {
      _resolvedCompanyId = cached;
      return cached;
    }

    // Fallback: fetch branch and extract company
    final branchId = prefs.getString('branchId')?.trim();
    if (branchId == null || branchId.isEmpty) return null;

    final headers = await _authHeaders();
    final response = await http.get(
      Uri.parse(
        'https://$apiHostPrimary/api/branches/$branchId?depth=1',
      ),
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
        _resolvedCompanyId = companyId;
        await prefs.setString('company_id', companyId);
      }
      return companyId;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Bill field management
  // ---------------------------------------------------------------------------

  void _addBillField() {
    setState(() {
      final controller = TextEditingController();
      controller.addListener(() => setState(() {}));
      _billControllers.add(controller);
      _invoiceNumberControllers.add(TextEditingController());
    });
  }

  void _removeBillField(int index) {
    if (_billControllers.length > 1 &&
        _invoiceNumberControllers.length > index) {
      setState(() {
        _billControllers[index].dispose();
        _billControllers.removeAt(index);
        _invoiceNumberControllers[index].dispose();
        _invoiceNumberControllers.removeAt(index);
      });
    }
  }

  double _calculateTotal() {
    double total = 0.0;
    for (var c in _billControllers) {
      total += double.tryParse(c.text) ?? 0.0;
    }
    return total;
  }

  // ---------------------------------------------------------------------------
  // Fetch Dealers
  // ---------------------------------------------------------------------------

  Future<void> _fetchDealers() async {
    setState(() => _isLoadingDealers = true);
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

          if (isAllowed || companyId == null) {
            final id = doc['id']?.toString() ?? '';
            final name = doc['companyName']?.toString() ??
                doc['name']?.toString() ??
                'Unknown Dealer';
            loaded.add({'id': id, 'name': name});
          }
        }

        loaded.sort((a, b) => a['name']
            .toString()
            .toLowerCase()
            .compareTo(b['name'].toString().toLowerCase()));

        setState(() => _dealers = loaded);
      } else {
        throw Exception('Failed to load dealers: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error fetching dealers: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() => _isLoadingDealers = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Fetch Raw Materials
  // ---------------------------------------------------------------------------

  Future<void> _fetchProducts(String dealerId) async {
    setState(() => _isLoadingProducts = true);
    try {
      final headers = await _authHeaders();
      final response = await http.get(
        Uri.parse(
          'https://$apiHostPrimary/api/raw-materials?where[dealer][equals]=$dealerId&limit=500&depth=0',
        ),
        headers: headers,
      );

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final docs = body['docs'] as List<dynamic>? ?? [];
        final loaded = <Map<String, dynamic>>[];
        for (var doc in docs) {
          loaded.add({
            'id': doc['id']?.toString() ?? '',
            'name': doc['name']?.toString() ?? 'Unknown',
            'unit': doc['unit']?.toString() ?? '',
          });
        }
        loaded.sort((a, b) => a['name']
            .toString()
            .toLowerCase()
            .compareTo(b['name'].toString().toLowerCase()));
        setState(() => _products = loaded);
      } else {
        throw Exception('Failed to load raw materials: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error fetching raw materials: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() => _isLoadingProducts = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Raw Material Selection
  // ---------------------------------------------------------------------------

  Future<void> _navigateToRawMaterialSelection() async {
    final result = await Navigator.push<Map<String, Map<String, double>>>(
      context,
      MaterialPageRoute(
        builder: (_) => _RawMaterialSelectionPage(
          products: _products,
          existing: _selectedRawMaterialQuantities,
        ),
      ),
    );
    if (result != null) {
      setState(() => _selectedRawMaterialQuantities = result);
    }
  }

  // ---------------------------------------------------------------------------
  // Photo capture
  // ---------------------------------------------------------------------------

  Future<void> _capturePhoto(_PhotoSlot slot) async {
    if (!mounted) return;
    final XFile? photo = await Navigator.push<XFile>(
      context,
      MaterialPageRoute(
        builder: (_) => const CameraCapturePage(),
        fullscreenDialog: true,
      ),
    );
    if (photo == null) return;

    final bytes = await photo.readAsBytes();
    final image = img_lib.decodeImage(bytes);
    if (image == null) return;
    final compressed = img_lib.encodeJpg(image, quality: 70);

    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final tempFile = File('${tempDir.path}/${slot.prefix}_$timestamp.jpg');
    await tempFile.writeAsBytes(compressed);

    setState(() {
      slot.file = tempFile;
      slot.mediaId = null;
      slot.url = null;
    });
  }

  void _removePhoto(_PhotoSlot slot) {
    setState(() {
      if (slot.file != null && slot.file!.existsSync()) {
        try {
          slot.file!.deleteSync();
        } catch (_) {}
      }
      slot.file = null;
      slot.mediaId = null;
      slot.url = null;
    });
  }

  Future<void> _captureProductPhoto() async {
    if (!mounted) return;
    final XFile? photo = await Navigator.push<XFile>(
      context,
      MaterialPageRoute(
        builder: (_) => const CameraCapturePage(),
        fullscreenDialog: true,
      ),
    );
    if (photo == null) return;

    final bytes = await photo.readAsBytes();
    final image = img_lib.decodeImage(bytes);
    if (image == null) return;
    final compressed = img_lib.encodeJpg(image, quality: 70);

    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final tempFile = File('${tempDir.path}/dealerproducts_$timestamp.jpg');
    await tempFile.writeAsBytes(compressed);

    setState(() => _productPhotos.add(tempFile));
  }

  // ---------------------------------------------------------------------------
  // Upload photo
  // ---------------------------------------------------------------------------

  Future<String?> _uploadPhoto(File file, String altText, String prefix) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token')?.trim();
    if (token == null || token.isEmpty) {
      throw Exception('Session token missing. Please login again.');
    }

    final bytes = await file.readAsBytes();
    final filename = file.path.split('/').last;

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('https://$apiHostPrimary/api/media?prefix=$prefix'),
    );
    request.headers['Authorization'] = 'Bearer $token';
    request.headers['Accept'] = 'application/json';
    request.fields['alt'] = altText;
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      bytes,
      filename: filename,
      contentType: MediaType('image', 'jpeg'),
    ));

    final streamed = await request.send();
    final respBody = await streamed.stream.bytesToString();
    if (streamed.statusCode == 200 || streamed.statusCode == 201) {
      final data = jsonDecode(respBody);
      final mediaId = (data is Map)
          ? (data['doc'] is Map ? data['doc']['id']?.toString() : data['id']?.toString())
          : null;
      if (mediaId != null && mediaId.isNotEmpty) {
        return mediaId;
      }
      throw Exception('Invalid media response: $respBody');
    } else {
      debugPrint('Media upload failed [${streamed.statusCode}]: $respBody');
      throw Exception('Photo upload failed (${streamed.statusCode}): $respBody');
    }
  }

  // ---------------------------------------------------------------------------
  // Submit billing
  // ---------------------------------------------------------------------------

  Future<void> _submitBilling() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedDealerId == null) {
      _showError('Please select a dealer');
      return;
    }
    if (_billCopySlot.file == null) {
      _showError('Please capture the bill copy photo');
      return;
    }
    if (_deliveryPersonSlot.file == null) {
      _showError('Please capture the delivery person photo');
      return;
    }
    if (_productPhotos.isEmpty) {
      _showError('Please capture at least one product photo');
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      // Upload photos
      final billCopyId = await _uploadPhoto(
        _billCopySlot.file!,
        'Dealer Bill Copy',
        _billCopySlot.prefix,
      );
      if (billCopyId == null) throw Exception('Failed to upload bill copy');

      final deliveryPersonId = await _uploadPhoto(
        _deliveryPersonSlot.file!,
        'Delivery Person',
        _deliveryPersonSlot.prefix,
      );
      if (deliveryPersonId == null) {
        throw Exception('Failed to upload delivery person photo');
      }

      final productPhotoIds = <String>[];
      for (var file in _productPhotos) {
        final id = await _uploadPhoto(file, 'Product Photo', 'dealerproducts');
        if (id == null) throw Exception('Failed to upload product photo');
        productPhotoIds.add(id);
      }

      // Build raw materials list
      final rawMaterialsList = <Map<String, dynamic>>[];
      for (var entry in _selectedRawMaterialQuantities.entries) {
        rawMaterialsList.add({
          'rawMaterial': entry.key,
          'quantity': entry.value['quantity'] ?? 0,
          'totalAmount': entry.value['totalAmount'] ?? 0,
        });
      }

      // Build bills list
      final bills = <Map<String, dynamic>>[];
      for (var i = 0; i < _billControllers.length; i++) {
        final amount = double.tryParse(_billControllers[i].text) ?? 0;
        final invoiceNumber = _invoiceNumberControllers[i].text.trim();
        bills.add({
          'amount': amount,
          'invoiceNumber': invoiceNumber,
        });
      }

      final companyId = await _resolveCompanyId();
      final prefs = await SharedPreferences.getInstance();
      final empName = prefs.getString('employee_name')?.trim();
      final userName = prefs.getString('user_name')?.trim();
      final userId = prefs.getString('user_id')?.trim();
      final userRole = prefs.getString('role')?.trim();

      final createdByName = (empName != null && empName.isNotEmpty)
          ? empName
          : (userName != null && userName.isNotEmpty ? userName : 'Unknown');

      final payload = {
        'dealer': _selectedDealerId,
        'company': companyId,
        'bills': bills,
        'total': _calculateTotal(),
        'billCopyPhoto': billCopyId,
        'deliveryPersonPhoto': deliveryPersonId,
        'productsPhoto': productPhotoIds,
        'rawMaterialsList': rawMaterialsList,
        'date': DateTime.now().toUtc().toIso8601String(),
        'createdBy': userId,
        'createdByName': createdByName,
        'createdByRole': userRole ?? 'Unknown',
      };

      final headers = await _authHeaders();
      final response = await http.post(
        Uri.parse('https://$apiHostPrimary/api/raw-material-billings'),
        headers: headers,
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Bill submitted successfully!'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context, true);
        }
      } else {
        throw Exception('Failed to submit: ${response.statusCode}');
      }
    } catch (e) {
      _showError('Error submitting bill: $e');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        title: const Text('New Raw Material Bill'),
        backgroundColor: const Color(0xFF2E7D32),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: _isSubmitting
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFF2E7D32)),
                  SizedBox(height: 16),
                  Text(
                    'Uploading photos & submitting bill...',
                    style: TextStyle(fontSize: 16, color: Colors.black54),
                  ),
                ],
              ),
            )
          : Form(
              key: _formKey,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildDealerDropdown(),
                    const SizedBox(height: 16),
                    if (_selectedDealerId != null) ...[
                      _buildRawMaterialsSection(),
                      const SizedBox(height: 16),
                    ],
                    _buildBillEntriesSection(),
                    const SizedBox(height: 16),
                    _buildPhotoSlotWidget(_billCopySlot),
                    const SizedBox(height: 16),
                    _buildPhotoSlotWidget(_deliveryPersonSlot),
                    const SizedBox(height: 16),
                    _buildProductPhotosWidget(),
                    const SizedBox(height: 24),
                    _buildTotalAndSubmit(),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
    );
  }

  // ---------------------------------------------------------------------------
  // Dealer dropdown
  // ---------------------------------------------------------------------------

  Widget _buildDealerDropdown() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Select Dealer',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: Color(0xFF1F2430),
              ),
            ),
            const SizedBox(height: 12),
            _isLoadingDealers
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(
                        color: Color(0xFF2E7D32),
                      ),
                    ),
                  )
                : DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _dealers.any((d) => d['id'] == _selectedDealerId)
                        ? _selectedDealerId
                        : null,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      hintText: 'Choose a dealer',
                    ),
                    items: _dealers.map((d) {
                      return DropdownMenuItem<String>(
                        value: d['id'] as String,
                        child: Text(
                          d['name'] as String,
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedDealerId = value;
                        _products = [];
                        _selectedRawMaterialQuantities = {};
                      });
                      if (value != null) _fetchProducts(value);
                    },
                    validator: (value) =>
                        value == null ? 'Please select a dealer' : null,
                  ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Raw materials section
  // ---------------------------------------------------------------------------

  Widget _buildRawMaterialsSection() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Raw Materials',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: Color(0xFF1F2430),
                  ),
                ),
                Text(
                  '${_selectedRawMaterialQuantities.length} selected',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_isLoadingProducts)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child:
                      CircularProgressIndicator(color: Color(0xFF2E7D32)),
                ),
              )
            else ...[
              if (_selectedRawMaterialQuantities.isNotEmpty)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _selectedRawMaterialQuantities.entries.map((entry) {
                    final product = _products.firstWhere(
                      (p) => p['id'] == entry.key,
                      orElse: () => {'name': 'Unknown', 'unit': ''},
                    );
                    final qty = entry.value['quantity'] ?? 0;
                    final amt = entry.value['totalAmount'] ?? 0;
                    return Chip(
                      label: Text(
                        '${product['name']} — Qty: ${qty.toStringAsFixed(qty.truncateToDouble() == qty ? 0 : 1)}, ₹${amt.toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      deleteIcon: const Icon(Icons.close, size: 16),
                      onDeleted: () {
                        setState(() {
                          _selectedRawMaterialQuantities.remove(entry.key);
                        });
                      },
                    );
                  }).toList(),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _products.isEmpty ? null : _navigateToRawMaterialSelection,
                icon: const Icon(Icons.add_circle_outline),
                label: Text(
                  _selectedRawMaterialQuantities.isEmpty
                      ? 'Select Raw Materials'
                      : 'Edit Selection',
                ),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  foregroundColor: const Color(0xFF2E7D32),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Bill entries section
  // ---------------------------------------------------------------------------

  Widget _buildBillEntriesSection() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Bill Entries',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: Color(0xFF1F2430),
                  ),
                ),
                IconButton(
                  onPressed: _addBillField,
                  icon: const Icon(Icons.add_circle, color: Color(0xFF2E7D32)),
                  tooltip: 'Add Bill Entry',
                ),
              ],
            ),
            for (var i = 0; i < _billControllers.length; i++) ...[
              if (i > 0) const Divider(height: 24),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: _invoiceNumberControllers[i],
                      decoration: InputDecoration(
                        labelText: 'Invoice #${i + 1}',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: _billControllers[i],
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: 'Amount (₹)',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Required';
                        }
                        if (double.tryParse(value) == null) {
                          return 'Invalid';
                        }
                        return null;
                      },
                    ),
                  ),
                  if (_billControllers.length > 1)
                    IconButton(
                      onPressed: () => _removeBillField(i),
                      icon: const Icon(Icons.remove_circle, color: Colors.red),
                      iconSize: 22,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Photo slot widget
  // ---------------------------------------------------------------------------

  Widget _buildPhotoSlotWidget(_PhotoSlot slot) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              slot.label,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
                color: Color(0xFF1F2430),
              ),
            ),
            const SizedBox(height: 12),
            if (slot.file != null)
              Stack(
                children: [
                  GestureDetector(
                    onTap: () => _viewFullImage(slot.file!, slot.label),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        slot.file!,
                        height: 160,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: Colors.red.withValues(alpha: 0.9),
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.close,
                            size: 16, color: Colors.white),
                        onPressed: () => _removePhoto(slot),
                      ),
                    ),
                  ),
                ],
              )
            else
              OutlinedButton.icon(
                onPressed: () => _capturePhoto(slot),
                icon: const Icon(Icons.camera_alt),
                label: Text('Capture ${slot.label}'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  foregroundColor: const Color(0xFF2E7D32),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Product photos widget
  // ---------------------------------------------------------------------------

  Widget _buildProductPhotosWidget() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Text(
                    'Product Photos (one or more)',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: Color(0xFF1F2430),
                    ),
                  ),
                ),
                Text(
                  '${_productPhotos.length} taken',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_productPhotos.isNotEmpty) ...[
              SizedBox(
                height: 100,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _productPhotos.length,
                  itemBuilder: (context, index) {
                    return Stack(
                      children: [
                        GestureDetector(
                          onTap: () => _viewFullImage(
                            _productPhotos[index],
                            'Product Photo ${index + 1}',
                          ),
                          child: Container(
                            margin: const EdgeInsets.only(right: 12),
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(
                                _productPhotos[index],
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 4,
                          top: -4,
                          child: CircleAvatar(
                            radius: 12,
                            backgroundColor: Colors.red.withValues(alpha: 0.9),
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              icon: const Icon(Icons.close,
                                  size: 14, color: Colors.white),
                              onPressed: () {
                                setState(() {
                                  try {
                                    _productPhotos[index].deleteSync();
                                  } catch (_) {}
                                  _productPhotos.removeAt(index);
                                });
                              },
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
            ],
            OutlinedButton.icon(
              onPressed: _captureProductPhoto,
              icon: const Icon(Icons.add_a_photo),
              label: const Text('Add Product Photo'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                foregroundColor: const Color(0xFF2E7D32),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Total + Submit
  // ---------------------------------------------------------------------------

  Widget _buildTotalAndSubmit() {
    final total = _calculateTotal();
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          decoration: BoxDecoration(
            color: const Color(0xFF2E7D32).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: const Color(0xFF2E7D32).withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Grand Total',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1F2430),
                ),
              ),
              Text(
                '₹${total.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2E7D32),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton.icon(
            onPressed: _isSubmitting ? null : _submitBilling,
            icon: const Icon(Icons.upload_file),
            label: const Text(
              'Submit Bill',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2E7D32),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Raw Material Selection Page
// =============================================================================

class _RawMaterialSelectionPage extends StatefulWidget {
  final List<Map<String, dynamic>> products;
  final Map<String, Map<String, double>> existing;

  const _RawMaterialSelectionPage({
    required this.products,
    required this.existing,
  });

  @override
  State<_RawMaterialSelectionPage> createState() =>
      _RawMaterialSelectionPageState();
}

class _RawMaterialSelectionPageState extends State<_RawMaterialSelectionPage> {
  late Map<String, Map<String, double>> _selections;
  late Set<String> _selectedIds;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _selections = Map.from(widget.existing);
    _selectedIds = _selections.keys.toSet();
  }

  List<Map<String, dynamic>> get _filteredProducts {
    if (_searchQuery.isEmpty) return widget.products;
    final q = _searchQuery.toLowerCase();
    return widget.products
        .where((p) => (p['name'] ?? '').toString().toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Raw Materials'),
        backgroundColor: const Color(0xFF2E7D32),
        foregroundColor: Colors.white,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _selections),
            child: const Text(
              'Done',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search raw materials...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              onChanged: (v) => setState(() => _searchQuery = v),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _filteredProducts.length,
              itemBuilder: (context, index) {
                final product = _filteredProducts[index];
                final id = product['id'] as String;
                final name = product['name'] as String;
                final unit = product['unit'] ?? '';
                final isSelected = _selectedIds.contains(id);
                final qty = _selections[id]?['quantity'] ?? 0;
                final amt = _selections[id]?['totalAmount'] ?? 0;

                return Card(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: ExpansionTile(
                    leading: Checkbox(
                      value: isSelected,
                      activeColor: const Color(0xFF2E7D32),
                      onChanged: (val) {
                        setState(() {
                          if (val == true) {
                            _selectedIds.add(id);
                            _selections[id] = {
                              'quantity': 0,
                              'totalAmount': 0,
                            };
                          } else {
                            _selectedIds.remove(id);
                            _selections.remove(id);
                          }
                        });
                      },
                    ),
                    title: Text(
                      name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: unit.isNotEmpty ? Text('Unit: $unit') : null,
                    initiallyExpanded: isSelected && qty > 0,
                    children: isSelected
                        ? [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: TextFormField(
                                      initialValue: qty > 0
                                          ? qty.toStringAsFixed(
                                              qty.truncateToDouble() == qty
                                                  ? 0
                                                  : 2)
                                          : '',
                                      keyboardType: const TextInputType
                                          .numberWithOptions(decimal: true),
                                      decoration: InputDecoration(
                                        labelText: 'Quantity',
                                        border: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        isDense: true,
                                      ),
                                      onChanged: (v) {
                                        _selections[id]?['quantity'] =
                                            double.tryParse(v) ?? 0;
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: TextFormField(
                                      initialValue: amt > 0
                                          ? amt.toStringAsFixed(2)
                                          : '',
                                      keyboardType: const TextInputType
                                          .numberWithOptions(decimal: true),
                                      decoration: InputDecoration(
                                        labelText: 'Amount (₹)',
                                        border: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        isDense: true,
                                      ),
                                      onChanged: (v) {
                                        _selections[id]?['totalAmount'] =
                                            double.tryParse(v) ?? 0;
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ]
                        : [],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
