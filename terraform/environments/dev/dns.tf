# このゾーンはAWSコンソールで手動作成済み(お名前.com側のネームサーバーを
# ここのNSレコードに向けて委任済み)。新規作成すると別ゾーンができてNS値が
# ずれてしまうため、importブロックで既存ゾーンをそのまま取り込む。
# 取り込み確認後(plan差分が無くなった後)は、このimportブロックを削除してよい。
import {
  to = aws_route53_zone.main
  id = var.route53_zone_id
}

resource "aws_route53_zone" "main" {
  name = var.domain_name

  # environments/devは使い捨て前提(destroyアクションあり)のstateだが、
  # このゾーンだけはお名前.com側のNS委任と紐づく長期生存リソースなので、
  # 誤って一緒にdestroyされないよう明示的に保護する。
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = "${var.project_name}-zone"
  }
}
