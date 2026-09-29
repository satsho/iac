# 自宅k3sクラスタのcert-manager(Let's Encrypt DNS-01検証)専用のIAMユーザー。
# 自宅サーバはGitHub ActionsのようなOIDCフェデレーションが使えないため、
# 静的アクセスキーを発行する。権限はこのホストゾーンのTXTレコード書き換えのみに絞る。
resource "aws_iam_user" "cert_manager" {
  name = "${var.project_name}-cert-manager-dns01"

  tags = {
    Name = "${var.project_name}-cert-manager-dns01"
  }
}

resource "aws_iam_user_policy" "cert_manager_route53" {
  name = "route53-dns01"
  user = aws_iam_user.cert_manager.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ChangeThisZoneOnly"
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = aws_route53_zone.main.arn
      },
      {
        # ListHostedZonesByNameとGetChangeはリソースレベルの権限指定に対応していないため
        # Resource: "*" が必須(AWS側の制約)。実害は読み取りのみなので許容する。
        Sid    = "ListAndPollChangeStatus"
        Effect = "Allow"
        Action = [
          "route53:ListHostedZonesByName",
          "route53:GetChange",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_access_key" "cert_manager" {
  user = aws_iam_user.cert_manager.name
}
