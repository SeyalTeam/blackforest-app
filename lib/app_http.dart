import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:blackforest_app/api_server_prefs.dart';
import 'package:blackforest_app/auth_session_manager.dart';
import 'package:blackforest_app/app_version.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as raw_http;
import 'package:shared_preferences/shared_preferences.dart';

export 'package:http/http.dart'
    show
        BaseRequest,
        BaseResponse,
        ByteStream,
        Client,
        ClientException,
        MultipartFile,
        MultipartRequest,
        Response,
        StreamedResponse;

bool _isUnauthorized(int statusCode) => statusCode == 401 || statusCode == 403;

const String envelopeHeaderName = 'x-bf-response-envelope';
const String requestIdHeaderName = 'x-request-id';
const String idempotencyHeaderName = 'Idempotency-Key';
const String skipUnauthorizedLogoutHeaderName = 'x-bf-skip-unauthorized-logout';
const String canaryEnvelopeEnabledPrefKey = 'bf_canary_envelope_enabled';
const String canaryEnvelopePercentPrefKey = 'bf_canary_envelope_percent';
const String canaryEnvelopeSeedPrefKey = 'bf_canary_envelope_seed';
const String _deviceIdPrefKey = 'deviceId';
const String _userIdPrefKey = 'user_id';
const bool _canaryEnvelopeEnabledDefault = bool.fromEnvironment(
  'BF_CANARY_ENVELOPE_ENABLED',
  defaultValue: false,
);
const int _canaryEnvelopePercentDefault = int.fromEnvironment(
  'BF_CANARY_ENVELOPE_PERCENT',
  defaultValue: 0,
);
const bool _logRequestIdOnFailure = bool.fromEnvironment(
  'BF_LOG_REQUEST_ID_ON_FAILURE',
  defaultValue: true,
);

const Duration _readRequestTimeout = Duration(seconds: 15);
const Duration _writeRequestTimeout = Duration(seconds: 20);
final raw_http.Client _sharedHttpClient = raw_http.Client();
const Duration _canaryConfigCacheTtl = Duration(seconds: 20);
_CanaryConfig? _cachedCanaryConfig;
DateTime? _cachedCanaryConfigAt;

final Random _idempotencyRandom = (() {
  try {
    return Random.secure();
  } catch (_) {
    return Random();
  }
})();

class _CanaryConfig {
  const _CanaryConfig({
    required this.envelopeEnabled,
    required this.rolloutPercent,
    required this.seed,
  });

  final bool envelopeEnabled;
  final int rolloutPercent;
  final String seed;
}

bool _hasBearerToken(Map<String, String>? headers) {
  if (headers == null || headers.isEmpty) return false;
  final auth = headers['Authorization'] ?? headers['authorization'];
  if (auth == null) return false;
  return auth.trim().toLowerCase().startsWith('bearer ');
}

bool _isLoginEndpoint(Uri url) {
  if (!isKnownApiHost(url.host)) return false;
  return url.path == '/api/users/login' || url.path == '/api/v1/users/login';
}

bool _isAppApi(Uri url) {
  return isKnownApiHost(url.host) && url.path.startsWith('/api/');
}

bool _isBillingWriteRequest(Uri url, String method) {
  if (!_isAppApi(url)) return false;
  final upperMethod = method.toUpperCase();
  if (upperMethod != 'POST' && upperMethod != 'PATCH') return false;
  String path = url.path;
  if (path.startsWith('/api/v1/')) {
    path = path.replaceFirst('/api/v1/', '/api/');
  }
  if (upperMethod == 'POST') {
    return path == '/api/billings';
  }
  return path.startsWith('/api/billings/');
}

int _normalizedRolloutPercent(int value) {
  if (value < 0) return 0;
  if (value > 100) return 100;
  return value;
}

int _stablePercentBucket(String seed) {
  var hash = 2166136261;
  for (final codeUnit in seed.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 16777619) & 0x7fffffff;
  }
  return hash % 100;
}

