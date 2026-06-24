output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs (one per AZ)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (one per AZ) - use for Lambda + ClickHouse EC2"
  value       = aws_subnet.private[*].id
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs"
  value       = aws_nat_gateway.this[*].id
}

output "nat_public_ips" {
  description = "EIPs of NAT gateway(s)"
  value       = aws_eip.nat[*].public_ip
}

output "vpc_endpoint_s3_id" {
  value = aws_vpc_endpoint.s3.id
}

output "vpc_endpoint_sqs_id" {
  value = aws_vpc_endpoint.sqs.id
}

output "vpc_endpoint_kms_id" {
  value = aws_vpc_endpoint.kms.id
}

output "vpc_endpoint_secretsmanager_id" {
  value = aws_vpc_endpoint.secretsmanager.id
}

output "vpc_endpoints_sg_id" {
  description = "Security group ID attached to all interface VPC endpoints"
  value       = aws_security_group.vpc_endpoints.id
}

output "flow_log_group_name" {
  value = aws_cloudwatch_log_group.flow_logs.name
}
