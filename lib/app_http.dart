import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:blackforest_app/api_server_prefs.dart';
import 'package:http/http.dart' as raw_http;

import 'package:blackforest_app/auth_session_manager.dart';

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

bool _isRetryableStatus(int statusCode) =>
    statusCode == 408 || statusCode == 429 || statusCode >= 500;

const Duration _readRequestTimeout = Duration(seconds: 15);
const Duration _writeRequestTimeout = Duration(seconds: 20);
String? _lastSuccessfulApiHost;
final raw_http.Client _sharedHttpClient = raw_http.Client();

bool _hasBearerToken(Map<String, String>? headers) {
  if (headers == null || headers.isEmpty) return false;
  final auth = headers['Authorization'] ?? headers['authorization'];
  if (auth == null) return false;
  return auth.trim().toLowerCase().startsWith('bearer ');
}

bool _isLoginEndpoint(Uri url) {
  return isKnownApiHost(url.host) && url.path == '/api/users/login';
}

bool _isAppApi(Uri url) {
  return isKnownApiHost(url.host) && url.path.startsWith('/api/');
}

bool _shouldHandleUnauthorized(Uri url, Map<String, String>? headers) {
  if (_isLoginEndpoint(url)) return false;
  if (_hasBearerToken(headers)) return true;
  return _isAppApi(url);
}

Uri _replaceHost(Uri url, String host) => url.replace(host: host);

Future<List<Uri>> _buildAttemptUrls(Uri originalUrl) async {
  if (!isKnownApiHost(originalUrl.host)) {
    return <Uri>[originalUrl];
  }

  final hosts = await getSelectedApiHostsInOrder();
  return hosts.map((host) => _replaceHost(originalUrl, host)).toList();
}

List<Uri> _prioritizeForWriteRequests(
  List<Uri> urls,
  String method,
  String preferredHost,
) {
  if (method == 'GET' || method == 'HEAD') return urls;

  final preferredCandidates = <String>[
    if (_lastSuccessfulApiHost != null) _lastSuccessfulApiHost!,
    preferredHost,
  ];
  for (final host in preferredCandidates) {
    final preferredIndex = urls.indexWhere((url) => url.host == host);
    if (preferredIndex <= 0) continue;

    final reordered = List<Uri>.from(urls);
    final preferredUrl = reordered.removeAt(preferredIndex);
    reordered.insert(0, preferredUrl);
    return reordered;
  }

  return urls;
}

typedef _RequestExecutor = Future<raw_http.Response> Function(Uri url);

bool _isProductEndpoint(Uri url) => url.path == '/api/products';

bool _hasEmptyDocs(raw_http.Response response) {
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return false;
    final docs = decoded['docs'];
    return docs is List && docs.isEmpty;
  } catch (_) {
    return false;
  }
}

bool _shouldRetryOnSemanticResult(
  String method,
  Uri attemptUrl,
  raw_http.Response response,
) {
  if (method != 'GET') return false;
  if (response.statusCode == 404) return true;
  if (_isProductEndpoint(attemptUrl) &&
      response.statusCode == 200 &&
      _hasEmptyDocs(response)) {
    return true;
  }
  return false;
}

