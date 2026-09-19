output "state_bucket_name" {
  description = "environments/dev/backend.tf に設定するバケット名"
  value       = aws_s3_bucket.tfstate.id
}

output "lock_table_name" {
  description = "environments/dev/backend.tf に設定するDynamoDBテーブル名"
  value       = aws_dynamodb_table.tfstate_lock.name
}
