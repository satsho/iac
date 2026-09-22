packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

source "amazon-ebs" "al2023" {
  ami_name      = "iac-poc-al2023-{{timestamp}}"
  instance_type = "t2.micro"
  region        = var.aws_region

  source_ami_filter {
    filters = {
      name                = "al2023-ami-*-x86_64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  ssh_username = "ec2-user"

  tags = {
    Name    = "iac-poc-al2023"
    Project = "iac-poc"
    Purpose = "learning"
  }
}

build {
  sources = ["source.amazon-ebs.al2023"]

  provisioner "shell" {
    inline = [
      "sudo dnf update -y",
      "sudo dnf install -y nginx",
      "sudo systemctl enable nginx"
    ]
  }
}
