# oauth2-proxy-hermes (Google連携)

Hermes Agentダッシュボードを、demo-nginxと同じパターンでGoogleアカウント経由の
ログインで保護する。KeycloakのGoogle Identity Provider(`home` realm)を使う。

前提として、Keycloak Admin Console側で以下を作成済みであること:

- Client: `oauth2-proxy-hermes` (confidential, redirect URI:
  `https://hermes.focus4.net/oauth2/callback`)

## Secretの作成(手動、一度だけ)

```bash
kubectl create secret generic oauth2-proxy-hermes-secrets -n hermes \
  --from-literal=client-secret='<Keycloakのoauth2-proxy-hermesクライアントのClient secret>' \
  --from-literal=cookie-secret="$(openssl rand -base64 32 | tr '+/' '-_')"
```

## 注意: 認証が2段階になる

Hermes Agent自体が`0.0.0.0`バインド時にBasic認証を必須にする仕様のため、
`https://hermes.focus4.net/`はGoogleログイン(oauth2-proxy)を通過した後、
さらにHermes自身のBasic認証(`manifests/hermes-agent/README.md`参照)を
求められる。意図した多層防御であり、不具合ではない。
