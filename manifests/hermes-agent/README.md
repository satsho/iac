# Hermes Agent（第1段階: 自宅ネットワーク内のみ）

モデルプロバイダはGoogle Gemini。認証・インターネット公開はまだ付けていない
(Tailscale経由でしか届かないNodePortのみ)。動作確認が取れたら、demo-nginxと
同じパターン(oauth2-proxy + Keycloak + Gateway API)で外部公開する。

起動するのはWebダッシュボード(`hermes dashboard --host 0.0.0.0`)のみ。
ゲートウェイAPI(OpenAI互換サーバ、8642番)は今回は起動していない。

注意1: Geminiの無料枠はエージェント用途(1ターンで複数回モデル呼び出しが発生)
には小さめ。動作確認レベルなら問題ないはずだが、使い込むとレート制限に
当たりやすい。

注意2: ダッシュボードは`0.0.0.0`など非ループバックアドレスにバインドすると
Basic認証が必須になる仕様。NodePort経由でPod外部からアクセスする以上、
Basic認証の設定なしではコンテナが起動すらしない。

## 事前準備(手動、一度だけ)

```bash
kubectl create namespace hermes
kubectl create secret generic hermes-agent-secrets -n hermes \
  --from-literal=GOOGLE_API_KEY='' \
  --from-literal=dashboard-username='admin' \
  --from-literal=dashboard-password="$(openssl rand -base64 18)" \
  --from-literal=dashboard-secret="$(openssl rand -base64 32)"
```

`GOOGLE_API_KEY`は空のままでも起動できる(ダッシュボードの「API Keys」画面から
後で入力できる)。パスワードは自動生成されるので、控えておくこと:

```bash
kubectl get secret hermes-agent-secrets -n hermes \
  -o jsonpath='{.data.dashboard-password}' | base64 -d; echo
```

## アクセス

```
http://<TailscaleのIP>:30119
```

(自宅サーバのTailscale IPは `tailscale ip -4` で確認)

ユーザー名`admin`、上記で確認したパスワードでBasic認証を通過すると、
ダッシュボードの「API Keys」画面からGoogle Gemini(`GOOGLE_API_KEY`または
`GEMINI_API_KEY`)を入力し、使用モデルを選択できる。
