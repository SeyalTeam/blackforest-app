import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

const String apiHostPrimary = 'blackforest4.vseyal.com';
const String apiHostFallback = 'blackforest.vseyal.com';

const String _api1EnabledKey = 'api_server_api1_enabled';

const List<String> defaultApiHostCandidates = <String>[apiHostPrimary];

String _apiHostActive = apiHostPrimary;
bool _routingReady = false;
bool _isUsingRuntimeApiDomainConfig = false;
bool _isApiRoutingPrimaryOnlyMode = false;
List<String> _runtimeApiFallbackHosts = const <String>[apiHostFallback];
Future<void>? _routingReadyFuture;

String get apiHostActive => _apiHostActive;
bool get isUsingRuntimeApiDomainConfig => _isUsingRuntimeApiDomainConfig;
bool get isApiRoutingPrimaryOnlyMode => _isApiRoutingPrimaryOnlyMode;
List<String> get runtimeApiFallbackHosts =>
    List<String>.unmodifiable(_runtimeApiFallbackHosts);



String _normalizeHost(String? value) {
  var normalized = (value ?? '').trim().toLowerCase();
  if (normalized.isEmpty) return '';

  if (normalized.startsWith('//')) {
    normalized = 'https:$normalized';
  }

  if (normalized.startsWith('http://') || normalized.startsWith('https://')) {
    final parsed = Uri.tryParse(normalized);
    if (parsed != null && parsed.host.trim().isNotEmpty) {
      normalized = parsed.host.trim().toLowerCase();
    }
  }

  if (normalized.contains('/')) {
    normalized = normalized.split('/').first;
  }

  if (normalized.contains(':')) {
    normalized = normalized.split(':').first;
  }

  return normalized.trim();
}

bool isKnownApiHost(String host) {
  final normalized = _normalizeHost(host);
  return normalized == apiHostPrimary;
}







Future<Map<String, bool>> loadApiServerSelections({
  SharedPreferences? prefs,
}) async {
  final resolvedPrefs = prefs ?? await SharedPreferences.getInstance();
  final isEnabled = resolvedPrefs.getBool(_api1EnabledKey) ?? true;
  return <String, bool>{apiHostPrimary: isEnabled};
}

Future<void> saveApiServerSelections(
  Map<String, bool> selections, {
  SharedPreferences? prefs,
}) async {
  final resolvedPrefs = prefs ?? await SharedPreferences.getInstance();
  await resolvedPrefs.setBool(
    _api1EnabledKey,
    selections[apiHostPrimary] ?? true,
  );
}

List<String> selectedApiHostsInOrderFromSelections(
  Map<String, bool> selections,
) {
  final enabled = selections[apiHostPrimary] ?? true;
  if (!enabled) {
    // Always keep billing API on primary host.
    return <String>[apiHostPrimary];
  }
  return <String>[apiHostPrimary];
}

Future<List<String>> getSelectedApiHostsInOrder({
  SharedPreferences? prefs,
}) async {
  final selections = await loadApiServerSelections(prefs: prefs);
  return selectedApiHostsInOrderFromSelections(selections);
}

Future<void> _hydrateRoutingState() async {
  _apiHostActive = apiHostPrimary;
  _runtimeApiFallbackHosts = const <String>[];
  _isUsingRuntimeApiDomainConfig = false;
  _isApiRoutingPrimaryOnlyMode = true;
  _routingReady = true;
}

Future<void> ensureApiHostRoutingReady() async {
  if (_routingReady) return;
  final pending = _routingReadyFuture;
  if (pending != null) {
    await pending;
    return;
  }

  final task = _hydrateRoutingState();
  _routingReadyFuture = task;
  try {
    await task;
  } finally {
    _routingReadyFuture = null;
  }
}

List<String> getApiHostCandidates({String? preferredHost}) {
  return const <String>[apiHostPrimary];
}

Uri withActiveApiHost(Uri uri) {
  final host = _normalizeHost(uri.host);
  if (host.isEmpty) return uri;
  if (!isKnownApiHost(host)) return uri;
  final targetHost = _normalizeHost(_apiHostActive).isEmpty
      ? apiHostPrimary
      : _apiHostActive;
  return uri.replace(host: targetHost);
}

List<Uri> buildApiHostCandidateUris(Uri baseUri) {
  return <Uri>[withActiveApiHost(baseUri)];
}

String resolveApiAssetUrl(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return value;
  if (value.startsWith('data:image/')) return value;

  final sanitized = value.replaceAll(' ', '%20');
  final normalizedInput = sanitized.startsWith('//')
      ? 'https:$sanitized'
      : sanitized;

  if (normalizedInput.startsWith('http://') ||
      normalizedInput.startsWith('https://')) {
    final parsed = Uri.tryParse(normalizedInput);
    if (parsed == null || parsed.host.isEmpty) return normalizedInput;
    final shouldReplaceHost = isKnownApiHost(parsed.host);
    final activeHost = _normalizeHost(_apiHostActive).isEmpty
        ? apiHostPrimary
        : _apiHostActive;
    return parsed
        .replace(
          scheme: 'https',
          host: shouldReplaceHost ? activeHost : parsed.host,
        )
        .toString();
  }

  final activeHost = _normalizeHost(_apiHostActive).isEmpty
      ? apiHostPrimary
      : _apiHostActive;
  final relative = normalizedInput.startsWith('/')
      ? normalizedInput
      : '/$normalizedInput';
  final relativeUri = Uri.parse('https://$activeHost$relative');
  return relativeUri.toString();
}
