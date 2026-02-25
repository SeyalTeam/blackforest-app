import 'package:shared_preferences/shared_preferences.dart';
import 'package:blackforest_app/table_customer_details_visibility_service.dart';

const String _favoriteCategoryPrefix = 'favorite_category_ids_';

Future<void> clearSessionPreservingFavorites(SharedPreferences prefs) async {
  final Map<String, List<String>> favoritesBackup = {};
  for (final key in prefs.getKeys()) {
    if (key.startsWith(_favoriteCategoryPrefix)) {
      favoritesBackup[key] = prefs.getStringList(key) ?? <String>[];
    }
  }

  await prefs.clear();
  TableCustomerDetailsVisibilityService.clearCache();

  for (final entry in favoritesBackup.entries) {
    await prefs.setStringList(entry.key, entry.value);
  }
}
