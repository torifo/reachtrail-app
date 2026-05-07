# Windows 配布手順

ReachTrail の Windows 版はローカル Windows PC 上でビルドします。
macOS からのクロスコンパイルはできません。

---

## 必要な値・ファイル一覧

| 項目 | 状態 | 補足 |
|------|------|------|
| `windows/` プラットフォームディレクトリ | ✅ リポジトリ済み | `flutter create --platforms=windows` で生成済み |
| `deploy/reachtrail/build-windows.ps1` | ✅ リポジトリ済み | リリース zip 作成スクリプト |
| Google Sign-in（Windows）| ⚠️ 未対応 | `google_sign_in` は Windows 非対応。別途実装が必要（下記参照） |

---

## Google Sign-in の Windows 対応について

`google_sign_in ^7.2.0` は Android / iOS / macOS / Web のみ対応しており、Windows はサポートされていません。
`google_sign_in_windows` パッケージも存在しません。

現時点の挙動: ログイン画面で「Google client ID is not configured for this platform.」と表示されます。

**将来の実装候補:**
- `desktop_webview_auth ^0.0.16` — webview で Google OAuth を行い、取得した id_token を `/auth/google` に渡す
- カスタム実装 — `url_launcher` でブラウザを開き、ローカルポートでコールバックを受け取る

Windows 実機でテストしながら別スプリントで対応します。

---

## Phase 1: Windows PC 初回セットアップ

### 1. Git をインストール

[git-scm.com](https://git-scm.com/) からインストール。

### 2. Flutter SDK をインストール

[flutter.dev](https://docs.flutter.dev/get-started/install/windows/desktop) に従いインストール。

```powershell
flutter doctor
```

### 3. Visual Studio 2022 をインストール

[visualstudio.microsoft.com](https://visualstudio.microsoft.com/) から **Community 版**（無料）をインストール。

インストール時に以下のワークロードを必ず選択:
- ✅ **C++ によるデスクトップ開発**（Windows 10/11 SDK が同梱される）

### 4. `flutter doctor` で全項目確認

```
[✓] Flutter (Channel stable, ...)
[✓] Windows Version (...)
[✓] Visual Studio - develop Windows apps (Visual Studio 2022 ...)
```

### 5. リポジトリをクローン

```powershell
git clone <repo-url>
cd reachtrail
flutter pub get
```

---

## Phase 2: リリースビルド

PowerShell で実行:

```powershell
cd reachtrail

flutter build windows --release `
  --dart-define=PLACE_SEARCH_PROVIDER=yahoo `
  --dart-define=YAHOO_PROXY_BASE_URL=https://api.reachtrail.riumu.net/yahoo/localSearch `
  --dart-define=API_BASE_URL=https://api.reachtrail.riumu.net
```

ビルド後に zip 作成:

```powershell
.\deploy\reachtrail\build-windows.ps1
```

生成物: `build\windows-dist\reachtrail-windows.zip`

---

## Phase 3: 配布

### SmartScreen 警告について

コード署名なしの場合、初回実行時に SmartScreen 警告が表示されます。
「詳細情報」→「実行」で回避できます（macOS の Gatekeeper より緩い）。

### VPS への配布

Windows で作成した zip を macOS に転送し（USB / ネットワーク共有 / クラウドストレージ等）、VPS へ sync します:

```bash
# build/windows-dist/reachtrail-windows.zip を macOS に置いた後
./deploy/reachtrail/sync-download-to-vps.sh
```

sync スクリプトの対象ディレクトリへ Windows zip を含めるよう、スクリプト側の更新が必要です。

---

## フロー全体図

```
Windows PC（ビルド）
  ├─ Flutter + Visual Studio セットアップ（初回のみ）
  ├─ git clone / git pull（最新コードを取得）
  ├─ flutter build windows --release --dart-define=...
  └─ build-windows.ps1 → build\windows-dist\reachtrail-windows.zip
            │
            ▼（zip を macOS に転送）
macOS（配布）
  └─ sync-download-to-vps.sh でダウンロードサイトに公開
```

---

## 補足

- `flutter_map` / `latlong2` は Windows で動作確認済み（ネイティブ依存なし）
- Yahoo ローカル検索は Windows でも同じプロキシ URL を使うため変更不要
- Google Sign-in が未対応のため、現時点の Windows 版ではログインできません
