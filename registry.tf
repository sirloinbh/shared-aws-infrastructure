# The app and shared-service names on the server (#66, #68). The DNS records (dns.tf), the SSM read
# paths (secrets.tf) and the outputs all derive from it. apps.json is generated from
# registry/projects.json in project-standards and arrives by the standards sync, so adding an app
# is one registry edit; do not edit apps.json here.
locals {
  registry_file = jsondecode(file("${path.module}/apps.json"))

  registry = {
    # The registry `name` of every active app, which is also its subdomain.
    apps = local.registry_file.apps
    # Shared services (registry sharedServices) by subdomain: auth is sirloinbh/shared-auth
    # (ADR-0015), ai is sirloinbh/shared-ai (ADR-0017).
    services = local.registry_file.sharedServices
  }

  # Apps and shared services whose own keys the server may read (secrets.tf).
  secret_apps = local.registry_file.secretApps
}
