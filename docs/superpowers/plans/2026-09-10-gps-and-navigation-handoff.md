# GPS 活用とナビ転送 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ReachTrail 版 1.0.0+6 として、(1) 検索結果・記録済み店舗から端末の地図アプリへナビを渡すボタン、(2) 端末の現在地を「基準地点設定の補助」と「店検索の起点切り替え」に使う機能を追加する。

**Architecture:** `LocationService`（geolocator ラッパー）を `ReachTrailController` に注入し、現在地は Controller が 1 回取得して UI に返す。店検索の起点は、現在地を `BaseLocation` 形の値（id `current-location`）に包んで既存の `PlaceSearchService.search(baseLocation:)` にそのまま渡すことで、検索サービス内部（パラメータ組み立て・半径フィルタ・距離順位）を無改造で流用する。ナビ転送は純粋関数 `buildMapHandoffUri` で URL を組み立て、`url_launcher` で外部アプリを開く。

**Tech Stack:** Flutter 3.47 / Dart 3.11、geolocator、url_launcher、flutter_map、shared_preferences。既存テストは `flutter test`。

**Spec:** `docs/superpowers/specs/2026-09-10-gps-and-navigation-handoff-design.md`

**規約:** コミットメッセージは Conventional Commits の EN / JA 併記。Claude / Anthropic の帰属行（Co-Authored-By 等）は絶対に入れない。作業ブランチは `feature/v6-gps-nav`（main から作成）。

---

## ファイル構成

| ファイル | 役割 |
|---|---|
| `lib/services/location_service.dart`（新規） | `LocationService` 抽象、`GeolocatorLocationService`、`LocationResult`、`LocationFailure`、`describeLocationFailure` |
| `lib/services/map_handoff.dart`（新規） | `buildMapHandoffUri`、`openInMapsApp` |
| `lib/app.dart` | Controller への注入と `locateCurrentPosition` / `searchPlaces(origin:)`、基準地点タブのボタン、検索タブの起点セグメント、結果タイルとマイマップのナビボタン |
| `pubspec.yaml`、`android/app/src/main/AndroidManifest.xml`、`ios/Runner/Info.plist` | 依存と権限 |
| `web/privacy.html` | 位置情報の項 |
| `test/location_service_test.dart`、`test/map_handoff_test.dart`（新規）、`test/reachtrail_hardening_test.dart`、`test/reachtrail_logic_test.dart` | テスト |

---

### Task 0: ブランチと依存の追加

**Files:**
- Modify: `pubspec.yaml`
- Modify: `android/app/src/main/AndroidManifest.xml:2`
- Modify: `ios/Runner/Info.plist`

- [ ] **Step 1: ブランチ作成**

```bash
cd ~/dev/app/reachtrail && git checkout -b feature/v6-gps-nav main
```

- [ ] **Step 2: 依存追加**

```bash
flutter pub add geolocator url_launcher
```
Expected: `pubspec.yaml` の dependencies に `geolocator: ^x.y.z` と `url_launcher: ^x.y.z` が入り、`flutter pub get` が成功する。

- [ ] **Step 3: Android 権限**

`AndroidManifest.xml` の `<uses-permission android:name="android.permission.INTERNET" />` の直後に追加:

```xml
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
```

- [ ] **Step 4: iOS 用途文言**

`ios/Runner/Info.plist` の最上位 `<dict>` 内（`CFBundleDisplayName` の近く）に追加:

```xml
	<key>NSLocationWhenInUseUsageDescription</key>
	<string>現在地を基準地点の候補と店検索の起点として使うためです。バックグラウンドでは使いません。</string>
```

- [ ] **Step 5: ビルド確認とコミット**

```bash
flutter analyze && flutter test
git add pubspec.yaml pubspec.lock android/app/src/main/AndroidManifest.xml ios/Runner/Info.plist
git commit -m "build: add geolocator and url_launcher with location permissions / 位置情報とナビ転送の依存・権限を追加"
```

---

### Task 1: LocationService

**Files:**
- Create: `lib/services/location_service.dart`
- Test: `test/location_service_test.dart`

- [ ] **Step 1: 失敗するテストを書く**

