#!/bin/bash
set -euxo pipefail

# RHELの公式AMIにはamazon-ssm-agentが同梱されていないため、最初に入れる。
# (IAMロールにはAmazonSSMManagedInstanceCoreが既にアタッチ済み)
dnf install -y "https://s3.${aws_region}.amazonaws.com/amazon-ssm-${aws_region}/latest/linux_amd64/amazon-ssm-agent.rpm"
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

subscription-manager register \
  --org="${rhel_org_id}" \
  --activationkey="${rhel_activation_key}" \
  --force

# activation key側でリポジトリが有効化されていない場合の保険(失敗しても続行)
subscription-manager repos \
  --enable="rhel-9-for-x86_64-baseos-rpms" \
  --enable="rhel-9-for-x86_64-appstream-rpms" || true

# k3sの自動デプロイ用ディレクトリにデモ用nginxを事前配置しておく。
# server起動時にk3s自身がこのディレクトリを監視してapplyする(ArgoCDはまだ無いため)。
mkdir -p /var/lib/rancher/k3s/server/manifests
cat <<MANIFEST > /var/lib/rancher/k3s/server/manifests/demo-nginx.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-nginx
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-nginx
  template:
    metadata:
      labels:
        app: demo-nginx
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: demo-nginx
  namespace: default
spec:
  type: NodePort
  selector:
    app: demo-nginx
  ports:
    - port: 80
      targetPort: 80
      nodePort: ${node_port}
MANIFEST

# ALBを前段に置く構成のため、k3s組み込みのTraefik/ServiceLBは無効化する。
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable traefik --disable servicelb" sh -

systemctl enable k3s
systemctl start k3s
