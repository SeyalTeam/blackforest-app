import 'dart:async';
import 'dart:convert';

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

const Duration _readRequestTimeout = Duration(seconds: 15);
const Duration _writeRequestTimeout = Duration(seconds: 20);
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

typedef _RequestExecutor = Future<raw_http.Response> Function(Uri url);

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
    _sendRequest(
      url,
      (requestUrl) => _sharedHttpClient.get(requestUrl, headers: headers),
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
    _sendRequest(
      url,
      (requestUrl) => _sharedHttpClient.post(
        requestUrl,
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
    _sendRequest(
      url,
      (requestUrl) => _sharedHttpClient.patch(
        requestUrl,
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
    _sendRequest(
      url,
      (requestUrl) => _sharedHttpClient.put(
        requestUrl,
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
    _sendRequest(
      url,
      (requestUrl) => _sharedHttpClient.delete(
        requestUrl,
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
    _sendRequest(
      url,
      (requestUrl) => _sharedHttpClient.head(requestUrl, headers: headers),
      'HEAD',
      timeout,
    ),
    url: url,
    headers: headers,
  );
}