```dart
// test/location_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:reachtrail_app/services/location_service.dart';

void main() {
  test('a successful result carries coordinates and no failure', () {
    const result = LocationResult.success(lat: 35.68, lng: 139.76);
    expect(result.isSuccess, isTrue);
    expect(result.lat, 35.68);
    expect(result.lng, 139.76);
    expect(result.failure, isNull);
  });

  test('a failed result has no coordinates', () {
    const result = LocationResult.failed(LocationFailure.denied);
    expect(result.isSuccess, isFalse);
    expect(result.lat, isNull);
    expect(result.failure, LocationFailure.denied);
  });

  test('every failure has a Japanese explanation', () {
    for (final failure in LocationFailure.values) {
      expect(describeLocationFailure(failure), isNotEmpty);
    }
    expect(
      describeLocationFailure(LocationFailure.serviceDisabled),
      contains('位置情報がオフ'),
    );
    expect(
      describeLocationFailure(LocationFailure.deniedForever),
      contains('設定'),
    );
    expect(
      describeLocationFailure(LocationFailure.timeout),
      contains('もう一度'),
    );
  });

  test('the stub service returns what it was given', () async {
    final service = StubLocationService(
      const LocationResult.success(lat: 1, lng: 2),
    );
    final result = await service.getCurrentPosition();
    expect(result.lat, 1);
    expect(service.callCount, 1);
  });
}
```

- [ ] **Step 2: 失敗を確認**

Run: `flutter test test/location_service_test.dart`
Expected: FAIL（`location_service.dart` が無い）

- [ ] **Step 3: 実装**

```dart
// lib/services/location_service.dart
import 'package:geolocator/geolocator.dart';

enum LocationFailure { serviceDisabled, denied, deniedForever, timeout, unknown }

/// One-shot position lookup result. Either coordinates or a failure, never both.
class LocationResult {
  const LocationResult.success({required double this.lat, required double this.lng})
      : failure = null;
  const LocationResult.failed(LocationFailure this.failure)
      : lat = null,
        lng = null;

  final double? lat;
  final double? lng;
  final LocationFailure? failure;

  bool get isSuccess => failure == null;
}

String describeLocationFailure(LocationFailure failure) {
  switch (failure) {
    case LocationFailure.serviceDisabled:
      return '端末の位置情報がオフです。設定でオンにするか、地図をタップして指定してください。';
    case LocationFailure.denied:
    case LocationFailure.deniedForever:
      return '位置情報の利用が許可されていません。端末の設定で ReachTrail に位置情報を許可すると使えます。';
    case LocationFailure.timeout:
    case LocationFailure.unknown:
      return '現在地を取得できませんでした。しばらくしてからもう一度お試しください。';
  }
}

abstract class LocationService {
  /// Asks for permission only when called, never at startup.
  Future<LocationResult> getCurrentPosition({
    Duration timeout = const Duration(seconds: 15),
  });

  /// Opens the OS settings page for this app (used after `deniedForever`).
  Future<void> openAppSettings();
}

class GeolocatorLocationService implements LocationService {
  @override
  Future<LocationResult> getCurrentPosition({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const LocationResult.failed(LocationFailure.serviceDisabled);
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      switch (permission) {
        case LocationPermission.denied:
          return const LocationResult.failed(LocationFailure.denied);
        case LocationPermission.deniedForever:
          return const LocationResult.failed(LocationFailure.deniedForever);
        case LocationPermission.unableToDetermine:
          return const LocationResult.failed(LocationFailure.unknown);
        case LocationPermission.whileInUse:
        case LocationPermission.always:
          break;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: timeout,
        ),
      );
      return LocationResult.success(
        lat: position.latitude,
        lng: position.longitude,
      );
    } on TimeoutException {
      return const LocationResult.failed(LocationFailure.timeout);
    } catch (_) {
      return const LocationResult.failed(LocationFailure.unknown);
    }
  }

  @override
  Future<void> openAppSettings() => Geolocator.openAppSettings();
}

/// Test double. Lives here so widget tests in other files can share it.
class StubLocationService implements LocationService {
  StubLocationService(this.result);

  LocationResult result;
  int callCount = 0;
  int settingsOpened = 0;

  @override
  Future<LocationResult> getCurrentPosition({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    callCount += 1;
    return result;
  }

  @override
  Future<void> openAppSettings() async {
    settingsOpened += 1;
  }
}
```

`TimeoutException` は `dart:async` から import する。

- [ ] **Step 4: 成功を確認**

Run: `flutter test test/location_service_test.dart`
Expected: 4 tests PASS

