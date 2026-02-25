import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class TableCustomerDetailsVisibilityConfig {
  final bool showCustomerDetailsForTableOrders;
  final bool allowSkipCustomerDetailsForTableOrders;
  final bool showCustomerDetailsForBillingOrders;
  final bool allowSkipCustomerDetailsForBillingOrders;

  const TableCustomerDetailsVisibilityConfig({
    required this.showCustomerDetailsForTableOrders,
    required this.allowSkipCustomerDetailsForTableOrders,
    required this.showCustomerDetailsForBillingOrders,
    required this.allowSkipCustomerDetailsForBillingOrders,
  });

  static const TableCustomerDetailsVisibilityConfig defaultValue =
      TableCustomerDetailsVisibilityConfig(
        showCustomerDetailsForTableOrders: true,
        allowSkipCustomerDetailsForTableOrders: true,
        showCustomerDetailsForBillingOrders: true,
        allowSkipCustomerDetailsForBillingOrders: true,
      );
}

class TableCustomerDetailsVisibilityService {
  TableCustomerDetailsVisibilityService._();

  static const String _apiHost = 'blackforest.vseyal.com';
  static final Map<String, TableCustomerDetailsVisibilityConfig>
  _cacheByBranch = {};
  static final Map<String, Future<TableCustomerDetailsVisibilityConfig>>
  _inFlightByBranch = {};

  static Future<TableCustomerDetailsVisibilityConfig> getConfigForBranch({
    String? branchId,
    String? token,
    bool forceRefresh = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final resolvedBranchId = branchId?.trim().isNotEmpty == true
        ? branchId!.trim()
        : prefs.getString('branchId')?.trim();

    if (resolvedBranchId == null || resolvedBranchId.isEmpty) {
      return TableCustomerDetailsVisibilityConfig.defaultValue;
    }

    // In debug builds, always fetch fresh value so backend setting changes
    // are visible without app restart/hot restart.
    final bypassCache = kDebugMode || forceRefresh;
    if (!bypassCache) {
      final cached = _cacheByBranch[resolvedBranchId];
      if (cached != null) {
        return cached;
      }

      final inFlight = _inFlightByBranch[resolvedBranchId];
      if (inFlight != null) {
        return inFlight;
      }
    }

    final request = _fetchVisibility(
      branchId: resolvedBranchId,
      token: token,
      prefs: prefs,
    );
    if (!bypassCache) {
      _inFlightByBranch[resolvedBranchId] = request;
    }

    try {
      final config = await request;
      _cacheByBranch[resolvedBranchId] = config;
      return config;
    } finally {
      if (!bypassCache) {
        _inFlightByBranch.remove(resolvedBranchId);
      }
    }
  }

  static Future<bool> shouldShowForBranch({
    String? branchId,
    String? token,
    bool forceRefresh = false,
  }) async {
    final config = await getConfigForBranch(
      branchId: branchId,
      token: token,
      forceRefresh: forceRefresh,
    );
    return config.showCustomerDetailsForTableOrders;
  }

  static void clearCache({String? branchId}) {
    final trimmed = branchId?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      _cacheByBranch.clear();
      _inFlightByBranch.clear();
      return;
    }
    _cacheByBranch.remove(trimmed);
    _inFlightByBranch.remove(trimmed);
  }

  static Future<TableCustomerDetailsVisibilityConfig> _fetchVisibility({
    required String branchId,
    required SharedPreferences prefs,
    String? token,
  }) async {
    final resolvedToken = token?.trim().isNotEmpty == true
        ? token!.trim()
        : prefs.getString('token')?.trim();

    if (resolvedToken == null || resolvedToken.isEmpty) {
      return TableCustomerDetailsVisibilityConfig.defaultValue;
    }

    final uri = Uri.https(
      _apiHost,
      '/api/widgets/table-customer-details-visibility',
      {'branchId': branchId},
    );

    try {
      final response = await http.get(
        uri,
        headers: {
          'Authorization': 'Bearer $resolvedToken',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode != 200) {
        debugPrint(
          '[TableCustomerDetailsVisibilityService] Non-200 response: ${response.statusCode}',
        );
        return TableCustomerDetailsVisibilityConfig.defaultValue;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        bool readBool(dynamic value, bool defaultValue) {
          if (value is bool) return value;
          if (value is String) {
            final normalized = value.trim().toLowerCase();
            if (normalized == 'true') return true;
            if (normalized == 'false') return false;
          }
          return defaultValue;
        }

        final showCustomerDetailsForTableOrders = readBool(
          decoded['showCustomerDetailsForTableOrders'],
          true,
        );
        final allowSkipCustomerDetailsForTableOrders = readBool(
          decoded['allowSkipCustomerDetailsForTableOrders'],
          true,
        );
        final showCustomerDetailsForBillingOrders = readBool(
          decoded['showCustomerDetailsForBillingOrders'],
          true,
        );
        final allowSkipCustomerDetailsForBillingOrders = readBool(
          decoded['allowSkipCustomerDetailsForBillingOrders'],
          true,
        );

        return TableCustomerDetailsVisibilityConfig(
          showCustomerDetailsForTableOrders: showCustomerDetailsForTableOrders,
          allowSkipCustomerDetailsForTableOrders:
              allowSkipCustomerDetailsForTableOrders,
          showCustomerDetailsForBillingOrders:
              showCustomerDetailsForBillingOrders,
          allowSkipCustomerDetailsForBillingOrders:
              allowSkipCustomerDetailsForBillingOrders,
        );
      }
    } catch (error) {
      debugPrint(
        '[TableCustomerDetailsVisibilityService] Request failed: $error',
      );
    }

    return TableCustomerDetailsVisibilityConfig.defaultValue;
  }
}
