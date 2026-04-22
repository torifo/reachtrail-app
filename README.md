# ReachTrail

ReachTrail は、基準地点からランチ先までの距離と難易度を記録する Flutter MVP です。

## MVPでできること

- 基準地点を1件登録
- 基準地点は Yahoo 検索ベースで候補から設定
- 店舗検索
- 候補選択または手入力で店舗登録
- OpenStreetMap ベースの簡易マップで候補位置を比較
- レーダー風UIで基準地点から見た方向と距離を把握
- 階数ラベルと数値階の補完
- ランチ記録保存
- 実距離と難易度スコアの表示
- 自己ベストと履歴一覧

## 技術方針

- UI: Flutter
- 保存: `shared_preferences`
- 検索: `PLACE_SEARCH_PROVIDER` に応じて切替
- `mock`: 同梱サンプルデータを検索
- `yahoo`: Yahooローカル検索APIを使用
- 基準地点からの近傍検索は「片道徒歩1時間」を円形半径に換算して絞り込み
- 店舗候補が見つからない場合は、建物名と階数候補を使って手入力登録へ寄せる

## 設定ファイル

ローカル設定は `assets/config/.env` または `assets/config/.vars` に記載します。
優先順位は `.env` -> `.vars` -> `--dart-define` です。

```bash
cp assets/config/.env.example assets/config/.env
```

`.env` の例:

```dotenv
PLACE_SEARCH_PROVIDER=yahoo
YAHOO_API_KEY=YOUR_YAHOO_CLIENT_ID
YAHOO_PROXY_BASE_URL=https://api.reachtrail.riumu.net/yahoo/localSearch
API_BASE_URL=https://api.reachtrail.riumu.net
GOOGLE_WEB_CLIENT_ID=823224608668-trbi6qgpsmsn2o8qika1bbf8o30ihqpd.apps.googleusercontent.com
GOOGLE_MACOS_CLIENT_ID=823224608668-a9tomojqjsh6tsi39igs6i3kniah43oi.apps.googleusercontent.com
```

`.vars` の例:

```dotenv
PLACE_SEARCH_PROVIDER=mock
YAHOO_CLIENT_ID=
```

設定変更後は、アプリ内の「設定を再読込」か再起動で反映します。

## 起動方法

```bash
flutter pub get
flutter run
```

Mock検索を明示する場合:

```bash
flutter run --dart-define=PLACE_SEARCH_PROVIDER=mock
```

Yahoo API を使う場合:

```bash
flutter run \
  --dart-define=PLACE_SEARCH_PROVIDER=yahoo \
  --dart-define=YAHOO_API_KEY=YOUR_API_KEY \
  --dart-define=YAHOO_PROXY_BASE_URL=https://api.reachtrail.riumu.net/yahoo/localSearch \
  --dart-define=API_BASE_URL=https://api.reachtrail.riumu.net \
  --dart-define=GOOGLE_WEB_CLIENT_ID=823224608668-trbi6qgpsmsn2o8qika1bbf8o30ihqpd.apps.googleusercontent.com \
  --dart-define=GOOGLE_MACOS_CLIENT_ID=823224608668-a9tomojqjsh6tsi39igs6i3kniah43oi.apps.googleusercontent.com
```

## VPS公開メモ

本番公開は `riumu.net` 配下の ReachTrail 専用サブドメインを前提にします。

- Web: `app.reachtrail.riumu.net`
- API: `api.reachtrail.riumu.net`
- macOS 配布: `download.reachtrail.riumu.net`

この VPS はホスト `nginx` ではなく Docker 上の `nginxproxy/nginx-proxy` と
`nginxproxy/acme-companion` で 80/443 を受ける構成です。
そのため ReachTrail も Docker コンテナを `global-proxy-network` に参加させて公開します。

配備用の雛形は [deploy/README.md](/Users/akito-shoji/dev/app/reachtrail/deploy/README.md) と
[deploy/reachtrail/compose.yml](/Users/akito-shoji/dev/app/reachtrail/deploy/reachtrail/compose.yml)
にまとめています。

`macOS` 配布手順は [docs/macos_distribution.md](/Users/akito-shoji/dev/app/reachtrail/docs/macos_distribution.md) にまとめています。

## Googleログイン

現時点では `web` と `macOS` で Google ログインを有効化しています。
メール認証はまだ未実装です。

- Web client ID:
  `823224608668-trbi6qgpsmsn2o8qika1bbf8o30ihqpd.apps.googleusercontent.com`
- macOS client ID:
  `823224608668-a9tomojqjsh6tsi39igs6i3kniah43oi.apps.googleusercontent.com`

`web` では Google Cloud 側の `Authorized JavaScript origins` に
`https://app.reachtrail.riumu.net` を登録済みである必要があります。

## 補足

- Yahoo API は公式レスポンスの `Property.PlaceInfo.FloorName`、`Property.Building.Name`、`Property.Building.Floor`、`Property.Genre[].Name` を優先して解釈します。
- 近傍検索の円半径は、徒歩速度 `5.0 km/h` と片道 `60分` を前提に `5km` で計算しています。
- Yahoo API から建物名や階数が安定取得できない場合でも、手入力で記録を完結できます。
- 店舗名で見つからない場合は、登録画面から建物名や住所で建物候補を検索し、建物名・座標・階数候補を引き継いで記録できます。
- 保存済み記録は履歴画面から編集して再保存できます。
- 難易度スコアは `scoreVersion` 付きで保存しており、将来の再計算に備えています。
- MVPでは実距離として2点間の直線距離を採用しています。