Future<_CanaryConfig> _resolveCanaryConfig() async {
  final now = DateTime.now();
  if (_cachedCanaryConfig != null &&
      _cachedCanaryConfigAt != null &&
      now.difference(_cachedCanaryConfigAt!) <= _canaryConfigCacheTtl) {
    return _cachedCanaryConfig!;
  }

  bool enabled = _canaryEnvelopeEnabledDefault;
  int percent = _normalizedRolloutPercent(_canaryEnvelopePercentDefault);
  String seed = '';

  try {
    final prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool(canaryEnvelopeEnabledPrefKey) ?? enabled;
    final percentOverride = prefs.getInt(canaryEnvelopePercentPrefKey);
    if (percentOverride != null) {
      percent = _normalizedRolloutPercent(percentOverride);
    }
    final explicitSeed = prefs.getString(canaryEnvelopeSeedPrefKey)?.trim();
    if (explicitSeed != null && explicitSeed.isNotEmpty) {
      seed = explicitSeed;
    } else {
      seed =
          prefs.getString(_deviceIdPrefKey)?.trim() ??
          prefs.getString(_userIdPrefKey)?.trim() ??
          '';
    }
  } catch (_) {
    // Keep compile-time fallback values when preferences are unavailable.
  }

  final resolved = _CanaryConfig(
    envelopeEnabled: enabled,
    rolloutPercent: percent,
    seed: seed,
  );
  _cachedCanaryConfig = resolved;
  _cachedCanaryConfigAt = now;
  return resolved;
}

Future<bool> _shouldAttachEnvelopeHeader(Uri url) async {
  if (!_isAppApi(url)) return false;
  final config = await _resolveCanaryConfig();
  if (config.envelopeEnabled) return true;
  final percent = config.rolloutPercent;
  if (percent <= 0) return false;
  if (percent >= 100) return true;
  final seed = config.seed.trim();
  if (seed.isEmpty) return false;
  return _stablePercentBucket(seed) < percent;
}

bool _hasHeaderKey(Map<String, String>? headers, String headerName) {
  if (headers == null || headers.isEmpty) return false;
  final target = headerName.toLowerCase();
  for (final key in headers.keys) {
    if (key.toLowerCase() == target) return true;
  }
  return false;
}

String? _readHeader(Map<String, String>? headers, String headerName) {
  if (headers == null || headers.isEmpty) return null;
  final target = headerName.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() != target) continue;
    final value = entry.value.trim();
    return value.isEmpty ? null : value;
  }
  return null;
}

String _randomHexToken(int length) {
  const chars = '0123456789abcdef';
  final buffer = StringBuffer();
  for (var i = 0; i < length; i++) {
    buffer.write(chars[_idempotencyRandom.nextInt(chars.length)]);
  }
  return buffer.toString();
}

String generateIdempotencyKey({String scope = 'billings'}) {
  final normalizedScope = scope.trim().isEmpty ? 'billings' : scope.trim();
  final now = DateTime.now().toUtc().millisecondsSinceEpoch.toRadixString(36);
  final entropy = _randomHexToken(16);
  return 'bf-$normalizedScope-$now-$entropy';
}

Future<Map<String, String>?> _prepareHeaders(
  Uri url,
  String method,
  Map<String, String>? headers,
) async {
  if (!_isAppApi(url)) return headers;
  Map<String, String>? resolved = headers == null
      ? null
      : Map<String, String>.from(headers);
  var changed = false;

  if (!_hasHeaderKey(resolved, envelopeHeaderName) &&
      await _shouldAttachEnvelopeHeader(url)) {
    resolved ??= <String, String>{};
    resolved[envelopeHeaderName] = 'v1';
    changed = true;
  }

  if (_isBillingWriteRequest(url, method) &&
      !_hasHeaderKey(resolved, idempotencyHeaderName)) {
    resolved ??= <String, String>{};
    final scope = method.toUpperCase() == 'POST'
        ? 'billings-create'
        : 'billings-update';
    resolved[idempotencyHeaderName] = generateIdempotencyKey(scope: scope);
    changed = true;
  }

  // Attach X-App-Version header to all app API requests
  if (_isAppApi(url)) {
    final version = AppVersion.current;
    if (version.isNotEmpty && !_hasHeaderKey(resolved, 'X-App-Version')) {
      resolved ??= <String, String>{};
      resolved['X-App-Version'] = version;
      changed = true;
    }
  }

  if (!changed) return headers;
  return resolved;
}

