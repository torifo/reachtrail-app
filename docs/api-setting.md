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

## 将来候補

### 2. 検索プロバイダ追加

- 候補: Google Places
- 位置づけ: 将来拡張用
- 目的: Yahoo単独で検索精度が足りない場合の補完

### 3. 地図表示API / SDK

- docsでは「地図UIは検索基盤と分離」とされている
- そのため、地図表示が必要になっても検索APIとは別に選定する
- MVPでは高度な地図演出は対象外

## 設定で決めるべき項目

### APIプロバイダ

- `PLACE_SEARCH_PROVIDER=yahoo`

### 認証情報

- `YAHOO_API_KEY=...`

必要になった時点で、将来拡張として以下を追加:

- `GOOGLE_PLACES_API_KEY=...`

## Flutter実行時の指定例

Mock検索:

```bash
flutter run --dart-define=PLACE_SEARCH_PROVIDER=mock
```

Yahoo検索:

```bash
flutter run \
  --dart-define=PLACE_SEARCH_PROVIDER=yahoo \
  --dart-define=YAHOO_API_KEY=YOUR_API_KEY
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
- 地図表示APIはMVP必須とは読み取れない
