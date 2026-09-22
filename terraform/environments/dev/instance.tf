# RHEL 9 の公式AMI(Red Hat所有、BYOS/Cloud Access版=Access2)を検索する。
# 注意: AMI名のパターンはRed Hat側のリリースで変わることがあるため、
# terraform plan で解決されたAMI名を確認し、Marketplace従量課金版(Hourly2)を
# 誤って掴んでいないか確認すること。BYOSの場合サブスク登録はuser_data側で行う。
data "aws_ami" "rhel" {
  most_recent = true
  owners      = ["309956199834"] # Red Hat公式

  filter {
    name   = "name"
    values = ["RHEL-9*_HVM-*-x86_64-*-Access2-GP3"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

resource "aws_security_group" "instance" {
  name        = "${var.project_name}-instance-sg"
  description = "SSM経由のみでアクセスする試験用インスタンス(インバウンドなし)"
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-instance-sg"
  }
}

resource "aws_iam_role" "instance" {
  name = "iac-poc-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "iac-poc-instance-profile"
  role = aws_iam_role.instance.name
}

moved {
  from = aws_instance.test
  to   = aws_instance.rke2
}

resource "aws_instance" "rke2" {
  ami                    = data.aws_ami.rhel.id
  instance_type          = var.rke2_instance_type
  subnet_id              = values(module.vpc.public_subnet_ids)[0]
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
