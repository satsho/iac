variable "aws_region" {
  description = "リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "リソース名のプレフィックス"
  type        = string
  default     = "iac-poc"
}

variable "domain_name" {
  description = "お名前.comで取得しRoute 53に委任したドメイン名"
  type        = string
  default     = "focus4.net"
}
