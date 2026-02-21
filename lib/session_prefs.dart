import 'package:shared_preferences/shared_preferences.dart';

const String _favoriteCategoryPrefix = 'favorite_category_ids_';

Future<void> clearSessionPreservingFavorites(SharedPreferences prefs) async {
  final Map<String, List<String>> favoritesBackup = {};
  for (final key in prefs.getKeys()) {
    if (key.startsWith(_favoriteCategoryPrefix)) {
      favoritesBackup[key] = prefs.getStringList(key) ?? <String>[];
    }
  }

  await prefs.clear();

  for (final entry in favoritesBackup.entries) {
    await prefs.setStringList(entry.key, entry.value);
  }
}
