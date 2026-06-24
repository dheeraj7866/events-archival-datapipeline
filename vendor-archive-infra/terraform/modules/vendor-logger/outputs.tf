output "instance_id" { value = aws_instance.vl.id }
output "private_ip" { value = aws_instance.vl.private_ip }
output "public_ip" { value = var.allocate_eip ? aws_eip.vl[0].public_ip : aws_instance.vl.public_ip }
output "private_dns" { value = aws_instance.vl.private_dns }
output "security_group_id" { value = aws_security_group.vl.id }
output "instance_profile_name" { value = aws_iam_instance_profile.vl.name }
