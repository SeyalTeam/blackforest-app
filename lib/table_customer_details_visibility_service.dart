import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:blackforest_app/app_http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class TableCustomerDetailsVisibilityConfig {
  final bool showCustomerDetailsForTableOrders;
  final bool allowSkipCustomerDetailsForTableOrders;
  final bool autoSubmitCustomerDetailsForTableOrders;
  final bool showCustomerDetailsForBillingOrders;
  final bool allowSkipCustomerDetailsForBillingOrders;
  final bool autoSubmitCustomerDetailsForBillingOrders;
  final bool showCustomerHistoryForTableOrders;
  final bool showCustomerHistoryForBillingOrders;

  const TableCustomerDetailsVisibilityConfig({
    required this.showCustomerDetailsForTableOrders,
    required this.allowSkipCustomerDetailsForTableOrders,
    required this.autoSubmitCustomerDetailsForTableOrders,
    required this.showCustomerDetailsForBillingOrders,
    required this.allowSkipCustomerDetailsForBillingOrders,
    required this.autoSubmitCustomerDetailsForBillingOrders,
    required this.showCustomerHistoryForTableOrders,
    required this.showCustomerHistoryForBillingOrders,
  });

  static const TableCustomerDetailsVisibilityConfig defaultValue =
      TableCustomerDetailsVisibilityConfig(
        showCustomerDetailsForTableOrders: true,
        allowSkipCustomerDetailsForTableOrders: true,
        autoSubmitCustomerDetailsForTableOrders: true,
        showCustomerDetailsForBillingOrders: true,
        allowSkipCustomerDetailsForBillingOrders: true,
        autoSubmitCustomerDetailsForBillingOrders: true,
        showCustomerHistoryForTableOrders: true,
        showCustomerHistoryForBillingOrders: true,
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
        bool? parseBool(dynamic value) {
          if (value is bool) return value;
          if (value is num) {
            if (value == 1) return true;
            if (value == 0) return false;
          }
          if (value is String) {
            final normalized = value.trim().toLowerCase();
            if (normalized.isEmpty) return null;
            if (normalized == 'true' ||
                normalized == '1' ||
                normalized == 'yes' ||
                normalized == 'on' ||
                normalized == 'enabled') {
              return true;
            }
            if (normalized == 'false' ||
                normalized == '0' ||
                normalized == 'no' ||
                normalized == 'off' ||
                normalized == 'disabled') {
              return false;
            }
          }
          return null;
        }

        Map<String, dynamic>? toMap(dynamic value) {
          if (value is Map) {
            return Map<String, dynamic>.from(value);
          }
          return null;
        }

        bool readBoolFromTree(
          dynamic node,
          List<String> keys,
          bool defaultValue,
        ) {
          final wanted = keys.map((k) => k.toLowerCase()).toSet();

          bool? scan(dynamic current) {
            if (current is Map) {
              for (final entry in current.entries) {
                final key = entry.key.toString().toLowerCase();
                if (wanted.contains(key)) {
                  final parsed = parseBool(entry.value);
                  if (parsed != null) return parsed;
                }
              }
              for (final entry in current.entries) {
                final nested = scan(entry.value);
                if (nested != null) return nested;
              }
            } else if (current is List) {
              for (final item in current) {
                final nested = scan(item);
                if (nested != null) return nested;
              }
            }
            return null;
          }

          return scan(node) ?? defaultValue;
        }

        final root = Map<String, dynamic>.from(decoded);
        final doc = toMap(root['doc']);
        final data = toMap(root['data']);
        final docs = root['docs'];
        final firstDoc = (docs is List && docs.isNotEmpty)
            ? toMap(docs.first)
            : null;
        final source = doc ?? data ?? firstDoc ?? root;

        final showCustomerDetailsForTableOrders = readBoolFromTree(source, [
          'showCustomerDetailsForTableOrders',
          'showCustomerDetailsForTableOrder',
          'showCustomerDetailsForTable',
          'showTableCustomerDetails',
          'show_table_customer_details',
          'showCustomerDetailsButtonForTableOrders',
          'showCustomerDetailsButtonForTableOrder',
        ], true);
        final allowSkipCustomerDetailsForTableOrders =
            readBoolFromTree(source, [
              'allowSkipCustomerDetailsForTableOrders',
              'allowSkipCustomerDetailsForTableOrder',
              'allowSkipForTableOrders',
              'allowSkipForTable',
              'allow_skip_customer_details_for_table_orders',
              'allowSkipButtonForTableOrders',
              'allowSkipButtonForTableOrder',
            ], true);
        final autoSubmitCustomerDetailsForTableOrders =
            readBoolFromTree(source, [
              'autoSubmitCustomerDetailsForTableOrders',
              'autoSubmitCustomerDetailsForTableOrder',
              'enableAutoSubmitCustomerDetailsForTableOrders',
              'enableAutoSubmitCustomerDetailsForTableOrder',
              'autoSubmitForTableOrders',
              'autoSubmitForTableOrder',
              'autoSubmitForTable',
              'auto_submit_customer_details_for_table_orders',
              'autoSubmitCustomerDetails',
            ], true);
        final showCustomerDetailsForBillingOrders = readBoolFromTree(source, [
          'showCustomerDetailsForBillingOrders',
          'showCustomerDetailsForBillingOrder',
          'showCustomerDetailsForBilling',
          'showBillingCustomerDetails',
          'show_billing_customer_details',
          'showCustomerDetailsButtonForBillingOrders',
          'showCustomerDetailsButtonForBillingOrder',
        ], true);
        final allowSkipCustomerDetailsForBillingOrders =
            readBoolFromTree(source, [
              'allowSkipCustomerDetailsForBillingOrders',
              'allowSkipCustomerDetailsForBillingOrder',
              'allowSkipCustomerDetailsForBilling',
              'allowSkipForBillingOrders',
              'allowSkipForBilling',
              'allow_skip_customer_details_for_billing_orders',
              'allowSkipButtonForBillingOrders',
              'allowSkipButtonForBillingOrder',
            ], true);
        final autoSubmitCustomerDetailsForBillingOrders =
            readBoolFromTree(source, [
              'autoSubmitCustomerDetailsForBillingOrders',
              'autoSubmitCustomerDetailsForBillingOrder',
              'enableAutoSubmitCustomerDetailsForBillingOrders',
              'enableAutoSubmitCustomerDetailsForBillingOrder',
              'autoSubmitForBillingOrders',
              'autoSubmitForBillingOrder',
              'autoSubmitForBilling',
              'auto_submit_customer_details_for_billing_orders',
              'autoSubmitCustomerDetails',
            ], true);
        final showCustomerHistoryForTableOrders = readBoolFromTree(source, [
          'showCustomerHistoryForTableOrders',
          'showCustomerHistoryForTableOrder',
          'showCustomerHistoryForTable',
          'showTableCustomerHistory',
          'show_table_customer_history',
          'showCustomerHistoryButtonForTableOrders',
          'showCustomerHistoryButtonForTableOrder',
          'showCustomerHistory',
        ], true);
        final showCustomerHistoryForBillingOrders = readBoolFromTree(source, [
          'showCustomerHistoryForBillingOrders',
          'showCustomerHistoryForBillingOrder',
          'showCustomerHistoryForBilling',
          'showBillingCustomerHistory',
          'show_billing_customer_history',
          'showCustomerHistoryButtonForBillingOrders',
          'showCustomerHistoryButtonForBillingOrder',
          'showCustomerHistory',
        ], true);

        final config = TableCustomerDetailsVisibilityConfig(
          showCustomerDetailsForTableOrders: showCustomerDetailsForTableOrders,
          allowSkipCustomerDetailsForTableOrders:
              allowSkipCustomerDetailsForTableOrders,
          autoSubmitCustomerDetailsForTableOrders:
              autoSubmitCustomerDetailsForTableOrders,
          showCustomerDetailsForBillingOrders:
              showCustomerDetailsForBillingOrders,
          allowSkipCustomerDetailsForBillingOrders:
              allowSkipCustomerDetailsForBillingOrders,
          autoSubmitCustomerDetailsForBillingOrders:
              autoSubmitCustomerDetailsForBillingOrders,
          showCustomerHistoryForTableOrders: showCustomerHistoryForTableOrders,
          showCustomerHistoryForBillingOrders:
              showCustomerHistoryForBillingOrders,
        );

        debugPrint(
          '[TableCustomerDetailsVisibilityService] config table(show=${config.showCustomerDetailsForTableOrders}, skip=${config.allowSkipCustomerDetailsForTableOrders}, history=${config.showCustomerHistoryForTableOrders}, autoSubmit=${config.autoSubmitCustomerDetailsForTableOrders}) billing(show=${config.showCustomerDetailsForBillingOrders}, skip=${config.allowSkipCustomerDetailsForBillingOrders}, history=${config.showCustomerHistoryForBillingOrders}, autoSubmit=${config.autoSubmitCustomerDetailsForBillingOrders})',
        );

        return config;
      }
    } catch (error) {
      debugPrint(
        '[TableCustomerDetailsVisibilityService] Request failed: $error',
      );
    }

    return TableCustomerDetailsVisibilityConfig.defaultValue;
  }
}