- [ ] **Step 5: コミット**

```bash
git add lib/services/location_service.dart test/location_service_test.dart
git commit -m "feat(location): add one-shot LocationService over geolocator / 現在地取得サービスを追加"
```

---

### Task 2: ナビ転送 URL

**Files:**
- Create: `lib/services/map_handoff.dart`
- Test: `test/map_handoff_test.dart`

- [ ] **Step 1: 失敗するテストを書く**

```dart
// test/map_handoff_test.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reachtrail_app/services/map_handoff.dart';

void main() {
  test('android uses a geo: uri that triggers the OS chooser', () {
    final uri = buildMapHandoffUri(
      lat: 35.6812,
      lng: 139.7671,
      label: '東京 駅前店',
      platform: TargetPlatform.android,
    );
    expect(uri.scheme, 'geo');
    expect(uri.toString(), 'geo:0,0?q=35.6812,139.7671(%E6%9D%B1%E4%BA%AC%20%E9%A7%85%E5%89%8D%E5%BA%97)');
  });

  test('ios uses Apple Maps directions', () {
    final uri = buildMapHandoffUri(
      lat: -33.8688,
      lng: 151.2093,
      label: 'Cafe',
      platform: TargetPlatform.iOS,
    );
    expect(uri.host, 'maps.apple.com');
    expect(uri.queryParameters['daddr'], '-33.8688,151.2093');
    expect(uri.queryParameters['q'], 'Cafe');
  });

  test('other platforms fall back to Google Maps directions on the web', () {
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.fuchsia,
    ]) {
      final uri = buildMapHandoffUri(
        lat: 1,
        lng: 2,
        label: '',
        platform: platform,
      );
      expect(uri.host, 'www.google.com');
      expect(uri.path, '/maps/dir/');
      expect(uri.queryParameters['destination'], '1.0,2.0');
    }
  });

  test('an empty label still yields a valid android uri', () {
    final uri = buildMapHandoffUri(
      lat: 1,
      lng: 2,
      label: '   ',
      platform: TargetPlatform.android,
    );
    expect(uri.toString(), 'geo:0,0?q=1.0,2.0');
  });
}
```

- [ ] **Step 2: 失敗を確認**

Run: `flutter test test/map_handoff_test.dart`
Expected: FAIL

- [ ] **Step 3: 実装**

```dart
// lib/services/map_handoff.dart
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Builds the URL that hands a destination to the device's maps app.
///
/// Android: `geo:` lets the OS show its own chooser (Google Maps, Yahoo, ...).
/// iOS: Apple Maps universal link, no `LSApplicationQueriesSchemes` needed.
/// Everything else: Google Maps directions in the browser.
Uri buildMapHandoffUri({
  required double lat,
  required double lng,
  required String label,
  required TargetPlatform platform,
}) {
  final point = '$lat,$lng';
  final trimmed = label.trim();
  switch (platform) {
    case TargetPlatform.android:
      final query = trimmed.isEmpty
          ? point
          : '$point(${Uri.encodeComponent(trimmed)})';
      return Uri.parse('geo:0,0?q=$query');
    case TargetPlatform.iOS:
      return Uri.https('maps.apple.com', '/', {
        'daddr': point,
        if (trimmed.isNotEmpty) 'q': trimmed,
      });
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return Uri.https('www.google.com', '/maps/dir/', {
        'api': '1',
        'destination': point,
      });
  }
}

/// Returns false when no app could take the URL, so the caller can show a
/// SnackBar instead of failing silently.
Future<bool> openInMapsApp({
  required double lat,
  required double lng,
  required String label,
  TargetPlatform? platform,
}) async {
  final uri = buildMapHandoffUri(
    lat: lat,
    lng: lng,
    label: label,
    platform: platform ?? defaultTargetPlatform,
  );
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
```

注意: `Uri.encodeComponent` はスペースを `%20` にする（テストの期待値どおり）。Web 実行時は `defaultTargetPlatform` がホスト OS 相当になるので、`kIsWeb` のときは Google Maps URL に固定する: `platform ?? (kIsWeb ? TargetPlatform.linux : defaultTargetPlatform)`。

- [ ] **Step 4: 成功を確認**

Run: `flutter test test/map_handoff_test.dart`
Expected: 4 tests PASS

- [ ] **Step 5: コミット**

