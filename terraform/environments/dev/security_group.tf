resource "aws_security_group" "instance" {
  name        = "${var.project_name}-instance-sg"
  description = "Trial instance, inbound only from the ALB on the app NodePort"
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

resource "aws_security_group_rule" "instance_from_alb" {
  type                     = "ingress"
  from_port                = var.web_node_port
  to_port                  = var.web_node_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.instance.id
  source_security_group_id = aws_security_group.alb.id
  description              = "Web app NodePort from the ALB only"
}

resource "aws_security_group_rule" "instance_from_alb_keycloak" {
  type                     = "ingress"
  from_port                = var.keycloak_node_port
  to_port                  = var.keycloak_node_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.instance.id
  source_security_group_id = aws_security_group.alb.id
  description              = "Keycloak NodePort from the ALB only"
}

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Public ALB, HTTP from the internet"
  vpc_id      = module.network.vpc_id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}
