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

curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="server" sh -

systemctl enable rke2-server.service
systemctl start rke2-server.service
