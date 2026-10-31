# 自宅サーバをSSM Hybrid Activation(マネージドインスタンス化)するためのIAMロール。
# アクティベーション自体(aws ssm create-activation、使い捨てのActivation Code/ID)は
# 一度きりの手動作業のため、Terraformの管理対象外(手動でAWS CLI/コンソールから実行)。
# ここではそのロールと、登録後に自宅サーバが引き受けられる権限だけを用意する。
resource "aws_iam_role" "ssm_hybrid_activation" {
  name = "${var.project_name}-ssm-hybrid-activation"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ssm.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      },
    ]
  })

  tags = {
    Name = "${var.project_name}-ssm-hybrid-activation"
  }
}

# Session Manager/Run Command/インベントリなど、Hybrid Activationしたインスタンスが
# SSM機能を使うために必要なAWS管理ポリシー。
resource "aws_iam_role_policy_attachment" "ssm_hybrid_activation_core" {
  role       = aws_iam_role.ssm_hybrid_activation.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# cert-managerのRoute53 DNS-01用。将来的にaws_iam_user.cert_manager(静的キー)を
# 置き換え、このロール経由の一時クレデンシャルに移行する想定。
resource "aws_iam_role_policy" "ssm_hybrid_activation_route53" {
  name = "route53-dns01"
  role = aws_iam_role.ssm_hybrid_activation.name

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
