# Hermes Agent（第1段階: 自宅ネットワーク内のみ）

モデルプロバイダはGoogle Gemini固定。認証・インターネット公開はまだ付けていない
(Tailscale経由でしか届かないNodePortのみ)。動作確認が取れたら、demo-nginxと
同じパターン(oauth2-proxy + Keycloak + Gateway API)で外部公開する。

注意: Geminiの無料枠はエージェント用途(1ターンで複数回モデル呼び出しが発生)
には小さめ。動作確認レベルなら問題ないはずだが、使い込むとレート制限に
当たりやすい。

## 事前準備(手動、一度だけ)

```bash
kubectl create namespace hermes
kubectl create secret generic hermes-agent-secrets -n hermes \
  --from-literal=GOOGLE_API_KEY='<Google AI StudioのAPIキー>'
```

## デプロイ後の初回セットアップ(手動、一度だけ)

APIキーは環境変数で渡しているが、どのGeminiモデルを使うかの選択は対話コマンド
が必要:

```bash
kubectl exec -it -n hermes deployment/hermes-agent -- hermes model
```

「More providers...」→「Google AI Studio」を選び、使うモデルを選択する。

## アクセス

```
http://<TailscaleのIP>:30119
```

(自宅サーバのTailscale IPは `tailscale ip -4` で確認)
