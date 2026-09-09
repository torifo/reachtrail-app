import 'package:flutter_test/flutter_test.dart';
import 'package:reachtrail_app/services/location_service.dart';

import 'support/stub_location_service.dart';

void main() {
  test('a successful result carries coordinates and no failure', () {
    const result = LocationResult.success(lat: 35.68, lng: 139.76);
    expect(result.isSuccess, isTrue);
    expect(result.lat, 35.68);
    expect(result.lng, 139.76);
    expect(result.failure, isNull);
  });

  test('a failed result has no coordinates', () {
    const result = LocationResult.failed(LocationFailure.denied);
    expect(result.isSuccess, isFalse);
    expect(result.lat, isNull);
    expect(result.failure, LocationFailure.denied);
  });

  test('every failure has a Japanese explanation', () {
    for (final failure in LocationFailure.values) {
      expect(describeLocationFailure(failure), isNotEmpty);
    }
    expect(
      describeLocationFailure(LocationFailure.serviceDisabled),
      contains('位置情報がオフ'),
    );
    expect(
      describeLocationFailure(LocationFailure.deniedForever),
      contains('設定'),
    );
    expect(describeLocationFailure(LocationFailure.timeout), contains('もう一度'));
  });

  test('the stub service returns what it was given', () async {
    final service = StubLocationService(
      const LocationResult.success(lat: 1, lng: 2),
    );
    final result = await service.getCurrentPosition();
    expect(result.lat, 1);
    expect(service.callCount, 1);
  });
}
