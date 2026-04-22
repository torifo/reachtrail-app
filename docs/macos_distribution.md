# macOS 配布手順

ReachTrail の `macOS` 版は、VPS でビルドせず、ローカル Mac 上で署名付きビルドと配布物作成を行います。

一般公開で Chrome や Finder から警告なく開かせるには、`Personal Team` 署名だけでは不足です。
`Developer ID Application` 署名と notarization が必要です。

## 前提

- Xcode で `macos/Runner.xcworkspace` を開けること
- `Runner > Signing & Capabilities` で Team が設定されていること
- Google ログイン用の entitlements が有効なため、未署名ビルドでは配布用 bundle を作れない

## 1. 署名付き release build

```bash
flutter build macos --release \
  --dart-define=PLACE_SEARCH_PROVIDER=yahoo \
  --dart-define=YAHOO_PROXY_BASE_URL=https://api.reachtrail.riumu.net/yahoo/localSearch \
  --dart-define=API_BASE_URL=https://api.reachtrail.riumu.net \
  --dart-define=GOOGLE_WEB_CLIENT_ID=823224608668-trbi6qgpsmsn2o8qika1bbf8o30ihqpd.apps.googleusercontent.com \
  --dart-define=GOOGLE_MACOS_CLIENT_ID=823224608668-a9tomojqjsh6tsi39igs6i3kniah43oi.apps.googleusercontent.com
```

この段階で理想なのは `Developer ID Application` 署名です。
`Personal Team` 署名でもローカル実行はできますが、ダウンロード配布では Gatekeeper 警告が強く残ります。

## 2. 配布用 zip を作成

```bash
./deploy/reachtrail/package-macos.sh
```

生成物:

- `build/macos-dist/reachtrail-macos.zip`
- `build/macos-dist/index.html`

## 3. notarization

事前に App Store Connect の API key か Apple ID ベースの notary 認証情報を
`xcrun notarytool store-credentials` で Keychain に保存しておきます。

```bash
./deploy/reachtrail/notarize-macos.sh
```

`Developer ID Application` 署名と notarization が通っていない zip は、
Chrome や Finder 経由の一般配布で「開けない」状態になりやすいです。

## 4. VPS の download 配下へ同期

```bash
./deploy/reachtrail/sync-download-to-vps.sh
```

同期先:

- `download.reachtrail.riumu.net`
- VPS 上の配置先は `/home/ubuntu/app/reachtrail/download/`

## 5. 公開確認

- `https://download.reachtrail.riumu.net/reachtrail-macos.zip`
- アプリ起動後に Google ログインできること
- Yahoo 検索と `api.reachtrail.riumu.net/auth/google` が通ること

## 補足

- `.dmg` 化は将来対応でよく、MVP では `zip` 配布で十分
- ただし `zip` でも一般公開配布には notarization が必要
- VPS では `macOS` ビルドを行わない
