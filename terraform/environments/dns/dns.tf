# このゾーンはAWSコンソールで手動作成済み(お名前.com側のネームサーバーを
# ここのNSレコードに向けて委任済み)。新規作成すると別ゾーンができてNS値が
# ずれてしまうため、importブロックで既存ゾーンをそのまま取り込む。
# Zone IDはコンソールで確認済みの一度きりの値なのでそのまま埋め込んでいる。
# 取り込み確認後(plan差分が無くなった後)は、このimportブロックを削除してよい。
import {
  to = aws_route53_zone.main
  id = "Z00444252EVDC2QR0ELW1"
}

resource "aws_route53_zone" "main" {
  name = var.domain_name

  # environments/dev(使い捨て前提のstate)とは別state・別ライフサイクルに
  # 分離済みだが、それでも誤destroyを防ぐため明示的に保護しておく。
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = "${var.project_name}-zone"
  }
}

# 自宅k3sサーバのTailscale IPを指す。パブリックDNS名だが、実際に到達できるのは
# 同じtailnetに参加しているデバイスだけ(100.64.0.0/10はTailscale以外からは
# 経路が無いため)。Google OAuthのリダイレクトURI登録などhttpsのドメイン名が
# 必要な場面でも、実際の到達性はTailscale経由に限定できる。
resource "aws_route53_record" "keycloak_tailscale" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "keycloak.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [var.tailscale_home_ip]
}