Future<raw_http.Response> _sendWithFailover(
  Uri originalUrl,
  _RequestExecutor execute,
  String method,
  Duration? timeoutOverride,
) async {
  final isReadRequest = method == 'GET' || method == 'HEAD';
  final baseUrls = await _buildAttemptUrls(originalUrl);
  final attemptUrls = _prioritizeForWriteRequests(
    baseUrls,
    method,
    originalUrl.host,
  );
  final effectiveAttemptUrls = isReadRequest
      ? attemptUrls
      : attemptUrls.take(1).toList(growable: false);
  final timeoutForMethod =
      timeoutOverride ??
      (isReadRequest ? _readRequestTimeout : _writeRequestTimeout);
  Object? lastError;
  StackTrace? lastStackTrace;
  raw_http.Response? fallbackResponse;

  for (var i = 0; i < effectiveAttemptUrls.length; i++) {
    final attemptUrl = effectiveAttemptUrls[i];
    final canRetry = i < effectiveAttemptUrls.length - 1;
    final isAppApi = _isAppApi(attemptUrl);

    try {
      final response = isAppApi
          ? await execute(attemptUrl).timeout(timeoutForMethod)
          : await execute(attemptUrl);

      if (isAppApi && _isRetryableStatus(response.statusCode) && canRetry) {
        fallbackResponse = response;
        continue;
      }
      if (isAppApi &&
          canRetry &&
          _shouldRetryOnSemanticResult(method, attemptUrl, response)) {
        fallbackResponse = response;
        continue;
      }

      if (isAppApi) {
        _lastSuccessfulApiHost = attemptUrl.host;
      }
      return response;
    } on TimeoutException catch (error, stackTrace) {
      lastError = error;
      lastStackTrace = stackTrace;
      if (!isAppApi || !canRetry) {
        rethrow;
      }
    } on SocketException catch (error, stackTrace) {
      lastError = error;
      lastStackTrace = stackTrace;
      if (!isAppApi || !canRetry) {
        rethrow;
      }
    } on raw_http.ClientException catch (error, stackTrace) {
      lastError = error;
      lastStackTrace = stackTrace;
      if (!isAppApi || !canRetry) {
        rethrow;
      }
    }
  }

  if (fallbackResponse != null) return fallbackResponse;
  if (lastError != null && lastStackTrace != null) {
    Error.throwWithStackTrace(lastError, lastStackTrace);
  }
  throw StateError('Request failed without a response.');
}

Future<raw_http.Response> _interceptResponse(
  Future<raw_http.Response> future, {
  required Uri url,
  Map<String, String>? headers,
}) async {
  final response = await future;
  if (_isUnauthorized(response.statusCode) &&
      _shouldHandleUnauthorized(url, headers)) {
    unawaited(
      AuthSessionManager.instance.handleUnauthorized(
        message: 'Session expired. Please login again.',
      ),
    );
  }
  return response;
}

Future<raw_http.Response> get(Uri url, {Map<String, String>? headers}) {
  return _interceptResponse(
    _sendWithFailover(
      url,
      (attemptUrl) => _sharedHttpClient.get(attemptUrl, headers: headers),
      'GET',
      null,
    ),
    url: url,
    headers: headers,
  );
}

Future<raw_http.Response> post(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  Duration? timeout,
}) {
  return _interceptResponse(
    _sendWithFailover(
      url,
      (attemptUrl) => _sharedHttpClient.post(
        attemptUrl,
        headers: headers,
        body: body,
        encoding: encoding,
      ),
      'POST',
      timeout,
    ),
    url: url,
    headers: headers,
  );
}

Future<raw_http.Response> patch(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  Duration? timeout,
}) {
  return _interceptResponse(
    _sendWithFailover(
      url,
      (attemptUrl) => _sharedHttpClient.patch(
        attemptUrl,
        headers: headers,
        body: body,
        encoding: encoding,
      ),
      'PATCH',
      timeout,
    ),
    url: url,
    headers: headers,
  );
}

Future<raw_http.Response> put(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  Duration? timeout,
}) {
  return _interceptResponse(
    _sendWithFailover(
      url,
      (attemptUrl) => _sharedHttpClient.put(
        attemptUrl,
        headers: headers,
        body: body,
        encoding: encoding,
      ),
      'PUT',
      timeout,
    ),
    url: url,
    headers: headers,
  );
}

Future<raw_http.Response> delete(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  Duration? timeout,
}) {
  return _interceptResponse(
    _sendWithFailover(
      url,
      (attemptUrl) => _sharedHttpClient.delete(
        attemptUrl,
        headers: headers,
        body: body,
        encoding: encoding,
      ),
      'DELETE',
      timeout,
    ),
    url: url,
    headers: headers,
  );
}

Future<raw_http.Response> head(
  Uri url, {
  Map<String, String>? headers,
  Duration? timeout,
}) {
  return _interceptResponse(
    _sendWithFailover(
      url,
      (attemptUrl) => _sharedHttpClient.head(attemptUrl, headers: headers),
      'HEAD',
      timeout,
    ),
    url: url,
    headers: headers,
  );
}
