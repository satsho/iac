terraform {
  backend "s3" {
    bucket       = "satsho-iac-tfstate"
    key          = "timed-release/terraform.tfstate"
    region       = "ap-northeast-1"
    encrypt      = true
    use_lockfile = true
  }
}
