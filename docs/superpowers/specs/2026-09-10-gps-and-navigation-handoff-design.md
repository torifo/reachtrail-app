# 位置情報（GPS）活用とナビ転送 — 設計

## 概要

テスターからの要望 2 点を版 1.0.0+6 として実装する。

1. **ナビ転送**: 店を検索・記録したあと、その店へのナビを端末の地図アプリ（Google マップ／Apple マップなど）に渡せるようにする。
2. **GPS の活用**: 端末の位置情報を、(a) 初回の基準地点設定の補助、(b) 店検索の起点の切り替え（基準地点／現在地）に使う。

基準地点の概念はそのまま維持する。記録の徒歩距離・スコアは従来どおり基準地点から計算し、現在地は「検索の起点」と「基準地点を作るときの座標候補」にだけ使う。

## スコープ

| 項目 | 対象コード |
|------|-----------|
| LocationService（geolocator ラッパー）と Controller への注入 | `lib/services/location_service.dart`（新規）、`lib/app.dart` |
| 基準地点タブ「現在地を使う」 | `lib/app.dart` `_BaseLocationTab` |
| 店検索タブの起点切り替え | `lib/app.dart` `_RegisterTab`、`lib/services/place_search_service.dart` |
| ナビ転送ボタン | `lib/app.dart` `_PlaceResultTile`、`_MyMapView` のマーカー、`lib/services/map_handoff.dart`（新規） |
| 権限・依存 | `pubspec.yaml`、`AndroidManifest.xml`、`ios/Runner/Info.plist` |
| ストア申告・ポリシー | `web/privacy.html`、Play Console データセーフティ |
| テスト | `test/location_service_test.dart`、`test/map_handoff_test.dart`、既存 `reachtrail_logic_test.dart` の拡張 |

スコープ外: バックグラウンド位置情報、地図上の現在地の常時表示、逆ジオコーディング（現在地から住所文字列を作る）、API サーバーの変更（プロキシは lat/lon を素通しするため不要）。

## 現状（2026-09-10 時点）

- 権限は INTERNET のみ。`geolocator` `url_launcher` は未導入。
- 基準地点は Yahoo 検索候補／住所手入力／地図タップで設定し、shared_preferences の `base_location` にだけ保存（`persistence_service.dart`）。
- 店検索は常に基準地点を中心に Yahoo ローカル検索へ問い合わせる（`buildYahooSearchParams` は `BaseLocation?` を受け取る）。プロキシ `/yahoo/localSearch` はクエリを素通しする。
- 外部アプリを開く箇所は存在しない。

## 1. LocationService

```dart
enum LocationFailure { serviceDisabled, denied, deniedForever, timeout, unknown }

class LocationResult { final double? lat; final double? lng; final LocationFailure? failure; }

abstract class LocationService {
  /// 1 回だけ現在地を取得する。権限が未決定なら OS のダイアログを出す。
  Future<LocationResult> getCurrentPosition({Duration timeout = const Duration(seconds: 15)});
}

class GeolocatorLocationService implements LocationService { ... }
```

- 実装は `geolocator` を使う。`isLocationServiceEnabled` → `checkPermission` → 必要なら `requestPermission` → `getCurrentPosition(accuracy: high, timeLimit: timeout)` の順。
- 権限を求めるのは **ユーザーがボタンを押したときだけ**。起動時には求めない。
- `ReachTrailController` に `LocationService` をコンストラクタ注入する（`PlaceSearchService` `PersistenceService` と同じ形）。テストではスタブに差し替える。
- 失敗の文言（`describeLocationFailure`）:
  - serviceDisabled: 「端末の位置情報がオフです。設定でオンにするか、地図をタップして指定してください」
  - denied / deniedForever: 「位置情報の利用が許可されていません。端末の設定で ReachTrail に位置情報を許可すると使えます」
  - timeout / unknown: 「現在地を取得できませんでした。しばらくしてからもう一度お試しください」
- deniedForever のときは `Geolocator.openAppSettings()` を呼ぶ「設定を開く」ボタンを案内バナーに付ける。

