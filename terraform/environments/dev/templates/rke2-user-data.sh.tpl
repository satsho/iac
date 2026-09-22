#!/bin/bash
set -euxo pipefail

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
