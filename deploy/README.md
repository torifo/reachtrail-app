# ReachTrail Deploy

ReachTrail の VPS 公開用メモです。

## 想定ドメイン

- Web: `app.reachtrail.riumu.net`
- API: `api.reachtrail.riumu.net`
- macOS 配布: `download.reachtrail.riumu.net`

## 前提

- VPS の 80/443 は Docker の `global-nginx-proxy` が利用中
- 各サービスは `global-proxy-network` に参加して公開する
- 証明書は `nginxproxy/acme-companion` が `LETSENCRYPT_HOST` から自動取得する
- ReachTrail の API キーは Web クライアントに置かず、API 側で保持する
- VPS は開発環境ではなく実行環境として使う
- VPS 上では `git clone`、アプリビルド、依存解決を常用しない

## このディレクトリの役割

- `reachtrail/compose.yml`
  ReachTrail 公開用 Compose 雛形
- `reachtrail/.env.example`
  ドメイン名やイメージ名の環境変数サンプル
- `reachtrail/build-web.sh`
  ローカルで Flutter Web を本番向けにビルドする
- `reachtrail/sync-web-to-vps.sh`
  ビルド済み Web 配信物を VPS に転送する
- `reachtrail/build-api-image.sh`
  `api/` から API イメージをローカルで作成する
- `reachtrail/push-api-image.sh`
  API イメージを GitHub Container Registry に push する

## VPS 側で使う配置先の想定

- `/home/ubuntu/app/reachtrail/app`
  Flutter Web ビルド成果物
- `/home/ubuntu/app/reachtrail/download`
  macOS の `.dmg` など配布物
- `/home/ubuntu/app/reachtrail/deploy`
  Compose と `.env`
- `/home/ubuntu/app/reachtrail/api-data`
  API のユーザー保存ファイル

## 公開方式

`app` と `download` は静的配信です。`api` は別実装のバックエンドコンテナを前提にしています。

## Git と配置の扱い

- `git@github.com:torifo/reachtrail-app.git` を VPS の作業 remote として設定する前提は不要です
- VPS にはソース一式を置かず、配信物と `compose.yml`、`.env` だけを置きます
- 更新はローカルまたは CI でビルドした成果物を VPS に転送して反映します
- API も VPS 上で `docker build` せず、事前に作成したイメージを `docker pull` して起動します
- API イメージの配布先は GitHub Container Registry (`ghcr.io`) を優先します
- このリポジトリ内の `api/` ディレクトリを API の正本として扱います

この方針なら VPS で重い処理が起きるのは主に `docker pull` とコンテナ再起動だけです。

現時点の Flutter アプリはローカル設定中心なので、本番化する際は以下を優先します。

1. Flutter Web から外部 API を直接叩かない
2. `api.reachtrail.riumu.net` に自前 API を置く
3. `macOS` ビルドも同じ API を参照する
