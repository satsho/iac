# 通信経路は「CDN → repository → infra → 業務サーバ」の一方向だけを許可する。
#   repository: 873/tcp(rsync)と80/tcp(確認用)を infra からのみ受ける
#   infra     : 80/tcp(dnf)を業務サーバからのみ受ける
#   業務サーバ : インバウンド無し。アウトバウンドは restrict_workload_egress で絞る

resource "aws_security_group" "repository" {
  name        = "${local.name}-repository-sg"
  description = "Repository server, rsync and http from the infra mirror only"
  vpc_id      = aws_vpc.this.id

  egress {
    description = "All outbound (Red Hat CDN via NAT)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name}-repository-sg"
  }
}

resource "aws_security_group_rule" "repository_rsync_from_infra" {
  type                     = "ingress"
  from_port                = 873
  to_port                  = 873
  protocol                 = "tcp"
  security_group_id        = aws_security_group.repository.id
  source_security_group_id = aws_security_group.infra.id
  description              = "rsync daemon, infra mirror only"
}

resource "aws_security_group_rule" "repository_http_from_infra" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  security_group_id        = aws_security_group.repository.id
  source_security_group_id = aws_security_group.infra.id
  description              = "httpd, for checking the repository from infra"
}

resource "aws_security_group" "infra" {
  name        = "${local.name}-infra-sg"
  description = "Infra mirror, http from workloads only"
  vpc_id      = aws_vpc.this.id

  egress {
    description = "All outbound (repository rsync, Red Hat CDN via NAT)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name}-infra-sg"
  }
}

resource "aws_security_group_rule" "infra_http_from_workload" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  security_group_id        = aws_security_group.infra.id
  source_security_group_id = aws_security_group.workload.id
  description              = "dnf from test/stg/prod"
}

# egressブロックを書かないと、Terraformは新規SGに自動で付くallow-allのegressを削除する。
# 業務サーバのアウトバウンドは下の個別ルールだけになる。
resource "aws_security_group" "workload" {
  name        = "${local.name}-workload-sg"
  description = "test/stg/prod workloads, no inbound"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${local.name}-workload-sg"
  }
}

resource "aws_security_group_rule" "workload_to_infra" {
  count = var.restrict_workload_egress ? 1 : 0

  type                     = "egress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  security_group_id        = aws_security_group.workload.id
  source_security_group_id = aws_security_group.infra.id
  description              = "dnf to the infra mirror"
}

resource "aws_security_group_rule" "workload_to_endpoints" {
  count = var.restrict_workload_egress ? 1 : 0

  type                     = "egress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.workload.id
  source_security_group_id = aws_security_group.vpc_endpoint.id
  description              = "SSM and CloudWatch Logs interface endpoints"
}

resource "aws_security_group_rule" "workload_to_s3" {
  count = var.restrict_workload_egress ? 1 : 0

  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.workload.id
  prefix_list_ids   = [aws_vpc_endpoint.s3.prefix_list_id]
  description       = "S3 gateway endpoint (SSM agent RPM, patch snapshots)"
}

resource "aws_security_group_rule" "workload_all_egress" {
  count = var.restrict_workload_egress ? 0 : 1

  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.workload.id
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "All outbound (restrict_workload_egress = false)"
}

resource "aws_security_group" "vpc_endpoint" {
  name        = "${local.name}-vpc-endpoint-sg"
  description = "Interface VPC endpoints, https from inside the VPC"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${local.name}-vpc-endpoint-sg"
  }
}