## 2. 基準地点タブ「現在地を使う」

- 「住所を手入力で使う」ボタンの隣に `OutlinedButton.icon(Icons.my_location, '現在地を使う')` を置く。
- 押下 → `controller.locateCurrentPosition()` → 成功したら既存の `_selectBasePoint(LatLng)` を呼ぶ。地図タップと同じ経路なので、候補との不一致タグ（`地図で指定した位置（候補とは別）`）や保存の検証はそのまま効く。ピッカー地図はその座標へ移動する。
- 名前・住所は従来どおり手入力。名前が空なら保存時の既存バリデーションで止まる（変更なし）。
- 取得中はボタンをスピナー付きの無効状態にする（二重押し防止。既存の二重送信ガードの方針に合わせる）。
- 失敗は既存の `_NoticeBanner` 形式で表示する。エラー扱い（赤）にはしない。

## 3. 店検索タブの起点切り替え

- 検索欄の直下に `SegmentedButton<SearchOrigin>`（`基準地点` / `現在地`）を置く。既定は `基準地点`。基準地点が未設定のときは `現在地` だけ有効にし、これまで無効だった検索ボタンを現在地起点なら押せるようにする。
- `現在地` を選んで検索すると、**検索のたびに 1 回** 現在地を取得してから Yahoo に問い合わせる（キャッシュしない。移動後の再検索で古い座標を使わないため）。
- 「片道徒歩 45 分圏内で絞り込む」スイッチのラベルは起点に応じて「基準地点から」「現在地から」に変える。半径 `dist` も起点に対して適用する。
- パラメータ組み立ては `buildYahooSearchParams` の引数を `BaseLocation?` から `SearchOrigin`（lat/lng を持つ小さな値オブジェクト）に一般化する。`ReachTrailController.searchPlaces(query, nearbyOnly:, origin:)` の `origin` は `SearchOriginKind.base | current`。
- 結果タイルの「基準地点から N m」タグは、現在地起点のときは「現在地から N m」にする。距離計算はタイル側で起点座標を受け取って行う。
- 記録（`RecordSheet`）の徒歩距離・スコアは基準地点から計算する（変更なし）。現在地起点で見つけた店を記録する場合も同じ。基準地点が未設定で現在地起点で検索した場合、記録ボタンは従来どおり「基準地点を先に設定」の案内にする。
- 位置取得に失敗したら検索は実行せず、案内バナーを出す（起点を基準地点に戻すことも提案）。

## 4. ナビ転送

`lib/services/map_handoff.dart`（純粋関数 + 起動関数）:

```dart
Uri buildMapHandoffUri({required double lat, required double lng, required String label, required TargetPlatform platform});
Future<bool> openInMapsApp(...);  // url_launcher の launchUrl(mode: externalApplication)
```

- **Android**: `geo:0,0?q=lat,lng(ラベル)`。OS が対応アプリの選択シートを出す（Google マップ・Yahoo マップ・その他）。単一アプリしか無ければそれが開く。`<queries>` の追加は不要（`launchUrl` は `canLaunchUrl` を経由せず直接起動する）。
- **iOS**: `https://maps.apple.com/?daddr=lat,lng&q=ラベル`。Apple マップが開く。Google マップを候補に加えるのは今回は見送り（`LSApplicationQueriesSchemes` の追加が必要になるため）。
- **Web／デスクトップ**: `https://www.google.com/maps/dir/?api=1&destination=lat,lng` を新しいタブで開く。
- ラベルは店名。URL エンコードする。
- 起動に失敗した場合は SnackBar「地図アプリを開けませんでした」。
- 置き場所:
  1. `_PlaceResultTile` の操作行（「この候補で記録」の左）に `OutlinedButton.icon(Icons.directions, '地図アプリで開く')`。
  2. マイマップ（`_MyMapView`）のマーカーをタップしたときの吹き出し／詳細に同じボタン。記録済みの店へ実際に向かうときに使う想定。
- 検索結果タイルの操作行が狭い端末で折り返す場合は `Wrap` にする（大フォント対応の既存方針）。

