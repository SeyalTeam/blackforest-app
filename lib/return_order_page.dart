import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:provider/provider.dart';
import 'package:blackforest_app/return_provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img_lib;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http_parser/http_parser.dart';
import 'package:blackforest_app/api_config.dart';
import 'package:blackforest_app/camera_page.dart';

class ReturnOrderPage extends StatefulWidget {
  final String categoryId;
  final String categoryName;

  const ReturnOrderPage({
    super.key,
    required this.categoryId,
    required this.categoryName,
  });

  @override
  _ReturnOrderPageState createState() => _ReturnOrderPageState();
}

class _ReturnOrderPageState extends State<ReturnOrderPage> {
  List<dynamic> _products = [];
  bool _isLoading = true;
  String? _branchId;
  String? _userRole;
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  bool _showAsGrid = true;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<dynamic> get _filteredProducts {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return _products;
    return _products.where((p) {
      final name = (p['name'] ?? '').toString().toLowerCase();
      final upc = (p['upc'] ?? '').toString().toLowerCase();
      return name.contains(query) || upc.contains(query);
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _fetchProducts().then((_) {
      // Load pending AFTER products fetched (for alt text)
      final provider = Provider.of<ReturnProvider>(context, listen: false);
      provider.loadPendingPhotos(_products);
    });
  }

  int _ipToInt(String ip) {
    final parts = ip.split('.').map(int.parse).toList();
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
  }

  bool _isIpInRange(String deviceIp, String range) {
    final parts = range.split('-');
    if (parts.length != 2) return false;
    final startIp = _ipToInt(parts[0].trim());
    final endIp = _ipToInt(parts[1].trim());
    final device = _ipToInt(deviceIp);
    return device >= startIp && device <= endIp;
  }

  Future<String?> _fetchDeviceIp() async {
    try {
      final info = NetworkInfo();
      final ip = await info.getWifiIP();
      return ip?.trim();
    } catch (e) {
      return null;
    }
  }

  Future<void> _fetchUserData(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final localBranchId = prefs.getString('branchId');

      final response = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/users/me?depth=2'),
        headers: ApiConfig.getHeaders(token),
      );
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final user = data['user'] ?? data;
        setState(() {
          _userRole = user['role'];
        });

        if (localBranchId != null && localBranchId.isNotEmpty) {
          setState(() {
            _branchId = localBranchId;
          });
          Provider.of<ReturnProvider>(
            context,
            listen: false,
          ).setBranchId(_branchId);
        } else if (user['branch'] != null) {
          setState(() {
            _branchId = (user['branch'] is Map)
                ? user['branch']['id']
                : user['branch'];
          });
          Provider.of<ReturnProvider>(
            context,
            listen: false,
          ).setBranchId(_branchId);
        } else if (user['role'] == 'waiter' ||
            user['role'] == 'kitchen' ||
            user['role'] == 'chef' ||
            user['role'] == 'manager' ||
            user['role'] == 'cashier') {
          await _fetchWaiterBranch(token);
        }
      }
    } catch (e) {}
  }

  Future<void> _fetchWaiterBranch(String token) async {
    String? deviceIp = await _fetchDeviceIp();
    if (deviceIp == null) return;
    try {
      final response = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/branches?depth=1'),
        headers: ApiConfig.getHeaders(token),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final branches = data['docs'] ?? [];
        for (var branch in branches) {
          String? branchIp = branch['ipAddress']?.toString().trim();
          if (branchIp == null) continue;
          if (branchIp == deviceIp || _isIpInRange(deviceIp, branchIp)) {
            setState(() {
              _branchId = branch['id'];
            });
            Provider.of<ReturnProvider>(
              context,
              listen: false,
            ).setBranchId(_branchId);
            break;
          }
        }
      }
    } catch (e) {}
  }

  Future<void> _fetchProducts() async {
    setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No token found. Please login again.')),
        );
        return;
      }
      if (_branchId == null && _userRole == null) {
        await _fetchUserData(token);
      }
      final url =
          '${ApiConfig.baseUrl}/products?where[category][equals]=${widget.categoryId}&limit=100&depth=1';
      final response = await http.get(
        Uri.parse(url),
        headers: ApiConfig.getHeaders(token),
      );
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        setState(() {
          _products = data['docs'] ?? [];
          _isLoading = false;
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to fetch products: ${response.statusCode}'),
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Network error, try again')));
    }
    setState(() => _isLoading = false);
  }

  Future<void> _promptReturnQuantity(dynamic product) async {
    final provider = Provider.of<ReturnProvider>(context, listen: false);
    final String id = (product['id'] ?? product['_id'])?.toString() ?? '';

    // Step 1: Get product price
    double price =
        (product['defaultPriceDetails']?['price'] as num?)?.toDouble() ?? 0.0;
    if (_branchId != null && product['branchOverrides'] != null) {
      for (var override in product['branchOverrides']) {
        var branch = override['branch'];
        String branchOid = branch is Map
            ? (branch[r'$oid'] ?? branch['id'] ?? '')
            : (branch ?? '');
        if (branchOid == _branchId) {
          price = (override['price'] as num?)?.toDouble() ?? price;
          break;
        }
      }
    }

    // Step 2: Detect if the product is weight-based
    bool isWeightBased = false;
    try {
      final unit = product['defaultPriceDetails']?['unit']
          ?.toString()
          .toLowerCase();
      final isKgFlag =
          product['isKg'] == true ||
          product['sellByWeight'] == true ||
          product['weightBased'] == true;
      final pricingType = product['pricingType']?.toString().toLowerCase();

      if (unit != null && (unit.contains('kg') || unit.contains('gram'))) {
        isWeightBased = true;
      }
      if (isKgFlag) isWeightBased = true;
      if (pricingType != null && pricingType.contains('kg')) {
        isWeightBased = true;
      }
    } catch (e) {
      isWeightBased = false;
    }

    // Step 3: Get current quantity if exists
    final matching = provider.returnItems.where((i) => i.id == id).toList();
    final double existingQty =
        matching.isNotEmpty ? matching.first.quantity : 0.0;
    final rawUnit = product['defaultPriceDetails']?['unit']?.toString().trim();
    final unit = (rawUnit != null && rawUnit.isNotEmpty)
        ? rawUnit
        : (isWeightBased ? 'kg' : 'pcs');

    String initialText = '';
    if (existingQty > 0) {
      if (existingQty == existingQty.floorToDouble()) {
        initialText = existingQty.toInt().toString();
      } else {
        initialText = existingQty.toString();
      }
    }

    final TextEditingController qtyController =
        TextEditingController(text: initialText);
    qtyController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: initialText.length,
    );

    final enteredQty = await showDialog<double>(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return AlertDialog(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                product['name'] ?? 'Product',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                isWeightBased
                    ? 'Enter Return Weight ($unit)'
                    : 'Enter Return Quantity ($unit)',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.normal,
                  color: Colors.grey.shade700,
                ),
              ),
            ],
          ),
          content: TextField(
            controller: qtyController,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
            ),
            decoration: InputDecoration(
              hintText: isWeightBased ? 'e.g. 0.5' : 'e.g. 100',
              labelText:
                  isWeightBased ? 'Weight in $unit' : 'Quantity in $unit',
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (val) {
              final value = double.tryParse(val.trim()) ?? 0.0;
              Navigator.pop(context, value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final value =
                    double.tryParse(qtyController.text.trim()) ?? 0.0;
                Navigator.pop(context, value);
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );

    if (enteredQty == null || enteredQty < 0) return;

    if (enteredQty == 0) {
      provider.removeItem(id);
    } else {
      if (matching.isNotEmpty) {
        provider.updateQuantity(id, enteredQty);
      } else {
        provider.addOrUpdateItem(
          id,
          product['name'] ?? 'Product',
          enteredQty,
          price,
        );
      }
    }

    // Auto-clear search on quantity confirmation
    if (_searchCtrl.text.isNotEmpty) {
      _searchCtrl.clear();
      setState(() {
        _searchQuery = '';
      });
      FocusScope.of(context).unfocus();
    } else {
      setState(() {});
    }
  }

  void _toggleReturnSelection(int index) {
    final list = _filteredProducts;
    if (index >= 0 && index < list.length) {
      _promptReturnQuantity(list[index]);
    }
  }

  void _handleScan(String scanResult) {
    for (var product in _products) {
      if (product['upc'] == scanResult) {
        _promptReturnQuantity(product);
        return;
      }
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Product not found')));
  }

  Future<void> _submitReturnOrders() async {
    final provider = Provider.of<ReturnProvider>(context, listen: false);
    await provider.submitReturn(context, _branchId);
    // Navigation handled in provider
  }

  Future<void> _capturePhoto(String productId) async {
    if (await Permission.camera.request().isDenied) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Camera permission required')),
      );
      return;
    }
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No camera found')));
      return;
    }
    final XFile? photo = await Navigator.push<XFile>(
      context,
      MaterialPageRoute(builder: (context) => CameraPage(cameras: cameras)),
    );
    if (photo == null) return;
    final bytes = await photo.readAsBytes();
    final image = img_lib.decodeImage(bytes);
    if (image == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to process captured image')),
      );
      return;
    }
    final compressed = img_lib.encodeJpg(image, quality: 70);
    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final tempFile = File('${tempDir.path}/return_${productId}_$timestamp.jpg');
    await tempFile.writeAsBytes(compressed);
    final product = _products.firstWhere(
      (p) => p['id'] == productId,
      orElse: () => {'name': 'Unknown'},
    );
    final altText = product['name'] ?? 'Return proof';
    final mediaId = await _uploadPhoto(tempFile, altText);
    final provider = Provider.of<ReturnProvider>(context, listen: false);
    if (mediaId != null) {
      final url = await _fetchMediaUrl(mediaId);
      provider.setPhoto(productId, mediaId, tempFile, url);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_lastUploadError ?? 'Upload failed, saved locally'),
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pending_photo_$productId', tempFile.path);
      provider.setPhoto(productId, '', tempFile, null);
    }
  }

  Future<String?> _fetchMediaUrl(String mediaId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) return null;
      final response = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/media/$mediaId?depth=0'),
        headers: ApiConfig.getHeaders(token),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['url'] ?? '${ApiConfig.domain}${data['filename']}';
      }
    } catch (e) {
      debugPrint('Error fetching media url: $e');
    }
    return null;
  }

  Future<File> _prepareImageForUpload(File originalFile, String prefix) async {
    try {
      if (!await originalFile.exists()) return originalFile;
      final length = await originalFile.length();
      if (length < 1500 * 1024) return originalFile;

      final bytes = await originalFile.readAsBytes();
      final image = img_lib.decodeImage(bytes);
      if (image == null) return originalFile;

      img_lib.Image resized = image;
      if (image.width > 1280 || image.height > 1280) {
        if (image.width > image.height) {
          resized = img_lib.copyResize(image, width: 1280);
        } else {
          resized = img_lib.copyResize(image, height: 1280);
        }
      }
      final compressedBytes = img_lib.encodeJpg(resized, quality: 70);
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final tempFile = File('${tempDir.path}/opt_${prefix}_$timestamp.jpg');
      await tempFile.writeAsBytes(compressedBytes);
      return tempFile;
    } catch (_) {
      return originalFile;
    }
  }

  String? _lastUploadError;

  Future<String?> _uploadPhoto(File file, String altText) async {
    _lastUploadError = null;
    try {
      final uploadFile = await _prepareImageForUpload(file, 'returnorder');
      if (!await uploadFile.exists()) {
        _lastUploadError = 'Upload failed: File does not exist';
        return null;
      }
      if (await uploadFile.length() == 0) {
        _lastUploadError = 'Upload failed: File is empty (0 bytes)';
        return null;
      }

      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) {
        _lastUploadError = 'Upload failed: No login token found';
        return null;
      }

      final filename =
          'returnorder_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final urlsToTry = [
        '${ApiConfig.baseUrl}/media?prefix=returnorder',
        '${ApiConfig.baseUrl}/media/?prefix=returnorder',
      ];

      for (final urlStr in urlsToTry) {
        final request = http.MultipartRequest('POST', Uri.parse(urlStr));
        request.followRedirects = false;
        request.headers['Authorization'] = 'Bearer $token';
        request.fields['_payload'] = jsonEncode({
          'alt': altText,
          'prefix': 'returnorder',
        });
        request.fields['alt'] = altText;
        request.fields['prefix'] = 'returnorder';

        final multipartFile = await http.MultipartFile.fromPath(
          'file',
          uploadFile.path,
          filename: filename,
          contentType: MediaType('image', 'jpeg'),
        );
        request.files.add(multipartFile);

        final response = await request.send();
        final body = await response.stream.bytesToString();

        debugPrint(
          'Upload attempt to $urlStr -> Status: ${response.statusCode}, Body: $body',
        );

        if (response.statusCode == 201 || response.statusCode == 200) {
          final data = jsonDecode(body);
          final doc = data['doc'] ?? data;
          return doc['id']?.toString();
        }

        if (response.statusCode >= 300 && response.statusCode < 400) {
          final location = response.headers['location'];
          if (location != null) {
            final resolvedUri = Uri.parse(urlStr).resolve(location);
            final redirRequest = http.MultipartRequest('POST', resolvedUri);
            redirRequest.headers['Authorization'] = 'Bearer $token';
            redirRequest.fields['_payload'] = jsonEncode({
              'alt': altText,
              'prefix': 'returnorder',
            });
            redirRequest.fields['alt'] = altText;
            redirRequest.fields['prefix'] = 'returnorder';
            redirRequest.files.add(
              await http.MultipartFile.fromPath(
                'file',
                uploadFile.path,
                filename: filename,
                contentType: MediaType('image', 'jpeg'),
              ),
            );
            final redirResponse = await redirRequest.send();
            final redirBody = await redirResponse.stream.bytesToString();
            debugPrint(
              'Redirect upload response -> Status: ${redirResponse.statusCode}, Body: $redirBody',
            );
            if (redirResponse.statusCode == 201 ||
                redirResponse.statusCode == 200) {
              final data = jsonDecode(redirBody);
              final doc = data['doc'] ?? data;
              return doc['id']?.toString();
            }
            _lastUploadError =
                'Upload failed (${redirResponse.statusCode}): $redirBody';
          }
        } else {
          _lastUploadError = 'Upload failed (${response.statusCode}): $body';
        }
      }
    } catch (e) {
      debugPrint('Upload exception: $e');
      _lastUploadError = 'Upload exception: $e';
    }
    return null;
  }

  Future<void> _handleCameraTap(String productId) async {
    final provider = Provider.of<ReturnProvider>(context, listen: false);
    final hasPhoto = provider.hasPhoto(productId);
    if (!hasPhoto) {
      await _capturePhoto(productId);
    } else {
      final file = provider.getTempPhoto(productId);
      String? previewUrl = provider.getPhotoUrl(productId);
      Widget previewWidget;
      if (file != null && await file.exists()) {
        previewWidget = Image.file(file);
      } else if (previewUrl != null) {
        previewWidget = CachedNetworkImage(
          imageUrl: previewUrl,
          fit: BoxFit.contain,
        );
      } else {
        previewWidget = const Text('No preview available');
      }
      final retake = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Current Photo'),
          content: previewWidget,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Retake'),
            ),
          ],
        ),
      );
      if (retake == true) {
        await _capturePhoto(productId);
      }
    }
  }

  Future<void> _unselectProduct(String productId) async {
    final provider = Provider.of<ReturnProvider>(context, listen: false);
    provider.removeItem(productId);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Product unselected and photo removed')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Return Order: ${widget.categoryName}',
      pageType: PageType.returnorder,
      onScanCallback: _handleScan,
      body: Column(
        children: [
          // SEARCH BAR
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.grey.withValues(alpha: 0.18),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: TextField(
                controller: _searchCtrl,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: "Search in ${widget.categoryName}...",
                  hintStyle:
                      TextStyle(color: Colors.grey.shade400, fontSize: 14),
                  prefixIcon: const Icon(Icons.search, color: Colors.grey),
                  suffixIcon: _searchCtrl.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, color: Colors.grey),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() {
                              _searchQuery = '';
                            });
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
                onChanged: (val) {
                  setState(() {
                    _searchQuery = val;
                  });
                },
              ),
            ),
          ),

          // HEADER ROW: PRODUCTS COUNT + SINGLE FIXED TOGGLE BUTTON
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Products (${_filteredProducts.length})',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade700,
                  ),
                ),
                InkWell(
                  onTap: () {
                    setState(() {
                      _showAsGrid = !_showAsGrid;
                    });
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade300),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.grey.withValues(alpha: 0.08),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _showAsGrid
                              ? Icons.view_list_rounded
                              : Icons.grid_view_rounded,
                          size: 16,
                          color: const Color(0xFF0F766E),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          _showAsGrid ? 'List View' : 'Grid View',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF0F766E),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.black),
                  )
                : _filteredProducts.isEmpty
                ? Center(
                    child: Text(
                      _searchQuery.isNotEmpty
                          ? 'No products match "$_searchQuery"'
                          : 'No products found',
                      style: const TextStyle(
                          color: Color(0xFF4A4A4A), fontSize: 18),
                    ),
                  )
                : (_showAsGrid
                    ? _buildProductGrid(context)
                    : _buildGoogleSearchList(context)),
          ),
        ],
      ),
    );
  }

  // ========================== GOOGLE SEARCH SUGGESTIONS LIST ===========================
  Widget _buildGoogleSearchList(BuildContext context) {
    final list = _filteredProducts;
    if (list.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 54,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 12),
            Text(
              'No return products found for "$_searchQuery"',
              style: TextStyle(
                fontSize: 15,
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }

    return Consumer<ReturnProvider>(
      builder: (context, returnProvider, _) {
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          itemCount: list.length,
          itemBuilder: (context, index) {
            final p = list[index];
            return _buildSuggestionTile(context, returnProvider, p);
          },
        );
      },
    );
  }

  Widget _buildSuggestionTile(
    BuildContext context,
    ReturnProvider returnProvider,
    dynamic p,
  ) {
    final id = (p['id'] ?? p['_id'])?.toString() ?? '';
    final name = p['name']?.toString() ?? 'Unknown';

    final matching =
        returnProvider.returnItems.where((i) => i.id == id).toList();
    final isSelected = matching.isNotEmpty && matching.first.quantity > 0;
    final qtyNum = isSelected ? matching.first.quantity : 0.0;
    final qtyText = (qtyNum == qtyNum.floorToDouble())
        ? qtyNum.toInt().toString()
        : qtyNum.toStringAsFixed(2);

    dynamic priceDetails = p['defaultPriceDetails'];
    if (_branchId != null && p['branchOverrides'] != null) {
      for (var override in p['branchOverrides']) {
        var branch = override['branch'];
        String branchOid = branch is Map
            ? (branch[r'$oid'] ?? branch['id'] ?? '')
            : (branch ?? '');
        if (branchOid == _branchId) {
          priceDetails = override;
          break;
        }
      }
    }
    final price = (priceDetails?['price'] as num?)?.toDouble() ?? 0.0;
    final rawUnit = priceDetails?['unit']?.toString() ?? '';
    final isKgFlag = p['isKg'] == true ||
        p['sellByWeight'] == true ||
        p['weightBased'] == true;
    final unit = rawUnit.isNotEmpty ? rawUnit : (isKgFlag ? 'kg' : 'pcs');

    String? imageUrl;
    if (p['images'] != null &&
        p['images'].isNotEmpty &&
        p['images'][0]['image'] != null &&
        p['images'][0]['image']['url'] != null) {
      imageUrl = p['images'][0]['image']['url'];
      if (imageUrl != null && imageUrl.startsWith('/')) {
        imageUrl = '${ApiConfig.domain}$imageUrl';
      }
    }

    final hasPhoto = returnProvider.hasPhoto(id);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFFF1F8E9) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isSelected ? Colors.green.shade400 : Colors.grey.shade200,
          width: isSelected ? 1.5 : 1,
        ),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        onTap: () => _promptReturnQuantity(p),
        leading: Stack(
          alignment: Alignment.center,
          children: [
            if (imageUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CachedNetworkImage(
                  imageUrl: imageUrl,
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                    width: 40,
                    height: 40,
                    color: Colors.grey.shade100,
                    child:
                        const Icon(Icons.search, size: 20, color: Colors.grey),
                  ),
                  errorWidget: (_, __, ___) => Container(
                    width: 40,
                    height: 40,
                    color: Colors.grey.shade100,
                    child:
                        const Icon(Icons.search, size: 20, color: Colors.grey),
                  ),
                ),
              )
            else
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isSelected
                      ? Colors.green.shade100
                      : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  isSelected
                      ? Icons.check_circle_rounded
                      : Icons.inventory_2_outlined,
                  color:
                      isSelected ? Colors.green.shade700 : Colors.grey.shade600,
                  size: 20,
                ),
              ),
          ],
        ),
        title: _buildHighlightedText(name, _searchQuery.trim()),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            "₹${price.toStringAsFixed(0)}",
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700,
            ),
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: () => _handleCameraTap(id),
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: hasPhoto ? Colors.green.shade700 : Colors.black,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(
                  Icons.camera_alt,
                  color: Colors.white,
                  size: 16,
                ),
              ),
            ),
            const SizedBox(width: 8),
            isSelected
                ? Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.green.shade700,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          "$qtyText $unit",
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.edit, color: Colors.white, size: 12),
                      ],
                    ),
                  )
                : Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(14),
                      color: Colors.grey.shade50,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add, size: 14, color: Colors.grey.shade700),
                        const SizedBox(width: 2),
                        Text(
                          "Add",
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade800,
                          ),
                        ),
                      ],
                    ),
                  ),
          ],
        ),
      ),
    );
  }

  Widget _buildHighlightedText(String text, String query) {
    if (query.isEmpty) {
      return Text(
        text,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final index = lowerText.indexOf(lowerQuery);

    if (index == -1) {
      return Text(
        text,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    final before = text.substring(0, index);
    final match = text.substring(index, index + query.length);
    final after = text.substring(index + query.length);

    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: const TextStyle(fontSize: 15, color: Colors.black87),
        children: [
          if (before.isNotEmpty)
            TextSpan(
              text: before,
              style: const TextStyle(fontWeight: FontWeight.normal),
            ),
          TextSpan(
            text: match,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.black,
              backgroundColor: Color(0x33FFD54F),
            ),
          ),
          if (after.isNotEmpty)
            TextSpan(
              text: after,
              style: const TextStyle(fontWeight: FontWeight.normal),
            ),
        ],
      ),
    );
  }

  // ========================== PRODUCT GRID ===========================
  Widget _buildProductGrid(BuildContext context) {
    final list = _filteredProducts;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = (width > 600) ? 5 : 3;
        return GridView.builder(
          padding: const EdgeInsets.all(10),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 0.75,
          ),
          itemCount: list.length,
          itemBuilder: (context, index) {
            final product = list[index];
            final id = product['id'];
            String? imageUrl;
            if (product['images'] != null &&
                product['images'].isNotEmpty &&
                product['images'][0]['image'] != null &&
                product['images'][0]['image']['url'] != null) {
              imageUrl = product['images'][0]['image']['url'];
              if (imageUrl != null && imageUrl.startsWith('/')) {
                imageUrl = '${ApiConfig.domain}$imageUrl';
              }
            }
            imageUrl ??= 'https://via.placeholder.com/150?text=No+Image';
            dynamic priceDetails = product['defaultPriceDetails'];
            if (_branchId != null && product['branchOverrides'] != null) {
              for (var override in product['branchOverrides']) {
                var branch = override['branch'];
                String branchOid = branch is Map
                    ? branch[r'$oid'] ?? branch['id'] ?? ''
                    : branch ?? '';
                if (branchOid == _branchId) {
                  priceDetails = override;
                  break;
                }
              }
            }
            final price = priceDetails != null
                ? '₹${priceDetails['price'] ?? 0}'
                : '₹0';
            return GestureDetector(
              onTap: () => _promptReturnQuantity(product),
              child: Consumer<ReturnProvider>(
                builder: (context, provider, child) {
                  final matching =
                      provider.returnItems.where((i) => i.id == id).toList();
                  final isSelected =
                      matching.isNotEmpty && matching.first.quantity > 0;
                  final qty = isSelected ? matching.first.quantity : 0.0;
                  String qtyText;
                  if (qty == qty.floorToDouble()) {
                    qtyText = qty.toInt().toString();
                  } else {
                    qtyText = qty.toStringAsFixed(2);
                  }
                  final hasPhoto = provider.hasPhoto(id);
                  return Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: isSelected
                          ? Border.all(
                              color: Colors.green,
                              width: 4,
                            )
                          : null,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.grey.withValues(alpha: 0.1),
                          spreadRadius: 2,
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Stack(
                      children: [
                        Column(
                          children: [
                            Expanded(
                              flex: 8,
                              child: ClipRRect(
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(8),
                                ),
                                child: CachedNetworkImage(
                                  imageUrl: imageUrl!,
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                  placeholder: (context, url) => const Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                  errorWidget: (context, url, error) =>
                                      const Center(
                                    child: Text(
                                      'No Image',
                                      style: TextStyle(
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Container(
                                width: double.infinity,
                                decoration: const BoxDecoration(
                                  color: Colors.black,
                                  borderRadius: BorderRadius.vertical(
                                    bottom: Radius.circular(
                                      8,
                                    ),
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  product['name'] ?? 'Unknown',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.center,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Positioned(
                          top: 2,
                          left: 2,
                          child: GestureDetector(
                            onTap: () => _unselectProduct(id),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                price,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 2,
                          right: 2,
                          child: GestureDetector(
                            onTap: () => _handleCameraTap(id),
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: Colors.black,
                                borderRadius: BorderRadius.circular(4),
                                border: hasPhoto
                                    ? Border.all(
                                        color: Colors.green,
                                        width: 2,
                                      )
                                    : null,
                              ),
                              child: provider.getTempPhoto(id) != null &&
                                      provider.getTempPhoto(id)!.existsSync()
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(
                                        4,
                                      ),
                                      child: Image.file(
                                        provider.getTempPhoto(
                                          id,
                                        )!,
                                        width: 24,
                                        height: 24,
                                        fit: BoxFit.cover,
                                      ),
                                    )
                                  : provider.getPhotoUrl(id) != null
                                      ? ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                          child: CachedNetworkImage(
                                            imageUrl:
                                                provider.getPhotoUrl(id)!,
                                            width: 24,
                                            height: 24,
                                            fit: BoxFit.cover,
                                            placeholder: (context, url) =>
                                                const CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                            errorWidget: (
                                              context,
                                              url,
                                              error,
                                            ) =>
                                                Icon(
                                              Icons.camera_alt,
                                              color: hasPhoto
                                                  ? Colors.green
                                                  : Colors.white,
                                              size: 20,
                                            ),
                                          ),
                                        )
                                      : Icon(
                                          Icons.camera_alt,
                                          color: hasPhoto
                                              ? Colors.green
                                              : Colors.white,
                                          size: 20,
                                        ),
                            ),
                          ),
                        ),
                        if (isSelected)
                          Positioned.fill(
                            child: Align(
                              alignment: Alignment.center,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(
                                    0.7,
                                  ),
                                  border: Border.all(
                                    color: Colors.grey,
                                    width: 1,
                                  ),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                child: Text(
                                  qtyText,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
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
            );
          },
        );
      },
    );
  }
}

// CameraDialog class removed in favor of shared CameraPage in camera_page.dart
