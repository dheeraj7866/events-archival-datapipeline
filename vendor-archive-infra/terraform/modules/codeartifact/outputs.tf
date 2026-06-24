output "domain_name" { value = aws_codeartifact_domain.vendor_logger.domain }
output "domain_owner" { value = aws_codeartifact_domain.vendor_logger.owner }

output "repository_name" { value = aws_codeartifact_repository.vendor_logger.repository }

output "npm_endpoint" {
  description = "npm registry endpoint - use as .npmrc registry"
  value       = "https://${aws_codeartifact_domain.vendor_logger.domain}-${aws_codeartifact_domain.vendor_logger.owner}.d.codeartifact.${data.aws_region.current.name}.amazonaws.com/npm/${aws_codeartifact_repository.vendor_logger.repository}/"
}
