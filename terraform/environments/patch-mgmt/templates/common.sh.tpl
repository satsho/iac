#!/bin/bash
set -euxo pipefail

# OSのタイムゾーンをメンテナンスウィンドウと揃えておくと、dnf・journalのログと
# パッチ適用の時刻を突き合わせやすい。
timedatectl set-timezone "${timezone}"

# RHELの公式AMIにはamazon-ssm-agentが同梱されていないため最初に入れる。
# dnfのリポジトリ(CDN/ミラー)にまだ到達できない段階でも入るよう、RPMはS3から直接
# 取得し、リポジトリを全て無効にした状態でローカルインストールする
# (業務サーバはS3ゲートウェイエンドポイント経由で取得する)。
curl -fsSL -o /tmp/amazon-ssm-agent.rpm \
  "https://s3.${aws_region}.amazonaws.com/amazon-ssm-${aws_region}/latest/linux_amd64/amazon-ssm-agent.rpm"
dnf install -y --disablerepo='*' /tmp/amazon-ssm-agent.rpm
rm -f /tmp/amazon-ssm-agent.rpm
systemctl enable --now amazon-ssm-agent