bool _shouldHandleUnauthorized(Uri url, Map<String, String>? headers) {
  final skipLogoutHeader = _readHeader(
    headers,
    skipUnauthorizedLogoutHeaderName,
  );
  final shouldSkipLogout =
      skipLogoutHeader != null &&
      (skipLogoutHeader == '1' ||
          skipLogoutHeader.toLowerCase() == 'true' ||
          skipLogoutHeader.toLowerCase() == 'yes');
  if (shouldSkipLogout) {
    return false;
  }
  if (_isLoginEndpoint(url)) return false;
  if (_hasBearerToken(headers)) return true;
  return _isAppApi(url);
}

typedef _RequestExecutor = Future<raw_http.Response> Function(Uri url);
typedef _RequestWithHeadersExecutor =
    Future<raw_http.Response> Function(Uri url, Map<String, String>? headers);

Future<raw_http.Response> _sendRequest(
  Uri url,
  _RequestExecutor execute,
  String method,
  Duration? timeoutOverride,
) async {
  final isReadRequest = method == 'GET' || method == 'HEAD';
  final timeoutForMethod =
      timeoutOverride ??
      (isReadRequest ? _readRequestTimeout : _writeRequestTimeout);
  if (_isAppApi(url)) {
    return execute(url).timeout(timeoutForMethod);
  }
  return execute(url);
}

bool _supportsApiFailover(String method) {
  final normalizedMethod = method.toUpperCase();
  return normalizedMethod == 'GET' || normalizedMethod == 'HEAD';
}

bool _shouldRetryOnServerStatus(String method, int statusCode) {
  if (!_supportsApiFailover(method)) return false;
  return statusCode >= 500;
}

Future<raw_http.Response> _executeRequestWithRouting({
  required Uri originalUrl,
  required String method,
  required Map<String, String>? headers,
  Duration? timeoutOverride,
  required _RequestWithHeadersExecutor execute,
}) async {
  await ensureApiHostRoutingReady();

  final primaryUrl = withActiveApiHost(originalUrl);
  final candidateUrls = _supportsApiFailover(method) && _isAppApi(primaryUrl)
      ? buildApiHostCandidateUris(primaryUrl)
      : <Uri>[primaryUrl];

  raw_http.Response? lastResponse;
  Object? lastError;
  StackTrace? lastStackTrace;

  for (var index = 0; index < candidateUrls.length; index++) {
    final requestUrl = candidateUrls[index];
    final resolvedHeaders = await _prepareHeaders(requestUrl, method, headers);
    final hasRemainingCandidate = index < candidateUrls.length - 1;
    final canFailover = _supportsApiFailover(method) && hasRemainingCandidate;

    try {
      final response = await _interceptResponse(
        _sendRequest(
          requestUrl,
          (resolvedUrl) => execute(resolvedUrl, resolvedHeaders),
          method,
          timeoutOverride,
        ),
        url: requestUrl,
        method: method,
        headers: resolvedHeaders,
      );


      if (_shouldRetryOnServerStatus(method, response.statusCode) &&
          canFailover) {
        lastResponse = response;
        continue;
      }

      return response;
    } on TimeoutException catch (error, stackTrace) {
      if (!canFailover) rethrow;
      lastError = error;
      lastStackTrace = stackTrace;
    } on SocketException catch (error, stackTrace) {
      if (!canFailover) rethrow;
      lastError = error;
      lastStackTrace = stackTrace;
    } on raw_http.ClientException catch (error, stackTrace) {
      if (!canFailover) rethrow;
      lastError = error;
      lastStackTrace = stackTrace;
    }
  }

  if (lastResponse != null) return lastResponse;
  if (lastError != null) {
    Error.throwWithStackTrace(lastError, lastStackTrace ?? StackTrace.current);
  }
  throw Exception('Request failed without response');
}

