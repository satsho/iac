resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # インターフェイスエンドポイントのプライベートDNS(ssm.<region>.amazonaws.com を
  # エンドポイントのENIに向ける)に両方とも必要
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name}-igw"
  }
}

# NAT Gateway を置くためだけのパブリックサブネット。EC2はすべてプライベート側に置く。
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name = "${local.name}-public"
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name = "${local.name}-private"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name}-public-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# repositoryがRed Hat CDNからreposyncするため、プライベートサブネットにもインターネットへの
# 出口(NAT)が必要。業務サーバはセキュリティグループ側で外に出られないようにしている。
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.name}-nat-eip"
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name = "${local.name}-nat"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name}-private-rt"
  }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# S3ゲートウェイエンドポイント(無料)。SSM Agent のRPMや、AWS-RunPatchBaseline が実行時に
# ダウンロードするパッチ処理用のファイルはS3から取得するので、業務サーバのSGで
# このプレフィックスリストだけを許可すればインターネットに出さずに済む。
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "${local.name}-s3"
  }
}

# 業務サーバのアウトバウンドを絞る場合に、SSM(Fleet Manager/Run Command/Session Manager)と
# Run Command出力のCloudWatch Logs送信をNAT無しで通すためのインターフェイスエンドポイント。
resource "aws_vpc_endpoint" "interface" {
  for_each = var.restrict_workload_egress ? toset(["ssm", "ssmmessages", "ec2messages", "logs"]) : toset([])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = {
    Name = "${local.name}-${each.key}"
  }
}
