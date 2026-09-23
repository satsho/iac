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
