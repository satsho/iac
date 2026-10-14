# Cowrie (SSHハニーポット)

本物のインターネットから到達可能にする必要がある唯一のサービス。
`honeypot`namespaceに隔離し、NetworkPolicyでEgressをPostgres+DNSのみに
絞っている(Ingressは攻撃者を受け入れるため無制限)。

## 前提

- `manifests/honeypot-postgres`が先にデプロイされ、`honeypot-postgres-secrets`
  Secretが作成されていること
- `terraform/environments/dns`がapply済みで、`honeypot.focus4.net`が
  DDNS(`manifests/ddns-updater`)経由で自宅の実際のグローバルIPを指して
  いること

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

## 自宅ルーターの設定(手動、ここだけはTerraform/Ansibleで自動化できない)

ルーターの管理画面(ポート転送/バーチャルサーバ等の設定項目)で:

| 項目 | 値 |
|---|---|
| 外部(WAN)ポート | 22 / TCP |
| 転送先IP | 自宅サーバ(rancher)のLAN IP |
| 転送先ポート | 30022(CowrieのNodePort) |

**重要**: 自宅サーバの本来のSSH(管理用)が外部ポート22に別途転送されていない
ことを確認してください。今の運用はTailscale経由のアクセスのみのはずなので、
通常は競合しないはずですが、念のため。

## 動作確認

```bash
# クラスタ内から
kubectl get pods -n honeypot

# 外部から(ルーター設定後)
ssh test@honeypot.focus4.net
# → 適当なユーザー名・パスワードでログインできる(ように見える)のがCowrieの仕様

# ログがPostgresに入っているか
kubectl exec -it -n honeypot deploy/honeypot-postgres -- \
  psql -U honeypot -d honeypot -c 'SELECT event_type, src_ip, username FROM honeypot_events ORDER BY event_time DESC LIMIT 10;'
```

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
