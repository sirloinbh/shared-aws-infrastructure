output "static_ip" { value = aws_lightsail_static_ip.app.ip_address }
output "url" { value = "http://${aws_lightsail_static_ip.app.ip_address}" }
output "ssh" { value = "ssh -i ~/.ssh/workout-memo-lightsail ubuntu@${aws_lightsail_static_ip.app.ip_address}" }
output "allowed_cidrs" { value = var.allowed_cidrs }
# Values for the server .env of each app (#7, #8). Access keys are made in the console.
output "backup_bucket" { value = aws_s3_bucket.backups.bucket }
output "backup_uploader_user" { value = aws_iam_user.backup_uploader.name }
output "secrets_reader_user" { value = aws_iam_user.secrets_reader.name }
output "certbot_user" { value = aws_iam_user.certbot.name }
# study-log FILE_BUCKET and the user whose key goes in its server .env (#53).
output "study_log_files_bucket" { value = aws_s3_bucket.study_log_files.bucket }
output "study_log_files_user" { value = aws_iam_user.study_log_files.name }
output "app_urls" { value = [for app in local.registry.apps : "https://${app}.${var.root_domain}"] }
output "secrets_reader_paths" { value = concat(["/sirloinbh/shared/*"], [for app in local.secret_apps : "/sirloinbh/${app}/*"]) }
output "server_ip_parameter" { value = aws_ssm_parameter.server_static_ip.name }
