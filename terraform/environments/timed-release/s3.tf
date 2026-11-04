# テストページ・画像の置き場。完全非公開にし、CloudFront(Origin Access Control)
# 経由でしかアクセスできないようにする。これが無いと、CloudFront Functionsで
# 日時制限をかけても、S3の直接URLから画像が見えてしまう。
resource "aws_s3_bucket" "site" {
  bucket = "${var.project_name}-${var.subdomain}"
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.project_name}-${var.subdomain}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_iam_policy_document" "site_bucket" {
  statement {
    sid    = "AllowCloudFrontServicePrincipal"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site_bucket.json
}

# テスト用の簡単なページ。実際にjpeg画像を置く手順はREADME参照(バイナリを
# Terraformにコミットしないため、手動でaws s3 cpする)。
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.site.id
  key          = "index.html"
  content_type = "text/html"
  content      = <<-EOT
    <!DOCTYPE html>
    <html lang="ja">
    <head><meta charset="utf-8"><title>日時指定公開テスト</title></head>
    <body>
      <h1>日時指定公開テスト</h1>
      <p>下の画像は指定した日時まで403になります。</p>
      <img src="/images/secret.jpg" alt="secret">
    </body>
    </html>
  EOT
}
