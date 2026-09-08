import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reachtrail_app/app.dart';
import 'package:reachtrail_app/models/base_location.dart';
import 'package:reachtrail_app/models/dine_challenge_record.dart';
import 'package:reachtrail_app/models/place.dart';
import 'package:reachtrail_app/services/local_config_service.dart';
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

DineChallengeRecord _record({required Map<String, dynamic> snapshot}) =>
    DineChallengeRecord(
      id: 'rec-1',
      baseLocationId: 'base-1',
      placeId: 'place-1',
      placeSnapshot: snapshot,
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

Future<ReachTrailController> _controllerWith(
  List<DineChallengeRecord> records,
) async {
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
  await persistence.saveRecords(records);
  final controller = ReachTrailController(
    persistence: persistence,
    configService: _StubConfigService(),
  );
  await controller.load();
  return controller;
}

Future<void> _pumpSheet(
  WidgetTester tester, {
  required ReachTrailController controller,
  Place? initialPlace,
  DineChallengeRecord? existingRecord,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ja'),
      supportedLocales: const [Locale('ja')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(
        body: RecordSheet(
          controller: controller,
          initialPlace: initialPlace,
          existingRecord: existingRecord,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _fieldWithLabel(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byType(TextFormField),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('editing an optional field arms the discard prompt', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final record = _record(
      snapshot: const Place(
        id: 'place-1',
        provider: 'manual',
        providerPlaceId: 'manual-1',
        name: 'Curry Stand',
        lat: 35.682,
        lng: 139.768,
        address: '東京都千代田区',
      ).toJson(),
    );
    final controller = await _controllerWith([record]);
    addTearDown(controller.dispose);

    await _pumpSheet(
      tester,
      controller: controller,
      initialPlace: placeFromSnapshot(record.placeSnapshot),
      existingRecord: record,
    );

    // メモ is not a required field, so nothing else rebuilds the sheet: the
    // dirty flag has to do it itself or the back gesture leaves without asking.
    await tester.enterText(_fieldWithLabel('メモ'), 'また来たい');
    await tester.pumpAndSettle();

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await navigator.maybePop();
    await tester.pumpAndSettle();

    expect(find.text('入力内容を破棄しますか？'), findsOneWidget);
  });

  testWidgets('a coordinate-less record cannot be saved back as 0, 0', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final record = _record(
      snapshot: const {'id': 'place-1', 'name': 'Old Record'},
    );
    final controller = await _controllerWith([record]);
    addTearDown(controller.dispose);
    final placeholder = placeFromSnapshot(record.placeSnapshot);
    expect(placeholder.isPlaceholder, isTrue);

    await _pumpSheet(
      tester,
      controller: controller,
      initialPlace: placeholder,
      existingRecord: record,
    );

    // The fabricated 0, 0 must never be offered back to the user as data.
    final latField = tester.widget<TextFormField>(_fieldWithLabel('緯度 *'));
    expect(latField.controller!.text, isEmpty);
    final lngField = tester.widget<TextFormField>(_fieldWithLabel('経度 *'));
    expect(lngField.controller!.text, isEmpty);

    // Submitting is refused until real coordinates are supplied.
    expect(find.text('未入力: 位置'), findsOneWidget);
    await tester.ensureVisible(find.text('更新する'));
    await tester.pumpAndSettle();
    final submitButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('更新する'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(submitButton.onPressed, isNull);
    await tester.tap(find.text('更新する'), warnIfMissed: false);
    await tester.pumpAndSettle();

    final stored = await PersistenceService().loadRecords();
    expect(stored, hasLength(1));
    expect(stored.single.placeSnapshot['lat'], isNull);
    expect(stored.single.placeSnapshot['lng'], isNull);

    // With coordinates typed in, the same sheet saves normally.
    await tester.enterText(_fieldWithLabel('緯度 *'), '35.6812');
    await tester.enterText(_fieldWithLabel('経度 *'), '139.7671');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('更新する'));
    await tester.tap(find.text('更新する'));
    await tester.pumpAndSettle();

    final saved = await PersistenceService().loadRecords();
    expect(saved.single.placeSnapshot['lat'], 35.6812);
    expect(saved.single.placeSnapshot['lng'], 139.7671);
  });
}
