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

  test('record copyWith can update score fields', () {
    final record = LunchChallengeRecord(
      id: '1',
      baseLocationId: 'base',
      placeId: 'place',
      placeSnapshot: const {
        'id': 'place',
        'provider': 'manual',
        'providerPlaceId': 'manual-1',
        'name': 'Sample',
        'lat': 35.0,
        'lng': 139.0,
        'address': '',
        'buildingName': '',
        'floorLabel': '10F',
        'floorNumber': 10,
        'category': '',
        'rawPayload': '',
      },
      visitedAt: DateTime(2026, 4, 18),
      timeLimitMinutes: 60,
      dineType: DineType.dineIn,
      menu: 'Lunch',
      price: 1000,
      paymentMethod: 'Card',
      memo: '',
      horizontalDistanceMeters: 500,
      difficultyScore: 900,
      scoreVersion: 1,
    );

    final updated = record.copyWith(
      horizontalDistanceMeters: 650,
      difficultyScore: 1050,
      scoreVersion: 2,
    );

    expect(updated.horizontalDistanceMeters, 650);
    expect(updated.difficultyScore, 1050);
    expect(updated.scoreVersion, 2);
    expect(updated.menu, 'Lunch');
  });
}
