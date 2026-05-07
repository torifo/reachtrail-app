# Windows 配布手順

ReachTrail の Windows 版はローカル Windows PC 上でビルドします。
macOS からのクロスコンパイルはできません。

---

## 必要な値・ファイル一覧

Windows 対応にあたり macOS 側でも設定が必要なものをまとめます。
**これらを先に用意してから** Windows PC に移ってください。

| 項目 | 取得方法 | 用途 |
|------|--------|------|
| Windows 用 OAuth クライアント ID | Google Cloud Console → 「デスクトップ アプリ」タイプで作成 | Google Sign-in |
| `google_sign_in_windows` パッケージ追加 | `pubspec.yaml` に追記＋コード修正（下記） | Windows の Google 認証 |
| `deploy/reachtrail/build-windows.ps1` | 下記スクリプトを Windows PC に配置 | リリースビルド自動化 |

---

## Phase 0: macOS 側でやること（コード変更）

Windows 対応のためにリポジトリ側の変更が必要です。Windows PC に移る前に macOS でコミットしておきます。

### 1. `pubspec.yaml` に `google_sign_in_windows` を追加

```yaml
dependencies:
  google_sign_in: ^7.2.0
  google_sign_in_web: ^1.1.3
  google_sign_in_windows: ^0.1.1   # ← 追加
```

### 2. `lib/services/local_config_service.dart` に Windows クライアント ID を追加

`LocalConfig` に `googleWindowsClientId` フィールドを追加し、
dart-define `GOOGLE_WINDOWS_CLIENT_ID` から読み込む。

```dart
// LocalConfig クラスに追加
final String googleWindowsClientId;

// LocalConfigService.load() の return に追加
googleWindowsClientId:
    entries['GOOGLE_WINDOWS_CLIENT_ID'] ??
    const String.fromEnvironment(
      'GOOGLE_WINDOWS_CLIENT_ID',
      defaultValue: '',
    ),
```

### 3. `lib/services/google_auth_service.dart` に Windows 分岐を追加

`_resolveSignInConfiguration` の `return const _GoogleSignInConfiguration()` の前に挿入：

```dart
if (defaultTargetPlatform == TargetPlatform.windows)
  return _GoogleSignInConfiguration(clientId: config.googleWindowsClientId);
```

### 4. Google Cloud Console で Windows 用クライアントを作成

1. [Google Cloud Console](https://console.cloud.google.com) → 「APIとサービス」→「認証情報」
2. 「認証情報を作成」→「OAuth 2.0 クライアント ID」
3. アプリケーションの種類: **デスクトップ アプリ**
4. 名前: `ReachTrail Windows`
5. 作成後に表示されるクライアント ID をメモ（例: `823224608668-xxxxxx.apps.googleusercontent.com`）

---

## Phase 1: Windows PC 初回セットアップ

### 1. Git をインストール

[git-scm.com](https://git-scm.com/) からインストール。Git Bash も合わせて入る。

### 2. Flutter SDK をインストール

[flutter.dev/docs/get-started/install/windows](https://docs.flutter.dev/get-started/install/windows/desktop) に従いインストール。

```powershell
# インストール後に確認
flutter doctor
```

### 3. Visual Studio 2022 をインストール

[visualstudio.microsoft.com](https://visualstudio.microsoft.com/) から **Community 版**（無料）をインストール。

インストール時に以下のワークロードを必ず選択：
- ✅ **C++ によるデスクトップ開発**
- ✅ Windows 10/11 SDK（ワークロード内に含まれる）

### 4. `flutter doctor` で確認

すべて ✓ になっていることを確認。

```
[✓] Flutter (Channel stable, ...)
[✓] Windows Version (...)
[✓] Visual Studio - develop Windows apps (Visual Studio 2022 ...)
```

### 5. リポジトリをクローン

macOS と同じリポジトリをクローンするか、USB/ネットワーク経由でコピー。

```powershell
git clone <repo-url>
cd reachtrail
flutter pub get
```

---

## Phase 2: ビルドスクリプトを作成

`deploy/reachtrail/build-windows.ps1` として保存（PowerShell スクリプト）。

```powershell
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$OutputDir = "$RepoRoot\build\windows-dist"
$ExeDir = "$RepoRoot\build\windows\x64\runner\Release"
$ZipPath = "$OutputDir\reachtrail-windows.zip"

if (-not (Test-Path "$ExeDir\reachtrail_app.exe")) {
    Write-Error "Windows build not found. Run build first."
    exit 1
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
if (Test-Path $ZipPath) { Remove-Item $ZipPath }

# Release フォルダ全体を zip
Compress-Archive -Path "$ExeDir\*" -DestinationPath $ZipPath

Write-Host "Created: $ZipPath"
```

---

## Phase 3: リリースビルド

PowerShell で実行：

```powershell
cd reachtrail

flutter build windows --release `
  --dart-define=PLACE_SEARCH_PROVIDER=yahoo `
  --dart-define=YAHOO_PROXY_BASE_URL=https://api.reachtrail.riumu.net/yahoo/localSearch `
  --dart-define=API_BASE_URL=https://api.reachtrail.riumu.net `
  --dart-define=GOOGLE_WINDOWS_CLIENT_ID=<WindowsクライアントID>
```

ビルド後に zip 作成：

```powershell
.\deploy\reachtrail\build-windows.ps1
```

生成物: `build\windows-dist\reachtrail-windows.zip`

---

## Phase 4: 配布

### SmartScreen 警告について

コード署名なしの場合、初回実行時に「Windows によって PC が保護されました」ダイアログが出ます。
macOS の Gatekeeper より緩く、ユーザーが「詳細情報」→「実行」で回避できます。

署名なしの手順をダウンロードページに掲載します（`deploy/reachtrail/download-index.html` を更新）。

### コード署名（オプション）

SmartScreen 警告を完全に消すには EV コード署名証明書（$200〜500/年）が必要です。
MVP 段階では署名なし配布で十分です。

### VPS への配布（macOS から実行）

Windows で作成した zip を macOS に転送して sync スクリプトで配布：

```bash
# Windows zip を build/windows-dist/ に置いた後
./deploy/reachtrail/sync-download-to-vps.sh  # 既存スクリプトの対象に追加が必要
```

---

## フロー全体図

```
macOS（コード変更・コミット）
  │
  ├─ pubspec.yaml に google_sign_in_windows を追加
  ├─ LocalConfig に googleWindowsClientId を追加
  ├─ google_auth_service.dart に Windows 分岐を追加
  └─ Google Cloud Console で Desktop タイプのクライアント ID を取得
            │
            ▼
Windows PC（ビルド）
  ├─ Flutter + Visual Studio セットアップ（初回のみ）
  ├─ git pull（最新コードを取得）
  ├─ flutter build windows --release --dart-define=... （クライアント ID を渡す）
  └─ build-windows.ps1 → reachtrail-windows.zip を生成
            │
            ▼
macOS（配布）
  ├─ zip を macOS に転送（USB / 共有フォルダ / ネットワーク）
  └─ sync-download-to-vps.sh でダウンロードサイトに公開
```

---

## 補足

- `google_sign_in_windows` は `client_id.json` を `assets/` に置く方式も取れますが、
  dart-define で渡す方式のほうが他プラットフォームと一貫性があります
- Yahoo ローカル検索は Windows でも同じプロキシ URL を使うため変更不要です
- `flutter_map` と `latlong2` は Windows で動作確認済み（ネイティブ依存なし）
