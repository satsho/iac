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
