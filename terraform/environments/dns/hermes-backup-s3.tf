# Hermes Agentの永続データ(/opt/data、PVC)のバックアップ先。
# "memory"や"skills"など、失うと学習内容がリセットされてしまうデータなので、
# CronJobで日次バックアップする(manifests/hermes-agent/backup-cronjob.yaml)。
resource "aws_s3_bucket" "hermes_backups" {
  bucket = "${var.project_name}-hermes-backups"

  tags = {
    Name = "${var.project_name}-hermes-backups"
  }
}

resource "aws_s3_bucket_versioning" "hermes_backups" {
  bucket = aws_s3_bucket.hermes_backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "hermes_backups" {
  bucket = aws_s3_bucket.hermes_backups.id
  rule {
    id     = "expire-old-backups"
    status = "Enabled"
    filter {}
    expiration {
      days = 90
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_s3_bucket_public_access_block" "hermes_backups" {
  bucket                  = aws_s3_bucket.hermes_backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 既存のSSM Hybrid Activationロール(自宅サーバが引き受ける一時クレデンシャル)に
# このバケットへの書き込み権限だけを追加する。新しいIAMユーザーは作らない。
resource "aws_iam_role_policy" "ssm_hybrid_activation_hermes_backup" {
  name = "hermes-backup-s3"
  role = aws_iam_role.ssm_hybrid_activation.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PutAndListBackups"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.hermes_backups.arn, "${aws_s3_bucket.hermes_backups.arn}/*"]
      },
    ]
  })
}
