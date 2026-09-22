data "aws_ami" "custom" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "tag:Purpose"
    values = ["learning"]
  }

  filter {
    name   = "name"
    values = ["iac-poc-al2023-*"]
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

resource "aws_instance" "test" {
  ami                    = data.aws_ami.custom.id
  instance_type          = "t2.micro"
  subnet_id              = values(module.vpc.public_subnet_ids)[0]
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  tags = {
    Name = "${var.project_name}-test-instance"
  }
}
