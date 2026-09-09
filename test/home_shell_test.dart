import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reachtrail_app/app.dart';
import 'package:reachtrail_app/models/base_location.dart';
import 'package:reachtrail_app/models/dine_challenge_record.dart';
import 'package:reachtrail_app/models/place.dart';
import 'package:reachtrail_app/services/google_auth_service.dart';
import 'package:reachtrail_app/services/local_config_service.dart';
import 'package:reachtrail_app/services/location_service.dart';
import 'package:reachtrail_app/services/persistence_service.dart';
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

const _place = Place(
  id: 'place-1',
  provider: 'manual',
  providerPlaceId: 'manual-1',
  name: 'Curry Stand',
  lat: 35.6820,
  lng: 139.7680,
  address: '東京都千代田区',
);

DineChallengeRecord _record() => DineChallengeRecord(
  id: 'rec-1',
  baseLocationId: 'base-1',
  placeId: _place.id,
  placeSnapshot: _place.toJson(),
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

/// Boots the real shell so the tab, its dialogs and its SnackBars are wired
/// together exactly as they are in the app.
Future<ReachTrailController> _pumpHome(WidgetTester tester) async {
  final persistence = PersistenceService();
  await persistence.saveBaseLocation(
    BaseLocation(
      id: 'base-1',
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
    ),
  );
  await persistence.savePlaces([_place]);
  await persistence.saveRecords([_record()]);

  final controller = ReachTrailController(
    persistence: persistence,
    configService: _StubConfigService(),
    // The default geolocator service has no platform channel under `flutter
    // test`, so every controller built here takes a stub instead.
    locationService: StubLocationService(
      const LocationResult.success(lat: 35, lng: 135),
    ),
  );
  await controller.load();
  addTearDown(controller.dispose);
  final authService = GoogleAuthService(configService: _StubConfigService());
  addTearDown(authService.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: ListenableBuilder(
        listenable: controller,
        builder: (context, _) =>
            ReachTrailHome(controller: controller, authService: authService),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

/// Presses the system back button the way the platform does.
Future<void> _pressBack(WidgetTester tester) => tester.binding.handlePopRoute();

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('deleting a record offers an undo that puts it back', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = await _pumpHome(tester);

    await tester.tap(find.text('記録'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('この記録の操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('削除').last);
    await tester.pumpAndSettle();

    // The dialog now promises an undo, so it must actually offer one.
    expect(find.text('この記録を削除します。削除直後であれば元に戻せます。'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '削除'));
    await tester.pumpAndSettle();

    expect(controller.records, isEmpty);
    expect(controller.places, isEmpty);
    expect(find.text('記録を削除しました。'), findsOneWidget);

    await tester.tap(find.text('元に戻す'));
    await tester.pumpAndSettle();

    // The place goes back too: a record pointing at nothing is not a restore.
    expect(controller.records.single.id, 'rec-1');
    expect(controller.places.single.id, _place.id);
    expect(await PersistenceService().loadRecords(), hasLength(1));
  });

  testWidgets('the first back press warns instead of leaving', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpHome(tester);

    await _pressBack(tester);
    await tester.pump();

    expect(find.text('もう一度押すと終了します'), findsOneWidget);
  });

  testWidgets('back from a secondary tab returns to the first one', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpHome(tester);

    await tester.tap(find.text('記録'));
    await tester.pumpAndSettle();

    await _pressBack(tester);
    await tester.pumpAndSettle();

    // Not an exit warning: the gesture spent itself going back a tab.
    expect(find.text('もう一度押すと終了します'), findsNothing);

    await _pressBack(tester);
    await tester.pump();
    expect(find.text('もう一度押すと終了します'), findsOneWidget);
  });

  testWidgets('switching the search origin relabels the radius switch', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpHome(tester);

    await tester.tap(find.text('登録'));
    await tester.pumpAndSettle();

    expect(find.text('基準地点から片道徒歩45分圏内で絞り込む'), findsOneWidget);

    await tester.tap(find.text('現在地'));
    await tester.pumpAndSettle();

    expect(find.text('現在地から片道徒歩45分圏内で絞り込む'), findsOneWidget);
  });
}
