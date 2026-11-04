terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "timed-release"
      ManagedBy   = "terraform"
    }
  }
}

# ACM証明書はCloudFrontで使う場合、リージョンに関係なくus-east-1で発行する必要がある
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "timed-release"
      ManagedBy   = "terraform"
    }
  }
}
