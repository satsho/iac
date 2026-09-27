# localargo

自宅サーバ(k3s)のArgoCDが同期する対象を管理するディレクトリ。

AWS dev環境(`terraform/environments/dev`)はTerraform/Ansibleが`argocd_apps`変数からApplicationを生成するのに対し、
自宅サーバはTerraform管理外の手動構築なので、このディレクトリをApp of Appsのソースとして直接ArgoCDに登録する。

## 構成

- `root-app.yaml` — 自宅サーバのArgoCDに一度だけ手動で`kubectl apply`するApp of Apps。`apps/`配下を監視する。
- `apps/*.yaml` — 個々のArgoCD Application定義。1ファイル1アプリ。
- 実際のKubernetesマニフェスト本体は既存の`manifests/`配下を共有する(AWS側と同じアプリを使う場合はそのまま指す)。

## 初回セットアップ(自宅サーバ側で1回だけ)

```bash
kubectl apply -f localargo/root-app.yaml
```

これで`apps/`配下のApplication定義がArgoCDにより自動的に同期されるようになる。

## アプリを追加する手順

1. `manifests/<app名>/`にKubernetesマニフェストを追加する
2. `localargo/apps/<app名>.yaml`にArgoCDのApplication定義を追加する(`apps/demo-nginx.yaml`を参考に)
3. mainにマージする

`root-app.yaml`が`apps/`を自動同期しているため、マージ後は手動操作不要でArgoCDが新しいApplicationを検知し、対象アプリをデプロイする。
