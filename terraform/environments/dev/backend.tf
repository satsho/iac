terraform {
  backend "s3" {
    bucket       = "satsho-iac-tfstate"
    key          = "dev/vpc/terraform.tfstate"
    region       = "ap-northeast-1"
    encrypt      = true
    use_lockfile = true
  }
}
