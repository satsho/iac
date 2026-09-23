# RHEL 9 の公式AMI(Red Hat所有)を検索する。
# 注意: "-Access2-"(BYOS/Cloud Access版)と"-Hourly2-"(AWS Marketplace従量課金版、
# サブスク登録不要でRHEL利用料がEC2料金に含まれる)が混在してヒットし得るため、
# terraform plan で解決されたAMI名を必ず確認し、Access2版になっているかチェックすること。
# Hourly2版を掴んでいた場合はfilterのvaluesに"*Access2*"を追加して絞り込む。
data "aws_ami" "rhel" {
  most_recent = true
  owners      = ["309956199834"] # Red Hat公式

  filter {
    name   = "name"
    values = ["RHEL-9*x86_64*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

moved {
  from = aws_instance.test
  to   = aws_instance.rke2
}

resource "aws_instance" "rke2" {
  ami                    = data.aws_ami.rhel.id
  instance_type          = var.rke2_instance_type
  subnet_id              = values(module.network.public_subnet_ids)[0]
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  ebs_optimized          = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  user_data = templatefile("${path.module}/templates/rke2-user-data.sh.tpl", {
    rhel_org_id         = var.rhel_org_id
    rhel_activation_key = var.rhel_activation_key
  })

  tags = {
    Name = "${var.project_name}-rke2-server"
    Role = "rke2-server"
  }
}
