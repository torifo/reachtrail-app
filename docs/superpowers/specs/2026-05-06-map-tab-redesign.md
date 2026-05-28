# Map タブ再設計 — マイマップ＋近くの共有

## 概要

「Shared」タブを「Map」にリネームし、2 つのビューを切り替えられるタブに刷新する。
- **マイマップ**: 現在の基準値で記録されたお店をマップ＋レーダーで表示（ローカルデータのみ）
- **近くの共有**: 選択した基準値から徒歩15分圏内（≈1,200m）に基準値を持つ他ユーザーのお店を表示

## スコープ

| フェーズ | 内容 | 対象コード |
|--------|------|-----------|
| Phase 1 | タブリネーム＋マイマップ実装 | `lib/app.dart`（フロントのみ） |
| Phase 2 | 近くの共有 | `lib/app.dart` ＋ `api/` バックエンド |

**注意**: 現在バックエンドに記録共有エンドポイントが存在しないため、Phase 2 は別スプリントとして扱う。

---

## 現在の実装状況

| 項目 | 状態 | 補足 |
|------|------|------|
| Shared -> Map のタブリネーム | 完了 | Desktop `NavigationRail` / Mobile `NavigationBar` の両方に反映 |
| Map ナビゲーションアイコン | 完了 | `Icons.map_outlined` / `Icons.map` を使用 |
| `_SharedPlacesTab` -> `_MapTab` | 完了 | `_MapMode { myMap, nearby }` で表示切替 |
| マイマップ | 完了 | 現在の基準値 ID に紐づくローカル記録だけを表示 |
| 基準値未設定時の案内 | 完了 | トグル・マップは表示しない |
| 近くの共有 | Phase 1 placeholder まで完了 | 実データ取得は Phase 2 で対応 |
| 本番反映 | 完了 | Web / macOS 配布物へ反映済み |

Phase 2 はまだ実装しない。

## Phase 1 — タブリネーム＋マイマップ

**状態: 完了**

### ナビゲーション変更

`NavigationRailDestination` と `NavigationDestination` の両方で `Shared` → `Map` に変更。

アイコンは視認性のため、`Icons.map_outlined` / `Icons.map` を使用する。

### `_SharedPlacesTab` → `_MapTab` リファクタリング

既存の `_SharedPlacesTab` を `_MapTab` にリネームし、内部に `_MapMode` 列挙型でビュー切り替えを管理する。

```
enum _MapMode { myMap, nearby }
```

State は `_MapMode _mode = _MapMode.myMap`（初期値: マイマップ）と既存の `_selectedPlaceId`、`_mapController` を持つ。

### 画面構成

```
Map タブ
├── 基準値バナー（現在の基準値名を表示、選択UIは持たない）
├── カード型切替 [マイマップ | 近くの共有]
└── IndexedStack（mode に応じて切り替え）
    ├── マイマップビュー（_MyMapView）
    └── 近くの共有ビュー（_NearbySharedView）
```

**基準値バナー**: 基準値が未設定の場合「先に「Base」タブで基準値を設定してください」と表示し、トグル・マップ非表示。

**カード型切替**: `SegmentedButton` では選択状態が分かりにくかったため、`_MapModeSelector` / `_MapModeTab` に分離したカード型 UI を使用する。
選択中は `Icons.check_circle`、濃い枠線、淡い背景、影で状態を明示する。

### `_MyMapView`

データソース: `controller.records.where((r) => r.baseLocationId == controller.baseLocation?.id)`

- 空の場合: 「この基準値でまだお店が記録されていません。「Register」タブから追加してください。」
- データありの場合: 現行 `_SharedPlaceMapOverview`（マップ＋レーダー）＋ `_SharedPlaceRankTile` リストを流用

既存の `_buildSharedPlaceEntries` を `_buildMapEntries(ReachTrailController, String baseLocationId)` に変更し、`baseLocationId` 引数でフィルタリングを追加する。

### `_NearbySharedView` — Phase 1 プレースホルダー

Phase 2 まではプレースホルダーを表示：

```
近くの共有は準備中です。
同じエリアで働く人のお店情報を、基準値から15分圏内でまとめて表示します。
```

---

## Phase 2 — 近くの共有（バックエンド＋フロント）

**状態: 未着手。現時点では実装しない。**

Phase 2 の残作業は以下。