## 5. 権限・依存・ストア申告

- `pubspec.yaml`: `geolocator`（最新安定）、`url_launcher`（最新安定）を追加。
- `AndroidManifest.xml`: `ACCESS_FINE_LOCATION` と `ACCESS_COARSE_LOCATION` を追加。バックグラウンド位置情報は追加しない（Play の権限申告フォームの対象外）。
- `Info.plist`: `NSLocationWhenInUseUsageDescription` = 「現在地を基準地点の候補と店検索の起点として使うためです。バックグラウンドでは使いません。」
- `web/privacy.html`: 「位置情報」の項を追加。取得はユーザー操作時のみ、用途は基準地点の候補と店検索の起点、座標は店検索のために ReachTrail API を経由して Yahoo! JAPAN に送信、端末外に保存しない、基準地点として保存した座標は端末内にのみ保存。
- Play Console データセーフティ: 「位置情報（おおよその位置／正確な位置）」を「収集」に変更、共有先として Yahoo! JAPAN（店検索）を申告、暗号化転送あり、ユーザーが削除依頼可能（基準地点の削除・アカウント削除）。**版 6 の審査送信前に更新する。**
- 版番号: `1.0.0+6`。

## 6. エラー処理まとめ

| 状況 | 挙動 |
|------|------|
| 位置情報サービスがオフ | バナーで案内、既存の手入力／地図タップに誘導 |
| 権限拒否（今回のみ） | バナーで案内。次回ボタン押下で再度ダイアログ |
| 権限拒否（今後表示しない） | バナー＋「設定を開く」 |
| 取得タイムアウト（15 秒） | バナーで再試行を案内。検索は実行しない |
| 地図アプリなし／起動失敗 | SnackBar |
| 現在地起点で基準地点なし | 検索は可能。記録は「基準地点を先に設定」の既存案内 |

## 7. テスト

- `test/location_service_test.dart`: `LocationResult` と `describeLocationFailure` の対応表。
- `test/map_handoff_test.dart`: 3 プラットフォームの URI 組み立て（エンコード、負の座標、空ラベル）。
- `test/reachtrail_logic_test.dart`: `buildYahooSearchParams` が `SearchOrigin` で lat/lon/dist を出すこと、起点なしでは出さないことを既存ケースに追加。
- `test/reachtrail_hardening_test.dart`: スタブ `LocationService` で「成功→`_selectBasePoint` 相当の座標が Controller に入る」「失敗→`locationNotice` が立ち検索が走らない」。
- ウィジェットテスト（`home_shell_test.dart` 程度の粒度）: 起点セグメントの切り替えでスイッチのラベルが変わること。
- 実機確認: エミュレーター Pixel_8 で `adb emu geo fix <lng> <lat>` を流し、(1) 基準地点タブで現在地を使う→保存、(2) 現在地起点で検索→結果の距離表示、(3) 権限拒否→バナー、(4) 「地図アプリで開く」→ Google マップ起動、の 4 点。

## 8. 公開手順

1. main で実装・テスト・レビュー → `1.0.0+6` にバンプ。
2. `web/privacy.html` を VPS へ同期（`deploy/reachtrail/sync-web-to-vps.sh`）。
3. Play Console データセーフティを更新して保存。
4. main で `flutter build appbundle` → `release/reachtrail-1.0.0+6.aab`（`keytool -printcert` で SHA1 F7:41:9C:1E… を確認）→ `release/release-notes-6.txt`。
5. Alpha にリリース作成（ノート入力）→ AAB は手動アップロード → 審査送信。
6. 審査通過後、テスターへ更新案内（内容: 新機能 2 点、位置情報の許可ダイアログが出る旨、Play ストアで更新する手順）。

## 決定事項の記録

- GPS は初回設定の補助と検索起点の切り替えに使い、基準地点の概念は維持（ユーザー決定 2026-09-10）。
- ナビ転送は OS の選択シートに任せる。アプリ内で地図アプリを選ばせない（同上）。
- 位置情報の許可はボタン押下時にのみ求める（同上）。
