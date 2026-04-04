import 'package:shared_preferences/shared_preferences.dart';

const String thermalReviewPrintEnabledKey = 'thermal_review_print_enabled';

bool isThermalReviewPrintEnabled(SharedPreferences prefs) {
  return prefs.getBool(thermalReviewPrintEnabledKey) ?? true;
}

Future<void> setThermalReviewPrintEnabled(
  SharedPreferences prefs,
  bool enabled,
) async {
  await prefs.setBool(thermalReviewPrintEnabledKey, enabled);
}
