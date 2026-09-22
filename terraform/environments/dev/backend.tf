terraform {
  backend "s3" {
    # bootstrap の出力値に合わせて書き換える
    bucket       = "satsho-iac-tfstate"
    key          = "dev/vpc/terraform.tfstate"
    region       = "ap-northeast-1"
    encrypt      = true
    use_lockfile = true # Terraform 1.10+ のS3ネイティブロック。DynamoDB不要
  }
}
