import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;
import 'package:flutter/services.dart';

class LocalConfig {
  const LocalConfig({
    required this.placeSearchProvider,
    required this.yahooApiKey,
    required this.yahooProxyBaseUrl,
    required this.apiBaseUrl,
    required this.googleWebClientId,
    required this.googleMacosClientId,
    required this.googleWindowsClientId,
  });

  final String placeSearchProvider;
  final String yahooApiKey;
  final String yahooProxyBaseUrl;
  final String apiBaseUrl;
  final String googleWebClientId;
  final String googleMacosClientId;
  final String googleWindowsClientId;
}

/// Thrown when a release build is missing its bundled configuration asset.
class LocalConfigException implements Exception {
  const LocalConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LocalConfigService {
  /// The only config asset bundled into the app.
  ///
  /// It must never contain a secret: everything in it ships inside the release
  /// artifact. `assets/config/.env` is intentionally NOT bundled (it is absent
  /// from the pubspec asset list), so the Yahoo! Local Search key can only
  /// reach the app through `--dart-define` in a local debug build.
  static const _varsAsset = 'assets/config/.vars';

  Future<LocalConfig> load() async {
    final entries = <String, String>{};

    if (!kIsWeb) {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      if (manifest.listAssets().contains(_varsAsset)) {
        final content = await rootBundle.loadString(_varsAsset);
        entries.addAll(_parse(content));
      } else if (!kDebugMode) {
        // A release build without the config asset would silently fall back to
        // the mock provider and a localhost API, which looks like a broken app
        // with no clue as to why. Fail loudly instead; the caller turns this
        // into a visible startup error.
        debugPrint(
          'ReachTrail: $_varsAsset is missing from the release bundle. '
          'Run the config generation step before building.',
        );
        throw const LocalConfigException(
          'アプリの設定ファイルが見つかりません。アプリを再インストールしてください。',
        );
      }
    }

    return LocalConfig(
      placeSearchProvider:
          entries['PLACE_SEARCH_PROVIDER'] ??
          const String.fromEnvironment(
            'PLACE_SEARCH_PROVIDER',
            defaultValue: 'mock',
          ),
      // Never sourced from a bundled asset: a client-side Yahoo key would ship
      // inside the release artifact. Debug builds may supply one via
      // `--dart-define=YAHOO_API_KEY=...`; release builds must use the proxy.
      yahooApiKey: kDebugMode
          ? const String.fromEnvironment('YAHOO_API_KEY', defaultValue: '')
          : '',
      yahooProxyBaseUrl:
          entries['YAHOO_PROXY_BASE_URL'] ??
          const String.fromEnvironment(
            'YAHOO_PROXY_BASE_URL',
            defaultValue: '',
          ),
      apiBaseUrl:
          entries['API_BASE_URL'] ??
          const String.fromEnvironment(
            'API_BASE_URL',
            defaultValue: 'http://localhost:8080',
          ),
      googleWebClientId:
          entries['GOOGLE_WEB_CLIENT_ID'] ??
          const String.fromEnvironment(
            'GOOGLE_WEB_CLIENT_ID',
            defaultValue:
                '823224608668-trbi6qgpsmsn2o8qika1bbf8o30ihqpd.apps.googleusercontent.com',
          ),
      googleMacosClientId:
          entries['GOOGLE_MACOS_CLIENT_ID'] ??
          const String.fromEnvironment(
            'GOOGLE_MACOS_CLIENT_ID',
            defaultValue:
                '823224608668-9blagvtvvuoa728q195ma5jlpeq1308a.apps.googleusercontent.com',
          ),
      googleWindowsClientId:
          entries['GOOGLE_WINDOWS_CLIENT_ID'] ??
          const String.fromEnvironment(
            'GOOGLE_WINDOWS_CLIENT_ID',
            defaultValue:
                '823224608668-62u7gnk85dab38e15s2ota4i6518enu0.apps.googleusercontent.com',
          ),
    );
  }

  Map<String, String> _parse(String input) {
    final result = <String, String>{};
    for (final raw in input.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      final separator = line.indexOf('=');
      if (separator <= 0) {
        continue;
      }
      result[line.substring(0, separator).trim()] = line
          .substring(separator + 1)
          .trim();
    }
    return result;
  }
}