```bash
git add lib/services/map_handoff.dart test/map_handoff_test.dart
git commit -m "feat(maps): build maps-app handoff URLs per platform / 地図アプリ転送 URL を追加"
```

---

### Task 3: Controller に現在地と検索起点を追加

**Files:**
- Modify: `lib/app.dart:405-430`（コンストラクタ）、`lib/app.dart:665-688`（`searchPlaces`）、`lib/app.dart:228-240`（`ReachTrailController(...)` 生成）
- Test: `test/reachtrail_hardening_test.dart`

- [ ] **Step 1: 失敗するテストを書く**

`test/reachtrail_hardening_test.dart` に import `package:reachtrail_app/services/location_service.dart` を足し、末尾に group を追加:

```dart
  group('current location', () {
    test('a successful lookup returns coordinates and clears the notice', () async {
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
    });

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
      expect(controller.locationNotice, describeLocationFailure(LocationFailure.deniedForever));
      expect(controller.locationNeedsSettings, isTrue);
    });

    test('searching from the current location does not run when lookup fails', () async {
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
```

- [ ] **Step 2: 失敗を確認**

Run: `flutter test test/reachtrail_hardening_test.dart`
Expected: コンパイルエラー（`locationService` / `SearchOriginKind` 未定義）

- [ ] **Step 3: 実装**

`lib/app.dart` 冒頭の import に追加:

```dart
import 'services/location_service.dart';
import 'services/map_handoff.dart';
```

`ReachTrailController` の直前に追加:

```dart
/// Which point a dine-place search is measured from.
enum SearchOriginKind { base, current }

const String currentLocationOriginId = 'current-location';
```

コンストラクタ（`lib/app.dart:406-416`）を変更:

```dart
  ReachTrailController({
    required PersistenceService persistence,
    required LocalConfigService configService,
    LocationService? locationService,
    String Function()? sessionTokenProvider,
    VoidCallback? onSessionExpired,
    VoidCallback? onNetworkSuccess,
  }) : _persistence = persistence,
       _configService = configService,
       _locationService = locationService ?? GeolocatorLocationService(),
       _sessionTokenProvider = sessionTokenProvider,
       _onSessionExpired = onSessionExpired,
       _onNetworkSuccess = onNetworkSuccess;

  final LocationService _locationService;
```

フィールド群（`sessionExpired` の近く）に追加:

```dart
  /// Set while a one-shot position lookup is running.
  bool isLocating = false;

  /// Calm explanation shown when the last lookup failed; null otherwise.
  String? locationNotice;

  /// True when the user has to flip the permission in OS settings.
  bool locationNeedsSettings = false;

  /// The point the most recent dine-place search was measured from. Null until
  /// a search ran, or when the last search could not determine its origin.
  BaseLocation? lastSearchOrigin;
```

メソッドを追加（`searchPlaces` の直前）:

```dart
  /// One-shot position lookup. Returns null on failure and leaves the reason
  /// in [locationNotice]; the UI decides where to show it.
  Future<latlong.LatLng?> locateCurrentPosition() async {
    if (isLocating) {
      return null;
    }
    isLocating = true;
    locationNotice = null;
    locationNeedsSettings = false;
    notifyListeners();
    try {
      final result = await _locationService.getCurrentPosition();
      if (result.isSuccess) {
        return latlong.LatLng(result.lat!, result.lng!);
      }
      locationNotice = describeLocationFailure(result.failure!);
      locationNeedsSettings = result.failure == LocationFailure.deniedForever;
      return null;
    } finally {
      isLocating = false;
      notifyListeners();
    }
  }

  Future<void> openLocationSettings() => _locationService.openAppSettings();

  void clearLocationNotice() {
    if (locationNotice == null) {
      return;
    }
    locationNotice = null;
    locationNeedsSettings = false;
    notifyListeners();
  }
```

`searchPlaces` を差し替え:

