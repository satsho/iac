terraform {
  backend "s3" {
    bucket       = "satsho-iac-tfstate"
    key          = "patch-mgmt/terraform.tfstate"
    region       = "ap-northeast-1"
    encrypt      = true
    use_lockfile = true # Terraform 1.10+ のS3ネイティブロック。DynamoDB不要
  }
}
