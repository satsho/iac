variable "project_name" {
  description = "リソース名のプレフィックスに使うプロジェクト名"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC全体のCIDRブロック"
  type        = string
}

variable "public_subnet_cidrs" {
  description = "AZ名 => CIDR のマップ。例: { \"ap-northeast-1a\" = \"10.0.0.0/24\" }"
  type        = map(string)
}

variable "tags" {
  description = "全リソースに共通で付与するタグ"
  type        = map(string)
  default     = {}
}
