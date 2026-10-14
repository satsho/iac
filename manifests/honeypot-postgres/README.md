# Honeypot Postgres

Cowrieハニーポットの攻撃イベント(ログイン試行・実行コマンド等)を保存する
専用Postgres。`honeypot`namespaceに他サービスと分離して置く。

## 事前準備(手動、一度だけ)

```bash
kubectl create namespace honeypot
kubectl create secret generic honeypot-postgres-secrets -n honeypot \
  --from-literal=username=honeypot \
  --from-literal=password="$(openssl rand -base64 24)"
```

パスワードは控えておくこと:

```bash
kubectl get secret honeypot-postgres-secrets -n honeypot \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

## 動作確認

```bash
kubectl exec -it -n honeypot deploy/honeypot-postgres -- \
  psql -U honeypot -d honeypot -c '\dt'
```

`honeypot_events`テーブルが見えればOK。

## 分析時の国名解決について

取り込み時点では`src_country`は空のまま(このPodはEgressをPostgres+DNSに
絞っているため、外部のGeoIP APIを呼べない)。国別の棒グラフを作る際は、
別途`src_ip`の一覧をこのNetworkPolicyの外側(手元のPCや、Egress制限の無い
別のバッチ用Pod)から解決して`UPDATE honeypot_events SET src_country = ...`
する想定。
