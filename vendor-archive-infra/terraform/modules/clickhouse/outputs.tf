output "instance_id" { value = aws_instance.clickhouse.id }
output "private_ip" { value = aws_instance.clickhouse.private_ip }
output "private_dns" { value = aws_instance.clickhouse.private_dns }
output "security_group_id" { value = aws_security_group.clickhouse.id }
output "data_volume_id" { value = aws_ebs_volume.clickhouse_data.id }
