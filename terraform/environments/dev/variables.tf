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

variable "vpc_cidr" {
  description = "VPC全体のCIDR"
  type        = string
  default     = "10.10.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "AZ名 => CIDR のマップ"
  type        = map(string)
  default = {
    "ap-northeast-1a" = "10.10.0.0/24"
    "ap-northeast-1c" = "10.10.1.0/24"
  }
}
