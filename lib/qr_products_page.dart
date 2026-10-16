import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:blackforest_app/common_scaffold.dart';
import 'package:blackforest_app/api_config.dart';
import 'package:blackforest_app/api_server_prefs.dart';

class QrProductsPage extends StatefulWidget {
  final dynamic categoryId;
  final String categoryName;
  final String? companyId;

  const QrProductsPage({
    super.key,
    required this.categoryId,
    required this.categoryName,
    this.companyId,
  });

  @override
  State<QrProductsPage> createState() => _QrProductsPageState();
}

class _QrProductsPageState extends State<QrProductsPage>
    with TickerProviderStateMixin {
  List<dynamic> _products = [];
  List<dynamic> _filteredProducts = [];
  bool _isLoading = true;
  String _errorMessage = '';
  String? _token;
  String? _companyId;
  dynamic _selectedProduct;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadTokenAndFetch();
  }

  @override
  void dispose() {
    _searchController.dispose();
    for (var p in _products) {
      if (p["upcController"] is TextEditingController) {
        (p["upcController"] as TextEditingController).dispose();
      }
      if (p["animController"] is AnimationController) {
        (p["animController"] as AnimationController).dispose();
      }
    }
    super.dispose();
  }

  Future<String?> _resolveCompanyId(SharedPreferences prefs, String? token) async {
    if (widget.companyId != null && widget.companyId!.isNotEmpty) {
      return widget.companyId;
    }
    String? cached = prefs.getString('company_id')?.trim();
    if (cached == null || cached.isEmpty) {
      cached = prefs.getString('companyId')?.trim();
    }
    if (cached != null && cached.isNotEmpty) return cached;

    final branchId = prefs.getString('branchId') ?? prefs.getString('branch') ?? prefs.getString('userBranchId');
    if (branchId != null && branchId.isNotEmpty && token != null) {
      try {
        final bRes = await http.get(
          Uri.parse("${ApiConfig.baseUrl}/branches/$branchId?depth=1"),
          headers: ApiConfig.getHeaders(token),
        );
        if (bRes.statusCode == 200) {
          final bData = jsonDecode(bRes.body);
          final comp = bData["company"];
          final compId = comp is Map ? (comp["id"] ?? comp["_id"])?.toString() : comp?.toString();
          if (compId != null && compId.isNotEmpty) {
            await prefs.setString('company_id', compId);
            return compId;
          }
        }
      } catch (_) {}
    }

    if (token != null) {
      try {
        final uRes = await http.get(
          Uri.parse("${ApiConfig.baseUrl}/users/me?depth=2"),
          headers: ApiConfig.getHeaders(token),
        );
        if (uRes.statusCode == 200) {
          final uData = jsonDecode(uRes.body);
          final user = uData["user"] ?? uData;
          dynamic comp = user["company"];
          if (comp == null && user["branch"] != null && user["branch"] is Map) {
            comp = user["branch"]["company"];
          }
          if (comp == null && user["lastLoginBranch"] != null && user["lastLoginBranch"] is Map) {
            comp = user["lastLoginBranch"]["company"];
          }
          final compId = comp is Map ? (comp["id"] ?? comp["_id"])?.toString() : comp?.toString();
          if (compId != null && compId.isNotEmpty) {
            await prefs.setString('company_id', compId);
            return compId;
          }
        }
      } catch (_) {}
    }
    return null;
  }

  bool _matchesCompany(dynamic product, String compId) {
    if (product is! Map) return false;

    // 1. If product has an explicit non-empty company list, check against it.
    final prodComp = product['company'];
    if (prodComp != null) {
      if (prodComp is List && prodComp.isNotEmpty) {
        return prodComp.any((c) {
          final cId =
              c is Map ? (c['id'] ?? c['_id'])?.toString() : c?.toString();
          return cId == compId;
        });
      } else if (prodComp is Map) {
        final cId = (prodComp['id'] ?? prodComp['_id'])?.toString();
        return cId == compId;
      } else if (prodComp is String && prodComp.isNotEmpty) {
        return prodComp == compId;
      }
    }

    // 2. If product has no explicit company, check product's category.company
    final cat = product['category'];
    if (cat is Map && cat['company'] != null) {
      final catComp = cat['company'];
      if (catComp is List && catComp.isNotEmpty) {
        return catComp.any((c) {
          final cId =
              c is Map ? (c['id'] ?? c['_id'])?.toString() : c?.toString();
          return cId == compId;
        });
      } else if (catComp is Map) {
        final cId = (catComp['id'] ?? catComp['_id'])?.toString();
        return cId == compId;
      } else if (catComp is String && catComp.isNotEmpty) {
        return catComp == compId;
      }
    }

    // 3. Fallback: If neither product nor category explicitly restricts to another company,
    // default to true because this category was already chosen from the filtered list of this company.
    return true;
  }

  Future<void> _loadTokenAndFetch() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString("token");
    _companyId = await _resolveCompanyId(prefs, _token);
    await _fetchProducts();
  }

  Future<void> _fetchProducts() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final resp = await http.get(
        Uri.parse(
          "${ApiConfig.baseUrl}/products?where[category][equals]=${widget.categoryId}&limit=500&depth=1",
        ),
        headers: ApiConfig.getHeaders(_token),
      );

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        List<dynamic> docs = data["docs"] ?? [];

        if (_companyId != null && _companyId!.isNotEmpty) {
          docs = docs.where((p) => _matchesCompany(p, _companyId!)).toList();
        }

        _products = docs;

        for (var p in _products) {
          p["upcController"] = TextEditingController(
            text: p["upc"]?.toString() ?? "",
          );

          p["animController"] = AnimationController(
            duration: const Duration(milliseconds: 250),
            vsync: this,
          );

          p["animScale"] = Tween(begin: 1.0, end: 1.25).animate(
            CurvedAnimation(
              parent: p["animController"],
              curve: Curves.easeOutBack,
            ),
          );

          p["updated"] = false;
          p["isUpdating"] = false;
        }

        _filterProducts(_searchController.text);
      } else {
        _errorMessage = "Failed to load products (${resp.statusCode})";
      }
    } catch (e) {
      _errorMessage = "Network error. Please check your connection.";
    }

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  void _filterProducts(String query) {
    final q = query.trim().toLowerCase();
    setState(() {
      if (q.isEmpty) {
        _filteredProducts = List.from(_products);
      } else {
        _filteredProducts = _products.where((p) {
          final name = (p["name"] ?? "").toString().toLowerCase();
          final upc = (p["upcController"]?.text ?? p["upc"] ?? "")
              .toString()
              .toLowerCase();
          return name.contains(q) || upc.contains(q);
        }).toList();
      }
    });
  }

  Future<void> _updateUPC(dynamic product) async {
    final upcController = product["upcController"] as TextEditingController;
    final upc = upcController.text.trim();
    final productId = product["id"] ?? product["_id"];

    final animController = product["animController"] as AnimationController?;
    animController?.forward().then((_) {
      animController.reverse();
    });

    setState(() {
      product["isUpdating"] = true;
    });

    try {
      final resp = await http.patch(
        Uri.parse("${ApiConfig.baseUrl}/products/$productId"),
        headers: ApiConfig.getHeaders(_token),
        body: jsonEncode({"upc": upc}),
      );

      if (resp.statusCode == 200) {
        if (mounted) {
          setState(() {
            product["updated"] = true;
            product["isUpdating"] = false;
            _selectedProduct = null;
          });

          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "${product['name'] ?? 'Product'} UPC updated to '$upc'",
                    ),
                  ),
                ],
              ),
              backgroundColor: Colors.green.shade700,
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          );

          await Future.delayed(const Duration(seconds: 2));
          if (mounted) {
            setState(() => product["updated"] = false);
          }
        }
      } else {
        if (mounted) {
          setState(() {
            product["isUpdating"] = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Update failed: ${resp.statusCode}"),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          product["isUpdating"] = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Network error during update"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _scanQR(dynamic product) async {
    _selectedProduct = product;

    final scannedValue = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const QrScannerPage()),
    );

    if (scannedValue != null && scannedValue.trim().isNotEmpty && mounted) {
      setState(() {
        (product["upcController"] as TextEditingController).text =
            scannedValue.trim();
      });

      // Auto-trigger update on scan for seamless experience
      await _updateUPC(product);
    }
  }

  String _getImage(dynamic p) {
    try {
      if (p["images"] != null &&
          p["images"] is List &&
          p["images"].isNotEmpty &&
          p["images"][0]["image"] != null) {
        final imgObj = p["images"][0]["image"];
        final rawUrl = (imgObj is Map) ? imgObj["url"] : null;
        if (rawUrl != null && rawUrl.toString().trim().isNotEmpty) {
          return resolveApiAssetUrl(rawUrl.toString().trim());
        }
      }
      final direct = p["imageUrl"] ?? p["thumbnail"];
      if (direct != null && direct.toString().trim().isNotEmpty) {
        return resolveApiAssetUrl(direct.toString().trim());
      }
    } catch (_) {}
    return "https://via.placeholder.com/150?text=No+Image";
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: "${widget.categoryName} (QR Update)",
      pageType: PageType.home,
      body: RefreshIndicator(
        onRefresh: _fetchProducts,
        child: Column(
          children: [
            // Search Bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _searchController,
                onChanged: _filterProducts,
                decoration: InputDecoration(
                  hintText: "Search products by name or barcode...",
                  prefixIcon: const Icon(Icons.search, color: Colors.grey),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, color: Colors.grey),
                          onPressed: () {
                            _searchController.clear();
                            _filterProducts('');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: Colors.grey.shade100,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),

            // Products List
            Expanded(
              child: _isLoading
                  ? const Center(
                      child:
                          CircularProgressIndicator(color: Color(0xFF7C3AED)),
                    )
                  : _errorMessage.isNotEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _errorMessage,
                                style: const TextStyle(color: Colors.red),
                              ),
                              const SizedBox(height: 12),
                              ElevatedButton(
                                onPressed: _fetchProducts,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF7C3AED),
                                  foregroundColor: Colors.white,
                                ),
                                child: const Text("Retry"),
                              ),
                            ],
                          ),
                        )
                      : _filteredProducts.isEmpty
                          ? Center(
                              child: Text(
                                _searchController.text.isNotEmpty
                                    ? "No products match your search"
                                    : "No products found for this company in this category",
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 16,
                                ),
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                              itemCount: _filteredProducts.length,
                              itemBuilder: (context, index) {
                                final p = _filteredProducts[index];
                                final img = _getImage(p);
                                final isSelected = p == _selectedProduct;
                                final isUpdated = p["updated"] == true;
                                final isUpdating = p["isUpdating"] == true;

                                return Container(
                                  margin: const EdgeInsets.only(bottom: 10),
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: isUpdated
                                          ? Colors.green
                                          : isSelected
                                              ? const Color(0xFF7C3AED)
                                              : Colors.grey.shade200,
                                      width: isUpdated || isSelected ? 2 : 1,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black
                                            .withValues(alpha: 0.04),
                                        blurRadius: 6,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      // Product Image with Scanner Cue
                                      GestureDetector(
                                        onTap: () => _scanQR(p),
                                        child: Stack(
                                          children: [
                                            ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              child: CachedNetworkImage(
                                                imageUrl: img,
                                                width: 64,
                                                height: 64,
                                                fit: BoxFit.cover,
                                                placeholder: (context, url) =>
                                                    Container(
                                                  width: 64,
                                                  height: 64,
                                                  color: Colors.grey.shade100,
                                                  child: const Center(
                                                    child: SizedBox(
                                                      width: 18,
                                                      height: 18,
                                                      child:
                                                          CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color:
                                                            Color(0xFF7C3AED),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                errorWidget: (context, url,
                                                        error) =>
                                                    Container(
                                                  width: 64,
                                                  height: 64,
                                                  color: Colors.grey.shade200,
                                                  child: const Icon(
                                                    Icons
                                                        .image_not_supported_outlined,
                                                    color: Colors.grey,
                                                    size: 24,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            Positioned(
                                              bottom: 2,
                                              right: 2,
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.all(3),
                                                decoration: BoxDecoration(
                                                  color: Colors.black87,
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                                child: const Icon(
                                                  Icons.qr_code_scanner,
                                                  color: Colors.white,
                                                  size: 14,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),

                                      const SizedBox(width: 12),

                                      // Title + UPC Input
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              p["name"] ?? "",
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w700,
                                                color: Colors.black87,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            if (p["price"] != null) ...[
                                              const SizedBox(height: 2),
                                              Text(
                                                "₹${p["price"]}",
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey.shade600,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ],
                                            const SizedBox(height: 6),
                                            SizedBox(
                                              height: 38,
                                              child: TextField(
                                                controller:
                                                    p["upcController"]
                                                        as TextEditingController,
                                                style: const TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                                decoration: InputDecoration(
                                                  hintText:
                                                      "Enter or scan barcode...",
                                                  hintStyle: TextStyle(
                                                    fontSize: 12,
                                                    color: Colors.grey.shade400,
                                                  ),
                                                  contentPadding:
                                                      const EdgeInsets
                                                          .symmetric(
                                                    horizontal: 10,
                                                    vertical: 8,
                                                  ),
                                                  isDense: true,
                                                  filled: true,
                                                  fillColor:
                                                      Colors.grey.shade50,
                                                  suffixIcon: IconButton(
                                                    padding: EdgeInsets.zero,
                                                    icon: const Icon(
                                                      Icons
                                                          .qr_code_scanner_rounded,
                                                      size: 20,
                                                      color: Color(0xFF7C3AED),
                                                    ),
                                                    onPressed: () => _scanQR(p),
                                                  ),
                                                  border: OutlineInputBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            8),
                                                    borderSide: BorderSide(
                                                      color:
                                                          Colors.grey.shade300,
                                                    ),
                                                  ),
                                                  enabledBorder:
                                                      OutlineInputBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            8),
                                                    borderSide: BorderSide(
                                                      color:
                                                          Colors.grey.shade300,
                                                    ),
                                                  ),
                                                  focusedBorder:
                                                      OutlineInputBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            8),
                                                    borderSide:
                                                      const BorderSide(
                                                        color:
                                                            Color(0xFF7C3AED),
                                                        width: 1.5,
                                                      ),
                                                  ),
                                                ),
                                                onSubmitted: (_) =>
                                                    _updateUPC(p),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),

                                      const SizedBox(width: 10),

                                      // Save/Update Button
                                      AnimatedBuilder(
                                        animation: (p["animController"]
                                                as AnimationController?) ??
                                            const AlwaysStoppedAnimation(0.0),
                                        builder: (_, child) {
                                          final scale = (p["animScale"]
                                                  as Animation<double>?)
                                              ?.value ??
                                              1.0;
                                          return Transform.scale(
                                            scale: scale,
                                            child: Container(
                                              width: 44,
                                              height: 44,
                                              decoration: BoxDecoration(
                                                color: isUpdated
                                                    ? Colors.green.shade600
                                                    : const Color(0xFF7C3AED),
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: (isUpdated
                                                            ? Colors.green
                                                            : const Color(
                                                                0xFF7C3AED))
                                                        .withValues(alpha: 0.3),
                                                    blurRadius: 6,
                                                    offset: const Offset(0, 2),
                                                  ),
                                                ],
                                              ),
                                              child: isUpdating
                                                  ? const Center(
                                                      child: SizedBox(
                                                        width: 20,
                                                        height: 20,
                                                        child:
                                                            CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                    )
                                                  : IconButton(
                                                      padding: EdgeInsets.zero,
                                                      onPressed: () =>
                                                          _updateUPC(p),
                                                      icon: Icon(
                                                        isUpdated
                                                            ? Icons.check
                                                            : Icons.save_rounded,
                                                        color: Colors.white,
                                                        size: 22,
                                                      ),
                                                    ),
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

// =====================================================================
//                    QR SCANNER SAFE PAGE
// =====================================================================
class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  final MobileScannerController controller = MobileScannerController();
  bool _scanned = false;
  bool _torchEnabled = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Scan Barcode / QR Code"),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: Icon(
              _torchEnabled ? Icons.flash_on : Icons.flash_off,
              color: _torchEnabled ? Colors.amber : Colors.white,
            ),
            onPressed: () async {
              await controller.toggleTorch();
              setState(() => _torchEnabled = !_torchEnabled);
            },
          ),
          IconButton(
            icon: const Icon(Icons.flip_camera_ios, color: Colors.white),
            onPressed: () => controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(
            controller: controller,
            onDetect: (capture) {
              if (_scanned) return;
              final barcodes = capture.barcodes;
              if (barcodes.isEmpty) return;

              final barcode = barcodes.first;
              final value = barcode.rawValue;

              if (value != null && value.trim().isNotEmpty) {
                _scanned = true;
                controller.stop();
                Navigator.pop(context, value.trim());
              }
            },
          ),

          // Reticle Scanner Overlay
          Container(
            width: 260,
            height: 260,
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFF7C3AED), width: 3),
              borderRadius: BorderRadius.circular(16),
            ),
          ),

          Positioned(
            bottom: 40,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                "Align barcode inside the frame",
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
