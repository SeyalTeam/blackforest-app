import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/api_config.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img_lib;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http_parser/http_parser.dart';
import 'package:blackforest_app/camera_page.dart';

class _PhotoSlot {
  final String label;
  final String prefix;
  File? file;
  String? mediaId;
  String? url;

  _PhotoSlot({required this.label, required this.prefix});
}

class DealerBillingPage extends StatefulWidget {
  const DealerBillingPage({super.key});

  @override
  State<DealerBillingPage> createState() => _DealerBillingPageState();
}

class _DealerBillingPageState extends State<DealerBillingPage> {
  final _formKey = GlobalKey<FormState>();

  List<Map<String, dynamic>> _dealers = [];
  String? _selectedDealerId;
  bool _isLoadingDealers = false;
  bool _isSubmitting = false;

  final List<TextEditingController> _billControllers = [];
  final List<TextEditingController> _invoiceNumberControllers = [];

  List<Map<String, dynamic>> _products = [];
  Map<String, Map<String, dynamic>> _selectedProductQuantities = {};
  bool _isLoadingProducts = false;

  late final _PhotoSlot _billCopySlot;
  late final _PhotoSlot _deliveryPersonSlot;
  final List<File> _productPhotos = [];

  @override
  void initState() {
    super.initState();
    _billCopySlot = _PhotoSlot(label: 'Dealer Bill Copy', prefix: 'dealerbill');
    _deliveryPersonSlot = _PhotoSlot(
      label: 'Delivery Person Photo',
      prefix: 'deliveryperson',
    );
    _addBillField(); // Start with one field
    _fetchDealers();
  }

