import 'package:package_info_plus/package_info_plus.dart';

/// Caches the app version string so every HTTP request can read it
/// without async overhead.
///
/// Call [AppVersion.init()] once at app startup (before runApp).
/// After that, [AppVersion.current] is always available synchronously.
class AppVersion {
  AppVersion._();

  static String _version = '';

  /// The app's version string, e.g. "2.0.0".
  /// Returns an empty string until [init] has been called.
  static String get current => _version;

  /// Reads the version from the package manifest and caches it.
  /// Safe to call multiple times — only fetches once.
  static Future<void> init() async {
    if (_version.isNotEmpty) return;
    try {
      final info = await PackageInfo.fromPlatform();
      _version = info.version.trim();
    } catch (_) {
      // Keep empty — the server will allow requests with no version header.
    }
  }
}
