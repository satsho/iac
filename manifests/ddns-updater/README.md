# DDNS Updater

自宅のグローバルIPは固定ではない。ハニーポット(`honeypot.focus4.net`、今後
構築予定)だけは本物のインターネットに公開する必要があり、Tailscale IP限定
にできないため、このCronJobが10分おきに実際のグローバルIPを検知し、
Route53の`honeypot.focus4.net`(Aレコード)を直接UPSERTする。

他のサービス(keycloak/demo/hermes)はTailscale IP固定のままで、DDNSの対象
ではない。

## 仕組み

1. `curlimages/curl`のinitContainerで`https://checkip.amazonaws.com`に
   アクセスし、現在のグローバルIPを取得
2. `amazon/aws-cli`のメインコンテナで、Route53の現在のレコード値と比較
3. 値が変わっていた場合のみ`change-resource-record-sets`でUPSERT

認証はSSM Hybrid Activationの一時クレデンシャル(`/root/.aws/credentials`、
自宅サーバ上でSSM Agentが自動更新)をhostPathでそのまま使う。追加のSecret
作成は不要。

Terraform側(`terraform/environments/dns/dns.tf`の`honeypot_ddns`)は初期値
だけ設定し、`lifecycle.ignore_changes`でこのCronJobによる書き換えを無視する
ので、Terraform applyのたびに値が戻されることはない。

## 前提

- `terraform/environments/dns`をapply済みで、`honeypot.focus4.net`レコード
  と、SSM Hybrid Activationロールへの`route53:ListResourceRecordSets`権限が
  存在すること
