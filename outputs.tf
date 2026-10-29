output "static_ip" { value = aws_lightsail_static_ip.app.ip_address }
output "url" { value = "http://${aws_lightsail_static_ip.app.ip_address}" }
output "ssh" { value = "ssh -i ~/.ssh/workout-memo-lightsail ubuntu@${aws_lightsail_static_ip.app.ip_address}" }
output "allowed_cidrs" { value = var.allowed_cidrs }
# Values for the server .env of each app (#7, #8). Access keys are made in the console.
output "backup_bucket" { value = aws_s3_bucket.backups.bucket }
output "backup_uploader_user" { value = aws_iam_user.backup_uploader.name }
output "secrets_reader_user" { value = aws_iam_user.secrets_reader.name }
output "claude_key_parameter" { value = local.claude_key_parameter }
