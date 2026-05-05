# ReachTrail

ReachTrail は、基準地点からランチ先までの距離と難易度を記録する Flutter MVP です。
Web は MVP として問題なく利用できる状態です。
macOS はダウンロードして使える状態です。
Android はテスターを募っており、公開準備中です。

現在の公開先:

- Web: `https://app.reachtrail.riumu.net`
- API: `https://api.reachtrail.riumu.net`
- macOS 配布: `https://download.reachtrail.riumu.net`
- Android: テスターを募集中

## MVPでできること

- 基準地点を 1 件登録
- 基準地点は Yahoo 検索ベースで候補から設定
- 飲食店検索
- 候補選択または手入力で店舗登録
- 店舗が見つからない場合の建物名・住所ベース補完
- OpenStreetMap ベースの簡易マップで候補位置を比較
- レーダー風 UI で基準地点から見た方向と距離を把握
- Google ログイン
- 階数ラベルと数値階の補完
- 直線距離、任意の実移動距離、縦移動情報の記録
- ランチ記録保存
- 実距離と難易度スコアの表示
- 自己ベストと履歴一覧

## 更新予告

次回以降の Web 更新では、テスターからのフィードバックを受けながら次の改善を反映予定です。

- 記録モーダルで、保存に必要な項目を明確化
- 候補から記録する場合の入力コストを削減
- メニュー、価格、支払い方法、メモなどの任意項目を後から追記しやすい構成に整理
- ランキング対象をユーザーではなくお店として扱う共有ビューを追加
- お店単位の集計を、レーダー形式と OpenStreetMap を組み合わせた共有地図で可視化
- 共有データ基盤へ接続する前段階として、現在の記録データをお店単位に集約して表示

## 技術方針

- UI: Flutter
- 保存: `shared_preferences`
- 認証: Google ログイン
- 検索: `PLACE_SEARCH_PROVIDER` に応じて切替
- `mock`: 同梱サンプルデータを検索
- `yahoo`: Yahoo ローカル検索 API を使用
- 基準地点からの近傍検索は「片道徒歩 45 分」を円形半径に換算して絞り込み
- 近傍検索で 0 件なら、Yahoo は距離制限なしで広域再検索する
- 同一店の候補が重複した場合は、階数情報を持つ候補を優先する
- 店舗候補が見つからない場合は、建物名と階数候補を使って手入力登録へ寄せる

## 設定ファイル

ローカル設定は `assets/config/.env` または `assets/config/.vars` に記載できます。
非 `web` では優先順位は `.env` -> `.vars` -> `--dart-define` です。
`web` はアセット設定を読まず、`--dart-define` を使います。

```bash
cp assets/config/.env.example assets/config/.env
```

`.env` の例:

```dotenv
PLACE_SEARCH_PROVIDER=yahoo
YAHOO_API_KEY=YOUR_YAHOO_API_KEY
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

Mock 検索を明示する場合:

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

`web` のローカル確認例:

```bash
flutter run -d web-server \
  --web-hostname localhost \
  --web-port 3000 \
  --dart-define=PLACE_SEARCH_PROVIDER=yahoo \
  --dart-define=YAHOO_PROXY_BASE_URL=https://api.reachtrail.riumu.net/yahoo/localSearch \
  --dart-define=API_BASE_URL=https://api.reachtrail.riumu.net \
  --dart-define=GOOGLE_WEB_CLIENT_ID=823224608668-trbi6qgpsmsn2o8qika1bbf8o30ihqpd.apps.googleusercontent.com \
  --dart-define=GOOGLE_MACOS_CLIENT_ID=823224608668-a9tomojqjsh6tsi39igs6i3kniah43oi.apps.googleusercontent.com
```

`macOS` のローカル確認例:

```bash
flutter run -d macos \
  --dart-define=PLACE_SEARCH_PROVIDER=yahoo \
  --dart-define=YAHOO_PROXY_BASE_URL=https://api.reachtrail.riumu.net/yahoo/localSearch \
  --dart-define=API_BASE_URL=https://api.reachtrail.riumu.net \
  --dart-define=GOOGLE_WEB_CLIENT_ID=823224608668-trbi6qgpsmsn2o8qika1bbf8o30ihqpd.apps.googleusercontent.com \
  --dart-define=GOOGLE_MACOS_CLIENT_ID=823224608668-a9tomojqjsh6tsi39igs6i3kniah43oi.apps.googleusercontent.com
```

## Google ログイン

現時点では `web`、`Android`、`macOS` で Google ログインを有効化しています。
メール認証はまだ未実装です。

- Web client ID:
  `823224608668-trbi6qgpsmsn2o8qika1bbf8o30ihqpd.apps.googleusercontent.com`
- Android は上記の Web client ID を `serverClientId` として利用します。
- macOS client ID:
  `823224608668-a9tomojqjsh6tsi39igs6i3kniah43oi.apps.googleusercontent.com`

`google-services.json` は不要です。

`web` では Google Cloud 側の `Authorized JavaScript origins` に
`https://app.reachtrail.riumu.net` を登録済みである必要があります。
ローカル確認も行う場合は `http://localhost:3000` も追加します。

## 補足

- Yahoo API は公式レスポンスの `Property.PlaceInfo.FloorName`、`Property.Building.Name`、`Property.Building.Floor`、`Property.Genre[].Name` を優先して解釈します。
- 近傍検索の円半径は、徒歩速度 `5.0 km/h` と片道 `45 分` を前提に `3.75km` で計算しています。
- Yahoo API から建物名や階数が安定取得できない場合でも、手入力で記録を完結できます。
- 店舗名で見つからない場合は、登録画面から建物名や住所で建物候補を検索し、建物名・座標・階数候補を引き継いで記録できます。
- 基準地点側は `拠点フロア` と `出入口フロア`、店舗側は `目的フロア` と `入口フロア` を任意で持てます。
- エレベータ有無と `エレベータ乗車回数` は任意入力で、詳細に入れるほど記録精度が上がります。
- 保存済み記録は履歴画面から編集して再保存できます。
- 難易度スコアは `scoreVersion` 付きで保存しており、将来の再計算に備えています。
- MVP では直線距離を自動計算し、実際に近い移動距離は任意入力で補完できます。
