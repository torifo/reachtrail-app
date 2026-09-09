import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as latlong;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reachtrail_app/app.dart';
import 'package:reachtrail_app/models/base_location.dart';
import 'package:reachtrail_app/models/dine_challenge_record.dart';
import 'package:reachtrail_app/models/place.dart';
import 'package:reachtrail_app/services/local_config_service.dart';
import 'package:reachtrail_app/services/location_service.dart';
import 'package:reachtrail_app/services/persistence_service.dart';
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

DineChallengeRecord _record({
  required Map<String, dynamic> snapshot,
  DateTime? visitedAt,
}) => DineChallengeRecord(
  id: 'rec-1',
  baseLocationId: 'base-1',
  placeId: 'place-1',
  placeSnapshot: snapshot,
  visitedAt: visitedAt ?? DateTime(2026, 3, 4, 12, 30),
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
    // No platform channel for geolocator under `flutter test`.
    locationService: StubLocationService(
      const LocationResult.success(lat: 35, lng: 135),
    ),
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
  of: find.text(label, skipOffstage: false),
  matching: find.byType(TextFormField, skipOffstage: false),
  matchRoot: false,
);

/// Fires the picker map's own tap callback.
///
/// Tapping the rendered map in a test would mean hitting real tiles that never
/// load, so the widget's callback is invoked directly — the same entry point a
/// real tap uses.
void _tapPickerMap(WidgetTester tester, latlong.LatLng point) {
  final map = tester.widget<FlutterMap>(
    find.byKey(locationPickerMapKey, skipOffstage: false),
  );
  map.options.onTap!(const TapPosition(Offset.zero, Offset.zero), point);
}

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
    expect(find.text('保存には位置が必要です。'), findsOneWidget);
    await tester.ensureVisible(find.text('更新する'));
    await tester.pumpAndSettle();
    final submitButton = tester.widget<FilledButton>(
      find.ancestor(of: find.text('更新する'), matching: find.byType(FilledButton)),
    );
    expect(submitButton.onPressed, isNull);
    await tester.tap(find.text('更新する'), warnIfMissed: false);
    await tester.pumpAndSettle();

    final stored = await PersistenceService().loadRecords();
    expect(stored, hasLength(1));
    expect(stored.single.placeSnapshot['lat'], isNull);
    expect(stored.single.placeSnapshot['lng'], isNull);

    // Tapping the picker map is the way a manual record gets its position.
    _tapPickerMap(tester, latlong.LatLng(35.6812, 139.7671));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(_fieldWithLabel('緯度 *')).controller!.text,
      '35.681200',
    );
    expect(find.text('必須項目は入力済みです。'), findsOneWidget);
    await tester.ensureVisible(find.text('更新する'));
    await tester.tap(find.text('更新する'));
    await tester.pumpAndSettle();

    final saved = await PersistenceService().loadRecords();
    expect(saved.single.placeSnapshot['lat'], 35.6812);
    expect(saved.single.placeSnapshot['lng'], 139.7671);
  });

  testWidgets('focusing a field without typing leaves the form clean', (
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

    // Focus and a caret move fire the controller's listeners without changing
    // a character; neither is an edit.
    await tester.ensureVisible(_fieldWithLabel('メモ'));
    await tester.pumpAndSettle();
    await tester.tap(_fieldWithLabel('メモ'));
    await tester.pumpAndSettle();
    final memo = tester
        .widget<TextFormField>(_fieldWithLabel('メモ'))
        .controller!;
    memo.selection = const TextSelection.collapsed(offset: 0);
    await tester.pumpAndSettle();

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await navigator.maybePop();
    await tester.pumpAndSettle();

    expect(find.text('入力内容を破棄しますか？'), findsNothing);
  });

  testWidgets('a second record for the same place today has to be confirmed', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const place = Place(
      id: 'place-1',
      provider: 'manual',
      providerPlaceId: 'manual-1',
      name: 'Curry Stand',
      lat: 35.682,
      lng: 139.768,
      address: '東京都千代田区',
    );
    // A new sheet visits "now", so the clash only exists if the record it is
    // compared against sits on today's date too.
    final controller = await _controllerWith([
      _record(snapshot: place.toJson(), visitedAt: DateTime.now()),
    ]);
    addTearDown(controller.dispose);
    expect(controller.records, hasLength(1));

    await _pumpSheet(tester, controller: controller, initialPlace: place);

    await tester.ensureVisible(find.text('保存する'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存する'));
    await tester.pumpAndSettle();

    expect(find.text('今日はすでに記録があります'), findsOneWidget);

    await tester.tap(find.text('やめる'));
    await tester.pumpAndSettle();

    // Backing out saves nothing: the duplicate is refused, not queued.
    expect(controller.records, hasLength(1));
    expect(await PersistenceService().loadRecords(), hasLength(1));
  });

  testWidgets('typing and then undoing it disarms the discard prompt', (
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

    await tester.enterText(_fieldWithLabel('メモ'), 'また来たい');
    await tester.pumpAndSettle();
    await tester.enterText(_fieldWithLabel('メモ'), '');
    await tester.pumpAndSettle();

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await navigator.maybePop();
    await tester.pumpAndSettle();

    expect(find.text('入力内容を破棄しますか？'), findsNothing);
  });
}
