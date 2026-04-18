import 'package:flutter_test/flutter_test.dart';
import 'package:reachtrail_app/models/lunch_challenge_record.dart';
import 'package:reachtrail_app/models/base_location.dart';
import 'package:reachtrail_app/models/place.dart';
import 'package:reachtrail_app/services/place_search_service.dart';
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

  test('deduplicate keeps richer Yahoo candidate', () {
    final sparse = Place(
      id: '1',
      provider: 'yahoo',
      providerPlaceId: 'gid-1',
      name: 'Sample Cafe',
      lat: 35.0,
      lng: 139.0,
      address: '東京都新宿区1-1-1',
    );
    final rich = Place(
      id: '2',
      provider: 'yahoo',
      providerPlaceId: 'gid-2',
      name: 'Sample Cafe',
      lat: 35.0002,
      lng: 139.0002,
      address: '東京都新宿区1-1-1',
      buildingName: 'Sample Building',
      floorLabel: '8F',
      floorNumber: 8,
      category: 'Cafe',
    );

    final deduplicated = deduplicatePlaces([sparse, rich]);

    expect(deduplicated, hasLength(1));
    expect(deduplicated.first.buildingName, 'Sample Building');
    expect(deduplicated.first.floorLabel, '8F');
  });

  test('ranking prefers closer place before richer but farther place', () {
    const base = BaseLocation(
      id: 'base',
      name: 'Office',
      lat: 35.6895,
      lng: 139.6917,
    );
    final close = Place(
      id: 'close',
      provider: 'yahoo',
      providerPlaceId: 'close',
      name: 'Near Shop',
      lat: 35.6897,
      lng: 139.6917,
      address: '東京都新宿区近場1-1-1',
    );
    final farRich = Place(
      id: 'far',
      provider: 'yahoo',
      providerPlaceId: 'far',
      name: 'Far Rich Shop',
      lat: 35.7000,
      lng: 139.7000,
      address: '東京都新宿区遠方1-1-1',
      buildingName: 'Tower',
      floorLabel: '20F',
      floorNumber: 20,
    );

    final ranked = rankPlaces(
      places: [farRich, close],
      baseLocation: base,
      deduplicate: false,
    );

    expect(ranked.first.id, 'close');
  });

  test('ranking prefers richer metadata when distance is effectively tied', () {
    const base = BaseLocation(
      id: 'base',
      name: 'Office',
      lat: 35.6895,
      lng: 139.6917,
    );
    final plain = Place(
      id: 'plain',
      provider: 'yahoo',
      providerPlaceId: 'plain',
      name: 'Same Spot A',
      lat: 35.6899,
      lng: 139.6919,
      address: '東京都新宿区同距離1-1-1',
    );
    final rich = Place(
      id: 'rich',
      provider: 'yahoo',
      providerPlaceId: 'rich',
      name: 'Same Spot B',
      lat: 35.68991,
      lng: 139.69191,
      address: '東京都新宿区同距離1-1-2',
      buildingName: 'Highrise',
      floorLabel: '12F',
      floorNumber: 12,
    );

    final ranked = rankPlaces(
      places: [plain, rich],
      baseLocation: base,
      deduplicate: false,
    );

    expect(ranked.first.id, 'rich');
  });
}
