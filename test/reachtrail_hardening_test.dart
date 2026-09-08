import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reachtrail_app/app.dart';
import 'package:reachtrail_app/models/base_location.dart';
import 'package:reachtrail_app/models/dine_challenge_record.dart';
import 'package:reachtrail_app/models/place.dart';
import 'package:reachtrail_app/services/local_config_service.dart';
import 'package:reachtrail_app/services/persistence_service.dart';
import 'package:reachtrail_app/services/place_search_service.dart';
import 'package:reachtrail_app/services/session_cache_service.dart';
import 'package:reachtrail_app/utils/score_calculator.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _config = LocalConfig(
  placeSearchProvider: 'mock',
  yahooApiKey: '',
  yahooProxyBaseUrl: '',
  apiBaseUrl: '',
  googleWebClientId: '',
  googleMacosClientId: '',
  googleWindowsClientId: '',
);

class _StubConfigService extends LocalConfigService {
  @override
  Future<LocalConfig> load() async => _config;
}

class _ThrowingPersistence extends PersistenceService {
  @override
  Future<List<Place>> loadPlaces() async {
    throw StateError('storage unavailable');
  }
}

BaseLocation _base({String id = 'base-1'}) => BaseLocation(
  id: id,
  name: 'Office',
  lat: 35.6812,
  lng: 139.7671,
  floorLabel: '10F',
  floorNumber: 10,
  entryFloorLabel: '1F',
  entryFloorNumber: 1,
  hasElevator: true,
  elevatorRideCount: 1,
  memo: '',
);