```dart
  Future<void> searchPlaces(
    String query, {
    required bool nearbyOnly,
    SearchOriginKind origin = SearchOriginKind.base,
  }) async {
    BaseLocation? searchFrom = baseLocation;
    if (origin == SearchOriginKind.current) {
      final point = await locateCurrentPosition();
      if (point == null) {
        lastSearchOrigin = null;
        searchResults = const [];
        notifyListeners();
        return;
      }
      // Wrapping the position as a BaseLocation lets the search service rank
      // and filter from it without learning a second kind of origin.
      searchFrom = BaseLocation(
        id: currentLocationOriginId,
        name: '現在地',
        lat: point.latitude,
        lng: point.longitude,
      );
    }
    isSearching = true;
    errorMessage = null;
    buildingSearchError = null;
    buildingSearchResults = const [];
    notifyListeners();
    try {
      searchResults = await _requireSearchService().search(
        query: query,
        baseLocation: searchFrom,
        nearbyOnly: nearbyOnly,
      );
      lastSearchOrigin = searchFrom;
      _onNetworkSuccess?.call();
    } catch (error) {
      errorMessage = describeSearchFailure(error);
      _noteSearchFailure(error);
      searchResults = const [];
    } finally {
      isSearching = false;
      notifyListeners();
    }
  }
```

`BaseLocation` の必須引数が `id, name, lat, lng` 以外にもある場合は `lib/models/base_location.dart` のコンストラクタを見て既定値で埋める（`floorLabel` などは null / false / 0）。

- [ ] **Step 4: 成功を確認**

Run: `flutter test`
Expected: 全 PASS（既存テストは `origin` 既定値で従来どおり）

- [ ] **Step 5: コミット**

```bash
git add lib/app.dart test/reachtrail_hardening_test.dart
git commit -m "feat(controller): one-shot current position and search origin / 現在地取得と検索起点を Controller に追加"
```

---

### Task 4: 基準地点タブ「現在地を使う」

**Files:**
- Modify: `lib/app.dart:1610-1640`（ボタン行）、`lib/app.dart:2013-2021`（`_selectBasePoint`）

- [ ] **Step 1: ボタンを追加**

`Wrap` の子（「住所を手入力で使う」の後ろ）に追加:

```dart
                    OutlinedButton.icon(
                      onPressed: controller.isLocating
                          ? null
                          : () => unawaited(_useCurrentPositionAsBase()),
                      icon: controller.isLocating
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.my_location),
                      label: const Text('現在地を使う'),
                    ),
```

`baseSearchError` の表示の直後に案内バナー:

```dart
                if (controller.locationNotice case final notice?)
                  _NoticeBanner(
                    message: notice,
                    icon: Icons.location_off_outlined,
                    action: controller.locationNeedsSettings
                        ? OutlinedButton(
                            onPressed: () => unawaited(controller.openLocationSettings()),
                            child: const Text('設定を開く'),
                          )
                        : null,
                  ),
```

- [ ] **Step 2: ハンドラ**

`_useTypedAddressAsBase` の直後に追加:

```dart
  /// Same path as a map tap, so the mismatch tag and save validation apply.
  Future<void> _useCurrentPositionAsBase() async {
    final controller = widget.controller;
    final point = await controller.locateCurrentPosition();
    if (!mounted || point == null) {
      return;
    }
    _selectBasePoint(point);
    _pickerMapController.move(point, 16);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('現在地を基準地点の位置にしました。名前を入力して保存してください。')),
    );
  }
```

`_pickerMapController` が存在しない場合: `_BaseLocationPickerMap` が内部で `MapController` を持っているので、`_BaseLocationPickerMap` に `initialCenter` ではなく `controller: MapController` を受け取らせて `_BaseLocationTabState` 側で `final _pickerMapController = MapController();` を持たせ、`dispose` で破棄する。`_BaseLocationPickerMap` の `FlutterMap(mapController: widget.controller, ...)`。

- [ ] **Step 3: 動作確認**

Run: `flutter analyze && flutter test`
Expected: PASS

- [ ] **Step 4: コミット**

```bash
git add lib/app.dart
git commit -m "feat(base): use current position as the base point candidate / 基準地点タブに現在地ボタンを追加"
```

---

### Task 5: 店検索タブの起点切り替え

**Files:**
- Modify: `lib/app.dart:2362`（state）、`lib/app.dart:2395-2425`（検索フォーム）、`lib/app.dart:2455-2475`（バナー）、`lib/app.dart:2578-2596`（`_runSearch`）、`lib/app.dart:2722-2760`（`_PlaceResultTile`）
- Test: `test/home_shell_test.dart`（ウィジェットテスト追加）

- [ ] **Step 1: 失敗するウィジェットテストを書く**

`test/home_shell_test.dart` の既存セットアップ（`ReachTrailController` を組んで `HomeShell` などを pump している箇所）に倣い、末尾に追加:

