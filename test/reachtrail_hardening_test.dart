import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reachtrail_app/app.dart';
import 'package:reachtrail_app/models/base_location.dart';
import 'package:reachtrail_app/models/dine_challenge_record.dart';
import 'package:reachtrail_app/models/place.dart';
import 'package:reachtrail_app/services/local_config_service.dart';
import 'package:reachtrail_app/services/location_service.dart';
import 'package:reachtrail_app/services/persistence_service.dart';
import 'package:reachtrail_app/services/place_search_service.dart';
import 'package:reachtrail_app/services/session_cache_service.dart';
import 'package:reachtrail_app/utils/score_calculator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/stub_location_service.dart';

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

/// Returns the records it read *before* yielding, so a wipe that lands
/// mid-load would otherwise be overwritten by stale data.
class _SlowPersistence extends PersistenceService {
  @override
  Future<List<DineChallengeRecord>> loadRecords() async {
    final records = await super.loadRecords();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return records;
  }
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

    test('a successful search reports that the network is reachable', () async {
      var reachable = 0;
      final controller = ReachTrailController(
        persistence: PersistenceService(),
        configService: _StubConfigService(),
        onNetworkSuccess: () => reachable++,
      );
      await controller.load();

      await controller.searchPlaces('curry', nearbyOnly: false);

      expect(controller.errorMessage, isNull);
      expect(reachable, 1);
    });
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

    test('a slow load cannot resurrect the previous account data', () async {
      final persistence = _SlowPersistence();
      await persistence.saveBaseLocation(_base());
      await persistence.saveRecords([_record()]);
      await persistence.saveLastUserId('user-1');

      final controller = ReachTrailController(
        persistence: persistence,
        configService: _StubConfigService(),
      );
      // Deliberately not awaited yet: a sign-in can land while the first read
      // of the previous user's data is still in flight.
      final loading = controller.load();

      await controller.adoptUser('user-2');
      await loading;

      expect(controller.records, isEmpty);
      expect(controller.baseLocation, isNull);
      expect(await persistence.loadRecords(), isEmpty);
      expect(await persistence.loadLastUserId(), 'user-2');
    });

    test('a re-sign-in after a wipe re-registers the account', () async {
      final tracker = SignedInUserTracker();

      expect(tracker.nextUserToAdopt('user-1'), 'user-1');
      expect(tracker.nextUserToAdopt('user-1'), isNull);
      // Account deletion signs the user out; signing back in must re-register
      // the id, or the next different account would inherit the local data.
      expect(tracker.nextUserToAdopt(null), isNull);
      expect(tracker.nextUserToAdopt('user-1'), 'user-1');
    });

    test('switching accounts adopts whichever account signs back in', () async {
      final tracker = SignedInUserTracker();

      expect(tracker.nextUserToAdopt('user-1'), 'user-1');
      // "Switch account" is a sign-out followed by an interactive sign-in.
      expect(tracker.nextUserToAdopt(null), isNull);
      // A different account must be adopted, which is what wipes local data.
      expect(tracker.nextUserToAdopt('user-2'), 'user-2');
      // Picking the same account again after a switch keeps the data.
      expect(tracker.nextUserToAdopt('user-2'), isNull);
    });

