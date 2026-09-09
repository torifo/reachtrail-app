import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reachtrail_app/services/map_handoff.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  test('android uses a geo: uri that triggers the OS chooser', () {
    final uri = buildMapHandoffUri(
      lat: 35.6812,
      lng: 139.7671,
      label: '東京 駅前店',
      platform: TargetPlatform.android,
    );
    expect(uri.scheme, 'geo');
    expect(
      uri.toString(),
      'geo:0,0?q=35.6812,139.7671(%E6%9D%B1%E4%BA%AC%20%E9%A7%85%E5%89%8D%E5%BA%97)',
    );
  });

  test('ios uses Apple Maps directions', () {
    final uri = buildMapHandoffUri(
      lat: -33.8688,
      lng: 151.2093,
      label: 'Cafe',
      platform: TargetPlatform.iOS,
    );
    expect(uri.host, 'maps.apple.com');
    expect(uri.queryParameters['daddr'], '-33.8688,151.2093');
    expect(uri.queryParameters['q'], 'Cafe');
  });

  test('other platforms fall back to Google Maps directions on the web', () {
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.fuchsia,
    ]) {
      final uri = buildMapHandoffUri(
        lat: 1,
        lng: 2,
        label: '',
        platform: platform,
      );
      expect(uri.host, 'www.google.com');
      expect(uri.path, '/maps/dir/');
      expect(uri.queryParameters['destination'], '1.0,2.0');
    }
  });

  test('parentheses in a label are escaped so the geo query stays flat', () {
    final uri = buildMapHandoffUri(
      lat: 35.6812,
      lng: 139.7671,
      label: 'Gyoza (Shibuya)',
      platform: TargetPlatform.android,
    );
    expect(uri.toString(), 'geo:0,0?q=35.6812,139.7671(Gyoza%20%28Shibuya%29)');
  });

  test('openInMapsApp reports false when the launcher fails', () async {
    final opened = await openInMapsApp(
      lat: 1,
      lng: 2,
      label: 'Cafe',
      platform: TargetPlatform.android,
      launcher: (uri, {mode = LaunchMode.platformDefault}) async => false,
    );
    expect(opened, isFalse);
  });

  test('openInMapsApp reports false when the launcher throws', () async {
    final opened = await openInMapsApp(
      lat: 1,
      lng: 2,
      label: 'Cafe',
      platform: TargetPlatform.android,
      launcher: (uri, {mode = LaunchMode.platformDefault}) async =>
          throw PlatformException(code: 'no-activity'),
    );
    expect(opened, isFalse);
  });

  test('an empty label still yields a valid android uri', () {
    final uri = buildMapHandoffUri(
      lat: 1,
      lng: 2,
      label: '   ',
      platform: TargetPlatform.android,
    );
    expect(uri.toString(), 'geo:0,0?q=1.0,2.0');
  });
}
