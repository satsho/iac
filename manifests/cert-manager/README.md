# cert-manager (ambient credentials化)

Route53認証は静的キーではなく、SSM Hybrid Activation由来の一時クレデンシャルを
使うambient credentials方式に移行済み。

## 仕組み

```
[自宅サーバ:root] SSM Agentが/root/.aws/credentialsを約30分おきに自動更新
        ↓ (aws-credentials-sync-cronjob.yaml、15分おき)
[k8s Secret: aws-ambient-credentials]
        ↓ (下記のDeploymentパッチでマウント)
[cert-manager Pod] AWS_SHARED_CREDENTIALS_FILE環境変数で参照
        ↓
cluster-issuer.yaml (accessKeyID等を書かず、ambientモードに)
```

`aws-credentials-sync-cronjob.yaml`と`aws-credentials-syncer-rbac.yaml`はGitOpsで
自動同期されるが、cert-manager本体(controller)はGitOps管理外(最初に
`kubectl apply`で手動インストールしたもの)のため、以下のパッチだけは
**一度だけ手動で当てる**必要がある。

## cert-manager controllerへのパッチ(手動、一度だけ)

コンテナ名が違う場合は事前に確認:

```bash
kubectl get deployment cert-manager -n cert-manager \
  -o jsonpath='{.spec.template.spec.containers[0].name}'
```

通常は`cert-manager-controller`のはず。以下を適用:

```bash
kubectl patch deployment cert-manager -n cert-manager --type=strategic -p '
spec:
  template:
    spec:
      containers:
        - name: cert-manager-controller
          env:
            - name: AWS_SHARED_CREDENTIALS_FILE
              value: /aws-creds/credentials
          volumeMounts:
            - name: aws-ambient-credentials
              mountPath: /aws-creds
              readOnly: true
      volumes:
        - name: aws-ambient-credentials
          secret:
            secretName: aws-ambient-credentials
'
```

`aws-ambient-credentials` SecretはCronJobが自動作成するので、先にCronJobが
最低1回成功している状態でこのパッチを当てること。
