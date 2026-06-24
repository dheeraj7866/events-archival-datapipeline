variable "name_prefix" {
  description = "Resource name prefix"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC, e.g. 10.10.0.0/16"
  type        = string
}

variable "az_count" {
  description = "Number of availability zones to use (2 or 3)"
  type        = number
  default     = 2
}

variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "List of CIDR blocks for private subnets (one per AZ)"
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "Use a single NAT gateway instead of one per AZ (saves ~₹3k/mo - use true for staging)"
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "CloudWatch retention for VPC flow logs"
  type        = number
  default     = 30
}
