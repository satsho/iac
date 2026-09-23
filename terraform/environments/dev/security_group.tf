resource "aws_security_group" "instance" {
  name        = "${var.project_name}-instance-sg"
  description = "Trial instance, SSM access only (no inbound rules)"
  vpc_id      = module.network.vpc_id

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
