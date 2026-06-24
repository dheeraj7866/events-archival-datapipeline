output "function_arn" { value = aws_lambda_function.archiver.arn }
output "function_name" { value = aws_lambda_function.archiver.function_name }
output "lambda_sg_id" { value = aws_security_group.lambda.id }
output "clickhouse_secret_arn" { value = aws_secretsmanager_secret.clickhouse_password.arn }