    test('adopting after a wipe writes the account id again', () async {
      final persistence = PersistenceService();
      await persistence.saveLastUserId('user-1');

      final controller = ReachTrailController(
        persistence: persistence,
        configService: _StubConfigService(),
      );
      await controller.load();
      await controller.clearLocalData();

      await controller.adoptUser('user-1');

      expect(await persistence.loadLastUserId(), 'user-1');
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

  group('record deletion undo', () {
    test('restoring a deleted record brings its place back too', () async {
      final persistence = PersistenceService();
      await persistence.saveBaseLocation(_base());
      final controller = ReachTrailController(
        persistence: persistence,
        configService: _StubConfigService(),
      );
      await controller.load();
      await controller.saveRecord(
        place: const Place(
          id: 'place-1',
          provider: 'manual',
          providerPlaceId: 'manual-1',
          name: 'カレー屋',
          lat: 35.682,
          lng: 139.768,
          address: '東京都千代田区',
        ),
        routeDistanceMeters: 400,
        visitedAt: DateTime(2026, 9, 9, 12, 30),
        timeLimitMinutes: 45,
        dineType: DineType.dineIn,
        menu: '',
        price: null,
        paymentMethod: '',
        memo: '',
      );
      final saved = controller.records.single;
      expect(controller.places, hasLength(1));

      await controller.deleteRecord(saved.id);
      expect(controller.records, isEmpty);
      expect(controller.places, isEmpty);

      await controller.restoreRecord(saved);

      expect(controller.records.single.id, saved.id);
      // The place went with the record, so it has to come back with it.
      expect(controller.places.single.id, 'place-1');
      expect(await persistence.loadRecords(), hasLength(1));

      // A second undo tap must not duplicate the entry.
      await controller.restoreRecord(saved);
      expect(controller.records, hasLength(1));
    });

    test('counts records per place and per day', () async {
      final persistence = PersistenceService();
      await persistence.saveBaseLocation(_base());
      final controller = ReachTrailController(
        persistence: persistence,
        configService: _StubConfigService(),
      );
      await controller.load();
      Future<void> record(DateTime visitedAt) => controller.saveRecord(
        place: const Place(
          id: 'place-1',
          provider: 'manual',
          providerPlaceId: 'manual-1',
          name: 'カレー屋',
          lat: 35.682,
          lng: 139.768,
          address: '東京都千代田区',
        ),
        routeDistanceMeters: 400,
        visitedAt: visitedAt,
        timeLimitMinutes: 45,
        dineType: DineType.dineIn,
        menu: '',
        price: null,
        paymentMethod: '',
        memo: '',
      );

      await record(DateTime(2026, 9, 9, 12, 0));
      await record(DateTime(2026, 9, 10, 12, 0));

      expect(controller.recordCountForPlace('place-1'), 2);
      expect(controller.recordCountForPlace('place-2'), 0);
      expect(
        controller.hasRecordForPlaceOn('place-1', DateTime(2026, 9, 9, 21, 0)),
        isTrue,
      );
      expect(
        controller.hasRecordForPlaceOn('place-1', DateTime(2026, 9, 11)),
        isFalse,
      );
    });
  });

  group('number formatting', () {
    test('groups thousands and keeps small numbers untouched', () {
      expect(formatCount(0), '0');
      expect(formatCount(999), '999');
      expect(formatCount(2936), '2,936');
      expect(formatCount(3056.4), '3,056');
      expect(formatCount(1234567), '1,234,567');
      expect(formatCount(-2500), '-2,500');
      expect(formatMeters(2936), '2,936m');
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
                  visitedAt: DateTime(2026, 3, 4, 12, 30),
                  onEdit: () async {},
                  onDelete: () async {},
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('2026/03/04 12:30'), findsOneWidget);
    });

    test('formats the date and time with zero padding', () {
      expect(
        RecordCardHeader.formatVisitedDate(DateTime(2026, 3, 4, 9, 5)),
        '2026/03/04 09:05',
      );
      expect(
        RecordCardHeader.formatVisitedDate(DateTime(2026, 12, 25, 18, 40)),
        '2026/12/25 18:40',
      );
    });
  });

  group('current location', () {
    test(
      'a successful lookup returns coordinates and clears the notice',
      () async {
        final location = StubLocationService(
          const LocationResult.success(lat: 35.0, lng: 135.0),
        );
        final controller = ReachTrailController(
          persistence: PersistenceService(),
          configService: _StubConfigService(),
          locationService: location,
        );
        await controller.load();

        final result = await controller.locateCurrentPosition();

        expect(result?.latitude, 35.0);
        expect(result?.longitude, 135.0);
        expect(controller.locationNotice, isNull);
        expect(controller.isLocating, isFalse);
      },
    );

    test('a failed lookup sets a notice and returns null', () async {
      final location = StubLocationService(
        const LocationResult.failed(LocationFailure.deniedForever),
      );
      final controller = ReachTrailController(
        persistence: PersistenceService(),
        configService: _StubConfigService(),
        locationService: location,
      );
      await controller.load();

      final result = await controller.locateCurrentPosition();

      expect(result, isNull);
      expect(
        controller.locationNotice,
        describeLocationFailure(LocationFailure.deniedForever),
      );
      expect(controller.locationNeedsSettings, isTrue);
    });

    test(
      'searching from the current location does not run when lookup fails',
      () async {
        final location = StubLocationService(
          const LocationResult.failed(LocationFailure.timeout),
        );
        final controller = ReachTrailController(
          persistence: PersistenceService(),
          configService: _StubConfigService(),
          locationService: location,
        );
        await controller.load();

        await controller.searchPlaces(
          'curry',
          nearbyOnly: true,
          origin: SearchOriginKind.current,
        );

        expect(controller.locationNotice, isNotNull);
        expect(controller.searchResults, isEmpty);
        expect(controller.lastSearchOrigin, isNull);
      },
    );

    test('saving a new base point drops the stale search origin', () async {
      final persistence = PersistenceService();
      await persistence.saveBaseLocation(_base());
      final controller = ReachTrailController(
        persistence: persistence,
        configService: _StubConfigService(),
        locationService: StubLocationService(
          const LocationResult.success(lat: 35.0, lng: 135.0),
        ),
      );
      await controller.load();

      await controller.searchPlaces('curry', nearbyOnly: false);
      expect(controller.lastSearchOrigin, isNotNull);
      expect(controller.searchResults, isNotEmpty);

      await controller.saveBaseLocation(
        name: 'New Office',
        lat: 34.0,
        lng: 135.5,
        floorLabel: '2F',
        floorNumber: 2,
        entryFloorLabel: '1F',
        entryFloorNumber: 1,
        hasElevator: false,
        elevatorRideCount: null,
        memo: '',
      );

      // Old tiles would otherwise keep measuring from the previous base.
      expect(controller.lastSearchOrigin, isNull);
      expect(controller.searchResults, isEmpty);
    });

    test('deleting the base point drops the stale search origin', () async {
      final persistence = PersistenceService();
      await persistence.saveBaseLocation(_base());
      final controller = ReachTrailController(
        persistence: persistence,
        configService: _StubConfigService(),
        locationService: StubLocationService(
          const LocationResult.success(lat: 35.0, lng: 135.0),
        ),
      );
      await controller.load();

      await controller.searchPlaces('curry', nearbyOnly: false);
      expect(controller.lastSearchOrigin, isNotNull);

      await controller.deleteBaseLocation();

      expect(controller.lastSearchOrigin, isNull);
    });

    test('searching from the current location records the origin', () async {
      final location = StubLocationService(
        const LocationResult.success(lat: 35.0, lng: 135.0),
      );
      final controller = ReachTrailController(
        persistence: PersistenceService(),
        configService: _StubConfigService(),
        locationService: location,
      );
      await controller.load();

      await controller.searchPlaces(
        'curry',
        nearbyOnly: false,
        origin: SearchOriginKind.current,
      );

      expect(controller.lastSearchOrigin?.id, currentLocationOriginId);
      expect(controller.lastSearchOrigin?.lat, 35.0);
      expect(controller.lastSearchOrigin?.name, '現在地');
    });
  });
}
