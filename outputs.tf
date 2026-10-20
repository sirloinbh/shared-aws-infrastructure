output "static_ip" { value = aws_lightsail_static_ip.app.ip_address }
output "url" { value = "http://${aws_lightsail_static_ip.app.ip_address}" }
output "ssh" { value = "ssh -i ~/.ssh/workout-memo-lightsail ubuntu@${aws_lightsail_static_ip.app.ip_address}" }
output "allowed_cidrs" { value = var.allowed_cidrs }
