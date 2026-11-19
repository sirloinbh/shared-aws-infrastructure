# The server's static IP as a plain (not secret) parameter next to the shared keys, so tools read it
# instead of people copying it by hand (#69). project-standards `server-ip` and `server-ssh` read it,
# and fall back to resolving the app DNS names when the profile cannot. The server's reader user can
# read it too: its policy already covers /sirloinbh/shared/*.
resource "aws_ssm_parameter" "server_static_ip" {
  name        = "/sirloinbh/shared/server-static-ip"
  description = "Public static IP of the shared Lightsail server (managed by Terraform, not a secret)"
  type        = "String"
  value       = aws_lightsail_static_ip.app.ip_address
  tags        = local.tags
  depends_on  = [terraform_data.account_guard]
}