```dart
  testWidgets('switching the search origin relabels the radius switch', (tester) async {
    // 既存テストと同じ手順で登録タブを表示する（base location を保存済みの状態にする）
    // ...pump...
    expect(find.text('基準地点から片道徒歩45分圏内で絞り込む'), findsOneWidget);
    await tester.tap(find.text('現在地'));
    await tester.pumpAndSettle();
    expect(find.text('現在地から片道徒歩45分圏内で絞り込む'), findsOneWidget);
  });
```

`ReachTrailController` を組む箇所には `locationService: StubLocationService(const LocationResult.success(lat: 35, lng: 135))` を渡す（既定の `GeolocatorLocationService` はテスト環境でプラットフォームチャネルが無く落ちるため）。

- [ ] **Step 2: 失敗を確認**

Run: `flutter test test/home_shell_test.dart`
Expected: FAIL（「現在地」セグメントが無い）

- [ ] **Step 3: 実装**

state に追加（`bool _nearbyOnly = true;` の隣）:

```dart
  SearchOriginKind _origin = SearchOriginKind.base;
```

`TextField` と `SwitchListTile` の間に挿入:

```dart
              SegmentedButton<SearchOriginKind>(
                segments: [
                  ButtonSegment(
                    value: SearchOriginKind.base,
                    icon: const Icon(Icons.home_work_outlined),
                    label: const Text('基準地点'),
                    enabled: base != null,
                  ),
                  const ButtonSegment(
                    value: SearchOriginKind.current,
                    icon: Icon(Icons.my_location),
                    label: Text('現在地'),
                  ),
                ],
                selected: {base == null ? SearchOriginKind.current : _origin},
                onSelectionChanged: (selection) {
                  setState(() => _origin = selection.first);
                  controller.clearLocationNotice();
                },
              ),
```

`SwitchListTile` を変更:

```dart
              SwitchListTile(
                title: Text(
                  '${_origin == SearchOriginKind.current ? '現在地' : '基準地点'}から片道徒歩45分圏内で絞り込む',
                ),
                value: _nearbyOnly,
                onChanged: (base == null && _origin == SearchOriginKind.base)
                    ? null
                    : (value) => setState(() => _nearbyOnly = value),
              ),
```

検索ボタンの `onPressed` を変更（基準地点が無くても現在地起点なら押せる）:

```dart
                      onPressed: controller.isSearching ||
                              controller.isLocating ||
                              (base == null && _origin == SearchOriginKind.base)
                          ? null
                          : _runSearch,
```

`_runSearch` の呼び出しを変更:

```dart
    await widget.controller.searchPlaces(
      query,
      nearbyOnly: _nearbyOnly,
      origin: base == null ? SearchOriginKind.current : _origin,
    );
```

（`base` は `_runSearch` 内で `widget.controller.baseLocation` を読む）

セッション切れバナーの直後に位置情報バナーを追加（Task 4 と同じ `_NoticeBanner`、`Icons.location_off_outlined`、`locationNeedsSettings` なら「設定を開く」）。

`_PlaceResultTile` の距離表示: 呼び出し側（`lib/app.dart:2507` 付近）で `baseLocation: controller.lastSearchOrigin ?? base` を渡し、タイル内のタグ文言を

```dart
                  if (distance != null)
                    _Tag(
                      label:
                          '${baseLocation!.id == currentLocationOriginId ? '現在地' : '基準地点'}から ${formatMeters(distance)}',
                    ),
```

にする。`_CandidateMap` と `_CandidateRadar` に渡している `baseLocation` も同じく `controller.lastSearchOrigin ?? base` にし、現在地起点のときは中心マーカーのラベルが「現在地」になるようにする（マーカーのラベルは `baseLocation.name` を使っている箇所を確認して合わせる）。

記録シート（`_openRecordSheet`）に渡す `baseLocation` は **従来どおり `controller.baseLocation`** のまま。基準地点が null なら既存の案内が出る。

- [ ] **Step 4: 成功を確認**

Run: `flutter analyze && flutter test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add lib/app.dart test/home_shell_test.dart
git commit -m "feat(search): search from the current location or the base point / 店検索の起点を切り替え可能に"
```

---

### Task 6: ナビ転送ボタン

