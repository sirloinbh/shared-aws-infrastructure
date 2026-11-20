# The one list of app and shared-service names on the server (#66). The DNS records (dns.tf), the
# SSM read paths (secrets.tf) and the outputs all derive from it, so adding an app is one edit here.
# The source is registry/projects.json in project-standards.
locals {
  registry = {
    # The registry `name` of every active app, which is also its subdomain.
    apps = ["workout-memo", "study-log", "health-log", "life-journal", "money-ledger", "cert-manager", "plan-routine", "dev-career-portfolio"]
    # Shared services (registry sharedServices) by subdomain. Each one's repo is shared-<subdomain>:
    # auth is sirloinbh/shared-auth (ADR-0015), ai is sirloinbh/shared-ai (ADR-0017).
    services = ["auth", "ai"]
  }

  # Apps and shared services whose own keys the server may read (secrets.tf): every app plus each
  # service's repo name (shared-auth, shared-ai).
  secret_apps = concat(local.registry.apps, [for service in local.registry.services : "shared-${service}"])
}