DineChallengeRecord _record({
  String id = 'rec-1',
  String baseLocationId = 'base-1',
}) => DineChallengeRecord(
  id: id,
  baseLocationId: baseLocationId,
  placeId: 'place-1',
  placeSnapshot: const Place(
    id: 'place-1',
    provider: 'manual',
    providerPlaceId: 'manual-1',
    name: 'Curry Stand',
    lat: 35.6820,
    lng: 139.7680,
    address: '東京都千代田区',
  ).toJson(),
  visitedAt: DateTime(2026, 3, 4, 12, 30),
  timeLimitMinutes: 45,
  dineType: DineType.dineIn,
  menu: 'カレー',
  price: 1200,
  paymentMethod: '現金',
  memo: '',
  straightLineDistanceMeters: 120,
  routeDistanceMeters: 150,
  baseVerticalFloors: 9,
  placeVerticalFloors: 0,
  difficultyScore: 42,
  scoreVersion: currentScoreVersion,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('session cache', () {
    test('saves, restores and clears a session', () async {
      final cache = SessionCacheService();
      expect(await cache.load(), isNull);

      await cache.save(
        const CachedSession(
          userId: 'user-1',
          email: 'user@example.com',
          sessionToken: 'token-1',
          displayName: 'User One',
        ),
      );

      final restored = await SessionCacheService().load();
      expect(restored, isNotNull);
      expect(restored!.userId, 'user-1');
      expect(restored.email, 'user@example.com');
      expect(restored.sessionToken, 'token-1');
      expect(restored.displayName, 'User One');

      await cache.clear();
      expect(await SessionCacheService().load(), isNull);
    });

    test('a session without a token is not restored', () async {
      SharedPreferences.setMockInitialValues({
        'auth_session': '{"userId":"user-1","sessionToken":""}',
      });

      expect(await SessionCacheService().load(), isNull);
    });

    test('a corrupt cache entry is ignored instead of throwing', () async {
      SharedPreferences.setMockInitialValues({'auth_session': 'not json'});

      expect(await SessionCacheService().load(), isNull);
    });
  });

  group('bootstrap', () {
    test(
      'a failing persistence surfaces an error instead of hanging',
      () async {
        final controller = ReachTrailController(
          persistence: _ThrowingPersistence(),
          configService: _StubConfigService(),
        );

        await controller.load();

        expect(controller.isBootstrapping, isFalse);
        expect(controller.bootstrapErrorMessage, bootstrapFailureMessage);
      },
    );

    test('a healthy load leaves no bootstrap error', () async {
      final controller = ReachTrailController(
        persistence: PersistenceService(),
        configService: _StubConfigService(),
      );

      await controller.load();

      expect(controller.isBootstrapping, isFalse);
      expect(controller.bootstrapErrorMessage, isNull);
    });

    test(
      'searching without a configured service reports a friendly message',
      () async {
        final controller = ReachTrailController(
          persistence: PersistenceService(),
          configService: _StubConfigService(),
        );

        // `load()` was never called, so no search service exists yet.
        await controller.searchPlaces('curry', nearbyOnly: false);

        expect(controller.errorMessage, searchUnavailableMessage);
        expect(controller.isSearching, isFalse);
      },
    );
  });

  group('cross-account data', () {
    test('a different user id wipes the previous local data', () async {
      final persistence = PersistenceService();
      await persistence.saveBaseLocation(_base());
      await persistence.saveRecords([_record()]);
      await persistence.saveLastUserId('user-1');

      final controller = ReachTrailController(
        persistence: persistence,
        configService: _StubConfigService(),
      );
      await controller.load();
      expect(controller.records, hasLength(1));

      await controller.adoptUser('user-2');

      expect(controller.baseLocation, isNull);
      expect(controller.records, isEmpty);
      expect(await persistence.loadRecords(), isEmpty);
      expect(await persistence.loadLastUserId(), 'user-2');
    });

    test('the same user keeps their data', () async {
      final persistence = PersistenceService();
      await persistence.saveBaseLocation(_base());
      await persistence.saveRecords([_record()]);
      await persistence.saveLastUserId('user-1');

      final controller = ReachTrailController(
        persistence: persistence,
        configService: _StubConfigService(),
      );
      await controller.load();

      await controller.adoptUser('user-1');

      expect(controller.records, hasLength(1));
      expect(controller.baseLocation, isNotNull);
    });

    test('a first sign-in on a fresh device keeps local data', () async {
      final persistence = PersistenceService();
      await persistence.saveRecords([_record()]);

      final controller = ReachTrailController(
        persistence: persistence,
        configService: _StubConfigService(),
      );
      await controller.load();

      await controller.adoptUser('user-1');

      expect(controller.records, hasLength(1));
      expect(await persistence.loadLastUserId(), 'user-1');
    });
  });

  group('yahoo query builder', () {
    test('omits dist when there is no base location', () {
      final params = buildYahooSearchParams(
        query: 'curry',
        baseLocation: null,
        nearbyOnly: true,
      );

      expect(params.containsKey('dist'), isFalse);
      expect(params.containsKey('lat'), isFalse);
      expect(params.containsKey('lon'), isFalse);
      expect(params['query'], 'curry');
    });

    test('sends dist together with the base coordinates', () {
      final params = buildYahooSearchParams(
        query: 'curry',
        baseLocation: _base(),
        nearbyOnly: true,
      );

      expect(params['dist'], '$walkingSearchRadiusKm');
      expect(params['lat'], '35.6812');
      expect(params['lon'], '139.7671');
      expect(params['sort'], 'geo');
    });

    test('omits dist when the nearby filter is off', () {
      final params = buildYahooSearchParams(
        query: 'curry',
        baseLocation: _base(),
        nearbyOnly: false,
      );

      expect(params.containsKey('dist'), isFalse);
      expect(params['lat'], '35.6812');
    });
  });

  group('place snapshots', () {
    test('a snapshot without coordinates is rejected', () {
      expect(
        () => Place.fromJson(const {'id': 'p', 'name': 'No coords'}),
        throwsFormatException,
      );
      expect(Place.tryFromJson(const {'id': 'p', 'name': 'No coords'}), isNull);
    });

    test('display falls back to a labelled placeholder', () {
      final place = placeFromSnapshot(const {'id': 'p', 'name': 'Old Record'});

      expect(place.name, 'Old Record');
      expect(place.lat, 0);
    });
  });

  group('record card header', () {
    testWidgets('does not overflow at a 2.0 text scale', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: RecordCardHeader(
                  placeName: 'とても長い名前のカレーとスパイスのお店 新宿西口店',
                  visitedAt: DateTime(2026, 3, 4),
                  onEdit: () async {},
                  onDelete: () async {},
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('2026/03/04'), findsOneWidget);
    });

    test('formats the date with zero padding', () {
      expect(
        RecordCardHeader.formatVisitedDate(DateTime(2026, 3, 4)),
        '2026/03/04',
      );
      expect(
        RecordCardHeader.formatVisitedDate(DateTime(2026, 12, 25)),
        '2026/12/25',
      );
    });
  });
}
