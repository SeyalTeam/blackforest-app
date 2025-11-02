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
import 'package:blackforest_app/categories_page.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img_lib;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http_parser/http_parser.dart';

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
  Map<String, String> _productPhotos = {}; // productId: mediaId from upload
  Map<String, File?> _tempPhotos = {}; // Temp file for preview/offline
  Map<String, String> _photoUrls = {}; // Cache URLs from media ID for remote display

  @override
  void initState() {
    super.initState();
    _fetchProducts();
    _loadPendingPhotos(); // Load/retry queued on init
  }

  Future<void> _loadPendingPhotos() async {
    final prefs = await SharedPreferences.getInstance();
    for (var key in prefs.getKeys()) {
      if (key.startsWith('pending_photo_')) {
        final productId = key.replaceFirst('pending_photo_', '');
        final path = prefs.getString(key);
        if (path != null) {
          final file = File(path);
          if (await file.exists()) {
            final product = _products.firstWhere((p) => p['id'] == productId, orElse: () => {'name': 'Unknown'});
            final altText = product['name'] ?? 'Return proof for product $productId';
            final mediaId = await _uploadPhoto(file, altText);
            if (mediaId != null) {
              setState(() {
                _productPhotos[productId] = mediaId;
                _tempPhotos[productId] = file;
              });
              prefs.remove(key);
              // Fetch URL after retry
              final url = await _fetchMediaUrl(mediaId);
              if (url != null) _photoUrls[productId] = url;
            }
          }
        }
      }
    }
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
      final response = await http.get(
        Uri.parse('https://admin.theblackforestcakes.com/api/users/me?depth=2'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final user = data['user'] ?? data;
        setState(() {
          _userRole = user['role'];
        });
        if (user['role'] == 'branch' && user['branch'] != null) {
          setState(() {
            _branchId = (user['branch'] is Map) ? user['branch']['id'] : user['branch'];
          });
        } else if (user['role'] == 'waiter') {
          await _fetchWaiterBranch(token);
        }
      }
    } catch (e) {
      // Handle silently
    }
  }

  Future<void> _fetchWaiterBranch(String token) async {
    String? deviceIp = await _fetchDeviceIp();
    if (deviceIp == null) return;
    try {
      final response = await http.get(
        Uri.parse('https://admin.theblackforestcakes.com/api/branches?depth=1'),
        headers: {'Authorization': 'Bearer $token'},
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
            break;
          }
        }
      }
    } catch (e) {
      // Handle silently
    }
  }

  Future<void> _fetchProducts() async {
    setState(() {
      _isLoading = true;
    });
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
      String url = 'https://admin.theblackforestcakes.com/api/products?where[category][equals]=${widget.categoryId}&limit=100&depth=1';
      final response = await http.get(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        setState(() {
          _products = data['docs'] ?? [];
          _isLoading = false;
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to fetch products: ${response.statusCode}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error: Check your internet')),
      );
    }
    setState(() {
      _isLoading = false;
    });
  }

  void _toggleReturnSelection(int index) {
    final product = _products[index];
    final provider = Provider.of<ReturnProvider>(context, listen: false);
    double price = product['defaultPriceDetails']?['price']?.toDouble() ?? 0.0;
    if (_branchId != null && product['branchOverrides'] != null) {
      for (var override in product['branchOverrides']) {
        var branch = override['branch'];
        String branchOid = branch is Map ? branch[r'$oid'] ?? branch['id'] ?? '' : branch ?? '';
        if (branchOid == _branchId) {
          price = override['price']?.toDouble() ?? price;
          break;
        }
      }
    }
    final matching = provider.returnItems.where((i) => i.id == product['id']).toList();
    final currentQty = matching.isNotEmpty ? matching.first.quantity : 0;
    final newQty = currentQty + 1;
    provider.addOrUpdateItem(product['id'], product['name'], newQty, price);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${product['name']} return qty updated to $newQty')),
    );
  }

  void _handleScan(String scanResult) {
    final provider = Provider.of<ReturnProvider>(context, listen: false);
    for (int index = 0; index < _products.length; index++) {
      final product = _products[index];
      if (product['upc'] == scanResult) {
        _toggleReturnSelection(index);
        return;
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Product not found in this category')),
    );
  }

  Future<void> _submitReturnOrders() async {
    final provider = Provider.of<ReturnProvider>(context, listen: false);
    // Retry pending uploads
    await _loadPendingPhotos();
    // Validate photos conditionally
    for (var item in provider.returnItems) {
      if (item.quantity > 1 && !_productPhotos.containsKey(item.id)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo proof required for items with quantity >1')),
        );
        return;
      }
    }
    await provider.submitReturn(context, _branchId, _productPhotos);
    // Cleanup
    for (var file in _tempPhotos.values) {
      if (file != null && await file.exists()) await file.delete();
    }
    _tempPhotos.clear();
    _productPhotos.clear();
    _photoUrls.clear();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const CategoriesPage(isStockFilter: true)),
    );
  }

  Future<void> _capturePhoto(String productId) async {
    if (await Permission.camera.request().isDenied) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Camera permission required for photo proof')),
      );
      return;
    }
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No camera available')),
      );
      return;
    }
    final XFile? photo = await showDialog<XFile>(
      context: context,
      builder: (context) => CameraDialog(cameras: cameras),
    );
    if (photo == null) return;
    // Compress
    final bytes = await photo.readAsBytes();
    final image = img_lib.decodeImage(bytes)!;
    final compressed = img_lib.encodeJpg(image, quality: 70);
    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final tempFile = File('${tempDir.path}/return_${productId}_$timestamp.jpg');
    await tempFile.writeAsBytes(compressed);
    // Preview dialog
    bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Photo Preview'),
        content: Image.file(tempFile),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Retake')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirm')),
        ],
      ),
    );
    if (confirmed != true) {
      await tempFile.delete();
      return _capturePhoto(productId); // Retake
    }
    // Find product name for alt
    final product = _products.firstWhere((p) => p['id'] == productId, orElse: () => {'name': 'Unknown Product'});
    final altText = product['name'] ?? 'Return proof for product $productId';
    // Upload with alt and MIME
    final mediaId = await _uploadPhoto(tempFile, altText);
    if (mediaId != null) {
      setState(() {
        _productPhotos[productId] = mediaId;
        _tempPhotos[productId] = tempFile;
      });
      // Fetch URL for remote display
      final url = await _fetchMediaUrl(mediaId);
      if (url != null) {
        setState(() {
          _photoUrls[productId] = url;
        });
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Upload failed. Photo saved locally for retry.')),
      );
      // Queue for offline
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pending_photo_$productId', tempFile.path);
    }
  }

  Future<String?> _fetchMediaUrl(String mediaId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) return null;
      final response = await http.get(
        Uri.parse('https://admin.theblackforestcakes.com/api/media/$mediaId?depth=0'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['url']; // Assume 'url' field; adjust if different (e.g., data['filename'] for Blob path)
      }
    } catch (e) {
      print('Fetch URL error: $e');
    }
    return null;
  }

  Future<String?> _uploadPhoto(File file, String altText) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) return null;
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('https://admin.theblackforestcakes.com/api/media?prefix=returnorder'),
      );
      request.headers['Authorization'] = 'Bearer $token';
      request.fields['alt'] = altText; // Use product name as alt
      request.files.add(http.MultipartFile(
        'file',
        file.readAsBytes().asStream(),
        file.lengthSync(),
        filename: file.path.split('/').last,
        contentType: MediaType('image', 'jpeg'), // Set MIME
      ));
      final response = await request.send();
      if (response.statusCode == 201 || response.statusCode == 200) {
        final body = await response.stream.bytesToString();
        final data = jsonDecode(body);
        return data['doc']['id'];  // Updated to ['doc']['id'] as per Payload response
      } else {
        final body = await response.stream.bytesToString();
        print('Upload error: ${response.statusCode} - $body'); // For debugging
        return null;
      }
    } catch (e) {
      print('Upload exception: $e'); // For debugging
      return null;
    }
  }

  Future<void> _handleCameraTap(String productId) async {
    final hasPhoto = _productPhotos.containsKey(productId) || _tempPhotos.containsKey(productId);
    if (!hasPhoto) {
      await _capturePhoto(productId);
    } else {
      final file = _tempPhotos[productId];
      String? previewUrl = _photoUrls[productId];
      Widget previewWidget;
      if (file != null && await file.exists()) {
        previewWidget = Image.file(file);
      } else if (previewUrl != null) {
        previewWidget = CachedNetworkImage(imageUrl: previewUrl, fit: BoxFit.contain);
      } else {
        previewWidget = const Text('No preview available');
      }
      final retake = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Current Photo'),
          content: previewWidget,
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Retake')),
          ],
        ),
      );
      if (retake == true) {
        await _capturePhoto(productId); // Overwrite
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Return Order Products in ${widget.categoryName}',
      pageType: PageType.stock,
      onScanCallback: _handleScan,
      body: Column(
        children: [
          Consumer<ReturnProvider>(
            builder: (context, provider, child) {
              return Padding(
                padding: const EdgeInsets.all(16.0),
                child: ElevatedButton(
                  onPressed: provider.returnItems.isNotEmpty ? _submitReturnOrders : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Confirm Return Order'),
                ),
              );
            },
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Colors.black))
                : _products.isEmpty
                ? const Center(
              child: Text('No products found', style: TextStyle(color: Color(0xFF4A4A4A), fontSize: 18)),
            )
                : LayoutBuilder(
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
                  itemCount: _products.length,
                  itemBuilder: (context, index) {
                    final product = _products[index];
                    final id = product['id'];
                    String? imageUrl;
                    if (product['images'] != null &&
                        product['images'].isNotEmpty &&
                        product['images'][0]['image'] != null &&
                        product['images'][0]['image']['url'] != null) {
                      imageUrl = product['images'][0]['image']['url'];
                      if (imageUrl != null && imageUrl.startsWith('/')) {
                        imageUrl = 'https://admin.theblackforestcakes.com$imageUrl';
                      }
                    }
                    imageUrl ??= 'https://via.placeholder.com/150?text=No+Image';
                    dynamic priceDetails = product['defaultPriceDetails'];
                    if (_branchId != null && product['branchOverrides'] != null) {
                      for (var override in product['branchOverrides']) {
                        var branch = override['branch'];
                        String branchOid = branch is Map ? branch[r'$oid'] ?? branch['id'] ?? '' : branch ?? '';
                        if (branchOid == _branchId) {
                          priceDetails = override;
                          break;
                        }
                      }
                    }
                    final price = priceDetails != null ? '₹${priceDetails['price'] ?? 0}' : '₹0';
                    return GestureDetector(
                      onTap: () => _toggleReturnSelection(index),
                      child: Consumer<ReturnProvider>(
                        builder: (context, provider, child) {
                          final matching = provider.returnItems.where((i) => i.id == id).toList();
                          final isSelected = matching.isNotEmpty && matching.first.quantity > 0;
                          final qty = isSelected ? matching.first.quantity : 0;
                          final hasPhoto = _tempPhotos.containsKey(id) || _productPhotos.containsKey(id);
                          return Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: isSelected ? Border.all(color: Colors.green, width: 4) : null,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.grey.withOpacity(0.1),
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
                                        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                                        child: CachedNetworkImage(
                                          imageUrl: imageUrl!,
                                          fit: BoxFit.cover,
                                          width: double.infinity,
                                          placeholder: (context, url) => const Center(child: CircularProgressIndicator()),
                                          errorWidget: (context, url, error) => const Center(child: Text('No Image', style: TextStyle(color: Colors.grey))),
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      flex: 2,
                                      child: Container(
                                        width: double.infinity,
                                        decoration: const BoxDecoration(
                                          color: Colors.black,
                                          borderRadius: BorderRadius.vertical(bottom: Radius.circular(8)),
                                        ),
                                        alignment: Alignment.center,
                                        child: Text(
                                          product['name'] ?? 'Unknown',
                                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
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
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
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
                                        border: hasPhoto ? Border.all(color: Colors.green, width: 2) : null,
                                      ),
                                      child: _tempPhotos.containsKey(id) && _tempPhotos[id] != null
                                          ? ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: Image.file(
                                          _tempPhotos[id]!,
                                          width: 24,
                                          height: 24,
                                          fit: BoxFit.cover,
                                        ),
                                      )
                                          : _photoUrls.containsKey(id)
                                          ? ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: CachedNetworkImage(
                                          imageUrl: _photoUrls[id]!,
                                          width: 24,
                                          height: 24,
                                          fit: BoxFit.cover,
                                          placeholder: (context, url) => const CircularProgressIndicator(strokeWidth: 2),
                                          errorWidget: (context, url, error) => Icon(
                                            Icons.camera_alt,
                                            color: hasPhoto ? Colors.green : Colors.white,
                                            size: 20,
                                          ),
                                        ),
                                      )
                                          : Icon(
                                        Icons.camera_alt,
                                        color: hasPhoto ? Colors.green : Colors.white,
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
                                          color: Colors.black.withOpacity(0.7),
                                          border: Border.all(color: Colors.grey, width: 1),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        child: Text(
                                          '$qty',
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
            ),
          ),
        ],
      ),
    );
  }
}

class CameraDialog extends StatefulWidget {
  final List<CameraDescription> cameras;

  const CameraDialog({super.key, required this.cameras});

  @override
  _CameraDialogState createState() => _CameraDialogState();
}

class _CameraDialogState extends State<CameraDialog> {
  late CameraController _controller;

  @override
  void initState() {
    super.initState();
    _controller = CameraController(widget.cameras[0], ResolutionPreset.high);
    _controller.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
    }).catchError((e) {
      print('Camera init error: $e');
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return AlertDialog(
      content: AspectRatio(
        aspectRatio: _controller.value.aspectRatio,
        child: CameraPreview(_controller),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          onPressed: () async {
            try {
              final XFile file = await _controller.takePicture();
              Navigator.pop(context, file);
            } catch (e) {
              print('Capture error: $e');
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Failed to capture photo')),
              );
              Navigator.pop(context);
            }
          },
          child: const Text('Capture'),
        ),
      ],
    );
  }
}