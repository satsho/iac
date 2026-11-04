# ---------------------------------------------------------------------------
# SSM Inventory → Resource Data Sync(S3) → Glue/Athena
# ---------------------------------------------------------------------------
# 全VMのインストール済みパッケージ一覧をSSM Inventoryで収集し、AWS標準機能の
# Resource Data SyncでS3へ自動同期する(自前でAPIを叩いて集約する必要がない)。
# infra上のtrivy-scan.sh(ansible/patch-mgmt)が、このS3のデータを定期的にスキャンして
# 脆弱性情報を同じバケットの別プレフィックスへ書き出し、Glueクローラでテーブル化する。
# QuickSightのダッシュボードは、このGlueデータベースをAthenaデータソースとして
# 手動で作る(Terraform未対応、README参照)。

resource "aws_s3_bucket" "inventory" {
  bucket = "${local.name}-inventory-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "inventory" {
  bucket                  = aws_s3_bucket.inventory.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "inventory" {
  bucket = aws_s3_bucket.inventory.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Inventory・スキャン結果とも「今の状態」が分かれば十分で、過去分の監査要件は無いので、
# コストを抑えるため一定期間で自動削除する
resource "aws_s3_bucket_lifecycle_configuration" "inventory" {
  bucket = aws_s3_bucket.inventory.id

  rule {
    id     = "expire-old-data"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }
  }
}

data "aws_iam_policy_document" "inventory_bucket" {
  # Resource Data Syncが使うサービスリンクロールからの書き込みを許可する
  statement {
    sid    = "AllowResourceDataSyncWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.inventory.arn}/inventory/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    sid    = "AllowResourceDataSyncGetBucketAcl"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.inventory.arn]
  }
}

resource "aws_s3_bucket_policy" "inventory" {
  bucket = aws_s3_bucket.inventory.id
  policy = data.aws_iam_policy_document.inventory_bucket.json
}

# 全VM(repository/infra/test/stg/prod)を対象に、インストール済みパッケージ一覧を収集する
resource "aws_ssm_association" "inventory" {
  name                = "AWS-GatherSoftwareInventory"
  association_name    = "${local.name}-daily-inventory"
  schedule_expression = var.inventory_schedule

  parameters = {
    applications = "Enabled"
  }

  targets {
    key    = "tag:PatchGroup"
    values = values(local.patch_groups)
  }
}

resource "aws_ssm_resource_data_sync" "inventory" {
  name = "${local.name}-inventory-sync"

  s3_destination {
    bucket_name = aws_s3_bucket.inventory.id
    prefix      = "inventory"
    region      = var.aws_region
    sync_format = "JsonSerDe"
  }

  depends_on = [aws_s3_bucket_policy.inventory]
}

# ---------------------------------------------------------------------------
# Glue/Athena
# ---------------------------------------------------------------------------

resource "aws_glue_catalog_database" "patch_mgmt" {
  name = replace("${local.name}_inventory", "-", "_")
}

resource "aws_iam_role" "glue_crawler" {
  name = "${local.name}-glue-crawler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_crawler_service" {
  role       = aws_iam_role.glue_crawler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_crawler_s3" {
  name = "read-inventory-bucket"
  role = aws_iam_role.glue_crawler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [aws_s3_bucket.inventory.arn, "${aws_s3_bucket.inventory.arn}/*"]
    }]
  })
}

# InventoryのJSONとtrivyのスキャン結果JSONの両方を、毎日のスキャンの後にクロールしてテーブル化する
resource "aws_glue_crawler" "inventory" {
  name          = "${local.name}-inventory-crawler"
  role          = aws_iam_role.glue_crawler.arn
  database_name = aws_glue_catalog_database.patch_mgmt.name
  schedule      = var.inventory_crawler_schedule

  s3_target {
    path = "s3://${aws_s3_bucket.inventory.id}/inventory/"
  }

  s3_target {
    path = "s3://${aws_s3_bucket.inventory.id}/trivy-results/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }
}
