data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Use the first N AZs available in the region
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

# ──────────────────────────────────────────────────────────────────────────────
# VPC
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpc" })
}

# ──────────────────────────────────────────────────────────────────────────────
# Internet Gateway (needed for public subnets + NAT gateway)
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-igw" })
}

# ──────────────────────────────────────────────────────────────────────────────
# Subnets - public (NAT GW, bastion) + private (Lambda, ClickHouse EC2)
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_subnet" "public" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  map_public_ip_on_launch = false # No auto-assign; bastion gets EIP explicitly

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public-${local.azs[count.index]}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-private-${local.azs[count.index]}"
    Tier = "private"
  })
}

# ──────────────────────────────────────────────────────────────────────────────
# NAT Gateway - one per AZ in prod, one shared in staging
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_eip" "nat" {
  count  = var.single_nat_gateway ? 1 : var.az_count
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nat-eip-${count.index}"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count         = var.single_nat_gateway ? 1 : var.az_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nat-${count.index}"
  })

  depends_on = [aws_internet_gateway.this]
}

# ──────────────────────────────────────────────────────────────────────────────
# Route tables
# ──────────────────────────────────────────────────────────────────────────────

# Public route table - all traffic → IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-rt-public" })
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route tables - one per AZ if multi-NAT, one shared if single-NAT
resource "aws_route_table" "private" {
  count  = var.single_nat_gateway ? 1 : var.az_count
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.this[0].id : aws_nat_gateway.this[count.index].id
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-rt-private-${count.index}"
  })
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = var.single_nat_gateway ? aws_route_table.private[0].id : aws_route_table.private[count.index].id
}

# ──────────────────────────────────────────────────────────────────────────────
# VPC Endpoints
# Lambda runs in private subnets. Without endpoints it would use NAT to reach
# AWS services - adding interface endpoints keeps all AWS API traffic on-net
# (cheaper, lower latency, no NAT bottleneck).
#
# Endpoints provisioned:
#   - S3          (gateway - free, handles bucket traffic)
#   - SQS         (interface)
#   - KMS         (interface)
#   - Secrets Manager (interface - Lambda fetches CH password)
#   - CloudWatch Logs (interface - Lambda log delivery)
# ──────────────────────────────────────────────────────────────────────────────

# Security group shared by all interface endpoints
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.name_prefix}-vpc-endpoints-sg"
  description = "Allow HTTPS from within the VPC to interface endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from VPC CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpc-endpoints-sg" })
}

# S3 - Gateway endpoint (attached to private route tables)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-s3" })
}

# SQS - Interface endpoint
resource "aws_vpc_endpoint" "sqs" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.sqs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-sqs" })
}

# KMS - Interface endpoint
resource "aws_vpc_endpoint" "kms" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.kms"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-kms" })
}

# Secrets Manager - Interface endpoint
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-secretsmanager" })
}

# CloudWatch Logs - Interface endpoint (Lambda log delivery from private subnet)
resource "aws_vpc_endpoint" "logs" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-logs" })
}

# SSM - Interface endpoint (for EC2 Session Manager instead of SSH)
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-ssm" })
}

resource "aws_vpc_endpoint" "ssm_messages" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-ssmmessages" })
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-ec2messages" })
}

# ──────────────────────────────────────────────────────────────────────────────
# Default security group - deny all inbound + outbound (belt-and-suspenders)
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.this.id

  # No ingress or egress rules - deny everything on the default SG
  tags = merge(var.tags, { Name = "${var.name_prefix}-default-sg-deny-all" })
}

# ──────────────────────────────────────────────────────────────────────────────
# VPC Flow Logs - captured to CloudWatch for network audit
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/${var.name_prefix}-flow-logs"
  retention_in_days = var.flow_log_retention_days

  tags = var.tags
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.name_prefix}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "flow-logs-cw"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs_policy.json
}

data "aws_iam_policy_document" "flow_logs_policy" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["*"]
  }
}

resource "aws_flow_log" "this" {
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-flow-log" })
}
