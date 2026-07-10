data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ──────────────────────────────────────────────────────────────────────────────
# ClickHouse EC2 - single node r6i.xlarge for MVP
# Phase 1.5: add replica node + 3x Keeper nodes via count variable
# ──────────────────────────────────────────────────────────────────────────────

# Latest Ubuntu 22.04 LTS (Jammy) AMI - official Canonical owner
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
resource "aws_security_group" "clickhouse" {
  name        = "${var.name_prefix}-clickhouse-sg"
  description = "ClickHouse EC2 - ingress from Lambda and bastion only"
  vpc_id      = var.vpc_id

  # Native protocol (Lambda archiver)
  ingress {
    description     = "ClickHouse native from Lambda"
    from_port       = 9000
    to_port         = 9000
    protocol        = "tcp"
    security_groups = var.allowed_ingress_sg_ids
  }

  # HTTP interface (Grafana datasource + ad-hoc queries)
  ingress {
    description     = "ClickHouse HTTP from Lambda + Grafana"
    from_port       = 8123
    to_port         = 8123
    protocol        = "tcp"
    security_groups = var.allowed_ingress_sg_ids
  }

  # Keeper inter-node (P1.5 HA)
  ingress {
    description = "ClickHouse Keeper intra-cluster"
    from_port   = 9181
    to_port     = 9181
    protocol    = "tcp"
    self        = true
  }

  # Replication traffic between replicas (P1.5)
  ingress {
    description = "ClickHouse interserver replication"
    from_port   = 9009
    to_port     = 9009
    protocol    = "tcp"
    self        = true
  }

  # SSH - only from bastion or via SSM (no open-internet SSH)
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

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-clickhouse-sg" })

  # The env adds the Lambda→CH ingress (9000/8123) as standalone
  # aws_security_group_rule resources to break the clickhouse<->lambda module cycle.
  # An aws_security_group with inline rules otherwise tries to OWN the full rule set
  # and revokes those standalone rules on every apply. Ignore ingress drift so the
  # two coexist. (Cleaner long-term: move ALL rules to standalone and drop inline.)
  lifecycle {
    ignore_changes = [ingress]
  }
}

# ── EBS data volume - separate from root so snapshots are clean ───────────────
resource "aws_ebs_volume" "clickhouse_data" {
  availability_zone = "${data.aws_region.current.name}a"
  size              = var.data_volume_size_gb
  type              = "gp3"
  iops              = 3000
  throughput        = 250
  encrypted         = true
  # Use CMK when provided, otherwise fall back to AWS-managed EBS key
  kms_key_id = var.kms_key_arn != "" ? var.kms_key_arn : null

  tags = merge(var.tags, { Name = "${var.name_prefix}-clickhouse-data" })
}

# ── IAM role + profile for EC2 (SSM access, no SSH required) ─────────────────
resource "aws_iam_role" "clickhouse" {
  name               = "${var.name_prefix}-clickhouse-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.clickhouse.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "clickhouse" {
  name = "${var.name_prefix}-clickhouse-ec2"
  role = aws_iam_role.clickhouse.name
}

# ── Bootstrap permissions: manage the ClickHouse credentials in Secrets Manager ─
# Scoped to this stack's own clickhouse/* secrets. KMS decrypt/genkey is allowed via
# the CMK's IAM-delegation key policy, so no kms module change is needed.
# (dev variant — see user_data.sh.tpl note for the prod-hardened approach.)
resource "aws_iam_role_policy" "clickhouse_bootstrap" {
  name   = "${var.name_prefix}-clickhouse-bootstrap"
  role   = aws_iam_role.clickhouse.id
  policy = data.aws_iam_policy_document.clickhouse_bootstrap.json
}

data "aws_iam_policy_document" "clickhouse_bootstrap" {
  statement {
    sid    = "ManageClickHouseCredentials"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.name_prefix}/clickhouse/*",
    ]
  }

  dynamic "statement" {
    for_each = var.kms_key_arn != "" ? [1] : []
    content {
      sid       = "DecryptSecretsViaCmk"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
      resources = [var.kms_key_arn]
    }
  }
}

# ── EC2 instance ──────────────────────────────────────────────────────────────
resource "aws_instance" "clickhouse" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.clickhouse.id]
  iam_instance_profile   = aws_iam_instance_profile.clickhouse.name
  key_name               = var.key_pair_name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    kms_key_id            = var.kms_key_arn != "" ? var.kms_key_arn : null
    delete_on_termination = true
  }

  # Prevent accidental termination - ClickHouse data is on separate EBS
  disable_api_termination = var.environment == "prod"

  # base64gzip (not base64encode): the rendered script (incl. the inlined init.sql)
  # exceeds EC2's 16KB user-data limit, so gzip it — cloud-init auto-decompresses
  # gzipped user-data, and the 16KB limit applies to the compressed (~5KB) bytes.
  user_data_base64 = base64gzip(templatefile("${path.module}/user_data.sh.tpl", {
    ch_version         = var.clickhouse_version
    data_device        = "/dev/xvdf"
    data_mount         = "/var/lib/clickhouse"
    ch_user            = "clickhouse"
    ch_group           = "clickhouse"
    region             = data.aws_region.current.name
    archiver_secret_id = "${var.name_prefix}/clickhouse/archiver-password"
    init_sql           = var.init_sql
  }))

  tags = merge(var.tags, {
    Name        = "${var.name_prefix}-clickhouse"
    Backup      = "daily"
    Environment = var.environment
  })

  lifecycle {
    ignore_changes = [ami, user_data_base64]
  }
}

resource "aws_volume_attachment" "clickhouse_data" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.clickhouse_data.id
  instance_id = aws_instance.clickhouse.id
}

# ── Automated EBS snapshots via Data Lifecycle Manager ───────────────────────
resource "aws_iam_role" "dlm" {
  name               = "${var.name_prefix}-dlm-role"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "dlm_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "clickhouse_daily" {
  description        = "${var.name_prefix} ClickHouse daily EBS snapshot"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    schedule {
      name      = "daily-7d-retention"
      copy_tags = true

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["02:00"]
      }

      retain_rule {
        count = 7
      }
    }

    target_tags = {
      Name = "${var.name_prefix}-clickhouse-data"
    }
  }

  tags = var.tags
}

# ── CloudWatch alarms for EC2 health ─────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "ch_cpu_high" {
  alarm_name          = "${var.name_prefix}-clickhouse-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "breaching"

  dimensions = { InstanceId = aws_instance.clickhouse.id }

  alarm_description = "ClickHouse EC2 CPU > 80% - consider scaling or query optimisation"
  alarm_actions     = var.alert_sns_arns
  tags              = var.tags
}

resource "aws_cloudwatch_metric_alarm" "ch_disk_high" {
  alarm_name          = "${var.name_prefix}-clickhouse-disk-queue"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "VolumeQueueLength"
  namespace           = "AWS/EBS"
  period              = 60
  statistic           = "Average"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  dimensions = { VolumeId = aws_ebs_volume.clickhouse_data.id }

  alarm_description = "ClickHouse data EBS queue depth > 10 - I/O saturation"
  alarm_actions     = var.alert_sns_arns
  tags              = var.tags
}

resource "aws_cloudwatch_metric_alarm" "ch_status_check" {
  alarm_name          = "${var.name_prefix}-clickhouse-status-check"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "breaching"

  dimensions = { InstanceId = aws_instance.clickhouse.id }

  alarm_description = "ClickHouse EC2 status check failed - instance health issue"
  alarm_actions     = var.alert_sns_arns
  tags              = var.tags
}
