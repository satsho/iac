# DDNS Updater(現在は休止中)

もともとは、ハニーポット(`honeypot.focus4.net`)を自宅のグローバルIP宛に
公開するため、自宅のグローバルIPを定期検知してRoute53のAレコードを
UPSERTする想定で作った。

しかし自宅のISP(NURO)がCGNAT(1つのIPv4を複数契約者と共有)を採用しており、
そもそも自宅のグローバルIP宛にルーターのポート転送ができないことが判明。
ハニーポットの公開はTailscale Funnel経由(`honeypot_funnel`、CNAME、
`terraform/environments/dns/dns.tf`参照)に変更したため、このCronJobは
今は使い道が無い。

削除はせず`spec.suspend: true`で休止している。将来「自分専用の固定IPv4が
使えるISPに変える」等でDDNSが必要になった場合は、`RECORD_NAME`を対象の
レコード名に変え、Terraform側もAレコード+`lifecycle.ignore_changes`に戻し、
`suspend: false`にすれば再利用できる。

## 仕組み(休止前の設計)

1. `curlimages/curl`のinitContainerで`https://checkip.amazonaws.com`に
   アクセスし、現在のグローバルIPを取得
2. `amazon/aws-cli`のメインコンテナで、Route53の現在のレコード値と比較
3. 値が変わっていた場合のみ`change-resource-record-sets`でUPSERT

認証はSSM Hybrid Activationの一時クレデンシャル(`/root/.aws/credentials`、
自宅サーバ上でSSM Agentが自動更新)をhostPathでそのまま使う。追加のSecret
作成は不要。