**Files:**
- Modify: `lib/app.dart:2806-2828`（`_PlaceResultTile` の操作行）、`lib/app.dart:5331-5360`（`_SharedPlaceRankTile`）

- [ ] **Step 1: 共通ボタン**

`_NoticeBanner` の近くに追加:

```dart
/// Hands the destination to the device's maps app; the OS picks which one.
class _OpenInMapsButton extends StatelessWidget {
  const _OpenInMapsButton({required this.place, this.compact = false});

  final Place place;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    Future<void> open() async {
      final messenger = ScaffoldMessenger.of(context);
      final ok = await openInMapsApp(
        lat: place.lat,
        lng: place.lng,
        label: place.name,
      );
      if (!ok) {
        messenger.showSnackBar(
          const SnackBar(content: Text('地図アプリを開けませんでした。')),
        );
      }
    }

    if (compact) {
      return IconButton(
        tooltip: '地図アプリで開く',
        icon: const Icon(Icons.directions_outlined),
        onPressed: () => unawaited(open()),
      );
    }
    return OutlinedButton.icon(
      onPressed: () => unawaited(open()),
      icon: const Icon(Icons.directions_outlined),
      label: const Text('地図アプリで開く'),
    );
  }
}
```

- [ ] **Step 2: 検索結果タイル**

`_PlaceResultTile` の `Align(alignment: centerRight, child: Row(...))` を `Wrap` に変え、「この候補で記録」の前に `_OpenInMapsButton(place: place)` を置く:

```dart
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (showDebugInfo && place.provider == 'yahoo')
                    OutlinedButton.icon(
                      onPressed: () => _openDebugSheet(context),
                      icon: const Icon(Icons.bug_report_outlined),
                      label: const Text('デバッグ'),
                    ),
                  _OpenInMapsButton(place: place),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0F766E),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: onUse,
                    child: const Text('この候補で記録'),
                  ),
                ],
              ),
```

- [ ] **Step 3: マイマップの店舗ランキング**

`_SharedPlaceRankTile` の行末（既存の trailing 要素の隣。無ければ `ListTile.trailing` 相当の位置）に `_OpenInMapsButton(place: entry.place, compact: true)` を置く。タイル全体の `onTap` は選択のままにし、ボタンのタップが親に伝播しないことを確認する（`IconButton` は独自に `onPressed` を消費するので通常は問題ない）。

- [ ] **Step 4: 確認とコミット**

```bash
flutter analyze && flutter test
git add lib/app.dart
git commit -m "feat(maps): open a place in the device maps app / 検索結果とマイマップに地図アプリで開くボタン"
```

---

### Task 7: プライバシーポリシー

**Files:**
- Modify: `web/privacy.html:152-205`

- [ ] **Step 1: 位置情報の項を追加**

「1. 取得する情報」の一覧に項目を追加し、「2. 外部サービスへの送信」に Yahoo! JAPAN への送信内容として座標を追記:

```html
        <li>
          <strong>位置情報（任意）</strong>：「現在地を使う」または検索起点で「現在地」を選んだときにのみ、
          端末の位置情報を 1 回取得します。取得した座標は、基準地点の位置候補として端末内に保存するか、
          店舗検索の起点として使います。バックグラウンドでは取得しません。
          位置情報の許可はいつでも端末の設定から取り消せます。
        </li>
```

```html
        <li>
          店舗検索の起点に「現在地」を選んだ場合、その座標は ReachTrail API を経由して
          Yahoo! JAPAN のローカルサーチ API に検索条件として送信されます。ReachTrail API は
          座標を保存しません。
        </li>
```

「更新日」の記載があれば 2026-09-10 に更新する。

- [ ] **Step 2: コミット**

```bash
git add web/privacy.html
git commit -m "docs(privacy): describe optional location use / プライバシーポリシーに位置情報の項を追加"
```

---

### Task 8: 実機確認（エミュレーター）

**Files:** なし（確認のみ）

- [ ] **Step 1: 起動**

```bash
cd ~/dev/app/reachtrail && flutter run -d emulator-5554
```
（Pixel_8 が起動していなければ `~/Library/Android/sdk/emulator/emulator -avd Pixel_8 &`）

- [ ] **Step 2: 擬似位置を流す**

```bash
adb -s emulator-5554 emu geo fix 139.7671 35.6812
```

- [ ] **Step 3: 4 点確認**

