# App subdomains under the shared domain (#33, project-standards ADR-0012): one A record per app
# points at the server, where one nginx forwards each name to that app's web port. No wildcard
# record, so names that are not an app do not reach the server.
locals {
  # The registry `name` of every active app, which is also its subdomain
  # (registry/projects.json in project-standards). Add an app here when it is registered.
  apps = ["workout-memo", "study-log", "health-log", "life-journal", "money-ledger", "cert-manager", "plan-routine", "dev-career-portfolio"]
}

# The domain registration created this zone and pointed the domain's name servers at it. It is read,
# not managed: a new zone would get other name servers, and destroying it would take the domain offline.
data "aws_route53_zone" "root" {
  name         = var.root_domain
  private_zone = false
}

resource "aws_route53_record" "apps" {
  for_each   = toset(local.apps)
  zone_id    = data.aws_route53_zone.root.zone_id
  name       = "${each.key}.${var.root_domain}"
  type       = "A"
  ttl        = 300
  records    = [aws_lightsail_static_ip.app.ip_address]
  depends_on = [terraform_data.account_guard]
}

# certbot on the server renews the wildcard certificate with DNS validation (certbot dns-route53).
# Its key can only write the one TXT record Let's Encrypt checks. The access key is made in the
# console (docs/operations.md section 10).
resource "aws_iam_user" "certbot" {
  name       = "${local.shared_prefix}-certbot"
  tags       = local.tags
  depends_on = [terraform_data.account_guard]
}

resource "aws_iam_user_policy" "certbot" {
  name = "acme-dns-challenge"
  user = aws_iam_user.certbot.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # certbot finds the zone by listing; this API has no resource-level permission.
        Sid      = "FindZone"
        Effect   = "Allow"
        Action   = "route53:ListHostedZones"
        Resource = "*"
      },
      {
        Sid      = "WaitForChange"
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:aws:route53:::change/*"
      },
      {
        Sid      = "WriteChallengeRecord"
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = data.aws_route53_zone.root.arn
        Condition = {
          # ForAllValues alone would also pass when the key is missing, so require it.
          Null = { "route53:ChangeResourceRecordSetsNormalizedRecordNames" = "false" }
          "ForAllValues:StringEquals" = {
            "route53:ChangeResourceRecordSetsNormalizedRecordNames" = ["_acme-challenge.${var.root_domain}"]
            "route53:ChangeResourceRecordSetsRecordTypes"           = ["TXT"]
          }
        }
      },
    ]
  })
}
