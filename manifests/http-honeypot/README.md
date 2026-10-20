# HTTP Honeypot(自作)

Cowrie(SSHハニーポット)の後継。Tailscale Funnelの`--tcp`(生TCP)モードが
TLSハンドシェイクを前提としており、SSHのような非TLSプロトコルを通せない
([tailscale/tailscale#14240](https://github.com/tailscale/tailscale/issues/14240)、
未解決の機能要望)ことが判明したため、Funnelが自然にサポートするHTTP(S)型の
ハニーポットに切り替えた。

SNARE/TANNER等の既存ツールも検討したが、Redis+PHPサンドボックス+API+本体の
5コンポーネント構成かつDockerイメージが2年以上更新されておらず、Cowrieで
踏んだ「中身の見えないイメージの罠」を繰り返すリスクが高いと判断し、全部
自分のコードで書く方針にした。

## 構成

- 単一コンテナ(`python:3.12-slim` + 標準ライブラリの`http.server`のみ)
- リクエストごとに直接Postgresへ記録(Cowrieのようなログファイルtail用
  サイドカーは不要)
- `/wp-login.php`・`/.env`・`/phpmyadmin/`・`/.git/config`など、よく無差別
  スキャンで狙われるパスには偽のコンテンツを返す。それ以外は404
- psycopg2-binaryは`job-pip-install.yaml`(`honeypot`namespace内、
  `app: http-honeypot`ラベルを持たないためNetworkPolicy対象外)が一度だけ
  PVCにインストールし、本体コンテナは`PYTHONPATH`で読むだけ
  (本体コンテナ自身は実行時にインターネットへ出ない)

## 前提

- `manifests/honeypot-postgres`が先にデプロイされていること(同じ
  `honeypot-postgres-secrets`Secretをそのまま使う)
- テーブル(`http_honeypot_events`)はアプリ自身が起動時に
  `CREATE TABLE IF NOT EXISTS`で作成する(Postgres初回起動時の
  initdbスクリプトには依存しない)

## Tailscale Funnelでの公開

Cowrieで使っていた生TCPモード(`--tcp=10000`)は停止し、HTTP(S)の
標準モードに切り替える。

```bash
# Cowrie時代の設定をオフにする(まだ残っていれば)
tailscale funnel --tcp=10000 off

# このNodePort(30080)をHTTPSの443番で公開する
tailscale funnel --bg 30080
tailscale funnel status
```

`https://iac-home.tail478255.ts.net/`で到達できる。

**証明書についての注意**: Tailscaleが自動発行するHTTPS証明書は
`iac-home.tail478255.ts.net`向けのもので、`honeypot.focus4.net`
(CNAME)向けではない。そのため`https://honeypot.focus4.net/`でアクセスする
と、証明書のホスト名不一致の警告が出る(ブラウザや証明書検証をする
クライアントの場合)。無差別スキャンボットの多くは証明書を検証しない、
またはIP直指定でSNI無しに接続してくるため実害は限定的だが、完全に正しい
証明書にしたい場合は、ドメイン名を使わず`https://iac-home.tail478255.ts.net/`
を直接使う運用にすること。

## 動作確認

```bash
kubectl get pods -n honeypot

curl -sk https://iac-home.tail478255.ts.net/wp-login.php

kubectl exec -it -n honeypot deploy/honeypot-postgres -- \
  psql -U honeypot -d honeypot -c \
  'SELECT event_time, src_ip, method, path, status_code FROM http_honeypot_events ORDER BY event_time DESC LIMIT 10;'
```

## 国別・攻撃手法別の分析について

`manifests/honeypot-postgres/README.md`の「分析時の国名解決について」と
同様、`src_country`は取り込み時には埋めない。棒グラフ化は今後のタスク。
