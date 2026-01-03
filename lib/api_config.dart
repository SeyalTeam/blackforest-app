class ApiConfig {
  static const String baseUrl = 'https://blackforest.vseyal.com/api';
  static const String apiKey = 'bf_billing_1Yz3Mn6Lq9Ra4Ao2Zx8k'; // TODO: Replace with your actual API key

  static Map<String, String> getHeaders([String? token]) {
    final headers = {
      'Content-Type': 'application/json',
      'x-api-key': apiKey,
    };
    if (token != null) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }
}