Future<raw_http.Response> _interceptResponse(
  Future<raw_http.Response> future, {
  required Uri url,
  required String method,
  Map<String, String>? headers,
}) async {
  final response = await future;
  final requestId = _readHeader(response.headers, requestIdHeaderName);
  if (response.statusCode >= 400 && _isAppApi(url)) {
    debugPrint(
      '[HTTP ERROR] ${method.toUpperCase()} ${url.path} failed with status: ${response.statusCode}\n'
      'Request ID: $requestId\n'
      'Response Body: ${response.body}',
    );
  } else if (_logRequestIdOnFailure &&
      requestId != null &&
      requestId.isNotEmpty &&
      response.statusCode >= 400 &&
      _isAppApi(url)) {
    debugPrint(
      '[HTTP] ${method.toUpperCase()} ${url.path} failed (${response.statusCode}) request-id=$requestId',
    );
  }
  if (response.statusCode == 426 && _isAppApi(url)) {
    // App version is outdated — show the update required screen
    String? updateMessage;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        updateMessage = decoded['message']?.toString();
      }
    } catch (_) {}
    unawaited(
      AuthSessionManager.instance.handleAppOutdated(message: updateMessage),
    );
    return response;
  }
  if (_isUnauthorized(response.statusCode) &&
      _shouldHandleUnauthorized(url, headers)) {
    unawaited(
      AuthSessionManager.instance.handleUnauthorized(
        message: AuthSessionManager.defaultSessionExpiredMessage,
      ),
    );
  }
  return response;
}

Future<raw_http.Response> get(Uri url, {Map<String, String>? headers}) async {
  return _executeRequestWithRouting(
    originalUrl: url,
    method: 'GET',
    headers: headers,
    execute: (requestUrl, resolvedHeaders) =>
        _sharedHttpClient.get(requestUrl, headers: resolvedHeaders),
  );
}

Future<raw_http.Response> post(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  Duration? timeout,
}) async {
  return _executeRequestWithRouting(
    originalUrl: url,
    method: 'POST',
    headers: headers,
    timeoutOverride: timeout,
    execute: (requestUrl, resolvedHeaders) => _sharedHttpClient.post(
      requestUrl,
      headers: resolvedHeaders,
      body: body,
      encoding: encoding,
    ),
  );
}

Future<raw_http.Response> patch(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  Duration? timeout,
}) async {
  return _executeRequestWithRouting(
    originalUrl: url,
    method: 'PATCH',
    headers: headers,
    timeoutOverride: timeout,
    execute: (requestUrl, resolvedHeaders) => _sharedHttpClient.patch(
      requestUrl,
      headers: resolvedHeaders,
      body: body,
      encoding: encoding,
    ),
  );
}

Future<raw_http.Response> put(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  Duration? timeout,
}) async {
  return _executeRequestWithRouting(
    originalUrl: url,
    method: 'PUT',
    headers: headers,
    timeoutOverride: timeout,
    execute: (requestUrl, resolvedHeaders) => _sharedHttpClient.put(
      requestUrl,
      headers: resolvedHeaders,
      body: body,
      encoding: encoding,
    ),
  );
}

Future<raw_http.Response> delete(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  Duration? timeout,
}) async {
  return _executeRequestWithRouting(
    originalUrl: url,
    method: 'DELETE',
    headers: headers,
    timeoutOverride: timeout,
    execute: (requestUrl, resolvedHeaders) => _sharedHttpClient.delete(
      requestUrl,
      headers: resolvedHeaders,
      body: body,
      encoding: encoding,
    ),
  );
}

Future<raw_http.Response> head(
  Uri url, {
  Map<String, String>? headers,
  Duration? timeout,
}) async {
  return _executeRequestWithRouting(
    originalUrl: url,
    method: 'HEAD',
    headers: headers,
    timeoutOverride: timeout,
    execute: (requestUrl, resolvedHeaders) =>
        _sharedHttpClient.head(requestUrl, headers: resolvedHeaders),
  );
}
