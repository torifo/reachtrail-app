import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reachtrail_app/models/dine_challenge_record.dart';
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
      routeDistanceMeters: 500,
      baseVerticalFloors: 3,
      placeVerticalFloors: 7,
      baseHasElevator: false,
      placeHasElevator: false,
      dineType: DineType.dineIn,
    );
    final takeout = calculateDifficultyScore(
      routeDistanceMeters: 500,
      baseVerticalFloors: 3,
      placeVerticalFloors: 7,
      baseHasElevator: false,
      placeHasElevator: false,
      dineType: DineType.takeout,
    );

    expect(dineIn, greaterThan(takeout));
    expect(dineIn, 900);
  });

  test('vertical floor travel uses entry floor as boundary', () {
    expect(
      calculateVerticalFloorTravel(
        startFloorNumber: 26,
        entryFloorNumber: 2,
        destinationFloorNumber: null,
      ),
      24,
    );
    expect(
      calculateVerticalFloorTravel(
        startFloorNumber: null,
        entryFloorNumber: 1,
        destinationFloorNumber: 32,
      ),
      31,
    );
  });

  test('record copyWith can update score fields', () {
    final record = DineChallengeRecord(
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
      straightLineDistanceMeters: 480,
      routeDistanceMeters: 500,
      baseVerticalFloors: 24,
      placeVerticalFloors: 31,
      difficultyScore: 900,
      scoreVersion: 2,
    );

    final updated = record.copyWith(
      routeDistanceMeters: 650,
      difficultyScore: 1050,
      scoreVersion: 2,
    );

    expect(updated.routeDistanceMeters, 650);
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

  test('deduplicate prefers floor metadata for nearby duplicate store', () {
    final plain = Place(
      id: '1',
      provider: 'yahoo',
      providerPlaceId: 'gid-1',
      name: 'Sample Cafe',
      lat: 35.0,
      lng: 139.0,
      address: '東京都新宿区1-1-1 Sample Building',
      buildingName: 'Sample Building',
      category: 'Cafe',
    );
    final withFloor = Place(
      id: '2',
      provider: 'yahoo',
      providerPlaceId: 'gid-2',
      name: 'Sample Cafe',
      lat: 35.00005,
      lng: 139.00005,
      address: '東京都新宿区1-1-1 Sample Building 8F',
      buildingName: 'Sample Building',
      floorLabel: '8F',
      floorNumber: 8,
    );

    final deduplicated = deduplicatePlaces([plain, withFloor]);

    expect(deduplicated, hasLength(1));
    expect(deduplicated.first.id, '2');
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
      purpose: SearchPurpose.dinePlace,
      query: 'shop',
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
      purpose: SearchPurpose.dinePlace,
      query: 'same',
    );

    expect(ranked.first.id, 'rich');
  });

  test('base location candidates collapse tenants into one building', () {
    final places = [
      Place(
        id: '1',
        provider: 'yahoo',
        providerPlaceId: 'a',
        name: 'タリーズコーヒー 新宿オークタワー店',
        lat: 35.6937,
        lng: 139.6907,
        address: '東京都新宿区西新宿6-8-1',
        buildingName: '住友不動産新宿オークタワー',
      ),
      Place(
        id: '2',
        provider: 'yahoo',
        providerPlaceId: 'b',
        name: '割烹 田一',
        lat: 35.6938,
        lng: 139.6907,
        address: '東京都新宿区西新宿6-8-1',
        buildingName: '住友不動産新宿オークタワー',
      ),
    ];

    final collapsed = collapseBaseLocationCandidates(places);

    expect(collapsed, hasLength(1));
    expect(collapsed.first.name, '住友不動産新宿オークタワー');
    expect(collapsed.first.buildingName, '住友不動産新宿オークタワー');
    expect(collapsed.first.category, 'BaseLocation');
  });

  test(
    'yahoo search retries without distance limit when nearby search is empty',
    () async {
      const base = BaseLocation(
        id: 'base',
        name: 'Office',
        lat: 35.6895,
        lng: 139.6917,
      );
      final requestedUris = <Uri>[];
      final client = MockClient((request) async {
        requestedUris.add(request.url);

        final isNearbySearch = request.url.queryParameters.containsKey('dist');
        final body = isNearbySearch
            ? '{"Feature":[]}'
            : '''
{
  "Feature": [
    {
      "Name": "マロリーポークステーキ 新宿店",
      "Geometry": {"Coordinates": "139.7000,35.6900"},
      "Property": {
        "Address": "東京都新宿区西新宿1-1-1",
        "Genre": [{"Name": "ステーキ"}]
      },
      "Gid": "mallory-shinjuku"
    }
  ]
}
''';

        return http.Response(
          body,
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final results = await YahooLocalSearchService(
        'dummy',
        proxyBaseUrl: 'https://example.com/yahoo/localSearch',
        client: client,
      ).search(query: 'マロリーポークステーキ', baseLocation: base, nearbyOnly: true);

      expect(requestedUris, hasLength(2));
      expect(requestedUris.first.queryParameters['dist'], isNotNull);
      expect(requestedUris.last.queryParameters['dist'], isNull);
      expect(results, hasLength(1));
      expect(results.first.name, 'マロリーポークステーキ 新宿店');
    },
  );

  test(
    'composite yahoo search returns empty instead of mock fallback',
    () async {
      final client = MockClient(
        (_) async => http.Response(
          '{"Feature":[]}',
          200,
          headers: {'content-type': 'application/json'},
        ),
      );

      final results = await YahooLocalSearchService(
        'dummy',
        proxyBaseUrl: 'https://example.com/yahoo/localSearch',
        client: client,
      ).search(query: '存在しない店', baseLocation: null, nearbyOnly: false);

      expect(results, isEmpty);
    },
  );

  test('yahoo search treats an unexpected 200 body as zero results', () async {
    final client = MockClient(
      (_) async => http.Response(
        '<html>maintenance</html>',
        200,
        headers: {'content-type': 'text/html'},
      ),
    );

    final results = await YahooLocalSearchService(
      'dummy',
      proxyBaseUrl: 'https://example.com/yahoo/localSearch',
      client: client,
    ).search(query: 'カフェ', baseLocation: null, nearbyOnly: false);

    expect(results, isEmpty);
  });

  test(
    'yahoo search treats a JSON body without Feature as zero results',
    () async {
      final client = MockClient(
        (_) async => http.Response(
          '{"ResultInfo":{"Count":0}}',
          200,
          headers: {'content-type': 'application/json'},
        ),
      );

      final results = await YahooLocalSearchService(
        'dummy',
        proxyBaseUrl: 'https://example.com/yahoo/localSearch',
        client: client,
      ).search(query: 'カフェ', baseLocation: null, nearbyOnly: false);

      expect(results, isEmpty);
    },
  );

  test('search failures map to short Japanese messages', () {
    expect(
      describeSearchFailure(TimeoutException('timeout')),
      '通信に失敗しました。電波状況を確認して再試行してください。',
    );
    expect(
      describeSearchFailure(http.ClientException('connection reset')),
      '通信に失敗しました。電波状況を確認して再試行してください。',
    );
    expect(
      describeSearchFailure(
        const PlaceSearchConfigurationException('ログインの有効期限が切れました。'),
      ),
      'ログインの有効期限が切れました。',
    );
    expect(
      describeSearchFailure(StateError('boom')),
      '検索に失敗しました。しばらく待ってから再試行してください。',
    );
    expect(describeSearchFailure(StateError('boom')), isNot(contains('boom')));
  });

  test('yahoo proxy 401 and 429 surface typed Japanese messages', () async {
    Future<void> expectMessage(int status, Matcher matcher) async {
      final client = MockClient((_) async => http.Response('{}', status));
      await expectLater(
        YahooLocalSearchService(
          'dummy',
          proxyBaseUrl: 'https://example.com/yahoo/localSearch',
          client: client,
        ).search(query: 'カフェ', baseLocation: null, nearbyOnly: false),
        throwsA(
          isA<PlaceSearchConfigurationException>().having(
            (error) => error.message,
            'message',
            matcher,
          ),
        ),
      );
    }

    await expectMessage(401, contains('サインイン'));
    await expectMessage(429, contains('しばらく'));
  });

  test('base location with missing or non-numeric coordinates is rejected', () {
    expect(
      () => BaseLocation.fromJson(const {'id': 'a', 'name': 'Office'}),
      throwsFormatException,
    );
    expect(
      () => BaseLocation.fromJson(const {
        'id': 'a',
        'name': 'Office',
        'lat': 'not-a-number',
        'lng': 139.7,
      }),
      throwsFormatException,
    );
    final valid = BaseLocation.fromJson(const {
      'id': 'a',
      'name': 'Office',
      'lat': '35.68',
      'lng': 139.76,
    });
    expect(valid.lat, closeTo(35.68, 1e-9));
    expect(valid.lng, closeTo(139.76, 1e-9));
  });

  test('record with an unparseable visitedAt is rejected', () {
    expect(
      () => DineChallengeRecord.fromJson(const {
        'id': 'r1',
        'visitedAt': 'yesterday',
      }),
      throwsFormatException,
    );
    expect(
      () => DineChallengeRecord.fromJson(const {'id': 'r1'}),
      throwsFormatException,
    );
    final valid = DineChallengeRecord.fromJson(const {
      'id': 'r1',
      'visitedAt': '2026-01-02T03:04:05Z',
    });
    expect(valid.visitedAt.toUtc().year, 2026);
  });
}
