# ---------------------------------------------------------------------------
# Grafana(rancher上に直接インストール、軽量構成) → Athena → Glue(inventory.tf) のデータソース用
# ---------------------------------------------------------------------------
# Grafana本体はKVMホスト(rancher)のRHELに直接インストールする(専用VMは作らない)。
# 新しい長期アクセスキーは作らず、rancher自身が既に持っているSSM Hybrid Activationの
# ロール(iac-poc-ssm-hybrid-activation、environments/dns管理)からsts:AssumeRoleできる
# ロールをここで作り、GrafanaのAthenaデータソース設定(Assume Role ARN)に使う。

locals {
  # rancher自身のHybrid Activationロール(environments/dns管理、ここではARN文字列として参照するだけ)
  rancher_hybrid_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/iac-poc-ssm-hybrid-activation"
}

# Athenaのクエリ結果の保存先。中身は使い捨てなので短期間で自動削除する
resource "aws_s3_bucket" "athena_results" {
  bucket = "${local.name}-athena-results-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    id     = "expire-query-results"
    status = "Enabled"

    filter {}

    expiration {
      days = 7
    }
  }
}

resource "aws_athena_workgroup" "patch_mgmt" {
  name = "${local.name}-grafana"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = false

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.id}/results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

# GrafanaのAthenaデータソースが使うロール。rancherのHybrid Activationロールからのみ
# AssumeRoleできる(長期アクセスキーを新規に作らない)
resource "aws_iam_role" "grafana_athena" {
  name = "${local.name}-grafana-athena-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = local.rancher_hybrid_role_arn }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "grafana_athena" {
  name = "athena-read-inventory"
  role = aws_iam_role.grafana_athena.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RunAthenaQueries"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
          "athena:GetWorkGroup",
          "athena:ListQueryExecutions",
          "athena:ListDataCatalogs",
          "athena:ListDatabases",
          "athena:GetDatabase",
          "athena:ListTableMetadata",
          "athena:GetTableMetadata",
        ]
        Resource = [
          aws_athena_workgroup.patch_mgmt.arn,
          "arn:aws:athena:${var.aws_region}:${data.aws_caller_identity.current.account_id}:datacatalog/AwsDataCatalog",
        ]
      },
      {
        Sid    = "ReadGlueCatalog"
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
        Resource = [
          "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.patch_mgmt.name}",
          "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.patch_mgmt.name}/*",
        ]
      },
      {
        Sid      = "ReadInventoryData"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.inventory.arn, "${aws_s3_bucket.inventory.arn}/*"]
      },
      {
        Sid      = "ReadWriteAthenaResults"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.athena_results.arn, "${aws_s3_bucket.athena_results.arn}/*"]
      },
    ]
  })
}
