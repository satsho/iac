#!/bin/bash
set -euxo pipefail

# amazon-ssm-agentはRPMを直接インストールするので、サブスクリプション登録前でも入る。
dnf install -y "https://s3.${aws_region}.amazonaws.com/amazon-ssm-${aws_region}/latest/linux_amd64/amazon-ssm-agent.rpm"
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# BYOSのRHELはdnfでの一般パッケージインストール(ansible-core等)に
# サブスクリプション登録・リポジトリ有効化が前提となるため、ここだけは
# Ansibleに移譲せずuser_dataで行う。
subscription-manager register \
  --org="${rhel_org_id}" \
  --activationkey="${rhel_activation_key}" \
  --force

subscription-manager repos \
  --enable="rhel-10-for-x86_64-baseos-rhui-rpms" \
  --enable="rhel-10-for-x86_64-appstream-rhui-rpms" || true

dnf install -y ansible-core git

# ここから先(kernel-modules-extra・k3s・ArgoCD・GitOps Applicationの適用)は
# GitHub上のAnsible playbookに委譲する。ansible-pullはインスタンス自身が
# リポジトリをpullしてローカル実行するため、SSHもpush用の認証情報も不要。
mkdir -p /etc/ansible
cat <<EOT > /etc/ansible/extra-vars.json
{
  "argocd_repo_url": "${argocd_repo_url}",
  "argocd_repo_revision": "${argocd_repo_revision}",
  "argocd_apps": ${jsonencode(argocd_apps)},
  "tailscale_auth_key": "${tailscale_auth_key}"
}
EOT
chmod 600 /etc/ansible/extra-vars.json

ansible-pull \
  --url "${ansible_repo_url}" \
  --checkout "${ansible_repo_revision}" \
  --inventory localhost, \
  --extra-vars "@/etc/ansible/extra-vars.json" \
  ansible/playbook.yml
