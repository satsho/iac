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

variable "web_node_port" {
  description = "デモWebアプリ(nginx)をk3s上でNodePort公開するポート番号。ALBのターゲットグループも同じポートに転送する"
  type        = number
  default     = 30080
}

variable "rhel_ami_id" {
  description = <<-EOT
    RHEL 9のAMI ID。EC2コンソールの「インスタンスを起動」画面 → Quick Startタブ →
    Red Hatを選択して確認したAMI IDを指定する(data "aws_ami"での動的検索はこの
    AWSアカウント/リージョンでは公式所有者IDからAMIが見えなかったため断念した)。
    GitHub VariablesのRHEL_AMI_IDからTF_VAR_rhel_ami_idとして渡す想定。
  EOT
  type        = string
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
