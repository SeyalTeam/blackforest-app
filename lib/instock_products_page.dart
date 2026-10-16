import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/instock_provider.dart';
import 'package:blackforest_app/api_config.dart';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img_lib;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:blackforest_app/camera_page.dart';

class InstockProductsPage extends StatefulWidget {
  const InstockProductsPage({super.key});

  @override
  State<InstockProductsPage> createState() => _InstockProductsPageState();
}

// _ProductCameraDialog class removed in favor of shared CameraPage in camera_page.dart

class _InstockProductsPageState extends State<InstockProductsPage> {
  // No need to set live mode as InstockProvider handles it implicitly
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  bool _showAsGrid = true;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<dynamic> _getFilteredProducts(InstockProvider sp) {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return sp.filteredProducts;
    return sp.filteredProducts.where((p) {
      final name = (p['name'] ?? '').toString().toLowerCase();
      final upc = (p['upc'] ?? '').toString().toLowerCase();
      return name.contains(query) || upc.contains(query);
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<InstockProvider>(context, listen: false).syncBranchId();
    });
  }

  Future<File?> _captureAndConfirmPhoto() async {
    final messenger = ScaffoldMessenger.of(context);

    final permission = await Permission.camera.request();
    if (!permission.isGranted) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Camera permission required')),
      );
      return null;
    }

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('No camera found')));
      return null;
    }
    if (!mounted) return null;

    final XFile? photo = await Navigator.push<XFile>(
      context,
      MaterialPageRoute(builder: (context) => CameraPage(cameras: cameras)),
    );
    if (photo == null) return null;

    final bytes = await photo.readAsBytes();
    final decoded = img_lib.decodeImage(bytes);
    if (decoded == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Failed to process captured image')),
      );
      return null;
    }

    final compressed = img_lib.encodeJpg(decoded, quality: 70);
    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final tempFile = File('${tempDir.path}/product_$timestamp.jpg');
    await tempFile.writeAsBytes(compressed);
    return tempFile;
  }

  Future<File?> _pickAndConfirmPhotoFromGallery() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picker = ImagePicker();
      final XFile? selected = await picker.pickImage(
        source: ImageSource.gallery,
      );
      if (selected == null) return null;

      final bytes = await selected.readAsBytes();
      final decoded = img_lib.decodeImage(bytes);
      if (decoded == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Failed to process selected image')),
        );
        return null;
      }

      final compressed = img_lib.encodeJpg(decoded, quality: 70);
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final tempFile = File('${tempDir.path}/product_gallery_$timestamp.jpg');
      await tempFile.writeAsBytes(compressed);
      if (!mounted) return null;

      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Image Preview'),
          content: Image.file(tempFile),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Choose Another'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      );

      if (confirmed == true) return tempFile;
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      return null;
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to pick image: $e')),
      );
      return null;
    }
  }

  Future<void> _showCreateProductDialog(InstockProvider sp) async {
    await sp.loadDealers();
    if (!mounted) return;

    final formKey = GlobalKey<FormState>();
    final nameCtrl = TextEditingController();
    final priceCtrl = TextEditingController();
    final rateCtrl = TextEditingController();

    String? selectedDealerId = sp.dealers.isNotEmpty
        ? sp.dealers.first["id"]?.toString()
        : null;
    String selectedUnit = "pcs";
    String selectedGst = "0";
    bool isVeg = false;
    bool isSubmitting = false;
    File? capturedImage;

    final created = await showDialog<bool>(
      context: context,
      barrierDismissible: !isSubmitting,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (_, setDialogState) {
            return AlertDialog(
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 24,
              ),
              title: const Text("Create New Product"),
              content: SizedBox(
                width: MediaQuery.of(dialogContext).size.width > 620
                    ? 520
                    : MediaQuery.of(dialogContext).size.width - 24,
                child: SingleChildScrollView(
                  child: Form(
                    key: formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextFormField(
                          controller: nameCtrl,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: "Product Name",
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return "Product name is required";
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<String>(
                          initialValue: selectedDealerId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: "Dealer",
                            border: OutlineInputBorder(),
                          ),
                          items: sp.dealers.map((dealer) {
                            final id = dealer["id"]?.toString() ?? "";
                            final name =
                                dealer["name"]?.toString() ?? "Unknown Dealer";
                            return DropdownMenuItem<String>(
                              value: id,
                              child: Text(
                                name,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            );
                          }).toList(),
                          onChanged: isSubmitting
                              ? null
                              : (value) {
                                  setDialogState(() {
                                    selectedDealerId = value;
                                  });
                                },
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return "Dealer is required";
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: priceCtrl,
                          textInputAction: TextInputAction.next,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: "Price",
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) {
                            final parsed = double.tryParse(
                              (value ?? "").trim(),
                            );
                            if (parsed == null || parsed <= 0) {
                              return "Enter a valid price";
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: rateCtrl,
                          textInputAction: TextInputAction.next,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: "Rate",
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) {
                            final parsed = double.tryParse(
                              (value ?? "").trim(),
                            );
                            if (parsed == null || parsed < 0) {
                              return "Enter a valid rate";
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<String>(
                          initialValue: selectedUnit,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: "Unit",
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(value: "pcs", child: Text("pcs")),
                            DropdownMenuItem(value: "kg", child: Text("kg")),
                            DropdownMenuItem(value: "g", child: Text("g")),
                          ],
                          onChanged: isSubmitting
                              ? null
                              : (value) {
                                  if (value == null) return;
                                  setDialogState(() {
                                    selectedUnit = value;
                                  });
                                },
                        ),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<String>(
                          initialValue: selectedGst,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: "GST",
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(value: "0", child: Text("0%")),
                            DropdownMenuItem(value: "5", child: Text("5%")),
                            DropdownMenuItem(value: "12", child: Text("12%")),
                            DropdownMenuItem(value: "18", child: Text("18%")),
                            DropdownMenuItem(value: "22", child: Text("22%")),
                          ],
                          onChanged: isSubmitting
                              ? null
                              : (value) {
                                  if (value == null) return;
                                  setDialogState(() {
                                    selectedGst = value;
                                  });
                                },
                        ),
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade400),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.camera_alt_outlined,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: Text(
                                      "Product Image",
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      TextButton(
                                        onPressed: isSubmitting
                                            ? null
                                            : () async {
                                                final file =
                                                    await _captureAndConfirmPhoto();
                                                if (file == null) return;
                                                setDialogState(() {
                                                  capturedImage = file;
                                                });
                                              },
                                        child: Text(
                                          capturedImage == null
                                              ? "Capture"
                                              : "Retake",
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: isSubmitting
                                            ? null
                                            : () async {
                                                final file =
                                                    await _pickAndConfirmPhotoFromGallery();
                                                if (file == null) return;
                                                setDialogState(() {
                                                  capturedImage = file;
                                                });
                                              },
                                        child: const Text(
                                          "Select from Gallery",
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              if (capturedImage != null) ...[
                                const SizedBox(height: 8),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.file(
                                    capturedImage!,
                                    height: 140,
                                    width: double.infinity,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text("Is Veg"),
                          value: isVeg,
                          onChanged: (value) {
                            setDialogState(() {
                              isVeg = value;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isSubmitting
                      ? null
                      : () => Navigator.pop(dialogContext, false),
                  child: const Text("Cancel"),
                ),
                ElevatedButton(
                  onPressed: isSubmitting
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;

                          final messenger = ScaffoldMessenger.of(context);
                          final navigator = Navigator.of(dialogContext);
                          if (capturedImage == null) {
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text('Please capture product image'),
                              ),
                            );
                            return;
                          }

                          setDialogState(() {
                            isSubmitting = true;
                          });

                          final mediaId = await sp.uploadProductPhoto(
                            capturedImage!,
                            nameCtrl.text.trim().isEmpty
                                ? 'Product image'
                                : nameCtrl.text.trim(),
                          );
                          if (mediaId == null || mediaId.isEmpty) {
                            setDialogState(() {
                              isSubmitting = false;
                            });
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text('Failed to upload product image'),
                              ),
                            );
                            return;
                          }

                          final error = await sp.createProduct(
                            name: nameCtrl.text,
                            dealerId: selectedDealerId ?? "",
                            price: double.parse(priceCtrl.text.trim()),
                            rate: double.parse(rateCtrl.text.trim()),
                            isVeg: isVeg,
                            unit: selectedUnit,
                            gst: selectedGst,
                            imageId: mediaId,
                          );

                          if (!mounted) return;

                          if (error == null) {
                            navigator.pop(true);
                          } else {
                            setDialogState(() {
                              isSubmitting = false;
                            });
                            messenger.showSnackBar(
                              SnackBar(content: Text(error)),
                            );
                          }
                        },
                  child: isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text("Create"),
                ),
              ],
            );
          },
        );
      },
    );

    if (!mounted) return;
    if (created == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Product created successfully")),
      );
    }
  }

  void _promptInstockQuantity(dynamic product) async {
    final sp = Provider.of<InstockProvider>(context, listen: false);
    final String id = product["id"];

    // Detect Weight Based
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
      if (isKgFlag) {
        isWeightBased = true;
      }
      if (pricingType != null && pricingType.contains('kg')) {
        isWeightBased = true;
      }
    } catch (e) {
      isWeightBased = false;
    }

    // Current InStock Value
    double currentStock = sp.inStockQuery[id] ?? 0.0;
    final rawUnit =
        product['defaultPriceDetails']?['unit']?.toString().trim();
    final unit = (rawUnit != null && rawUnit.isNotEmpty)
        ? rawUnit
        : (isWeightBased ? 'kg' : 'pcs');

    String initialText = '';
    if (currentStock > 0) {
      if (currentStock == currentStock.floorToDouble()) {
        initialText = currentStock.toInt().toString();
      } else {
        initialText = currentStock.toString();
      }
    }

    final TextEditingController stockController =
        TextEditingController(text: initialText);
    stockController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: initialText.length,
    );

    final enteredStock = await showDialog<double>(
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
                    ? 'Enter Instock Weight ($unit)'
                    : 'Enter Instock Quantity ($unit)',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.normal,
                  color: Colors.grey.shade700,
                ),
              ),
            ],
          ),
          content: TextField(
            controller: stockController,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
            ),
            decoration: InputDecoration(
              hintText: isWeightBased ? 'e.g. 0.5' : 'e.g. 100',
              labelText: isWeightBased
                  ? 'Weight in $unit'
                  : 'Quantity in $unit',
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
                    double.tryParse(stockController.text.trim()) ?? 0.0;
                Navigator.pop(context, value);
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );

    if (enteredStock == null || enteredStock < 0) return;
    sp.updateInStock(id, enteredStock);

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

  void _toggleProductSelection(dynamic product) {
    _promptInstockQuantity(product);
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

  @override
  Widget build(BuildContext context) {
    return Consumer<InstockProvider>(
      builder: (context, sp, child) {
        final filteredProducts = _getFilteredProducts(sp);

        return CommonScaffold(
          title: 'Instock: ${sp.selectedCategoryName ?? "Products"}',
          pageType: PageType.instock,
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
                      hintText:
                          "Search in ${sp.selectedCategoryName ?? 'Products'}...",
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
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
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
                      'Products (${filteredProducts.length})',
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
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
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
                child: sp.isLoading
                    ? const Center(
                        child: CircularProgressIndicator(color: Colors.black),
                      )
                    : filteredProducts.isEmpty && _searchQuery.isNotEmpty
                    ? Center(
                        child: Text(
                          'No products match "$_searchQuery"',
                          style: const TextStyle(
                              color: Color(0xFF4A4A4A), fontSize: 18),
                        ),
                      )
                    : (_showAsGrid
                        ? _buildGrid(sp, filteredProducts)
                        : _buildGoogleSearchList(sp, filteredProducts)),
              ),
            ],
          ),
        );
      },
    );
  }

  // ========================== GOOGLE SEARCH SUGGESTIONS LIST ===========================
  Widget _buildGoogleSearchList(InstockProvider sp, List<dynamic> products) {
    if (products.isEmpty) {
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
              'No instock products found for "$_searchQuery"',
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

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      itemCount: products.length,
      itemBuilder: (context, index) {
        final p = products[index];
        final id = p['id']?.toString() ?? '';
        final name = p['name']?.toString() ?? 'Unknown';

        final double pVal = sp.prices[id] ?? 0.0;
        final price = '₹${pVal % 1 == 0 ? pVal.toInt() : pVal}';

        final currentStock = sp.inStockQuery[id] ?? 0.0;
        final isSelected = currentStock > 0;

        String qtyText;
        if (currentStock == currentStock.floorToDouble()) {
          qtyText = currentStock.toInt().toString();
        } else {
          qtyText = currentStock.toStringAsFixed(2);
        }

        final unitDetails = p['defaultPriceDetails'];
        final String uName = unitDetails?['unit'] ?? 'pcs';

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
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            onTap: () => _promptInstockQuantity(p),
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
                        child: const Icon(Icons.search,
                            size: 20, color: Colors.grey),
                      ),
                      errorWidget: (_, __, ___) => Container(
                        width: 40,
                        height: 40,
                        color: Colors.grey.shade100,
                        child: const Icon(Icons.search,
                            size: 20, color: Colors.grey),
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
                      color: isSelected
                          ? Colors.green.shade700
                          : Colors.grey.shade600,
                      size: 20,
                    ),
                  ),
              ],
            ),
            title: _buildHighlightedText(name, _searchQuery.trim()),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                price,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade700,
                ),
              ),
            ),
            trailing: isSelected
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
                          "$qtyText $uName",
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
          ),
        );
      },
    );
  }

  // ========================== GRID VIEW ===========================
  Widget _buildGrid(InstockProvider sp, List<dynamic> products) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = (width > 600) ? 5 : 3;
        final showNewProduct = _searchQuery.isEmpty;
        final itemCount = products.length + (showNewProduct ? 1 : 0);

        return GridView.builder(
          padding: const EdgeInsets.all(10),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 0.75,
          ),
          itemCount: itemCount,
          itemBuilder: (context, index) {
            if (showNewProduct && index == 0) {
              return GestureDetector(
                onTap: () => _showCreateProductDialog(sp),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: const Color(0xFFEFFAF1),
                    border: Border.all(
                      color: const Color(0xFF2E7D32),
                      width: 2,
                    ),
                  ),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.add_circle,
                        size: 48,
                        color: Color(0xFF2E7D32),
                      ),
                      SizedBox(height: 10),
                      Text(
                        "New Product",
                        style: TextStyle(
                          color: Color(0xFF1B5E20),
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        "Add to this category",
                        style: TextStyle(
                          color: Color(0xFF2E7D32),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }

            final productIndex = showNewProduct ? index - 1 : index;
            final product = products[productIndex];
            final String id = product["id"];

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

            final double pVal = sp.prices[id] ?? 0.0;
            final price = '₹${pVal % 1 == 0 ? pVal.toInt() : pVal}';

            final currentStock = sp.inStockQuery[id] ?? 0.0;
            final isSelected = currentStock > 0;

            String qtyText;
            if (currentStock == currentStock.floorToDouble()) {
              qtyText = currentStock.toInt().toString();
            } else {
              qtyText = currentStock.toStringAsFixed(2);
            }

            final unitDetails = product['defaultPriceDetails'];
            final double uQty =
                (unitDetails != null && unitDetails['quantity'] != null)
                ? (unitDetails['quantity'] as num).toDouble()
                : 1.0;
            final String uName = unitDetails?['unit'] ?? 'pcs';
            final String uQtyStr = uQty % 1 == 0
                ? uQty.toInt().toString()
                : uQty.toString();
            final String unitDisplay = '$uQtyStr$uName';

            return GestureDetector(
              onTap: () => _promptInstockQuantity(product),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: isSelected
                      ? Border.all(color: Colors.blue, width: 4)
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
                              imageUrl: imageUrl,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              placeholder: (context, url) => const Center(
                                child: CircularProgressIndicator(),
                              ),
                              errorWidget: (context, url, error) =>
                                  const Center(
                                    child: Text(
                                      'No Image',
                                      style: TextStyle(color: Colors.grey),
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
                                bottom: Radius.circular(8),
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
                    Positioned(
                      top: 2,
                      right: 2,
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
                          unitDisplay,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 10,
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
                              color: Colors.black.withValues(alpha: 0.7),
                              border: Border.all(color: Colors.white, width: 1),
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
              ),
            );
          },
        );
      },
    );
  }
}