  @override
  void dispose() {
    for (var controller in _billControllers) {
      controller.dispose();
    }
    for (var controller in _invoiceNumberControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _addBillField() {
    setState(() {
      final controller = TextEditingController();
      controller.addListener(() {
        setState(() {}); // Recalculate total dynamically
      });
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
    for (var controller in _billControllers) {
      total += double.tryParse(controller.text) ?? 0.0;
    }
    return total;
  }

  Future<void> _fetchDealers() async {
    setState(() => _isLoadingDealers = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) throw Exception('No token found');

      final response = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/dealers?limit=200&depth=0'),
        headers: ApiConfig.getHeaders(token),
      );

      if (response.statusCode == 200) {
        final Map<String, dynamic> body = jsonDecode(response.body);
        final List<dynamic> docs = body['docs'] ?? [];
        final List<Map<String, dynamic>> loadedDealers = [];
        for (var doc in docs) {
          final id = doc['id']?.toString() ?? '';
          final name =
              doc['companyName']?.toString() ??
              doc['name']?.toString() ??
              'Unknown Dealer';
          loadedDealers.add({'id': id, 'name': name});
        }
        // Sort alphabetically by name
        loadedDealers.sort(
          (a, b) => a['name'].toString().toLowerCase().compareTo(
            b['name'].toString().toLowerCase(),
          ),
        );
        setState(() {
          _dealers = loadedDealers;
        });
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

  Future<void> _fetchProducts(String dealerId) async {
    setState(() => _isLoadingProducts = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) throw Exception('No token found');

      final response = await http.get(
        Uri.parse(
          '${ApiConfig.baseUrl}/products?where[dealer][equals]=$dealerId&limit=500&depth=0',
        ),
        headers: ApiConfig.getHeaders(token),
      );

      if (response.statusCode == 200) {
        final Map<String, dynamic> body = jsonDecode(response.body);
        final List<dynamic> docs = body['docs'] ?? [];
        final List<Map<String, dynamic>> loadedProducts = [];
        for (var doc in docs) {
          final id = doc['id']?.toString() ?? '';
          final name = doc['name']?.toString() ?? 'Unknown Product';
          loadedProducts.add({'id': id, 'name': name});
        }
        loadedProducts.sort(
          (a, b) => a['name'].toString().toLowerCase().compareTo(
            b['name'].toString().toLowerCase(),
          ),
        );
        setState(() {
          _products = loadedProducts;
        });
      } else {
        throw Exception('Failed to load products: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error fetching products: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() => _isLoadingProducts = false);
    }
  }

  Future<void> _capturePhoto(_PhotoSlot slot) async {
    if (await Permission.camera.request().isDenied) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Camera permission required')),
        );
      }
      return;
    }
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No camera found')));
      }
      return;
    }
    if (!mounted) return;
    final XFile? photo = await Navigator.push<XFile>(
      context,
      MaterialPageRoute(
        builder: (context) => CameraPage(cameras: cameras),
        fullscreenDialog: true,
      ),
    );
    if (photo == null) return;

    final bytes = await photo.readAsBytes();
    File finalFile;
    try {
      final image = img_lib.decodeImage(bytes);
      if (image != null) {
        final compressed = img_lib.encodeJpg(image, quality: 70);
        final tempDir = await getTemporaryDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final tempFile = File('${tempDir.path}/${slot.prefix}_$timestamp.jpg');
        await tempFile.writeAsBytes(compressed);
        finalFile = tempFile;
      } else {
        finalFile = File(photo.path);
      }
    } catch (_) {
      finalFile = File(photo.path);
    }

    setState(() {
      slot.file = finalFile;
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
    if (await Permission.camera.request().isDenied) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Camera permission required')),
        );
      }
      return;
    }
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No camera found')));
      }
      return;
    }
    if (!mounted) return;
    final XFile? photo = await Navigator.push<XFile>(
      context,
      MaterialPageRoute(
        builder: (context) => CameraPage(cameras: cameras),
        fullscreenDialog: true,
      ),
    );
    if (photo == null) return;

    final bytes = await photo.readAsBytes();
    File finalFile;
    try {
      final image = img_lib.decodeImage(bytes);
      if (image != null) {
        final compressed = img_lib.encodeJpg(image, quality: 70);
        final tempDir = await getTemporaryDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final tempFile = File('${tempDir.path}/dealerproducts_$timestamp.jpg');
        await tempFile.writeAsBytes(compressed);
        finalFile = tempFile;
      } else {
        finalFile = File(photo.path);
      }
    } catch (_) {
      finalFile = File(photo.path);
    }

    setState(() {
      _productPhotos.add(finalFile);
    });
  }

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
                    'Products Photos (Take one or more)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
                const SizedBox(width: 8),
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
                        Container(
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
                        Positioned(
                          right: 4,
                          top: -4,
                          child: CircleAvatar(
                            radius: 12,
                            backgroundColor: Colors.red.withValues(alpha: 0.9),
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              icon: const Icon(
                                Icons.close,
                                size: 14,
                                color: Colors.white,
                              ),
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
                minimumSize: const Size(double.infinity, 45),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<File> _prepareImageForUpload(File originalFile, String prefix) async {
    try {
      if (!await originalFile.exists()) return originalFile;
      final length = await originalFile.length();
      if (length == 0) return originalFile;
      if (length < 1000 * 1024) return originalFile;

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

  Future<String?> _uploadPhoto(File file, String altText, String prefix) async {
    final uploadFile = await _prepareImageForUpload(file, prefix);
    if (!await uploadFile.exists()) {
      throw Exception('Photo file does not exist on device.');
    }
    final length = await uploadFile.length();
    if (length == 0) {
      throw Exception('Photo file is empty (0 bytes).');
    }

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    if (token == null) {
      throw Exception('No login token found. Please log in again.');
    }

    final filename = '${prefix}_${DateTime.now().millisecondsSinceEpoch}.jpg';

    final urlsToTry = [
      '${ApiConfig.baseUrl}/media?prefix=$prefix',
      '${ApiConfig.baseUrl}/media/?prefix=$prefix',
    ];

    String lastResponseBody = '';
    int lastStatusCode = 0;

    for (final urlStr in urlsToTry) {
      final request = http.MultipartRequest('POST', Uri.parse(urlStr));
      request.followRedirects = false;
      request.headers['Authorization'] = 'Bearer $token';
      request.fields['_payload'] = jsonEncode({
        'alt': altText,
        'prefix': prefix,
      });
      request.fields['alt'] = altText;
      request.fields['prefix'] = prefix;

      final multipartFile = await http.MultipartFile.fromPath(
        'file',
        uploadFile.path,
        filename: filename,
        contentType: MediaType('image', 'jpeg'),
      );
      request.files.add(multipartFile);

      final response = await request.send();
      final body = await response.stream.bytesToString();
      lastStatusCode = response.statusCode;
      lastResponseBody = body;

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
          debugPrint(
            'Upload redirected to: $location (resolved: $resolvedUri). Retrying POST with body...',
          );
          final redirRequest = http.MultipartRequest('POST', resolvedUri);
          redirRequest.headers['Authorization'] = 'Bearer $token';
          redirRequest.fields['_payload'] = jsonEncode({
            'alt': altText,
            'prefix': prefix,
          });
          redirRequest.fields['alt'] = altText;
          redirRequest.fields['prefix'] = prefix;
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
            'Redirected upload response -> Status: ${redirResponse.statusCode}, Body: $redirBody',
          );
          if (redirResponse.statusCode == 201 ||
              redirResponse.statusCode == 200) {
            final data = jsonDecode(redirBody);
            final doc = data['doc'] ?? data;
            return doc['id']?.toString();
          }
        }
      }
    }

    String detail = 'HTTP $lastStatusCode';
    try {
      final data = jsonDecode(lastResponseBody);
      if (data['errors'] != null && (data['errors'] as List).isNotEmpty) {
        detail = data['errors'][0]['message'] ?? lastResponseBody;
      } else if (data['message'] != null) {
        detail = data['message'].toString();
      }
    } catch (_) {
      detail = lastResponseBody;
    }
    throw Exception('Upload failed ($detail)');
  }

  Future<void> _submitBilling() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedDealerId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a dealer'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    if (_selectedProductQuantities.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select at least one product'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    if (_billCopySlot.file == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Dealer Bill Copy photo is required'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    if (_deliveryPersonSlot.file == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Delivery Person photo is required'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    if (_productPhotos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('At least one Dealer Product photo is required'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) {
        throw Exception('No session token found. Please login again.');
      }

      String? branchId =
          prefs.getString('branchId') ?? prefs.getString('branch') ?? prefs.getString('userBranchId');

      if (branchId == null || branchId.isEmpty) {
        try {
          final meRes = await http.get(
            Uri.parse('${ApiConfig.baseUrl}/users/me?depth=1'),
            headers: ApiConfig.getHeaders(token),
          );
          if (meRes.statusCode == 200) {
            final meData = jsonDecode(meRes.body);
            final user = meData['user'] ?? meData;
            final userBranch = user['lastLoginBranch'] ?? user['branch'];
            if (userBranch is Map) {
              branchId = (userBranch['id'] ?? userBranch['_id'])?.toString();
            } else if (userBranch != null) {
              branchId = userBranch.toString();
            }
          }
        } catch (_) {}
      }

      // 1. Upload Bill Copy Photo
      final billCopyAlt = 'Dealer Bill Copy for dealer $_selectedDealerId';
      final billCopyId = (await _uploadPhoto(
        _billCopySlot.file!,
        billCopyAlt,
        'dealerbill',
      ))!;

      // 2. Upload Delivery Person Photo
      final deliveryPersonAlt = 'Delivery Person for dealer $_selectedDealerId';
      final deliveryPersonId = (await _uploadPhoto(
        _deliveryPersonSlot.file!,
        deliveryPersonAlt,
        'deliveryperson',
      ))!;

      // 3. Upload Multiple Product Photos
      final List<String> productsPhotoIds = [];
      for (var i = 0; i < _productPhotos.length; i++) {
        final productsAlt =
            'Dealer Product Photo ${i + 1} for dealer $_selectedDealerId';
        final id = (await _uploadPhoto(
          _productPhotos[i],
          productsAlt,
          'dealerproducts',
        ))!;
        productsPhotoIds.add(id);
      }

      // 4. Compile Bills list
      final List<Map<String, dynamic>> billsData = [];
      for (var i = 0; i < _billControllers.length; i++) {
        final val = double.tryParse(_billControllers[i].text) ?? 0.0;
        final invNum = _invoiceNumberControllers[i].text.trim();
        billsData.add({'amount': val, 'invoiceNumber': invNum});
      }

      // 5. Compile productsList
      final List<Map<String, dynamic>> productsListData = [];
      for (var entry in _selectedProductQuantities.entries) {
        final id = entry.key;
        final data = entry.value;

        String? itemPhotoMediaId;
        final File? itemPhotoFile = data['photoFile'] as File?;
        if (itemPhotoFile != null && itemPhotoFile.existsSync()) {
          final altText = 'Dealer Product Photo for product $id';
          itemPhotoMediaId = await _uploadPhoto(
            itemPhotoFile,
            altText,
            'dealerproductitem',
          );
        }

        final itemMap = <String, dynamic>{
          'product': id,
          'quantity': data['quantity'] ?? 0.0,
          'totalAmount': data['totalAmount'] ?? 0.0,
        };
        if (itemPhotoMediaId != null) {
          itemMap['photo'] = itemPhotoMediaId;
        }

        productsListData.add(itemMap);
      }

      // Capture Waiter/Cashier ID and Name accurately
      final cashierId =
          prefs.getString('user_id') ??
          prefs.getString('userId') ??
          prefs.getString('employee_id') ??
          '';
      final cashierName =
          (prefs.getString('employee_name')?.trim().isNotEmpty == true)
              ? prefs.getString('employee_name')!.trim()
              : ((prefs.getString('user_name')?.trim().isNotEmpty == true)
                  ? prefs.getString('user_name')!.trim()
                  : ((prefs.getString('userName')?.trim().isNotEmpty == true)
                      ? prefs.getString('userName')!.trim()
                      : ((prefs.getString('username')?.trim().isNotEmpty == true)
                          ? prefs.getString('username')!.trim()
                          : 'Waiter')));

      // 6. Submit Dealer Billing Document
      final payload = {
        'dealer': _selectedDealerId,
        'branch': branchId,
        'cashierId': cashierId,
        'cashierName': cashierName,
        'bills': billsData,
        'total': _calculateTotal(),
        'billCopyPhoto': billCopyId,
        'deliveryPersonPhoto': deliveryPersonId,
        'productsPhoto': productsPhotoIds,
        'products': _selectedProductQuantities.keys.toList(),
        'productsList': productsListData,
        'date': DateTime.now().toUtc().toIso8601String(),
      };

      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/dealer-billings'),
        headers: ApiConfig.getHeaders(token),
        body: jsonEncode(payload),
      );

      if (response.statusCode == 201 || response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Dealer Billing submitted successfully!'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context);
        }
      } else {
        throw Exception(
          'Server returned ${response.statusCode}: ${response.body}',
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Submission failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Widget _buildPhotoSlotWidget(_PhotoSlot slot) {
    final hasPhoto = slot.file != null;
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
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: hasPhoto
                      ? Container(
                          height: 120,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade300),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(
                              slot.file!,
                              fit: BoxFit.cover,
                              width: double.infinity,
                            ),
                          ),
                        )
                      : OutlinedButton.icon(
                          onPressed: () => _capturePhoto(slot),
                          icon: const Icon(Icons.camera_alt),
                          label: Text('Take ${slot.label}'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(double.infinity, 50),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                ),
                if (hasPhoto) ...[
                  const SizedBox(width: 12),
                  Column(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.refresh, color: Colors.blue),
                        onPressed: () => _capturePhoto(slot),
                        tooltip: 'Retake',
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Colors.red,
                        ),
                        onPressed: () => _removePhoto(slot),
                        tooltip: 'Remove',
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _navigateToProductSelection() async {
    final Map<String, Map<String, dynamic>>? result =
        await Navigator.push<Map<String, Map<String, dynamic>>>(
          context,
          MaterialPageRoute(
            builder: (context) => ProductSelectionPage(
              products: _products,
              initialData: _selectedProductQuantities,
            ),
          ),
        );
    if (result != null) {
      setState(() {
        _selectedProductQuantities = result;
      });
    }
  }

  Widget _buildProductSelector() {
    if (_selectedDealerId == null) {
      return const SizedBox.shrink();
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Select Products',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            if (_isLoadingProducts)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(8.0),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_products.isEmpty)
              const Text(
                'No products associated with this dealer.',
                style: TextStyle(color: Colors.grey, fontSize: 14),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: _navigateToProductSelection,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade400),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              _selectedProductQuantities.isEmpty
                                  ? 'Select products'
                                  : '${_selectedProductQuantities.length} products selected',
                              style: TextStyle(
                                color: _selectedProductQuantities.isEmpty
                                    ? Colors.grey
                                    : Colors.black87,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          const Icon(Icons.arrow_drop_down, color: Colors.grey),
                        ],
                      ),
                    ),
                  ),
                  if (_selectedProductQuantities.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 48,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: _selectedProductQuantities.entries.map((
                            entry,
                          ) {
                            final id = entry.key;
                            final qty = entry.value['quantity'] ?? 0.0;
                            final amt = entry.value['totalAmount'] ?? 0.0;
                            final product = _products.firstWhere(
                              (p) => p['id'] == id,
                              orElse: () => {'name': 'Unknown'},
                            );
                            return Padding(
                              padding: const EdgeInsets.only(right: 8.0),
                              child: Chip(
                                label: Text(
                                  '${product['name']} (Qty: $qty, ₹$amt)',
                                ),
                                onDeleted: () {
                                  setState(() {
                                    _selectedProductQuantities.remove(id);
                                  });
                                },
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: 'Dealer Billing',
      pageType: PageType.dealerBilling,
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Dealer Dropdown card
                  Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
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
                            ),
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            isExpanded: true,
                            initialValue: _selectedDealerId,
                            hint: _isLoadingDealers
                                ? const Text(
                                    'Loading dealers...',
                                    overflow: TextOverflow.ellipsis,
                                  )
                                : const Text(
                                    'Select a dealer',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                            items: _dealers.map((dealer) {
                              return DropdownMenuItem<String>(
                                value: dealer['id'],
                                child: Text(
                                  dealer['name'],
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            }).toList(),
                            onChanged: _isLoadingDealers
                                ? null
                                : (val) {
                                    setState(() {
                                      _selectedDealerId = val;
                                      _selectedProductQuantities = {};
                                      _products = [];
                                    });
                                    if (val != null) {
                                      _fetchProducts(val);
                                    }
                                  },
                            decoration: InputDecoration(
                              prefixIcon: const Icon(Icons.business_outlined),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                            ),
                            validator: (val) => val == null
                                ? 'Dealer selection is required'
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                  _selectedDealerId == null
                      ? const SizedBox.shrink()
                      : const SizedBox(height: 16),
                  _buildProductSelector(),
                  const SizedBox(height: 16),

                  // Bill copy entries card
                  Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Bill Amount Entries',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.add_circle,
                                  color: Colors.green,
                                ),
                                onPressed: _addBillField,
                                tooltip: 'Add Bill Entry',
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _billControllers.length,
                            itemBuilder: (context, index) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 12.0),
                                child: Row(
                                  children: [
                                    Expanded(
                                      flex: 3,
                                      child: TextFormField(
                                        controller: _billControllers[index],
                                        keyboardType:
                                            const TextInputType.numberWithOptions(
                                              decimal: true,
                                            ),
                                        decoration: InputDecoration(
                                          labelText: 'Amount ${index + 1}',
                                          prefixText: '₹ ',
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                horizontal: 16,
                                                vertical: 12,
                                              ),
                                        ),
                                        validator: (val) {
                                          if (val == null || val.trim().isEmpty) {
                                            return 'Required';
                                          }
                                          if (double.tryParse(val) == null) {
                                            return 'Invalid';
                                          }
                                          return null;
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      flex: 4,
                                      child: TextFormField(
                                        controller:
                                            _invoiceNumberControllers[index],
                                        decoration: InputDecoration(
                                          labelText: 'Invoice Number',
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                horizontal: 16,
                                                vertical: 12,
                                              ),
                                        ),
                                        validator: (val) {
                                          if (val == null || val.trim().isEmpty) {
                                            return 'Required';
                                          }
                                          return null;
                                        },
                                      ),
                                    ),
                                    if (_billControllers.length > 1)
                                      IconButton(
                                        icon: const Icon(
                                          Icons.remove_circle,
                                          color: Colors.red,
                                        ),
                                        onPressed: () => _removeBillField(index),
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
                          const Divider(height: 24),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Total Amount:',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              Text(
                                '₹ ${_calculateTotal().toStringAsFixed(2)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                  color: Colors.green,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  _buildPhotoSlotWidget(_billCopySlot),
                  const SizedBox(height: 16),

                  _buildPhotoSlotWidget(_deliveryPersonSlot),
                  const SizedBox(height: 16),

                  _buildProductPhotosWidget(),
                  const SizedBox(height: 24),

                  Center(
                    child: SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFC2410C),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _isSubmitting ? null : _submitBilling,
                        child: const Text(
                          'SUBMIT DEALER BILLING',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_isSubmitting)
            Container(
              color: Colors.black45,
              child: const Center(
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text(
                          'Uploading files & submitting...',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class ProductSelectionPage extends StatefulWidget {
  final List<dynamic> products;
  final Map<String, Map<String, dynamic>> initialData;

  const ProductSelectionPage({
    super.key,
    required this.products,
    required this.initialData,
  });

  @override
  State<ProductSelectionPage> createState() => _ProductSelectionPageState();
}

class _ProductSelectionPageState extends State<ProductSelectionPage> {
  final Map<String, double> _quantities = {};
  final Map<String, double> _amounts = {};
  final Map<String, File?> _productPhotoFiles = {};
  final Map<String, TextEditingController> _qtyControllers = {};
  final Map<String, TextEditingController> _amtControllers = {};
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    // Restore previously selected data
    for (var entry in widget.initialData.entries) {
      final id = entry.key;
      final data = entry.value;
      _quantities[id] = (data['quantity'] as num?)?.toDouble() ?? 0.0;
      _amounts[id] = (data['totalAmount'] as num?)?.toDouble() ?? 0.0;
      if (data['photoFile'] is File) {
        _productPhotoFiles[id] = data['photoFile'] as File;
      }
    }
    // Create controllers for all products
    for (var p in widget.products) {
      final id = p['id'] as String;
      final qty = _quantities[id];
      final amt = _amounts[id];
      _qtyControllers[id] = TextEditingController(
        text: qty != null && qty > 0 ? qty.toString() : '',
      );
      _amtControllers[id] = TextEditingController(
        text: amt != null && amt > 0 ? amt.toString() : '',
      );
    }
  }

  Future<void> _capturePhotoForProduct(String id) async {
    if (await Permission.camera.request().isDenied) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Camera permission required')),
        );
      }
      return;
    }
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No camera found')));
      }
      return;
    }
    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final XFile? photo = await Navigator.push<XFile>(
      context,
      MaterialPageRoute(
        builder: (context) => CameraPage(cameras: cameras),
        fullscreenDialog: true,
      ),
    );
    FocusManager.instance.primaryFocus?.unfocus();
    if (photo == null) return;

    final bytes = await photo.readAsBytes();
    File finalFile;
    try {
      final image = img_lib.decodeImage(bytes);
      if (image != null) {
        final compressed = img_lib.encodeJpg(image, quality: 70);
        final tempDir = await getTemporaryDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final tempFile = File(
          '${tempDir.path}/dealerproduct_${id}_$timestamp.jpg',
        );
        await tempFile.writeAsBytes(compressed);
        finalFile = tempFile;
      } else {
        finalFile = File(photo.path);
      }
    } catch (_) {
      finalFile = File(photo.path);
    }

    setState(() {
      _productPhotoFiles[id] = finalFile;
    });
  }

  void _removePhotoForProduct(String id) {
    setState(() {
      final file = _productPhotoFiles[id];
      if (file != null && file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
      _productPhotoFiles[id] = null;
    });
  }

  @override
  void dispose() {
    for (var c in _qtyControllers.values) {
      c.dispose();
    }
    for (var c in _amtControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _saveAndReturn() {
    final Map<String, Map<String, dynamic>> results = {};
    for (var p in widget.products) {
      final id = p['id'] as String;
      final qty = _quantities[id] ?? 0.0;
      final amt = _amounts[id] ?? 0.0;
      if (qty > 0) {
        results[id] = {
          'quantity': qty,
          'totalAmount': amt,
          'photoFile': _productPhotoFiles[id],
        };
      }
    }
    Navigator.pop(context, results);
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.products.where((p) {
      final name = (p['name'] ?? '').toString().toLowerCase();
      return name.contains(_searchQuery.toLowerCase());
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Products & Quantities'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: _saveAndReturn,
            tooltip: 'Confirm',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search products...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              onChanged: (val) {
                setState(() {
                  _searchQuery = val;
                });
              },
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final p = filtered[index];
                final id = p['id'] as String;
                final qtyCtrl = _qtyControllers[id]!;
                final amtCtrl = _amtControllers[id]!;
                final currentQty = _quantities[id] ?? 0.0;
                final photoFile = _productPhotoFiles[id];

                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Product photo or add photo button
                      Container(
                        width: 50,
                        height: 50,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(8),
                          color: Colors.grey.shade100,
                        ),
                        child: photoFile != null
                            ? Stack(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.file(
                                      photoFile,
                                      width: 50,
                                      height: 50,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                  Positioned(
                                    right: -2,
                                    top: -2,
                                    child: InkWell(
                                      onTap: () => _removePhotoForProduct(id),
                                      child: Container(
                                        padding: const EdgeInsets.all(2),
                                        decoration: const BoxDecoration(
                                          color: Colors.red,
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.close,
                                          size: 10,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : IconButton(
                                padding: EdgeInsets.zero,
                                icon: const Icon(
                                  Icons.add_a_photo,
                                  size: 20,
                                  color: Colors.blue,
                                ),
                                onPressed: () => _capturePhotoForProduct(id),
                                tooltip: 'Take Photo',
                              ),
                      ),
                      // Product Name
                      Expanded(
                        child: Text(
                          p['name'] ?? 'Unknown',
                          style: TextStyle(
                            fontWeight: currentQty > 0
                                ? FontWeight.bold
                                : FontWeight.normal,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Quantity field
                      SizedBox(
                        width: 70,
                        child: TextField(
                          controller: qtyCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Qty',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onChanged: (val) {
                            setState(() {
                              _quantities[id] = double.tryParse(val) ?? 0.0;
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Total Amount field
                      SizedBox(
                        width: 85,
                        child: TextField(
                          controller: amtCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Amount',
                            prefixText: '₹',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onChanged: (val) {
                            setState(() {
                              _amounts[id] = double.tryParse(val) ?? 0.0;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black12,
                  blurRadius: 4,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFC2410C),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _saveAndReturn,
                child: const Text(
                  'CONFIRM SELECTION',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
