import 'dart:async';

import 'package:geolocator/geolocator.dart';

enum LocationFailure { serviceDisabled, denied, deniedForever, timeout, unknown }

/// One-shot position lookup result. Either coordinates or a failure, never both.
class LocationResult {
  const LocationResult.success({
    required double this.lat,
    required double this.lng,
  }) : failure = null;

  const LocationResult.failed(LocationFailure this.failure)
    : lat = null,
      lng = null;

  final double? lat;
  final double? lng;
  final LocationFailure? failure;

  bool get isSuccess => failure == null;
}

String describeLocationFailure(LocationFailure failure) {
  switch (failure) {
    case LocationFailure.serviceDisabled:
      return '端末の位置情報がオフです。設定でオンにするか、地図をタップして指定してください。';
    case LocationFailure.denied:
    case LocationFailure.deniedForever:
      return '位置情報の利用が許可されていません。端末の設定で ReachTrail に位置情報を許可すると使えます。';
    case LocationFailure.timeout:
    case LocationFailure.unknown:
      return '現在地を取得できませんでした。しばらくしてからもう一度お試しください。';
  }
}

abstract class LocationService {
  /// Asks for permission only when called, never at startup.
  Future<LocationResult> getCurrentPosition({
    Duration timeout = const Duration(seconds: 15),
  });

  /// Opens the OS settings page for this app (used after `deniedForever`).
  Future<void> openAppSettings();
}

class GeolocatorLocationService implements LocationService {
  @override
  Future<LocationResult> getCurrentPosition({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const LocationResult.failed(LocationFailure.serviceDisabled);
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      switch (permission) {
        case LocationPermission.denied:
          return const LocationResult.failed(LocationFailure.denied);
        case LocationPermission.deniedForever:
          return const LocationResult.failed(LocationFailure.deniedForever);
        case LocationPermission.unableToDetermine:
          return const LocationResult.failed(LocationFailure.unknown);
        case LocationPermission.whileInUse:
        case LocationPermission.always:
          break;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: timeout,
        ),
      );
      return LocationResult.success(
        lat: position.latitude,
        lng: position.longitude,
      );
    } on TimeoutException {
      return const LocationResult.failed(LocationFailure.timeout);
    } catch (_) {
      return const LocationResult.failed(LocationFailure.unknown);
    }
  }

  @override
  Future<void> openAppSettings() => Geolocator.openAppSettings();
}

/// Test double. Lives here so widget tests in other files can share it.
class StubLocationService implements LocationService {
  StubLocationService(this.result);

  LocationResult result;
  int callCount = 0;
  int settingsOpened = 0;

  @override
  Future<LocationResult> getCurrentPosition({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    callCount += 1;
    return result;
  }

  @override
  Future<void> openAppSettings() async {
    settingsOpened += 1;
  }
}