1. 基準地点タブ → 「現在地を使う」→ 権限ダイアログ →「アプリの使用中のみ許可」→ 地図が東京駅へ移動し SnackBar が出る → 名前を入れて保存できる。
2. 登録タブ → 起点「現在地」→ 「カレー」で検索 → 結果のタグが「現在地から N m」。
3. 権限を拒否した状態（`adb shell pm revoke net.riumu.reachtrail android.permission.ACCESS_FINE_LOCATION` の後、アプリ再起動）→ 「現在地を使う」→ バナーが出る。
4. 検索結果の「地図アプリで開く」→ Google マップが起動し目的地に店名が入る。

- [ ] **Step 4: 結果を記録**

確認結果を `docs/audit_2026-09-10_v6_gps_nav.md` に 4 行で残してコミット。

---

### Task 9: レビュー・マージ・版更新

- [ ] **Step 1: コードレビュー**

`superpowers:requesting-code-review` で spec に照らしてレビュー。指摘は修正してコミット。

- [ ] **Step 2: main へマージ**

```bash
git checkout main && git merge --no-ff feature/v6-gps-nav -m "Merge feature/v6-gps-nav: GPS and maps handoff / 現在地活用とナビ転送"
```

- [ ] **Step 3: 版更新**

`pubspec.yaml` の `version: 1.0.0+5` → `version: 1.0.0+6`。

```bash
git commit -am "chore(release): bump to 1.0.0+6 / 版6"
```

- [ ] **Step 4: リリースノート**

`release/release-notes-6.txt`（`release/` は git 管理外）:

```
版 6（1.0.0+6）
・検索結果と記録済みの店に「地図アプリで開く」を追加。Google マップなど端末の地図アプリにナビを渡せます。
・基準地点の設定で「現在地を使う」が選べるようになりました。
・店検索の起点を「基準地点」と「現在地」で切り替えられるようになりました。
・上記のため、位置情報の許可を求めることがあります（ボタンを押したときのみ。バックグラウンドでは使いません）。
```

- [ ] **Step 5: AAB ビルド（必ず main のチェックアウトで）**

```bash
cd ~/dev/app/reachtrail && flutter build appbundle --release
cp build/app/outputs/bundle/release/app-release.aab release/reachtrail-1.0.0+6.aab
unzip -p release/reachtrail-1.0.0+6.aab 'META-INF/*.RSA' | keytool -printcert | grep SHA1
```
Expected: SHA1 が `F7:41:9C:1E` で始まる（アップロード鍵）。`CC:93:E9:12` ならデバッグ鍵なので `android/key.properties` を確認する。

- [ ] **Step 6: push**

```bash
git push origin main
```

---

### Task 10: 公開（人手が必要な箇所を明示）

- [ ] **Step 1: privacy.html を VPS へ同期**

```bash
cd ~/dev/app/reachtrail && bash deploy/reachtrail/sync-web-to-vps.sh
curl -s https://reachtrail.riumu.net/privacy.html | grep -c '位置情報'
```
Expected: 1 以上

- [ ] **Step 2: Play Console データセーフティ更新（ブラウザ操作）**

アプリ → ポリシーとプログラム → アプリのコンテンツ → データセーフティ → 「位置情報」で「おおよその位置情報」「正確な位置情報」を収集にし、目的「アプリの機能」、共有先あり（Yahoo! JAPAN、店舗検索）、転送は暗号化、ユーザーが削除依頼可能。保存して送信。

- [ ] **Step 3: Alpha リリース作成**

クローズドテスト Alpha → 新しいリリースを作成 → リリースノートに `release-notes-6.txt` の内容 → **AAB はユーザーが手動でドロップ**（ブラウザツールの 10MB 上限） → 審査に送信。

- [ ] **Step 4: 審査通過後、テスターへ案内**

案内文（ユーザーが送る。送信先はユーザー判断）:

```
ReachTrail 版 6 を公開しました。Play ストアで「更新」を押してください。
新機能:
・検索結果や記録した店に「地図アプリで開く」ボタンが付き、Google マップ等にナビを渡せます
・基準地点の設定で「現在地を使う」が選べます
・店検索の起点を「基準地点／現在地」で切り替えられます
初めて現在地を使うときに位置情報の許可を求められます。「アプリの使用中のみ許可」で大丈夫です。
テスト期間中はアンインストールやテスターからの離脱をしないようお願いします。
```
