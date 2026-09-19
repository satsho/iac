variable "aws_region" {
  description = "リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "state_bucket_name" {
  description = "tfstateを保存するS3バケット名(グローバルで一意である必要あり)"
  type        = string
  default     = "satsho-iac-tfstate"
}

variable "lock_table_name" {
  description = "state lock用のDynamoDBテーブル名"
  type        = string
  default     = "satsho-iac-tfstate-lock"
}
