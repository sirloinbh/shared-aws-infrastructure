# money-ledger (sirloinbh/money-ledger#314, #300).
#
# 1. The receipt photo bucket (#300): private, one server key, like the study-log files (files.tf).
# 2. The public door for the Kakao i Open Builder skill webhook (#314). Kakao's servers must reach
#    the skill over public HTTPS, but the server's firewall only lets allowed IPs in (main.tf) and
#    everything else in money-ledger is private. So the only public thing is a CloudFront
#    distribution whose viewer-request function lets exactly `POST /kakao/skill` through and answers
#    every other method and path with 404 at the edge, before any request reaches the server. The
#    app still answers nothing without its secret header and Kakao user ID allowlist
#    (money-ledger docs/kakao-webhook-access.md).

# --- 1. Receipt photos ---------------------------------------------------------------------------
# The app stores each photo under a key it chooses and reads and deletes it by key. The backup (#298)
# reads the same files with the same key. Versioning keeps a deleted or overwritten photo for
# var.app_file_recovery_days, as for the study-log files.
module "money_ledger_photos" {
  source     = "./modules/private_bucket"
  name       = "sirloinbh-money-ledger-photos-${data.aws_caller_identity.current.account_id}"
  tags       = local.tags
  depends_on = [terraform_data.account_guard]
  lifecycle_rule = {
    id                    = "expire-deleted-photos"
    noncurrent_days       = var.app_file_recovery_days
    expire_delete_markers = true
  }
}

# Get, put and delete photos, and list keys so a missing photo reads as NoSuchKey (not found)
# instead of AccessDenied. No bucket settings, so a leaked key cannot turn off versioning or delete
# earlier versions. Its access key is made in the console (docs/operations.md section 10).
resource "aws_iam_user" "money_ledger_photos" {
  name                 = "${local.shared_prefix}-money-ledger-photos"
  permissions_boundary = local.terraform_server_user_boundary
  tags                 = local.tags
  depends_on           = [terraform_data.account_guard]
}

resource "aws_iam_user_policy" "money_ledger_photos" {
  name = "money-ledger-photos"
  user = aws_iam_user.money_ledger_photos.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Objects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${module.money_ledger_photos.arn}/*"
      },
      {
        Sid      = "MissingIsNotFound"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = module.money_ledger_photos.arn
      },
    ]
  })
}

# --- 2. Kakao skill webhook ----------------------------------------------------------------------
# Edge: viewer request -> function (only POST /kakao/skill) -> origin money-ledger.<root_domain> on
# var.kakao_origin_port. Nothing is cached, and every viewer header (including the secret header
# x-kakao-skill-secret) is forwarded; the Host header is the origin's own, so the server proxy
# routes by name and its certificate (the wildcard one) matches.
resource "aws_cloudfront_function" "kakao_skill" {
  name       = "sirloinbh-money-ledger-kakao-skill"
  runtime    = "cloudfront-js-2.0"
  comment    = "Let only POST /kakao/skill through; every other method and path is a 404 at the edge"
  publish    = true
  code       = file("${path.module}/kakao-skill-edge.js")
  depends_on = [terraform_data.account_guard]
}

resource "aws_cloudfront_distribution" "kakao_skill" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "money-ledger Kakao skill webhook (only POST /kakao/skill)"
  http_version    = "http2"
  # North America, Europe, and Asia including Korea; Kakao calls from Korea.
  price_class = "PriceClass_200"
  tags        = { Project = "money-ledger-kakao" }

  origin {
    origin_id   = "money-ledger-api"
    domain_name = "money-ledger.${var.root_domain}"
    custom_origin_config {
      http_port              = 80
      https_port             = var.kakao_origin_port
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      # Kakao drops a skill answer after 5 seconds, so the app answers within 4.
      origin_read_timeout      = 10
      origin_keepalive_timeout = 5
    }
  }

  default_cache_behavior {
    target_origin_id       = "money-ledger-api"
    viewer_protocol_policy = "https-only"
    # POST needs the full method list; the function turns every method except POST into a 404.
    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]
    compress        = false
    # AWS managed "CachingDisabled" and "AllViewerExceptHostHeader".
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = "b689b0a8-53d0-42c2-a5f1-4e5a4cc2ab36"
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.kakao_skill.arn
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # The default *.cloudfront.net name and certificate: Open Builder takes any HTTPS URL, so no
  # extra certificate or DNS name is needed.
  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
