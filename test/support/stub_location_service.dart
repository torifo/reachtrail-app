import 'package:reachtrail_app/services/location_service.dart';

/// Test double for [LocationService], shared by the widget and unit tests.
///
/// It lives under `test/` so no production code can depend on it.
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
