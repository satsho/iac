# oauth2-proxy (Google連携)

demo-nginxをGoogleアカウントでログインさせるための構成。認証自体はKeycloakの
`home` realmに委譲し(Identity Provider: Google)、oauth2-proxyはKeycloakを
OIDCプロバイダとして使うリバースプロキシとしてdemo-nginxの前段に立つ。

```
ブラウザ → Traefik(Gateway) → oauth2-proxy → (未認証ならKeycloak→Googleへリダイレクト)
                                            → (認証済みならdemo-nginxへ転送)
```

前提として、Keycloak Admin Console (`https://keycloak.focus4.net/admin/master/console/`)
側で以下を作成済みであること:

- realm `home`
- Identity Provider: Google (Client ID/Secretを設定済み)
- Client: `oauth2-proxy` (confidential, redirect URI:
  `https://demo.focus4.net/oauth2/callback`)

## Secretの作成(手動、一度だけ)

`client-secret`はKeycloakの`oauth2-proxy`クライアントの Credentials タブに
表示される値。`cookie-secret`はランダムな32バイトを生成する。

```bash
kubectl create secret generic oauth2-proxy-secrets -n default \
  --from-literal=client-secret='<Keycloakのoauth2-proxyクライアントのClient secret>' \
  --from-literal=cookie-secret="$(openssl rand -base64 32)"
```
