# Grafana(patch-mgmt Inventory/脆弱性ダッシュボード)

SSM Inventory(全VMのパッケージ一覧)とPatch Compliance(パッチ未適用状況・CVE)を、
AthenaのGlueテーブル(terraform/environments/patch-mgmt/inventory.tf)経由で
ダッシュボード化する。QuickSightは無料枠が無い(30日トライアルのみ)ため、
自宅k3s上にGrafana + [grafana-athena-datasource](https://grafana.com/grafana/plugins/grafana-athena-datasource/)
プラグインで構築している。

## 事前準備(手動、一度だけ)

```bash
kubectl create namespace grafana
kubectl create secret generic grafana-admin -n grafana \
  --from-literal=username=admin \
  --from-literal=password="$(openssl rand -base64 18)"
```

パスワードは自動生成されるので、控えておくこと:

```bash
kubectl get secret grafana-admin -n grafana \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

## アクセス

```
https://grafana.focus4.net   (Tailscale経由)
http://<TailscaleのIP>:30300
```

Athenaデータソース(`patch-mgmt-inventory`)は自動プロビジョニング済み
(`datasource-configmap.yaml`)。認証はKVMホスト(= このk3sノード)自身の
SSM Hybrid Activationクレデンシャルをそのまま使う(`terraform/environments/dns`の
`grafana-athena-iam.tf`でAthena/Glue/S3の読み取り権限を追加済み)。

プラグインのバージョンによって`jsonData`のキーが変わることがあるので、
データソース画面で接続テストが失敗する場合は設定を見直すこと。

## ダッシュボードの作り方(手動)

Explore画面やパネル編集画面から、Athenaデータソースに対して直接SQLを書く。例:

```sql
-- インスタンスごとの未適用パッチ件数
SELECT resourceid, count(*) AS missing_count
FROM aws_complianceitem
WHERE patchstate = 'Missing'
GROUP BY resourceid
```

```sql
-- CVE付きの未適用パッチ一覧
SELECT resourceid, title, patchseverity, cveids
FROM aws_complianceitem
WHERE patchstate = 'Missing' AND cveids != ''
```

ダッシュボードの定義自体はGrafanaの`grafana-data`PVC(k3s標準のlocal-path、
ノードのローカルディスク)に保存される。GitOps管理下ではないので、重要な
ダッシュボードは個別にJSONエクスポートしてGitに残すことを検討すること。
