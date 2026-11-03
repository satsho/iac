# 家のk3sのGrafana(grafana-athena-datasourceプラグイン)が、patch-mgmtの
# Inventory/脆弱性スキャン結果(terraform/environments/patch-mgmt/inventory.tf)を
# Athena経由でダッシュボード化するための権限。新しいIAMユーザーは作らず、
# 既存のSSM Hybrid Activationロール(自宅サーバが引き受ける一時クレデンシャル)に
# 読み取り専用の権限だけを追加する(hermes-backup-s3.tfと同じパターン)。
data "aws_caller_identity" "current" {}

locals {
  # terraform/environments/patch-mgmtのaws_s3_bucket.inventoryと同じ名前(クロス環境
  # 参照はしていないので、バケット名の生成規則を合わせておくこと)
  patch_inventory_bucket_arn = "arn:aws:s3:::${var.project_name}-patch-inventory-${data.aws_caller_identity.current.account_id}"
}

resource "aws_iam_role_policy" "ssm_hybrid_activation_grafana_athena" {
  name = "grafana-athena-readonly"
  role = aws_iam_role.ssm_hybrid_activation.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AthenaQuery"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
          "athena:GetWorkGroup",
        ]
        Resource = "*"
      },
      {
        Sid    = "GlueCatalogRead"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:BatchGetPartition",
        ]
        Resource = "*"
      },
      {
        Sid      = "ReadInventoryData"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [local.patch_inventory_bucket_arn, "${local.patch_inventory_bucket_arn}/*"]
      },
      {
        # Athenaのクエリ結果の書き出し先(同じバケットのathena-results/配下)
        Sid      = "WriteAthenaQueryResults"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${local.patch_inventory_bucket_arn}/athena-results/*"
      },
    ]
  })
}
