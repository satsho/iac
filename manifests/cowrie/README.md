# Cowrie (SSHハニーポット)

本物のインターネットから到達可能にする必要がある唯一のサービス。
`honeypot`namespaceに隔離し、NetworkPolicyでEgressをPostgres+DNSのみに
絞っている(Ingressは攻撃者を受け入れるため無制限)。

## 前提

- `manifests/honeypot-postgres`が先にデプロイされ、`honeypot-postgres-secrets`
  Secretが作成されていること
- `terraform/environments/dns`がapply済みで、`honeypot.focus4.net`が
  Tailscale FunnelのFQDN(`honeypot_funnel`、CNAME)を指していること
- 下記のTailscale Funnel設定が済んでいること

## log-shipperがインターネットに出ない理由

log-shipperは`psycopg2-binary`を使うが、NetworkPolicyでPostgres+DNS以外への
egressを塞いでいるため、Pod自身は`pip install`できない。そこで
`job-pip-install.yaml`(`app: cowrie`ラベルを持たないためNetworkPolicyの
対象外)が、一度だけPVC(`cowrie-pip-cache`)にインストールし、log-shipperは
そこを`PYTHONPATH`で読むだけにしている。

このJobはArgoCDのhookではなく普通のJobとして追跡される(一度だけ実行され、
その後は変更されない限り再実行されない)。`pip install`の内容を変える場合は
`kubectl delete job cowrie-pip-install -n honeypot`で手動削除してから
再同期すること(Jobのspecは不変のため、ArgoCDが自動で更新してくれない)。

log-shipperは起動直後、Jobが完了してPVCにパッケージが入るまで数回クラッシュ
ループすることがあるが、Jobが完了すれば次のコンテナ再起動時に自動で復帰する
(自己修復するので手動対応は不要)。

## 公開方法: Tailscale Funnel(手動、ここだけはTerraform/Ansibleで自動化できない)

自宅のISP(NURO)がCGNAT(1つのIPv4を複数契約者と共有)のため、ルーターの
ポート転送が使えない。そのため、自宅サーバの既存のTailscale接続をそのまま
使って公開する「Tailscale Funnel」経由にしている。

Funnelの公開ポートは443・8443・10000の3つしか選べない(22番は使えない)。
443/8443は将来ほかのHTTPS系サービスをFunnel公開する時のために空けておき、
ここでは10000を使う。

### 1. tailnetでFunnelを有効化(一度だけ、Tailscale管理コンソール)

[Tailscale admin console](https://login.tailscale.com/admin/acls)のACL
ポリシーに、このノード向けのFunnel許可を追加する(`nodeAttrs`に`funnel`
capabilityを追加)。詳細はTailscale公式の
[Funnel setup](https://tailscale.com/kb/1223/funnel)を参照。

### 2. 自宅サーバでFunnelを起動(一度だけ、ホスト上で実行)

```bash
tailscale funnel --tcp=10000 tcp://localhost:30022
```

(`30022`はCowrieのNodePort。k3sのNodePortはノードの`localhost`からも
到達できる)

設定確認:

```bash
tailscale funnel status
```

### 3. 動作確認

```bash
# クラスタ内から
kubectl get pods -n honeypot

# 外部から(Funnel設定後)
ssh -p 10000 test@honeypot.focus4.net
# → 適当なユーザー名・パスワードでログインできる(ように見える)のがCowrieの仕様

# ログがPostgresに入っているか
kubectl exec -it -n honeypot deploy/honeypot-postgres -- \
  psql -U honeypot -d honeypot -c 'SELECT event_type, src_ip, username FROM honeypot_events ORDER BY event_time DESC LIMIT 10;'
```

**捕獲率についての注意**: 無差別スキャン攻撃の大半は22番ポートを狙うため、
10000番では本来Cowrieが想定する「無差別スキャンでの被発見」の効果は薄い。
ドメイン名を知っている/積極的にポートスキャンする相手のみが対象になる。
NURO光のCGNAT制約の下で、VPS等を新たに増やさずに公開するためのトレードオフ
として受け入れている。

## ログパスについて

Cowrie公式イメージのJSONログの実際の出力パスはバージョンによって変わる
可能性がある。初回デプロイ後に確認し、ズレていたら`deployment.yaml`の
`log-shipper`コンテナの`LOG_PATH`と、`cowrie`コンテナの`volumeMounts`の
`subPath`を実際のパスに合わせて修正すること:

```bash
kubectl exec -n honeypot deploy/cowrie -c cowrie -- /bin/ls -la /cowrie/cowrie-git/var/log/cowrie/
```

(コンテナのPATHにcowrieのvenv binしか含まれておらず、`ls`/`find`を素のコマンド名
では呼べないため、絶対パスで実行する)

## 国別・攻撃手法別の分析について

`manifests/honeypot-postgres/README.md`の「分析時の国名解決について」を
参照。棒グラフ化(国別・手法別)は今回のスコープ外で、データが蓄積されて
からの別タスク。
