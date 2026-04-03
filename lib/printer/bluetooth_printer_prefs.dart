import 'package:shared_preferences/shared_preferences.dart';

const String btPrinterMacKey = 'bt_printer_mac';
const String btPrinterNameKey = 'bt_printer_name';
const String btPrinterUseBillingKey = 'bt_printer_use_billing';
const String btPrinterUseKotKey = 'bt_printer_use_kot';

bool isBluetoothBillingEnabled(SharedPreferences prefs) {
  return prefs.getBool(btPrinterUseBillingKey) ?? true;
}

bool isBluetoothKotEnabled(SharedPreferences prefs) {
  return prefs.getBool(btPrinterUseKotKey) ?? true;
}

Future<void> ensureBluetoothPrinterRoutingPrefs(SharedPreferences prefs) async {
  if (!prefs.containsKey(btPrinterUseBillingKey)) {
    await prefs.setBool(btPrinterUseBillingKey, true);
  }
  if (!prefs.containsKey(btPrinterUseKotKey)) {
    await prefs.setBool(btPrinterUseKotKey, true);
  }
}

Future<void> saveBluetoothPrinterRoutingPrefs(
  SharedPreferences prefs, {
  required bool billingEnabled,
  required bool kotEnabled,
}) async {
  await prefs.setBool(btPrinterUseBillingKey, billingEnabled);
  await prefs.setBool(btPrinterUseKotKey, kotEnabled);
}

Future<void> clearBluetoothPrinterPrefs(SharedPreferences prefs) async {
  await prefs.remove(btPrinterMacKey);
  await prefs.remove(btPrinterNameKey);
  await prefs.remove(btPrinterUseBillingKey);
  await prefs.remove(btPrinterUseKotKey);
}
