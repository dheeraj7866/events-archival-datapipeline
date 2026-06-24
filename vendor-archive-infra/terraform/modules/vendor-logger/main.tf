data "aws_region" "current" {}

# ──────────────────────────────────────────────────────────────────────────────
# finagle-vendor-logger producer host — single small EC2 (prod).
# Stateless Node service (the @finagle/vendor-logger app): captures vendor API
# events and SendMessage → SQS. No local data, so no data EBS / snapshots —
# just a small root volume and the Docker image. Deployed by Jenkinsfile-prod
# (docker compose -f docker-compose.prod.yml over SSH).
# ──────────────────────────────────────────────────────────────────────────────

# Latest Ubuntu 22.04 LTS (Jammy) — same family/owner as the clickhouse module.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ── Security group ─────────────────────────────────────────────────────────────
resource "aws_security_group" "vl" {
  name        = "${var.name_prefix}-vendor-logger-sg"
  description = "vendor-logger producer - egress to SQS/ECR/Secrets; optional internal app + SSH ingress"
  vpc_id      = var.vpc_id

  # App port — only from explicitly allowed internal callers (CIDRs or SGs).
  dynamic "ingress" {
    for_each = length(var.allowed_app_ingress_cidrs) > 0 ? [1] : []
    content {
      description = "App port from internal CIDRs"
      from_port   = var.app_port
      to_port     = var.app_port
      protocol    = "tcp"
      cidr_blocks = var.allowed_app_ingress_cidrs
    }
  }

  dynamic "ingress" {
    for_each = length(var.allowed_app_ingress_sg_ids) > 0 ? [1] : []
    content {
      description     = "App port from internal SGs"
      from_port       = var.app_port
      to_port         = var.app_port
      protocol        = "tcp"
      security_groups = var.allowed_app_ingress_sg_ids
    }
  }

  # nginx HTTP (80) — public for Let's Encrypt ACME + redirect to HTTPS.
  dynamic "ingress" {
    for_each = length(var.allowed_web_ingress_cidrs) > 0 ? [1] : []
    content {
      description = "HTTP (nginx) - ACME + redirect"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = var.allowed_web_ingress_cidrs
    }
  }

  # nginx HTTPS (443) — public TLS endpoint (logger.tezcredit.com).
  dynamic "ingress" {
    for_each = length(var.allowed_web_ingress_cidrs) > 0 ? [1] : []
    content {
      description = "HTTPS (nginx) - logger.tezcredit.com"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = var.allowed_web_ingress_cidrs
    }
  }

  # SSH from bastion SG. Empty list = no SG-based SSH.
  dynamic "ingress" {
    for_each = length(var.bastion_sg_ids) > 0 ? [1] : []
    content {
      description     = "SSH from bastion"
      from_port       = 22
      to_port         = 22
      protocol        = "tcp"
      security_groups = var.bastion_sg_ids
    }
  }

  # SSH from explicit CIDRs (e.g. Jenkins /32). Empty = no CIDR-based SSH.
  dynamic "ingress" {
    for_each = length(var.allowed_ssh_cidrs) > 0 ? [1] : []
    content {
      description = "SSH from allowed CIDRs (Jenkins)"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.allowed_ssh_cidrs
    }
  }

  egress {
    description = "All outbound (SQS, ECR, Secrets Manager, package mirrors)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-vendor-logger-sg" })
}

# ── Instance profile from the existing vendor-logger-svc role ──────────────────
# The iam module owns the role (SQS send + KMS + salt-secret read, trusts
# ec2.amazonaws.com). We only add the management/runtime bits the host needs:
# SSM (no-SSH ops) and ECR pull (docker pull the image).
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = var.iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Scoped ECR pull when a repo ARN is given; otherwise the AWS-managed read-only policy.
resource "aws_iam_role_policy_attachment" "ecr_read_managed" {
  count      = var.ecr_repository_arn == "" ? 1 : 0
  role       = var.iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy" "ecr_pull_scoped" {
  count = var.ecr_repository_arn != "" ? 1 : 0
  name  = "${var.name_prefix}-vendor-logger-ecr-pull"
  role  = var.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuthToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "EcrPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability",
        ]
        Resource = var.ecr_repository_arn
      },
    ]
  })
}

resource "aws_iam_instance_profile" "vl" {
  name = "${var.name_prefix}-vendor-logger"
  role = var.iam_role_name
}

# ── EC2 instance ──────────────────────────────────────────────────────────────
resource "aws_instance" "vl" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.vl.id]
  iam_instance_profile        = aws_iam_instance_profile.vl.name
  key_name                    = var.key_pair_name != "" ? var.key_pair_name : null
  associate_public_ip_address = var.associate_public_ip

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    kms_key_id            = var.kms_key_arn != "" ? var.kms_key_arn : null
    delete_on_termination = true
  }

  disable_api_termination = var.environment == "prod"

  # Installs Docker + compose plugin + AWS CLI v2 and prepares the deploy dir.
  # The actual app rollout is done by Jenkinsfile-prod (docker compose over SSH);
  # gzipped to stay under EC2's 16KB user-data limit.
  user_data_base64 = base64gzip(templatefile("${path.module}/user_data.sh.tpl", {
    region      = data.aws_region.current.name
    deploy_dir  = var.deploy_dir
    app_port    = var.app_port
    domain_name = var.domain_name
  }))

  tags = merge(var.tags, {
    Name        = "${var.name_prefix}-vendor-logger"
    Environment = var.environment
  })

  lifecycle {
    ignore_changes = [ami, user_data_base64]
  }
}

# ── Elastic IP (stable address, survives instance replacement) ───────────────
resource "aws_eip" "vl" {
  count    = var.allocate_eip ? 1 : 0
  domain   = "vpc"
  instance = aws_instance.vl.id
  tags     = merge(var.tags, { Name = "${var.name_prefix}-vendor-logger" })
}

# ── CloudWatch alarms ────────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.name_prefix}-vendor-logger-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  treat_missing_data  = "notBreaching"

  dimensions = { InstanceId = aws_instance.vl.id }

  alarm_description = "vendor-logger EC2 CPU > 85% sustained"
  alarm_actions     = var.alert_sns_arns
  tags              = var.tags
}

resource "aws_cloudwatch_metric_alarm" "status_check" {
  alarm_name          = "${var.name_prefix}-vendor-logger-status-check"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "breaching"

  dimensions = { InstanceId = aws_instance.vl.id }

  alarm_description = "vendor-logger EC2 status check failed - instance health issue"
  alarm_actions     = var.alert_sns_arns
  tags              = var.tags
}
