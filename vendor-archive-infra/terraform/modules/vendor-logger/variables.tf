variable "name_prefix" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "Subnet ID for the vendor-logger instance (private subnet recommended; reaches SQS/ECR/Secrets via NAT)"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type — small by design (stateless Node producer)."
  type        = string
  default     = "t3.small"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB (OS + Docker image; no persistent data lives here)."
  type        = number
  default     = 20
}

variable "kms_key_arn" {
  description = "KMS key ARN for root volume encryption. Empty string = AWS-managed key."
  type        = string
  default     = ""
}

variable "key_pair_name" {
  description = "EC2 key pair for SSH. Empty = SSM Session Manager only."
  type        = string
  default     = ""
}

variable "iam_role_name" {
  description = "Name of the existing vendor-logger-svc IAM role (from the iam module). This module builds the instance profile from it and attaches SSM + ECR-read."
  type        = string
}

variable "associate_public_ip" {
  description = "Attach a public IP (set true only if Jenkins reaches the host directly over the internet; otherwise keep false and use a private subnet + SSM/bastion)."
  type        = bool
  default     = false
}

variable "allocate_eip" {
  description = "Allocate + associate a stable Elastic IP (survives instance replacement). Requires the host to be in a public subnet."
  type        = bool
  default     = false
}

variable "bastion_sg_ids" {
  description = "Security group IDs allowed SSH (22). Empty = no SSH ingress (SSM only)."
  type        = list(string)
  default     = []
}

variable "allowed_ssh_cidrs" {
  description = "CIDRs allowed SSH (22), e.g. Jenkins' IP as a /32. Empty = no CIDR-based SSH. Never use 0.0.0.0/0."
  type        = list(string)
  default     = []
}

variable "app_port" {
  description = "Host port the container publishes (docker-compose.prod.yml maps 9013:3013)."
  type        = number
  default     = 9013
}

variable "allowed_app_ingress_cidrs" {
  description = "CIDRs allowed to reach the app port (e.g. the VPC CIDR for internal callers). Empty = no app ingress."
  type        = list(string)
  default     = []
}

variable "allowed_app_ingress_sg_ids" {
  description = "Security group IDs allowed to reach the app port. Empty = none."
  type        = list(string)
  default     = []
}

variable "allowed_web_ingress_cidrs" {
  description = "CIDRs allowed to reach nginx on 80/443 (public HTTPS endpoint). Port 80 must be world-reachable for Let's Encrypt HTTP-01. Empty = no web ingress."
  type        = list(string)
  default     = []
}

variable "ecr_repository_arn" {
  description = "ARN of the ECR repo the image is pulled from (scopes the pull policy). Empty = use the AWS-managed ECR read-only policy (all repos)."
  type        = string
  default     = ""
}

variable "deploy_dir" {
  description = "Directory on the host where Jenkins places docker-compose.prod.yml/.env.prod and writes .env.secrets."
  type        = string
  default     = "/home/ubuntu/finagle_vendor_logger"
}

variable "domain_name" {
  description = "Public hostname nginx fronts (e.g. logger.tezcredit.com). Set => user_data installs nginx + an HTTP reverse proxy to the app port; run certbot once for TLS. Empty => skip nginx."
  type        = string
  default     = ""
}

variable "alert_sns_arns" {
  description = "SNS topic ARNs for CloudWatch alarm notifications."
  type        = list(string)
  default     = []
}
