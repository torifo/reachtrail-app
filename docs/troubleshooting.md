# トラブルシューティング

## macOS でYahoo検索が動かない（検索結果が出ない）

**症状:** 基準地点検索や飲食店検索でキーワードを入力して検索しても結果が返らない。`Mock Search` と表示されていないのに結果がモックデータになる。

**原因:** macOS アプリはサンドボックス環境で動作するため、外部ネットワークへのアクセスには entitlements の明示的な許可が必要。`com.apple.security.network.client` がない場合、Yahoo API への HTTP リクエストがブロックされる。例外はコード内でキャッチされてモックデータにサイレントフォールバックするため、エラーメッセージが表示されずに気づきにくい。

**対処:** 以下のファイルに `com.apple.security.network.client` を追加する。

`macos/Runner/DebugProfile.entitlements`:
```xml
<key>com.apple.security.network.client</key>
<true/>
```

`macos/Runner/Release.entitlements`:
```xml
<key>com.apple.security.network.client</key>
<true/>
```

追加後、`flutter run` で再起動する。

## Web で Google ログイン時に FedCM / COOP の警告が出る

**症状:** ブラウザの console に次のような警告が出る。

- `FedCM get() rejects with AbortError`
- `Cross-Origin-Opener-Policy policy would block the window.postMessage call.`
- `The request has been aborted.`

**原因:** Google Identity Services の Web ログインは、FedCM への移行過程で One Tap や popup 周辺の警告を出すことがある。特に `google_sign_in_web` の描画ボタンを使う場合、ログイン自体が成功していても console に警告が残ることがある。

**判断基準:** 次が満たされていれば、現時点では重大障害ではない。

- Google ログインが完了する
- `POST /auth/google` が `200` を返す
- アプリ画面へ遷移できる

**補足:** 公開版では通常のサインイン導線を優先し、FedCM まわりの警告は既知の制約として扱う。完全に抑え込む場合は、Google Identity Services の FedCM 対応状況に合わせて実装方式を再検討する。
