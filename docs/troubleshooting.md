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
