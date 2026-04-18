import 'package:flutter_test/flutter_test.dart';
import 'package:reachtrail_app/models/lunch_challenge_record.dart';
import 'package:reachtrail_app/utils/distance_calculator.dart';
import 'package:reachtrail_app/utils/floor_parser.dart';
import 'package:reachtrail_app/utils/score_calculator.dart';

void main() {
  test('floor parser supports upper floors and basement labels', () {
    expect(parseFloorNumber('32F'), 32);
    expect(parseFloorNumber('B1'), -1);
    expect(parseFloorNumber(' 7 '), 7);
  });

  test('distance calculator returns positive value', () {
    final distance = calculateDistanceMeters(
      startLat: 35.6895,
      startLng: 139.6917,
      endLat: 35.6905,
      endLng: 139.7000,
    );

    expect(distance, greaterThan(700));
    expect(distance, lessThan(800));
  });

  test('difficulty score reflects floor and dine type', () {
    final dineIn = calculateDifficultyScore(
      horizontalDistanceMeters: 500,
      floorNumber: 10,
      dineType: DineType.dineIn,
    );
    final takeout = calculateDifficultyScore(
      horizontalDistanceMeters: 500,
      floorNumber: 10,
      dineType: DineType.takeout,
    );

    expect(dineIn, greaterThan(takeout));
    expect(dineIn, 900);
  });
}
