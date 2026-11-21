# Study notes wiki (sirloinbh/develop-skill#30, decision in its docs/wiki-site.md): a static site
# in a private S3 bucket, served by CloudFront at wiki.<root_domain>. A CloudFront function asks
# every request for one user name and password (HTTP basic authentication), so the site is not
# public although CloudFront has no IP allow list. The develop-skill workflow uploads the site
# with a role it assumes through GitHub's OpenID Connect (OIDC) token, so no AWS key is stored
# in GitHub.
locals {
  wiki_domain = "wiki.${var.root_domain}"
  wiki_tags   = { Project = "develop-skill-wiki" }
  wiki_origin = "wiki-s3"
}

# The site files. Everything in it is rebuilt from the notes on each deploy, so no versioning.
resource "aws_s3_bucket" "wiki" {
  bucket     = "sirloinbh-wiki-site-${data.aws_caller_identity.current.account_id}"
  tags       = local.wiki_tags
  depends_on = [terraform_data.account_guard]
}

resource "aws_s3_bucket_public_access_block" "wiki" {
  bucket                  = aws_s3_bucket.wiki.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "wiki" {
  bucket = aws_s3_bucket.wiki.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "wiki" {
  bucket = aws_s3_bucket.wiki.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "wiki" {
  bucket = aws_s3_bucket.wiki.id
  rule {
    id     = "abort-failed-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# Only this distribution may read the files, and only over HTTPS. The bucket has no public access.
resource "aws_s3_bucket_policy" "wiki" {
  bucket     = aws_s3_bucket.wiki.id
  depends_on = [aws_s3_bucket_public_access_block.wiki]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CloudFrontRead"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.wiki.arn}/*"
        Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.wiki.arn } }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.wiki.arn, "${aws_s3_bucket.wiki.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}

# CloudFront reads certificates only from us-east-1. Validation is one DNS record in the zone.
resource "aws_acm_certificate" "wiki" {
  provider          = aws.us_east_1
  domain_name       = local.wiki_domain
  validation_method = "DNS"
  tags              = local.wiki_tags
  depends_on        = [terraform_data.account_guard]
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "wiki_cert" {
  for_each = {
    for o in aws_acm_certificate.wiki.domain_validation_options : o.domain_name => o
  }
  zone_id         = data.aws_route53_zone.root.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  ttl             = 300
  records         = [each.value.resource_record_value]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "wiki" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.wiki.arn
  validation_record_fqdns = [for r in aws_route53_record.wiki_cert : r.fqdn]
}

resource "aws_cloudfront_origin_access_control" "wiki" {
  name                              = "sirloinbh-wiki-site"
  description                       = "CloudFront signs its requests to the wiki bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
  depends_on                        = [terraform_data.account_guard]
}

# Runs before the cache on every request: checks the password, then maps a folder address to its
# index.html (S3 behind CloudFront has no folder index). The code holds only a SHA-256 hash of
# the expected Authorization header, never the password.
resource "aws_cloudfront_function" "wiki" {
  name    = "sirloinbh-wiki-auth"
  runtime = "cloudfront-js-2.0"
  comment = "Basic authentication and index.html for the study notes wiki"
  publish = true
  code = templatefile("${path.module}/wiki-auth.js.tftpl", {
    auth_sha256 = var.wiki_auth_sha256
  })
  depends_on = [terraform_data.account_guard]
}

resource "aws_cloudfront_distribution" "wiki" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Study notes wiki (develop-skill)"
  aliases             = [local.wiki_domain]
  default_root_object = "index.html"
  http_version        = "http2and3"
  # North America, Europe, and Asia including Korea; the cheapest class that has a Seoul edge.
  price_class = "PriceClass_200"
  tags        = local.wiki_tags

  origin {
    origin_id                = local.wiki_origin
    domain_name              = aws_s3_bucket.wiki.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.wiki.id
  }

  default_cache_behavior {
    target_origin_id       = local.wiki_origin
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    # AWS managed policy "CachingOptimized": no cookies, headers, or query strings reach S3.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.wiki.arn
    }
  }

  # CloudFront may not list the bucket, so S3 answers a missing page with 403. Show it as 404.
  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 60
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.wiki.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

resource "aws_route53_record" "wiki" {
  for_each = toset(["A", "AAAA"])
  zone_id  = data.aws_route53_zone.root.zone_id
  name     = local.wiki_domain
  type     = each.key
  alias {
    name                   = aws_cloudfront_distribution.wiki.domain_name
    zone_id                = aws_cloudfront_distribution.wiki.hosted_zone_id
    evaluate_target_health = false
  }
}

# GitHub Actions proves which repository and branch a workflow runs for with a signed token.
# AWS trusts that token through this provider. An account can have only one provider per URL:
# if it already exists, import it instead of creating it (docs/operations.md section 12).
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = local.wiki_tags
  depends_on     = [terraform_data.account_guard]
}

# The deploy identity: only a workflow on the main branch of the notes repository can assume it.
# The subject uses the immutable form with owner and repository IDs (see var.wiki_oidc_subject_prefix),
# so a renamed or re-created repository with the same name cannot assume it.
resource "aws_iam_role" "wiki_deploy" {
  name                 = "sirloinbh-wiki-deploy"
  max_session_duration = 3600
  tags                 = local.wiki_tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "GitHubActionsMainBranch"
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "${var.wiki_oidc_subject_prefix}:ref:refs/heads/main"
        }
      }
    }]
  })
}

# Upload and delete the site files, and tell CloudFront to drop its cached copies. Nothing else.
resource "aws_iam_role_policy" "wiki_deploy" {
  name = "deploy-wiki-site"
  role = aws_iam_role.wiki_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListSiteFiles"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.wiki.arn
      },
      {
        Sid      = "WriteSiteFiles"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.wiki.arn}/*"
      },
      {
        Sid      = "RefreshCache"
        Effect   = "Allow"
        Action   = "cloudfront:CreateInvalidation"
        Resource = aws_cloudfront_distribution.wiki.arn
      },
    ]
  })
}
