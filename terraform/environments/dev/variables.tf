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

variable "rke2_instance_type" {
  description = "RKE2ノードのインスタンスタイプ(server単体でもある程度のCPU/メモリが必要)"
  type        = string
  default     = "t3.medium"
}

variable "rhel_org_id" {
  description = "Red HatのOrg ID(subscription-manager register用)。GitHub SecretsからTF_VAR_rhel_org_idとして渡す"
  type        = string
  sensitive   = true
}

variable "rhel_activation_key" {
  description = "Red Hatのactivation key(subscription-manager register用)。GitHub SecretsからTF_VAR_rhel_activation_keyとして渡す"
  type        = string
  sensitive   = true
}
