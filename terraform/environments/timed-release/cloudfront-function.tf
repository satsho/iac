resource "aws_cloudfront_key_value_store" "release_gate" {
  name = "${var.project_name}-${var.subdomain}-kvs"
}

# 初期値だけTerraformで作り、以降の更新はAWS CLIで直接行う(README参照)。
# release_timeは頻繁に書き換える値なので、他の変更をapplyした拍子に
# variables.tfのdefaultへ巻き戻ってしまわないよう、valueの変更はTerraformの
# 管理外にする。
resource "aws_cloudfrontkeyvaluestore_key" "release_time" {
  key_value_store_arn = aws_cloudfront_key_value_store.release_gate.arn
  key                  = "release_time_secret_jpg"
  value                = var.release_time

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_cloudfront_function" "release_gate" {
  name    = "${var.project_name}-${var.subdomain}-release-gate"
  runtime = "cloudfront-js-2.0" # KVS APIを使うため1.0ではなく2.0が必須
  comment = "指定日時までimages/secret.jpgを403にする"
  publish = true
  code    = file("${path.module}/files/release-gate.js")

  key_value_store_associations = [aws_cloudfront_key_value_store.release_gate.arn]
}
