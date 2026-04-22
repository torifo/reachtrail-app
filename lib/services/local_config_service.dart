import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

class LocalConfig {
  const LocalConfig({
    required this.placeSearchProvider,
    required this.yahooApiKey,
    required this.yahooProxyBaseUrl,
    required this.apiBaseUrl,
    required this.googleWebClientId,
    required this.googleMacosClientId,
  });

  final String placeSearchProvider;
  final String yahooApiKey;
  final String yahooProxyBaseUrl;
  final String apiBaseUrl;
  final String googleWebClientId;
  final String googleMacosClientId;
}

class LocalConfigService {
  static const _envAsset = 'assets/config/.env';
  static const _varsAsset = 'assets/config/.vars';

  Future<LocalConfig> load() async {
    final entries = <String, String>{};

    if (!kIsWeb) {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final assets = manifest.listAssets();
      for (final asset in [_envAsset, _varsAsset]) {
        if (!assets.contains(asset)) {
          continue;
        }
        final content = await rootBundle.loadString(asset);
        entries.addAll(_parse(content));
      }
    }

    return LocalConfig(
      placeSearchProvider:
          entries['PLACE_SEARCH_PROVIDER'] ??
          const String.fromEnvironment(
            'PLACE_SEARCH_PROVIDER',
            defaultValue: 'mock',
          ),
      yahooApiKey:
          entries['YAHOO_API_KEY'] ??
          entries['YAHOO_CLIENT_ID'] ??
          const String.fromEnvironment('YAHOO_API_KEY', defaultValue: ''),
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
                '823224608668-a9tomojqjsh6tsi39igs6i3kniah43oi.apps.googleusercontent.com',
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
