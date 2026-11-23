output "static_ip" { value = aws_lightsail_static_ip.app.ip_address }
# The private key sits next to the public key: the same path without ".pub".
output "ssh" { value = "ssh -i ${trimsuffix(var.ssh_public_key_path, ".pub")} ubuntu@${aws_lightsail_static_ip.app.ip_address}" }
output "allowed_cidrs" { value = var.allowed_cidrs }
# Values for the server .env of each app (#7, #8). Access keys are made in the console.
output "backup_bucket" { value = module.backups.bucket }
output "backup_uploader_user" { value = aws_iam_user.backup_uploader.name }
output "secrets_reader_user" { value = aws_iam_user.secrets_reader.name }
output "certbot_user" { value = aws_iam_user.certbot.name }
# study-log FILE_BUCKET and the user whose key goes in its server .env (#53).
output "study_log_files_bucket" { value = module.study_log_files.bucket }
output "study_log_files_user" { value = aws_iam_user.study_log_files.name }
output "app_urls" { value = [for app in local.registry.apps : "https://${app}.${var.root_domain}"] }
output "secrets_reader_paths" { value = concat(["/sirloinbh/shared/*"], [for app in local.registry.secretApps : "/sirloinbh/${app}/*"]) }
output "server_ip_parameter" { value = aws_ssm_parameter.server_static_ip.name }
# The bucket name for the backend settings file (docs/operations.md section 3, #63).
output "state_bucket" { value = module.terraform_state.bucket }
# Study notes wiki: the three repository variables of sirloinbh/develop-skill (docs/operations.md section 12).
output "wiki_url" { value = "https://${local.wiki_domain}/" }
output "wiki_bucket" { value = module.wiki.bucket }
output "wiki_distribution_id" { value = aws_cloudfront_distribution.wiki.id }
output "wiki_deploy_role_arn" { value = aws_iam_role.wiki_deploy.arn }
# Uptime alert path (#105): AWS_ALERT_TOPIC_ARN, AWS_ALERT_REGION and AWS_ALERT_NAMESPACE for the server's shared .env; the user's access key is made in the console.
output "uptime_alert_user" { value = aws_iam_user.uptime_alerts.name }
output "uptime_alert_topic_arn" { value = aws_sns_topic.uptime.arn }
output "uptime_alert_namespace" { value = local.uptime_namespace }
