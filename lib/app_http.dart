import 'dart:async';
import 'dart:convert';

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

bool _hasBearerToken(Map<String, String>? headers) {
  if (headers == null || headers.isEmpty) return false;
  final auth = headers['Authorization'] ?? headers['authorization'];
  if (auth == null) return false;
  return auth.trim().toLowerCase().startsWith('bearer ');
}

bool _isLoginEndpoint(Uri url) {
  return url.host == 'blackforest.vseyal.com' && url.path == '/api/users/login';
}

bool _isAppApi(Uri url) {
  return url.host == 'blackforest.vseyal.com' && url.path.startsWith('/api/');
}

bool _shouldHandleUnauthorized(Uri url, Map<String, String>? headers) {
  if (_isLoginEndpoint(url)) return false;
  if (_hasBearerToken(headers)) return true;
  return _isAppApi(url);
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
    raw_http.get(url, headers: headers),
    url: url,
    headers: headers,
  );
}

Future<raw_http.Response> post(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
}) {
  return _interceptResponse(
    raw_http.post(url, headers: headers, body: body, encoding: encoding),
    url: url,
    headers: headers,
  );
}

Future<raw_http.Response> patch(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
}) {
  return _interceptResponse(
    raw_http.patch(url, headers: headers, body: body, encoding: encoding),
    url: url,
    headers: headers,
  );
}

Future<raw_http.Response> put(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
}) {
  return _interceptResponse(
    raw_http.put(url, headers: headers, body: body, encoding: encoding),
    url: url,
    headers: headers,
  );
}

Future<raw_http.Response> delete(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
}) {
  return _interceptResponse(
    raw_http.delete(url, headers: headers, body: body, encoding: encoding),
    url: url,
    headers: headers,
  );
}

Future<raw_http.Response> head(Uri url, {Map<String, String>? headers}) {
  return _interceptResponse(
    raw_http.head(url, headers: headers),
    url: url,
    headers: headers,
  );
}
