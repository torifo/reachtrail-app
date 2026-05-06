# ReachTrail API設定メモ

## 結論

MVP要件を満たすには、少なくとも店舗検索用の外部APIが必要です。
現時点のdocsでは、第1候補は Yahoo!ローカルサーチAPI です。

## 必須候補

### 1. 店舗検索API

- 用途: 店名検索、カテゴリ検索、基準地点周辺での絞り込み、候補選択
- docs上の第1候補: Yahoo!ローカルサーチAPI
- 期待する取得項目:
  - 店舗名
  - 緯度経度
  - 住所
  - 建物名
  - 階数ラベル
  - プロバイダ側の店舗ID
  - カテゴリ
- 実装上の注意:
  - 建物名や階数が必ず取れる前提ではない
  - 候補重複や誤同定がある前提で、候補選択UIと手入力補完を残す
  - 店舗候補が見つからない場合は、建物名・住所で再検索し、建物名と階数候補を記録画面へ引き継ぐ

## 将来候補

### 2. 検索プロバイダ追加

- 候補: Google Places
- 位置づけ: 将来拡張用
- 目的: Yahoo単独で検索精度が足りない場合の補完

他の候補:

- Foursquare Places API
  - 海外寄りだが店舗名解決は比較的強い
  - 建物名や階数の表現は Yahoo より弱い可能性がある
- Mapbox Search
  - 位置検索と住所正規化は強い
  - 飲食店データの粒度は地域差が大きい
- Google Places API
  - 店舗掲載の網羅性は高い
  - 料金と利用条件の整理が必要
  - 地図表示を Google に寄せる圧力が生まれやすい
- Gurunavi / Hotpepper 系 API
  - 飲食店情報の粒度は高い
  - 位置検索や建物名補完は別設計になりやすい

### 3. 地図表示API / SDK

- docsでは「地図UIは検索基盤と分離」とされている
- そのため、地図表示が必要になっても検索APIとは別に選定する
- MVPでは高度な地図演出は対象外

## 設定で決めるべき項目

### APIプロバイダ

- `PLACE_SEARCH_PROVIDER=yahoo`

### 認証情報

- `YAHOO_API_KEY=...`
- または `YAHOO_CLIENT_ID=...`
- `YAHOO_PROXY_BASE_URL=...`
- `API_BASE_URL=...`
- `GOOGLE_WEB_CLIENT_ID=...`
- `GOOGLE_MACOS_CLIENT_ID=...`

必要になった時点で、将来拡張として以下を追加:

- `GOOGLE_PLACES_API_KEY=...`

## 設定ファイル

ローカルでは `assets/config/.env` または `assets/config/.vars` に記載する。

`.env` 例:

```dotenv
PLACE_SEARCH_PROVIDER=yahoo
YAHOO_API_KEY=YOUR_YAHOO_CLIENT_ID
YAHOO_PROXY_BASE_URL=https://api.reachtrail.riumu.net/yahoo/localSearch
API_BASE_URL=https://api.reachtrail.riumu.net
GOOGLE_WEB_CLIENT_ID=823224608668-trbi6qgpsmsn2o8qika1bbf8o30ihqpd.apps.googleusercontent.com
GOOGLE_MACOS_CLIENT_ID=823224608668-9blagvtvvuoa728q195ma5jlpeq1308a.apps.googleusercontent.com
```

`.vars` 例:

```dotenv
PLACE_SEARCH_PROVIDER=mock
YAHOO_CLIENT_ID=
```

優先順位は `.env` -> `.vars` -> `--dart-define`。

## Flutter実行時の指定例

Mock検索:

```bash
flutter run --dart-define=PLACE_SEARCH_PROVIDER=mock
```

Yahoo検索:

```bash
flutter run \
  --dart-define=PLACE_SEARCH_PROVIDER=yahoo \
  --dart-define=YAHOO_API_KEY=YOUR_API_KEY \
  --dart-define=YAHOO_PROXY_BASE_URL=https://api.reachtrail.riumu.net/yahoo/localSearch \
  --dart-define=API_BASE_URL=https://api.reachtrail.riumu.net \
  --dart-define=GOOGLE_WEB_CLIENT_ID=823224608668-trbi6qgpsmsn2o8qika1bbf8o30ihqpd.apps.googleusercontent.com \
  --dart-define=GOOGLE_MACOS_CLIENT_ID=823224608668-9blagvtvvuoa728q195ma5jlpeq1308a.apps.googleusercontent.com
```

## 実装前に確認すべきこと

- Yahoo!ローカルサーチAPIで `buildingName` 相当がどこまで取れるか
- Yahoo!ローカルサーチAPIで `floorLabel` / `FloorName` 相当が安定して取れるか
- 周辺絞り込みの仕様で MVP の検索体験が成立するか
- 利用制限、レート制限、料金、商用利用条件
- APIレスポンスを `rawPayload` としてどこまで保存するか

## 現時点の判断

- MVPの「店舗検索」「候補選択」「階数補完」を成立させるため、外部APIは必要
- ただし、階数取得は不完全である可能性が高いため、手入力補完は必須
- Yahoo 単独では未収録店舗があるため、公開時点では「建物名と階数で補完する導線」を優先し、検索エンジンの追加は次段階とする
- 将来は Google Places を第1候補に比較検証し、コストと利用規約が許せば併用を検討する
- 地図表示APIはMVP必須とは読み取れない
