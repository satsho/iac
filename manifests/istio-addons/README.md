# Istio + Kiali

k3sクラスタにIstio(サイドカー注入モード)を導入し、Kialiでメッシュを可視化する。

## 構成

| コンポーネント | Application | ソース | namespace |
|---|---|---|---|
| CRD・クラスタ共通リソース | `istio-base` | Helmチャート`base`(istio-release公式リポジトリ) | istio-system |
| コントロールプレーン(istiod) | `istio-istiod` | Helmチャート`istiod` | istio-system |
| Prometheus(Kialiのメトリクス源) | `istio-addons` | このリポジトリの`manifests/istio-addons/prometheus.yaml`(Istio公式サンプルをそのまま取得) | istio-system |
| Kiali本体 | `kiali` | Helmチャート`kiali-server`(kiali.org公式リポジトリ) | istio-system |

Istio自身のIngress Gatewayは入れていない。外部公開は既存のTraefik(Gateway API)を
そのまま使う(`manifests/gateway/httproute-kiali.yaml`)。Istioはサイドカー注入による
メッシュ内可視化・制御だけに使う構成。

## サイドカー注入の対象

`default`・`grafana`・`keycloak`の3つのnamespaceに`istio-injection: enabled`ラベルを
付けている(各namespaceの`namespace.yaml`参照)。`cert-manager`・`argocd`・`kube-system`は
対象外(インフラコンポーネントなのでリスクと手間に対して得るものが少ないため)。

## 導入後に必要な手動作業(1回だけ)

ラベルを付けただけでは、**既にPodが動いているnamespaceの既存Podにはサイドカーが入らない**
(Mutating Webhookは新規Pod作成時にしか働かない)。ラベル適用後、対象Podをロールアウト
再起動すること:

```bash
kubectl rollout restart deployment -n default
kubectl rollout restart deployment -n grafana
kubectl rollout restart deployment -n keycloak
```

`kubectl get pods -n <namespace>`でコンテナ数が2/2になっていれば、サイドカー(`istio-proxy`)が
正しく注入されている。

## アクセス

```
https://kiali.focus4.net   (Tailscale経由、既存のgrafana/keycloakと同じGateway)
```

認証は`anonymous`(自宅LAN/Tailscale内のみを想定した設定。インターネットに公開する場合は
`auth.strategy`をkeycloak経由のOpenID Connectに変更すること)。

Grafanaへのリンクは`external_services.grafana`で既存のGrafana(`manifests/grafana`)を
指すように設定済み。

## バージョン

istio-base/istio-istiod: `1.30.8`、kiali-server: `2.35.0`(導入時点の最新安定版)。
アップグレードする場合は3つのバージョンをまとめて上げること(istioの各コンポーネント間は
マイナーバージョンを揃えるのが前提)。

## 既知の制約

- Kialiのサービスはgrafana/keycloakと違い、NodePortでの直接公開(Tailscale IP経由)は
  設定していない。Gateway API経由のアクセスのみ。必要になったらkiali-serverの
  Helm値(`deployment.service_type`等)を確認して追加する。
- Prometheusはデータを永続化していない(emptyDir)。Pod再作成で過去のメトリクスは消える。
  可視化・デモ用途として割り切っている。
