output "url" {
  value = "https://${var.subdomain}.${var.domain_name}"
}

output "bucket_name" {
  value = aws_s3_bucket.site.id
}

output "distribution_id" {
  value = aws_cloudfront_distribution.site.id
}

output "key_value_store_arn" {
  value = aws_cloudfront_key_value_store.release_gate.arn
}
