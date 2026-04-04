import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/table_customer_details_visibility_service.dart';
import 'package:blackforest_app/printer/bluetooth_printer_prefs.dart';
import 'package:blackforest_app/printer/thermal_print_prefs.dart';

const String _favoriteCategoryPrefix = 'favorite_category_ids_';

Future<void> clearSessionPreservingFavorites(SharedPreferences prefs) async {
  final Map<String, dynamic> backup = {};
  for (final key in prefs.getKeys()) {
    if (key.startsWith(_favoriteCategoryPrefix)) {
      backup[key] = prefs.getStringList(key) ?? <String>[];
    } else if (key == btPrinterMacKey ||
        key == btPrinterNameKey ||
        key == btPrinterUseBillingKey ||
        key == btPrinterUseKotKey ||
        key == thermalReviewPrintEnabledKey ||
        key == 'printerPort' ||
        key == 'branchIp' ||
        key == 'printerIp') {
      backup[key] = prefs.get(key);
    }
  }

  await prefs.clear();
  TableCustomerDetailsVisibilityService.clearCache();

  for (final entry in backup.entries) {
    if (entry.value is List<String>) {
      await prefs.setStringList(entry.key, entry.value as List<String>);
    } else if (entry.value is String) {
      await prefs.setString(entry.key, entry.value as String);
    } else if (entry.value is int) {
      await prefs.setInt(entry.key, entry.value as int);
    } else if (entry.value is bool) {
      await prefs.setBool(entry.key, entry.value as bool);
    }
  }
}
