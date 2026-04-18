import 'package:flutter/services.dart';

class LocalConfig {
  const LocalConfig({
    required this.placeSearchProvider,
    required this.yahooApiKey,
  });

  final String placeSearchProvider;
  final String yahooApiKey;
}

class LocalConfigService {
  static const _envAsset = 'assets/config/.env';
  static const _varsAsset = 'assets/config/.vars';

  Future<LocalConfig> load() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest.listAssets();
    final entries = <String, String>{};

    for (final asset in [_envAsset, _varsAsset]) {
      if (!assets.contains(asset)) {
        continue;
      }
      final content = await rootBundle.loadString(asset);
      entries.addAll(_parse(content));
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
