# The app and shared-service names on the server (#66, #68), used by dns.tf, secrets.tf and
# outputs.tf. apps.json is generated from registry/projects.json in project-standards and arrives
# by the standards sync, so adding an app is one registry edit; do not edit apps.json here.
#   apps           every active app's registry `name`, which is also its subdomain
#   sharedServices shared-service subdomains: auth (sirloinbh/shared-auth, ADR-0015) and
#                  ai (sirloinbh/shared-ai, ADR-0017)
#   secretApps     apps and shared services whose own SSM keys the server may read
locals {
  registry = jsondecode(file("${path.module}/apps.json"))
}
