import 'package:shared_preferences/shared_preferences.dart';

const String apiHostPrimary = 'blackforest.vseyal.com';
const String apiHostSecondary = 'blackforest1.vseyal.com';
const String apiHostTertiary = 'blackforest2.vseyal.com';

const String _api1EnabledKey = 'api_server_api1_enabled';
const String _api2EnabledKey = 'api_server_api2_enabled';
const String _api3EnabledKey = 'api_server_api3_enabled';

const List<String> _defaultApiFailoverOrder = [
  apiHostSecondary,
  apiHostPrimary,
  apiHostTertiary,
];

String _preferenceKeyForHost(String host) {
  switch (host) {
    case apiHostPrimary:
      return _api1EnabledKey;
    case apiHostSecondary:
      return _api2EnabledKey;
    case apiHostTertiary:
      return _api3EnabledKey;
    default:
      throw ArgumentError('Unknown API host: $host');
  }
}

bool isKnownApiHost(String host) {
  return host == apiHostPrimary ||
      host == apiHostSecondary ||
      host == apiHostTertiary;
}

Future<Map<String, bool>> loadApiServerSelections({
  SharedPreferences? prefs,
}) async {
  final resolvedPrefs = prefs ?? await SharedPreferences.getInstance();
  return {
    apiHostPrimary: resolvedPrefs.getBool(_api1EnabledKey) ?? true,
    apiHostSecondary: resolvedPrefs.getBool(_api2EnabledKey) ?? true,
    apiHostTertiary: resolvedPrefs.getBool(_api3EnabledKey) ?? true,
  };
}

Future<void> saveApiServerSelections(
  Map<String, bool> selections, {
  SharedPreferences? prefs,
}) async {
  final resolvedPrefs = prefs ?? await SharedPreferences.getInstance();
  for (final host in [apiHostPrimary, apiHostSecondary, apiHostTertiary]) {
    await resolvedPrefs.setBool(
      _preferenceKeyForHost(host),
      selections[host] ?? true,
    );
  }
}

List<String> selectedApiHostsInOrderFromSelections(
  Map<String, bool> selections,
) {
  final ordered = _defaultApiFailoverOrder
      .where((host) => selections[host] ?? true)
      .toList(growable: false);
  if (ordered.isEmpty) {
    return List<String>.from(_defaultApiFailoverOrder);
  }
  return ordered;
}

Future<List<String>> getSelectedApiHostsInOrder({
  SharedPreferences? prefs,
}) async {
  final selections = await loadApiServerSelections(prefs: prefs);
  return selectedApiHostsInOrderFromSelections(selections);
}