- 共有レコードの匿名化データモデルを `api/` に追加する
- `POST /records/sync` を追加する
- `GET /places/nearby?lat=X&lng=Y&radius=1200` を追加する
- `sessionToken` 認証で userId を特定する
- フロントに `PlaceSyncService` を追加する
- 記録保存後に fire-and-forget で同期する
- `_NearbySharedView` を実データ取得 UI に差し替える
- 近くの共有の空状態、エラー、再試行、ローディングを実装する

### バックエンド変更 (`api/`)

#### 新規データモデル

`ReachTrailSharedRecord`: ユーザーが記録したお店を匿名化して保存する。

```
{
  "userId": "...",              // ユーザーID（匿名識別用）
  "baseLat": 35.6813,          // 基準値の緯度
  "baseLng": 139.7671,         // 基準値の経度
  "placeId": "...",            // お店ID（providerPlaceId）
  "placeSnapshot": { ... },    // Place の JSON スナップショット
  "visitCount": 3,             // 訪問回数
  "averageDifficulty": 82.5,   // 平均難易度
  "bestRouteDistanceMeters": 450.0,
  "updatedAt": "2026-05-06T..."
}
```

永続化: `data/shared-records.json`（既存の userStore と同様の JSON ファイル方式）

#### 新規エンドポイント

**`POST /records/sync`** — 認証必須（Authorization: Bearer `sessionToken`）

リクエスト: 現在の基準値（lat/lng）＋全記録（`_SharedPlaceEntry` 形式の配列）を送信。サーバー側で既存エントリを上書き（userId ＋ placeId でユニーク）。

**`GET /places/nearby?lat=X&lng=Y&radius=1200`** — 認証必須

レスポンス: 指定座標から radius メートル以内に baseLat/baseLng を持つ全ユーザーの `SharedRecord` 配列（自分自身のレコードは除外）。

フィルタリング: `calculateDistanceMeters(baseLat, baseLng, queryLat, queryLng) <= radius` をサーバー側で計算。

#### 認証

`sessionToken` を Authorization ヘッダで受け取り、既存の `SessionTokenIssuer` の検証ロジックを使用して userId を取得。

### フロント変更 (`lib/`)

#### `PlaceSyncService`（新規サービス）

```
class PlaceSyncService {
  Future<void> syncRecords(String sessionToken, BaseLocation base, List<DineChallengeRecord> records);
  Future<List<SharedPlaceEntry>> fetchNearby(String sessionToken, double lat, double lng, {double radiusMeters = 1200});
}
```

`syncRecords` は記録保存後（`saveRecord` の後）に非同期で呼ぶ（失敗しても記録保存は完了とする）。

#### `_NearbySharedView`（Phase 2 実装）

- 初回表示時に `fetchNearby` を呼び出し
- ローディング中: CircularProgressIndicator
- エラー: 「近くの共有データを取得できませんでした。」＋再試行ボタン
- データなし: 「この基準値から15分圏内に記録したユーザーはまだいません。」
- データあり: `_CandidateMap` ＋ランキングリスト（`_SharedPlaceEntry` を流用）

---

## 文言（production copy）

| 箇所 | テキスト |
|------|--------|
| タブラベル | Map |
| トグル左 | マイマップ |
| トグル右 | 近くの共有 |
| マイマップ サブタイトル | 現在の基準値で記録したお店をマップで振り返ります。 |
| 近くの共有 サブタイトル | 基準値から徒歩15分圏内に登録したユーザーのお店をまとめて表示します。 |
| 基準値未設定 | 先に「Base」タブで基準値を設定してください。 |
| マイマップ 空状態 | この基準値でまだお店が記録されていません。「Register」タブから追加してください。 |
| 近くの共有 Phase 1 placeholder | 近くの共有は準備中です。同じエリアで働く人のお店情報を、基準値から15分圏内でまとめて表示します。 |
| 近くの共有 データなし | この基準値から15分圏内に記録したユーザーはまだいません。 |

---

## 実装しないこと

- 複数基準値の選択UI（現在1基準値のみ保存のため。将来拡張で対応）
- お店の詳細画面への遷移（既存実装に合わせる）
- 近くの共有の push 通知

---

## 定数

- 近くの共有 検索半径: `1200` m（徒歩80m/分 × 15分）
- データ同期タイミング: 記録保存後に fire-and-forget
