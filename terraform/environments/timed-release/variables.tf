variable "aws_region" {
  description = "リージョン(S3バケット等。CloudFrontはグローバル、ACMはus-east-1固定)"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "リソース名のプレフィックス"
  type        = string
  default     = "iac-poc"
}

variable "domain_name" {
  description = "既存のRoute 53ゾーン(terraform/environments/dnsで管理)のドメイン名"
  type        = string
  default     = "focus4.net"
}

variable "subdomain" {
  description = "このテストページのサブドメイン(<subdomain>.<domain_name>でアクセスする)"
  type        = string
  default     = "release-test"
}

# CloudFront FunctionsのKVSに入れる値(aws_cloudfrontkeyvaluestore_key)。
# 初期値はテストしやすいよう過去日時にしておき、実際のテストでは未来日時に書き換える。
variable "release_time" {
  description = "images/secret.jpgを解禁するISO8601日時(UTC)。例: 2026-12-25T00:00:00Z"
  type        = string
  default     = "2020-01-01T00:00:00Z"
}
