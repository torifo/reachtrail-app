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
Future<ReachTrailController> _pumpHome(
  WidgetTester tester, {
  bool withBase = true,
  LocationService? locationService,
}) async {
  final persistence = PersistenceService();
  if (withBase) {
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
  }

  final controller = ReachTrailController(
    persistence: persistence,
    configService: _StubConfigService(),
    // The default geolocator service has no platform channel under `flutter
    // test`, so every controller built here takes a stub instead.
    locationService:
        locationService ??
        StubLocationService(const LocationResult.success(lat: 35, lng: 135)),
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

  testWidgets('recording is blocked until a base point exists', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = await _pumpHome(
      tester,
      withBase: false,
      // Near the mock candidates, so the 45-minute filter keeps them.
      locationService: StubLocationService(
        const LocationResult.success(lat: 35.6890, lng: 139.6917),
      ),
    );

    await tester.tap(find.text('登録'));
    await tester.pumpAndSettle();

    // Manual entry is gated too, not just the candidate tiles.
    await tester.tap(find.widgetWithText(OutlinedButton, '手入力登録'));
    await tester.pumpAndSettle();
    expect(find.text(baseRequiredForRecordMessage), findsOneWidget);
    expect(find.byType(RecordSheet), findsNothing);

    await tester.tap(find.text('現在地'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'curry');
    await tester.tap(find.widgetWithText(FilledButton, '検索'));
    await tester.pumpAndSettle();
    expect(controller.searchResults, isNotEmpty);

    await tester.tap(find.widgetWithText(FilledButton, 'この候補で記録').first);
    await tester.pumpAndSettle();

    // The sheet would only fail on save, so it must not open at all.
    expect(find.byType(RecordSheet), findsNothing);
    expect(find.text(baseRequiredForRecordMessage), findsOneWidget);
  });

  testWidgets('the deniedForever banner opens the OS settings page', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final location = StubLocationService(
      const LocationResult.failed(LocationFailure.deniedForever),
    );
    await _pumpHome(tester, withBase: false, locationService: location);

    await tester.tap(find.text('登録'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('現在地'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'curry');
    await tester.tap(find.widgetWithText(FilledButton, '検索'));
    await tester.pumpAndSettle();

    expect(
      find.text(describeLocationFailure(LocationFailure.deniedForever)),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(OutlinedButton, '設定を開く'));
    await tester.pumpAndSettle();

    expect(location.settingsOpened, 1);
  });

  testWidgets(
    'a location failure does not also claim the query found nothing',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await _pumpHome(
        tester,
        withBase: false,
        locationService: StubLocationService(
          const LocationResult.failed(LocationFailure.timeout),
        ),
      );

      await tester.tap(find.text('登録'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'curry');
      await tester.tap(find.widgetWithText(FilledButton, '検索'));
      await tester.pumpAndSettle();

      expect(find.text('「curry」の店舗候補は見つかりませんでした。'), findsNothing);
    },
  );

  testWidgets('candidate copy names the current location as the origin', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpHome(
      tester,
      locationService: StubLocationService(
        const LocationResult.success(lat: 35.6890, lng: 139.6917),
      ),
    );

    await tester.tap(find.text('登録'));
    await tester.pumpAndSettle();

    expect(
      find.text('基準地点から円形半径で候補を絞り込みます。建物名と階数ラベルを確認し、必要なら補正してから記録します。'),
      findsOneWidget,
    );

    await tester.tap(find.text('現在地'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'curry');
    await tester.tap(find.widgetWithText(FilledButton, '検索'));
    await tester.pumpAndSettle();

    expect(
      find.text('現在地から円形半径で候補を絞り込みます。建物名と階数ラベルを確認し、必要なら補正してから記録します。'),
      findsOneWidget,
    );
    expect(find.text('船のレーダーのように、現在地から見た方向と距離で候補を拾います。'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('OpenStreetMap ベースの地図で、現在地と候補位置を直感的に比較できます。地図表示は今後も拡張予定です。'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.text('OpenStreetMap ベースの地図で、現在地と候補位置を直感的に比較できます。地図表示は今後も拡張予定です。'),
      findsOneWidget,
    );
  });
}
