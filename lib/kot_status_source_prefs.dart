import 'package:shared_preferences/shared_preferences.dart';

const String kotStatusSourcePrefKey = 'kot_status_source_v1';
const String kotStatusSourceConfirmed = 'confirmed';
const String kotStatusSourcePrepared = 'prepared';

String normalizeKotStatusSource(
  String? raw, {
  String fallback = kotStatusSourceConfirmed,
}) {
  final normalized = (raw ?? '').trim().toLowerCase();
  if (normalized == kotStatusSourcePrepared) {
    return kotStatusSourcePrepared;
  }
  if (normalized == kotStatusSourceConfirmed) {
    return kotStatusSourceConfirmed;
  }
  return fallback;
}

String loadKotStatusSourceFromPrefs(
  SharedPreferences prefs, {
  String fallback = kotStatusSourceConfirmed,
}) {
  return normalizeKotStatusSource(
    prefs.getString(kotStatusSourcePrefKey),
    fallback: fallback,
  );
}

Future<void> saveKotStatusSourceToPrefs(
  SharedPreferences prefs,
  String status,
) async {
  final normalized = normalizeKotStatusSource(status);
  await prefs.setString(kotStatusSourcePrefKey, normalized);
}
