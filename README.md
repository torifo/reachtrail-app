# ReachTrail

ReachTrail は、基準地点からランチ先までの距離と難易度を記録する Flutter MVP です。

## MVPでできること

- 基準地点を1件登録
- 店舗検索
- 候補選択または手入力で店舗登録
- 階数ラベルと数値階の補完
- ランチ記録保存
- 実距離と難易度スコアの表示
- 自己ベストと履歴一覧

## 技術方針

- UI: Flutter
- 保存: `shared_preferences`
- 検索: `PLACE_SEARCH_PROVIDER` に応じて切替
  - `mock`: 同梱サンプルデータを検索
  - `yahoo`: Yahooローカル検索APIを使用し、失敗時は `mock` にフォールバック

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
  --dart-define=YAHOO_API_KEY=YOUR_API_KEY
```

## 補足

- Yahoo API から建物名や階数が安定取得できない場合でも、手入力で記録を完結できます。
- 難易度スコアは `scoreVersion` 付きで保存しており、将来の再計算に備えています。
- MVPでは実距離として2点間の直線距離を採用しています。
