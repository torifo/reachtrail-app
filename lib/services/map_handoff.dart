import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Builds the URL that hands a destination to the device's maps app.
///
/// Android: `geo:` lets the OS show its own chooser (Google Maps, Yahoo, ...).
/// iOS: Apple Maps universal link, no `LSApplicationQueriesSchemes` needed.
/// Everything else: Google Maps directions in the browser.
Uri buildMapHandoffUri({
  required double lat,
  required double lng,
  required String label,
  required TargetPlatform platform,
}) {
  final point = '$lat,$lng';
  final trimmed = label.trim();
  switch (platform) {
    case TargetPlatform.android:
      final query = trimmed.isEmpty
          ? point
          : '$point(${Uri.encodeComponent(trimmed)})';
      return Uri.parse('geo:0,0?q=$query');
    case TargetPlatform.iOS:
      return Uri.https('maps.apple.com', '/', {
        'daddr': point,
        if (trimmed.isNotEmpty) 'q': trimmed,
      });
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return Uri.https('www.google.com', '/maps/dir/', {
        'api': '1',
        'destination': point,
      });
  }
}

/// Returns false when no app could take the URL, so the caller can show a
/// SnackBar instead of failing silently.
Future<bool> openInMapsApp({
  required double lat,
  required double lng,
  required String label,
  TargetPlatform? platform,
}) async {
  final uri = buildMapHandoffUri(
    lat: lat,
    lng: lng,
    label: label,
    // On the web `defaultTargetPlatform` reports the host OS, which would pick
    // a native scheme the browser cannot open; force the Google Maps URL.
    platform:
        platform ?? (kIsWeb ? TargetPlatform.linux : defaultTargetPlatform),
  );
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
